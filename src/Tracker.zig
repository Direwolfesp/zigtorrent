//!
//!

pub const Response = struct {
    /// If present, then no other keys may be present
    failure_reason: ?[]const u8 = null,
    /// The response still gets processed normally. The warning message is shown just like an error.
    warning_message: ?[]const u8 = null,
    /// Seconds to wait between requests
    interval_s: u64,
    /// If present clients must not reannounce more frequently than this
    min_interval: ?u64 = null,
    /// seeders
    complete: u32,
    /// leechers
    incomplete: u32,
    /// Peers
    peers: bencode.Value,
};

const Status = enum(u8) {
    /// The first request to the tracker must include the event key with this value
    started,
    /// Must be sent to the tracker if the client is shutting down gracefully
    stopped,
    /// Must be sent to the tracker when the download completes. However, must
    ///not be sent if the download was already 100% complete when the client started.
    completed,
    /// After contacting to the tracker, we switch to here.
    /// This doesnt get send in the event field in the request.
    in_progress,
};

const Tracker = @This();

/// tracker state that is used across responses
announce_url: []const u8,
/// from the metainfo bencoded dictionary
info_hash: [20]u8 = undefined,
/// Generated once at start-up
peer_id: [20]u8 = undefined, // -[2chars][4digits]-[20chars]
/// state is null before contacting to tracker
state: ?Status = null,
/// where this client is listening on, typically 6881-6889
port: u16 = 6881,
/// Bytes uploaded since the started event.
uploaded: u64 = 0,
/// Bytes downloaded since the started event.
downloaded: u64 = 0,
/// Bytes this client still has to download.
left: u64,
/// Indicates that the client accepts binary format response
compact: bool = true,
/// Store last response for quick access
last_response: ?Response = null,
/// If present, must be reused for consecutive connections
tracker_id: ?[]const u8 = null,

pub fn init(torr: *const TorrentFile) !Tracker {
    return .{
        .announce_url = torr.announce,
        .info_hash = torr.info_hash,
        .peer_id = try genPeerId(),
        .left = @intCast(torr.calculateDownloadSize()),
    };
}

fn formatEvent(self: *const Tracker) []const u8 {
    if (self.state == null) return "";

    return switch (self.state.?) {
        .completed => "&event=" ++ @tagName(Status.completed),
        .started => "&event=" ++ @tagName(Status.started),
        .stopped => "&event=" ++ @tagName(Status.stopped),
        .in_progress => "",
    };
}

pub fn announce(self: *const Tracker, alloc: std.mem.Allocator) !void {
    const hash_comp = std.Uri.Component{ .raw = &self.info_hash };
    const info_hash = try std.fmt.allocPrint(alloc, "{f}", .{std.fmt.alt(hash_comp, .formatEscaped)});
    defer alloc.free(info_hash);

    const peer_id_comp = std.Uri.Component{ .raw = &self.peer_id };
    const peer_id = try std.fmt.allocPrint(alloc, "{f}", .{std.fmt.alt(peer_id_comp, .formatEscaped)});
    defer alloc.free(peer_id);

    const trackerid: []const u8 = if (self.tracker_id) |tracker_id|
        try std.fmt.allocPrint(alloc, "&trackerid={s}", .{tracker_id})
    else
        "";
    defer if (trackerid.len != 0) alloc.free(trackerid);

    const url = try std.fmt.allocPrint(alloc, "{s}?" ++
        "info_hash={s}" ++ "&peer_id={s}" ++
        "&port={d}" ++ "&uploaded={d}" ++
        "&downloaded={d}" ++ "&left={d}" ++
        "&compact={d}" ++
        "{s}" ++ // trackerid
        "{s}", // event
        .{
            self.announce_url,
            info_hash,
            peer_id,
            self.port,
            self.uploaded,
            self.downloaded,
            self.left,
            @intFromBool(self.compact),
            trackerid,
            self.formatEvent(),
        });
    defer alloc.free(url);

    const uri = try std.Uri.parse(url);

    var client = std.http.Client{ .allocator = alloc };
    defer client.deinit();

    const server_header_buff: []u8 = try alloc.alloc(u8, 1024);
    defer alloc.free(server_header_buff);

    var res_alloc: std.Io.Writer.Allocating = try .initCapacity(alloc, 1000);
    defer res_alloc.deinit();
    const res_writer: *std.Io.Writer = &res_alloc.writer;

    const res = client.fetch(.{
        .method = .GET,
        .location = .{ .uri = uri },
        .response_writer = res_writer,
    }) catch |err| {
        log.err("Could not stablish a connection with the tracker. Error: {t}", .{err});
        return Error.NetworkFailure;
    };

    if (res.status != .ok) {
        log.err("Tracker response error: {t}", .{res.status});
        return Error.NetworkFailure;
    }

    std.debug.assert(res_writer.buffered().len != 0);
    var body = try bencode.decodeBencode(alloc, res_writer.buffered());
    defer body.deinit(alloc);
    std.debug.assert(body == .dict);

    const body_dict = &body.dict;
    if (body_dict.get("failure reason")) |reason| {
        std.debug.assert(reason == .string);
        log.err("Failure reason: {s}", .{reason.string});
        return Error.ResponseFailure;
    }

    if (body_dict.get("warning message")) |warning| {
        std.debug.assert(warning == .string);
        log.warn("Warning: {s}", .{warning.string});
    }

    const peers = body_dict.get("peers") orelse {
        log.warn("Tracker did not respond with any peers.", .{});
        return Error.MissingPeers;
    };

    const parsed_peers: []std.net.Ip4Address = switch (peers) {
        .string => |str| try parsePeersBinary(alloc, str),
        .list => |list| try parsePeersDict(alloc, &list),
        else => unreachable,
    };
    defer alloc.free(parsed_peers);

    log.debug("Peer count: {d}", .{parsed_peers.len});
    for (parsed_peers) |p| {
        log.debug("{f}", .{p});
    }

    // TODO: keep parsing the response and store it in self
    log.info("tracker response success", .{});
}

