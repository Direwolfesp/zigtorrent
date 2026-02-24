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

    /// Construct query params in encoded URI
    pub fn toURI(self: *const @This(), gpa: Allocator, query: *std.ArrayList(u8)) !std.Uri {
        const hash_comp = std.Uri.Component{ .raw = &self.info_hash };
        const info_hash = try std.fmt.allocPrint(gpa, "{f}", .{std.fmt.alt(hash_comp, .formatEscaped)});
        defer gpa.free(info_hash);

        const url = try std.fmt.allocPrint(gpa, "{s}?" ++
            "info_hash={s}" ++
            "&peer_id={s}" ++
            "&port={d}" ++
            "&uploaded={d}" ++
            "&downloaded={d}" ++
            "&left={d}" ++
            "&compact={d}", .{
            self.announce,
            info_hash,
            self.peer_id,
            self.port,
            self.uploaded,
            self.downloaded,
            self.left,
            self.compact,
        });
        defer gpa.free(url);

        try query.appendSlice(gpa, url);

        return try std.Uri.parse(url);
    }
};

/// constructs a request based on metainfo
fn createRequest(meta: *const MetaInfo) RequestParams {
    return RequestParams{
        .info_hash = meta.info_hash,
        .left = meta.info.length,
        .announce = meta.announce,
    };
}

/// Makes a request to the tracker listed in the metainfo
/// and returns the `Bencode.ValueManaged` response.
/// -> `meta` is the MetaInfo struct from the file
/// -> `allocator` caller owns the returned memory.
fn getResponse(io: Io, gpa: Allocator, meta: *const MetaInfo) !bencode.Value {
    var req_params = createRequest(meta);
    var queryBuf: std.ArrayList(u8) = .empty;
    defer queryBuf.deinit(gpa);
    const uri: std.Uri = try req_params.toURI(gpa, &queryBuf);

    // create client
    var client = std.http.Client{ .allocator = gpa, .io = io };
    defer client.deinit();

    var res_alloc: std.Io.Writer.Allocating = try .initCapacity(gpa, 1000);
    defer res_alloc.deinit();
    const res_writer: *std.Io.Writer = &res_alloc.writer;

    var res = client.fetch(.{
        .method = .GET,
        .location = .{ .uri = uri },
        .response_writer = res_writer,
    }) catch |err| {
        log.err("Could not stablish a connection with the tracker. Error: {t}", .{err});
        return error.NetworkFailure;
    };

    if (res.status != .ok) {
        log.err("Tracker response error: {t}", .{res.status});
        return error.NetworkFailure;
    }

    std.debug.assert(res_writer.buffered().len != 0);
    const body = try bencode.decodeBencode(gpa, res_writer.buffered());
    return body;
}

/// Parses the peer ips from the response of the tracker.
/// Caller owns the returned memory.
pub fn getPeersFromResponse(io: Io, gpa: std.mem.Allocator, meta: *const MetaInfo) ![]Ip4Address {
    var response = try getResponse(io, gpa, meta);
    defer response.deinit(gpa);

    const peer: bencode.Value = response.dict.get("peers") orelse
        return error.PeersNotFound;

    return switch (peer) {
        .string => |str| try Peer.parsePeersBinary(gpa, str),
        .list => |list| try Peer.parsePeersDict(gpa, &list),
        else => error.InvalidPeers,
    };
}
