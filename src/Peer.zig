const std = @import("std");
const stdout = std.io.getStdOut().writer();
const Allocator = std.mem.Allocator;
const MetaInfo = @import("MetaInfo.zig").MetaInfo;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;
const activeTag = std.meta.activeTag;
const intToEnum = std.meta.intToEnum;
const readInt = std.mem.readInt;

//-----------------------------------------------------------------------------
// BitTorrent Peer Messaging:
// https://wiki.theory.org/BitTorrentSpecification#Peer_wire_protocol_.28TCP.29
//-----------------------------------------------------------------------------

pub const HandShake = extern struct {
    // layout matters
    pstrlen: u8 align(1) = 19,
    pstr: [19]u8 align(1) = "BitTorrent protocol".*,
    reserved: [8]u8 align(1) = std.mem.zeroes([8]u8),
    info_hash: [20]u8 align(1) = undefined,
    peer_id: [20]u8 align(1) = "-qB6666-weoiuv8324ns".*,

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
};

const MessageID = enum(u8) {
    Choke = 0,
    Unchoke = 1,
    Interested,
    NotInterested,
    Have,
    Bitfield,
    Request,
    Piece,
    Cancel,
};

/// Message memory layout: |`message_len`(4bytes)|`messageid`(1byte)|`payload`(any)|
/// message_len = @sizeof(messageid) + @sizeof(payload).
pub const Message = union(enum) {
    const Self = @This();

    keep_alive: void, // no id, len = 0
    choke: void,
    unchoke: void,
    interested: void,
    not_interested: void,
    bitfield: []const u8,

    have: struct {
        piece_index: u32,
    },
    piece: struct {
        index: u32,
        begin: u32,
        block: []const u8, // usually 2^14 bytes
    },
    request: struct {
        index: u32,
        begin: u32,
        length: u32,
    },
    cancel: struct {
        index: u32,
        begin: u32,
        length: u32,
    },

    /// Creates a message from a given buffer.
    /// Caller does not own the returned memory.
    /// Message memory layout: |`message_len`(4bytes)|`messageid`(1byte)|`payload`(any)|
    pub fn init(buff: []const u8) !Self {
        const len: u32 = readInt(u32, buff[0..4], .big);
        return switch (len) {
            0 => .keep_alive,
            1 => {
                const msg_id = try intToEnum(MessageID, buff[4]);
                return switch (msg_id) {
                    .Choke => .choke,
                    .Unchoke => .unchoke,
                    .Interested => .interested,
                    .NotInterested => .not_interested,
                    else => MessageError.UnexpectedId,
                };
            },
            5 => {
                const msg_id = try intToEnum(MessageID, buff[4]);
                return switch (msg_id) {
                    .Have => .{ .have = .{ .piece_index = readInt(u32, buff[5..9], .big) } },
                    else => MessageError.UnexpectedId,
                };
            },
            13 => {
                const msg_id = try intToEnum(MessageID, buff[4]);
                return switch (msg_id) {
                    .Request => .{
                        .request = .{
                            .index = readInt(u32, buff[5..9], .big),
                            .begin = readInt(u32, buff[9..13], .big),
                            .length = readInt(u32, buff[13..17], .big),
                        },
                    },
                    .Cancel => .{
                        .cancel = .{
                            .index = readInt(u32, buff[5..9], .big),
                            .begin = readInt(u32, buff[9..13], .big),
                            .length = readInt(u32, buff[13..17], .big),
                        },
                    },
                    else => MessageError.UnexpectedId,
                };
            },
            else => {
                const msg_id = try intToEnum(MessageID, buff[4]);
                return switch (msg_id) {
                    .Bitfield => .{
                        .bitfield = buff[5 .. 5 + len - 1],
                    },
                    .Piece => .{
                        .piece = .{
                            .index = readInt(u32, buff[5..9], .big),
                            .begin = readInt(u32, buff[9..13], .big),
                            .block = buff[13 .. 13 + len - 9],
                        },
                    },
                    else => MessageError.UnexpectedId,
                };
            },
        };
    }

    /// little hack to cast usize to u32 :3
    pub fn @"u32"(x: usize) u32 {
        return @intCast(x);
    }

    /// Dumps the message to a designated writer
    /// using the accoding memory layout
    pub fn write(self: Self, writer: anytype) !void {
        switch (self) {
            .keep_alive => {
                try writer.writeInt(u32, 0, .big);
            },
            .choke => {
                try writer.writeInt(u32, 1, .big);
                try writer.writeByte(@intFromEnum(MessageID.Choke));
            },
            .unchoke => {
                try writer.writeInt(u32, 1, .big);
                try writer.writeByte(@intFromEnum(MessageID.Unchoke));
            },
            .interested => {
                try writer.writeInt(u32, 1, .big);
                try writer.writeByte(@intFromEnum(MessageID.Interested));
            },
            .not_interested => {
                try writer.writeInt(u32, 1, .big);
                try writer.writeByte(@intFromEnum(MessageID.NotInterested));
            },
            .bitfield => |slice| {
                try writer.writeInt(u32, @"u32"(slice.len) + 1, .big);
                try writer.writeByte(@intFromEnum(MessageID.Bitfield));
                try writer.writeAll(slice);
            },
            .have => |have| {
                try writer.writeInt(u32, 5, .big);
                try writer.writeByte(@intFromEnum(MessageID.Have));
                try writer.writeInt(u32, have.piece_index, .big);
            },
            .piece => |piece| {
                try writer.writeInt(u32, 9 + @"u32"(piece.block.len), .big);
                try writer.writeByte(@intFromEnum(MessageID.Piece));
                try writer.writeInt(u32, piece.index, .big);
                try writer.writeInt(u32, piece.begin, .big);
                try writer.writeAll(piece.block);
            },
            .request => |request| {
                try writer.writeInt(u32, 13, .big);
                try writer.writeByte(@intFromEnum(MessageID.Request));
                try writer.writeInt(u32, request.index, .big);
                try writer.writeInt(u32, request.begin, .big);
                try writer.writeInt(u32, request.length, .big);
            },
            .cancel => |cancel| {
                try writer.writeInt(u32, 13, .big);
                try writer.writeByte(@intFromEnum(MessageID.Cancel));
                try writer.writeInt(u32, cancel.index, .big);
                try writer.writeInt(u32, cancel.begin, .big);
                try writer.writeInt(u32, cancel.length, .big);
            },
        }
    }
};