pub fn onDownload(self: *const Tracker, bytes: i64) void {
    self.downloaded += bytes;
    self.left -|= bytes;

    if (self.left == 0 and self.state.? == .in_progress) {
        self.state = .completed;
        log.info("Downloaded completed. State = completed", .{});
    }
}

const Error = error{
    NetworkFailure,
    ResponseFailure,
    MissingPeers,
};

const ParseError = error{
    PeersNotFound,
    InvalidIpFormat,
    WrongPeerCount,
    MissingIp,
    MissingPort,
} || error{OutOfMemory};

/// Parses peers from a torrent in dictionary form and returns the ips
/// Caller owns the returned memory
fn parsePeersDict(
    allocator: std.mem.Allocator,
    data: *const std.ArrayList(bencode.Value),
) ParseError![]std.net.Ip4Address {
    var peers: std.ArrayList(std.net.Ip4Address) = try .initCapacity(allocator, data.items.len);
    errdefer peers.deinit(allocator);

    for (data.items) |d| {
        if (d != .dict) return ParseError.InvalidIpFormat;
        const dict = &d.dict;
        const ip = dict.get("ip") orelse return ParseError.MissingIp;
        const port = dict.get("port") orelse return ParseError.MissingPort;
        const addr = std.net.Address.resolveIp(ip.string, @intCast(port.integer)) catch
            return ParseError.InvalidIpFormat;
        peers.appendAssumeCapacity(addr.in);
    }

    return peers.items;
}

/// Parses peer IPs in binary form
/// Caller owns the returned memory
fn parsePeersBinary(
    allocator: std.mem.Allocator,
    data: []const u8,
) ParseError![]std.net.Ip4Address {
    if (data.len % 6 != 0) return ParseError.WrongPeerCount;
    var peers: std.ArrayList(std.net.Ip4Address) = try .initCapacity(allocator, data.len / 6);
    errdefer peers.deinit(allocator);

    var i: usize = 0;
    while (i + 5 < data.len) : (i += 6) {
        const port: u16 = std.mem.readInt(u16, data[i + 4 .. i + 6][0..2], .big);
        const ip: [4]u8 = data[i .. i + 4][0..4].*;
        const address = std.net.Address.initIp4(ip, port);
        peers.appendAssumeCapacity(address.in);
    }

    return peers.items;
}

/// Generates a random peer id based on pid
/// format: -[2chars][4digits]-[20chars]
fn genPeerId() std.fmt.BufPrintError![20]u8 {
    var id: [20]u8 = undefined;
    const pid: u32 = @intCast(std.os.linux.getpid());
    const short_pid = @mod(pid, 10_000);

    const seed: u64 = @intCast(pid * 4);
    var sfc = std.Random.Sfc64.init(seed);
    const random = sfc.random();

    _ = try std.fmt.bufPrint(id[0..8], "-PE{d:0>4}-", .{short_pid});
    inline for (8..20) |i|
        id[i] = random.intRangeAtMost(u8, 32, 126);

    return id;
}

test "tracker: generate peer id" {
    // -[2chars][4digits]-[20chars]
    const id = try genPeerId();

    inline for (0..20) |i| {
        switch (i) {
            0 => try testing.expect(id[i] == '-'),
            1...2 => try testing.expect(ascii.isAlphabetic(id[i])),
            3...6 => try testing.expect(ascii.isDigit(id[i])),
            7 => try testing.expect(id[i] == '-'),
            8...19 => try testing.expect(ascii.isPrint(id[i])),
            else => unreachable,
        }
    }
}

const log = std.log.scoped(.tracker);

const std = @import("std");
const testing = std.testing;
const ascii = std.ascii;

const bencode = @import("bencode.zig");
const TorrentFile = @import("TorrentFile.zig");
