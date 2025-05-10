const std = @import("std");
const Allocator = std.mem.Allocator;
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
    pub fn createFromBuffer(buffer: []u8) HandShake {
        return HandShake{
            .pstrlen = buffer[0],
            .pstr = buffer[1..20].*,
            .reserved = buffer[20..28].*,
            .info_hash = buffer[28..48].*,
            .peer_id = buffer[48..68].*,
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

test "createhandshake" {
    // TODO
    // Test converting bytes to HandShake and
    // viceversa
}

const MessageID = enum(u8) {
    Choke = 0,
    Unchoke,
    Interested,
    NotInterested,
    Have,
    Bitfield,
    Request,
    Piece,
    Cancel,
};

pub const Message = struct {
    msg_id: MessageID,
    payload: []const u8,

    // Serialized the message to a slice
    // format: <id+payload len:u32><msg_id:u8><payload:[]u8>
    // Result must be freed!
    pub fn serialize(self: @This(), allocator: Allocator) ![]u8 {
        var buff = try allocator.alloc(u8, self.payload.len + 4 + 1);

        const size: u32 = @intCast(self.payload.len + 1);
        buff[0..4].* = @bitCast(size);
        buff[4] = @bitCast(@intFromEnum(self.msg_id));
        @memcpy(buff[5..], self.payload);

        return buff;
    }
};

// Returns a valid message from a buffer
// Used to parse peers payloads
pub fn createMessage(buff: []const u8) MessageError!Message {
    if (buff.len <= 5) return MessageError.InvalidMessageSize;
    const payld_len: u32 = @bitCast(buff[0..4].*);
    return .{
        .msg_id = @enumFromInt(buff[4]),
        .payload = buff[5..payld_len],
    };
}

const MessageError = error{
    InvalidMessageSize,
};

test "message size" {
    const t = std.testing;
    var debug = std.heap.DebugAllocator(.{}){};
    const alloc = debug.allocator();

    var msg: Message = .{ .msg_id = .Choke, .payload = "HELLO" };
    const res = try msg.serialize(alloc);
    defer alloc.free(res);

    var msg2: Message = .{ .msg_id = .NotInterested, .payload = "LongerString" };
    const res2 = try msg2.serialize(alloc);
    defer alloc.free(res2);

    try t.expectEqual(res.len, 4 + 1 + 5); // length is 10 bytes
    try t.expectEqual(res2.len, 4 + 1 + 12); // length is 17 bytes
}
