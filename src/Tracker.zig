const std = @import("std");
const Allocator = std.mem.Allocator;
const Ip4Address = std.net.Ip4Address;
const stdout = std.io.getStdOut().writer();
const stderr = std.io.getStdErr().writer();

const Bencode = @import("Bencode.zig");
const MetaInfo = @import("Torrent.zig").MetaInfo;
const Peer = @import("Peer.zig");

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
    pub fn toURI(self: *const @This(), query: *std.ArrayList(u8), allocator: Allocator) !std.Uri {
        const hsh = try std.fmt.allocPrint(allocator, "{%}", .{std.Uri.Component{ .raw = &self.info_hash }});
        defer allocator.free(hsh);

        const url = try std.fmt.allocPrint(allocator, "{s}?" ++
            "info_hash={s}" ++
            "&peer_id={s}" ++
            "&port={d}" ++
            "&uploaded={d}" ++
            "&downloaded={d}" ++
            "&left={d}" ++
            "&compact={d}", .{
            self.announce,
            hsh,
            self.peer_id,
            self.port,
            self.uploaded,
            self.downloaded,
            self.left,
            self.compact,
        });
        defer allocator.free(url);
        try query.appendSlice(url);

        return try std.Uri.parse(try query.toOwnedSlice());
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
fn getResponse(allocator: std.mem.Allocator, meta: *const MetaInfo) !Bencode.ValueManaged {
    // MetaInfo -> RequestParams -> Response

    // request Params and create URI
    var req_params = createRequest(meta);
    var queryBuf = std.ArrayList(u8).init(allocator);
    defer queryBuf.deinit();
    const uri: std.Uri = try req_params.toURI(&queryBuf, allocator);

    // create client
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    // header buffer
    const server_header_buff: []u8 = try allocator.alloc(u8, 1024);
    defer allocator.free(server_header_buff);

    var req: std.http.Client.Request = try client.open(
        .GET,
        uri,
        .{ .server_header_buffer = server_header_buff },
    );
    defer req.deinit();

    // make request
    try req.send();
    try req.finish();
    try stdout.print("tracker response: ⏳️", .{});
    try req.wait();
    if (req.response.status != .ok)
        return error.RequestFailed;

    try stdout.print("\rtracker response: ✔️\n", .{});

    // read the bencoded response body
    const body: []u8 = try req.reader().readAllAlloc(allocator, std.math.maxInt(usize));
    const response: Bencode.Value = try Bencode.decodeBencode(allocator, body);

    if (response.dict.get("failure reason")) |failure| {
        try stderr.print("Failed to connect to tracker, Error: {s}\n", .{failure.string});
        return error.TrackerError;
    }

    return .{
        .backing_buffer = body,
        .value = response,
    };
}

/// Parses the peer ips from the response of the tracker.
/// Caller owns the returned memory.
pub fn getPeersFromResponse(allocator: std.mem.Allocator, meta: *const MetaInfo) ![]Ip4Address {
    var resp_managed = try getResponse(allocator, meta);
    defer resp_managed.deinit(allocator);

    const peer: Bencode.Value = resp_managed.value.dict.get("peers") orelse
        return error.PeersNotFound;

    return switch (peer) {
        .string => |str| try Peer.parsePeersBinary(allocator, str),
        .list => |list| try Peer.parsePeersDict(allocator, &list),
        else => error.InvalidPeers,
    };
}
