const std = @import("std");
const Bencode = @import("Bencode.zig");
const MetaInfo = @import("MetaInfo.zig").MetaInfo;
const stdout = std.io.getStdOut().writer();

pub const RequestParams = struct {
    announce: []const u8 = undefined,
    info_hash: [20]u8 = undefined,
    peer_id: *const [20:0]u8 = "-qB6666-weoiuv8324ns",
    port: u16 = 6881,
    uploaded: i65 = 0,
    downloaded: i64 = 0,
    left: i64 = undefined,
    compact: u8 = 1,

    // construct query params in encoded URI
    pub fn toURI(self: @This(), query: *std.ArrayList(u8), allocator: std.mem.Allocator) !std.Uri {
        try query.appendSlice(self.announce);
        try query.append('?');

        try query.appendSlice("info_hash=");
        const hsh = try std.fmt.allocPrint(
            allocator,
            "{%}",
            .{std.Uri.Component{ .raw = &self.info_hash }},
        );
        try query.appendSlice(hsh);
        defer allocator.free(hsh);

        try query.appendSlice("&peer_id=");
        try query.appendSlice(self.peer_id);

        try query.appendSlice("&port=");
        const prt = try std.fmt.allocPrint(
            allocator,
            "{d}",
            .{self.port},
        );
        try query.appendSlice(prt);
        defer allocator.free(prt);

        try query.appendSlice("&uploaded=");
        const up = try std.fmt.allocPrint(
            allocator,
            "{d}",
            .{self.uploaded},
        );
        try query.appendSlice(up);
        defer allocator.free(up);

        try query.appendSlice("&downloaded=");
        const dl = try std.fmt.allocPrint(
            allocator,
            "{d}",
            .{self.downloaded},
        );
        try query.appendSlice(dl);
        defer allocator.free(dl);

        try query.appendSlice("&left=");
        const lft = try std.fmt.allocPrint(
            allocator,
            "{d}",
            .{self.left},
        );
        try query.appendSlice(lft);
        defer allocator.free(lft);

        try query.appendSlice("&compact=");
        const cmpct = try std.fmt.allocPrint(
            allocator,
            "{d}",
            .{self.compact},
        );
        try query.appendSlice(cmpct);
        defer allocator.free(cmpct);

        return try std.Uri.parse(query.items);
    }
};

// constructs a request based on metainfo
pub fn create(meta: MetaInfo) !RequestParams {
    return RequestParams{
        .info_hash = meta.info_hash,
        .left = meta.info.length,
        .announce = meta.announce,
    };
}