const MessageError = error{
    UnexpectedId,
};

test "message init" {
    {
        const buf = [_]u8{ 0, 0, 0, 0 };
        const msg = try Message.init(&buf);
        try expectEqual(.keep_alive, std.meta.activeTag(msg));
    }
    {
        const buf = [_]u8{ 0, 0, 0, 1, 0 };
        const msg = try Message.init(&buf);
        try expectEqual(.choke, std.meta.activeTag(msg));
    }
    {
        const buf = [_]u8{ 0, 0, 0, 1, 1 };
        const msg = try Message.init(&buf);
        try expectEqual(.unchoke, std.meta.activeTag(msg));
    }
    {
        const buf = [_]u8{ 0, 0, 0, 1, 2 };
        const msg = try Message.init(&buf);
        try expectEqual(.interested, std.meta.activeTag(msg));
    }
    {
        const buf = [_]u8{ 0, 0, 0, 1, 3 };
        const msg = try Message.init(&buf);
        try expectEqual(.not_interested, std.meta.activeTag(msg));
    }
    {
        const buf = [_]u8{ 0, 0, 0, 5, 4, 0, 0, 0, 222 };
        const msg = try Message.init(&buf);
        try expectEqual(.have, std.meta.activeTag(msg));
        try expectEqual(222, msg.have.piece_index);
    }
    {
        const buf = [_]u8{
            0, 0, 0, 13,
            6,
            0, 0, 4, 101, // index = 1125
            0, 0, 11, 165, // begin = 2981
            0, 0, 64, 164, // length = 16548
        };
        const msg = try Message.init(&buf);
        try expectEqual(.request, std.meta.activeTag(msg));
        try expectEqual(1125, msg.request.index);
        try expectEqual(2981, msg.request.begin);
        try expectEqual(16548, msg.request.length);
    }
    {
        const buf = [_]u8{
            0, 0, 0, 13,
            8,
            0, 0, 4, 101, // index = 1125
            0, 0, 11, 165, // begin = 2981
            0, 0, 64, 164, // end = 16548
        };
        const msg = try Message.init(&buf);
        try expectEqual(.cancel, std.meta.activeTag(msg));
        try expectEqual(1125, msg.cancel.index);
        try expectEqual(2981, msg.cancel.begin);
        try expectEqual(16548, msg.cancel.length);
    }
    {
        const buf = [_]u8{
            0, 0, 0, 6,
            5,
            0b01010001, 0, 0, 222, 0, // bitfield
        };
        const msg = try Message.init(&buf);
        try expectEqual(.bitfield, std.meta.activeTag(msg));
        try expectEqual(1, 1 & msg.bitfield[0]);
        try expectEqual(0, 1 & msg.bitfield[1]);
    }
}

test "round trip" {
    {
        const buf = [_]u8{
            0, 0, 0, 6,
            5,
            0b01010001, 0, 0, 222, 0, // bitfield
        };
        const msg = try Message.init(&buf);
        var res = std.ArrayList(u8).init(std.testing.allocator);
        defer res.deinit();
        const writer = res.writer();
        try msg.write(writer);

        const actual = try res.toOwnedSlice();
        defer std.testing.allocator.free(actual);

        try expectEqualSlices(u8, &buf, actual);
    }
}
