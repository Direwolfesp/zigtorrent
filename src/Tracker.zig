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
left: i64,
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
        .left = try torr.calculateDownloadSize(),
    };
}

pub fn announce() !void {
    @panic("Unimplemented function stub\n");
}

const Error = error{
    NetworkFailure,
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
