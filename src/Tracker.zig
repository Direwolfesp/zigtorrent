const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Ip4Address = std.Io.net.Ip4Address;

const bencode = @import("bencode.zig");
const MetaInfo = @import("Torrent.zig").MetaInfo;
const Peer = @import("Peer.zig");

const log = std.log.scoped(.tracker);

pub const RequestParams = struct {
    announce: []const u8 = undefined,
    info_hash: [20]u8 = undefined,
    peer_id: *const [20:0]u8 = "-qB6666-weoiuv8324ns",
    port: u16 = 6881,
    uploaded: i65 = 0,
    downloaded: i64 = 0,
    left: i64 = undefined,
    compact: u8 = 1,

    /// constructs a request based on metainfo
    fn init(meta: *const MetaInfo) RequestParams {
        return RequestParams{
            .info_hash = meta.info_hash,
            .left = meta.info.length,
            .announce = meta.announce,
        };
    }

    /// Construct query params in encoded URI
    /// buf should be big enough to hold >= 512 Bytes aprox
    pub fn toUri(self: *const RequestParams, buf: []u8) !std.Uri {
        const hash = std.Uri.Component{ .raw = &self.info_hash };
        const peer_id = std.Uri.Component{ .raw = self.peer_id };

        const url = try std.fmt.bufPrint(buf, "{s}?" ++
            "info_hash={f}" ++ "&peer_id={f}" ++
            "&port={d}" ++ "&uploaded={d}" ++
            "&downloaded={d}" ++ "&left={d}" ++
            "&compact={d}", .{
            self.announce,
            std.fmt.alt(hash, .formatEscaped),
            std.fmt.alt(peer_id, .formatEscaped),
            self.port,
            self.uploaded,
            self.downloaded,
            self.left,
            self.compact,
        });

        return try std.Uri.parse(url);
    }
};

/// Makes a request to the tracker listed in the metainfo
/// and returns the bencode response.
/// Caller owns the returned memory.
fn getAnnounce(io: Io, gpa: Allocator, meta: *const MetaInfo) !bencode.Value {
    var client = std.http.Client{ .allocator = gpa, .io = io };
    defer client.deinit();

    var response_writer: std.Io.Writer.Allocating = try .initCapacity(gpa, 1000);
    defer response_writer.deinit();

    var req_params: RequestParams = .init(meta);
    var uri_buf: [1024]u8 = undefined;
    const uri: std.Uri = try req_params.toUri(&uri_buf);

    log.info("Contacting tracker", .{});

    const res = client.fetch(.{
        .method = .GET,
        .location = .{ .uri = uri },
        .response_writer = &response_writer.writer,
    }) catch |err| {
        log.err("Could not stablish a connection with the tracker. Error: {t}", .{err});
        return error.NetworkFailure;
    };

    if (res.status != .ok) {
        log.err("Tracker response error: {t}", .{res.status});
        return error.NetworkFailure;
    }

    log.info("Tracker response ok", .{});
    std.debug.assert(response_writer.written().len != 0);
    const body = try bencode.decodeBencode(gpa, response_writer.written());
    return body;
}

/// Parses the peer ips from the response of the tracker.
/// Caller owns the returned memory.
pub fn getPeersFromResponse(io: Io, gpa: Allocator, meta: *const MetaInfo) ![]Ip4Address {
    var response = try getAnnounce(io, gpa, meta);
    defer response.deinit(gpa);

    if (response.dict.get("failure reason")) |f| switch (f) {
        .string => |str| {
            log.err("tracker failure: {s}", .{str});
            return error.TrackerFailure;
        },
        else => {},
    };

    const peer: bencode.Value = response.dict.get("peers") orelse
        return error.PeersNotFound;

    return switch (peer) {
        .string => |str| try Peer.parsePeersBinary(gpa, str),
        .list => |list| try Peer.parsePeersDict(gpa, &list),
        else => error.InvalidPeerFormat,
    };
}
