const std = @import("std");
const Allocator = std.mem.Allocator;
const Ip4Address = std.net.Ip4Address;
const stdout = std.io.getStdOut().writer();

const Bencode = @import("Bencode.zig");
const MetaInfo = @import("MetaInfo.zig").MetaInfo;

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
    pub fn toURI(self: @This(), query: *std.ArrayList(u8), allocator: Allocator) !std.Uri {
        try query.appendSlice(self.announce);
        try query.append('?');

        try query.appendSlice("info_hash=");
        const hsh = try std.fmt.allocPrint(allocator, "{%}", .{
            std.Uri.Component{ .raw = &self.info_hash },
        });
        try query.appendSlice(hsh);
        defer allocator.free(hsh);

        try query.appendSlice("&peer_id=");
        try query.appendSlice(self.peer_id);

        try query.appendSlice("&port=");
        const prt = try std.fmt.allocPrint(allocator, "{d}", .{self.port});
        try query.appendSlice(prt);
        defer allocator.free(prt);

        try query.appendSlice("&uploaded=");
        const up = try std.fmt.allocPrint(allocator, "{d}", .{self.uploaded});
        try query.appendSlice(up);
        defer allocator.free(up);

        try query.appendSlice("&downloaded=");
        const dl = try std.fmt.allocPrint(allocator, "{d}", .{self.downloaded});
        try query.appendSlice(dl);
        defer allocator.free(dl);

        try query.appendSlice("&left=");
        const lft = try std.fmt.allocPrint(allocator, "{d}", .{self.left});
        try query.appendSlice(lft);
        defer allocator.free(lft);

        try query.appendSlice("&compact=");
        const cmpct = try std.fmt.allocPrint(allocator, "{d}", .{self.compact});
        try query.appendSlice(cmpct);
        defer allocator.free(cmpct);

        return try std.Uri.parse(query.items);
    }
};

/// constructs a request based on metainfo
pub fn createRequest(meta: MetaInfo) RequestParams {
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
pub fn getResponse(allocator: std.mem.Allocator, meta: MetaInfo) !Bencode.ValueManaged {
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
    try req.wait();
    if (req.response.status != .ok)
        return error.RequestFailed;

    // read the bencoded response body
    const body: []u8 = try req.reader().readAllAlloc(allocator, std.math.maxInt(usize));
    const bodyDecoded: Bencode.Value = try Bencode.decodeBencode(allocator, body);

    return .{
        .backing_buffer = body,
        .value = bodyDecoded,
    };
}

/// Parses the peer ips from the response of the tracker.
/// Caller owns the returned memory.
pub fn getPeersFromResponse(allocator: std.mem.Allocator, response: Bencode.Value) ![]Ip4Address {
    const data_opt: ?[]const u8 = blk: {
        const peer: Bencode.Value = response.dict.get("peers") orelse return error.PeersNotFound;
        switch (peer) {
            .string => |str| break :blk str,
            else => break :blk null,
        }
    };

    // Data could be null or could be incomplete.
    // Each address is 6 bytes.
    if (data_opt) |data| {
        if (data.len % 6 != 0) return error.InvalidPeers;
        var peers = std.ArrayList(Ip4Address).init(allocator);
        defer peers.deinit();

        var i: usize = 0;
        while (i + 5 < data.len) : (i += 6) {
            const ip: []const u8 = data[i .. i + 4];
            const port: u16 = std.mem.readInt(u16, data[i + 4 .. i + 6][0..2], .big);
            const ip_fmt = try std.fmt.allocPrint(allocator, "{}.{}.{}.{}", .{
                ip[0],
                ip[1],
                ip[2],
                ip[3],
            });
            defer allocator.free(ip_fmt);
            const addr = try std.net.Address.resolveIp(ip_fmt, port);
            try peers.append(addr.in);
        }
        return peers.toOwnedSlice();
    }
    return error.InvalidPeers;
}
