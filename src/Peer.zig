const std = @import("std");
const MetaInfo = @import("MetaInfo.zig").MetaInfo;

pub const HandShake = struct {
    pstrlen: u8 = 19,
    pstr: [19]u8 = "BitTorrent protocol".*,
    reserved: [8]u8 = std.mem.zeroes([8]u8),
    info_hash: [20]u8 = undefined,
    peer_id: [20]u8 = "-qB6666-weoiuv8324ns".*,

    pub fn createFromMeta(meta: MetaInfo) HandShake {
        return HandShake{
            .info_hash = meta.info_hash,
        };
    }

    // (49+len(pstr)) bytes long
    pub fn createFromBuffer(info: []u8) HandShake {
        std.debug.assert(info.len == 49 + 19);
        return HandShake{
            .pstrlen = info[0],
            .pstr = info[1..20].*,
            .reserved = info[20..28].*,
            .info_hash = info[28..48].*,
            .peer_id = info[48..68].*,
        };
    }

    pub fn dumpToWriter(self: @This(), writer: anytype) !void {
        try writer.print("{c}{s}{s}{s}{s}", .{
            self.pstrlen,
            self.pstr,
            self.reserved,
            self.info_hash,
            self.peer_id,
        });
    }
};
