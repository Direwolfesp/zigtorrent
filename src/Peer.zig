const std = @import("std");
const stdout = std.io.getStdOut().writer();
const Allocator = std.mem.Allocator;
const MetaInfo = @import("MetaInfo.zig").MetaInfo;
const expectEqual = std.testing.expectEqual;
const activeTag = std.meta.activeTag;
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

/// Message memory layout: |`message_len`(4bytes)|`messageid`(1byte)|`payload`(any)|
pub const Message = union(enum) {
    const Self = @This();

    keep_alive: void, // len = 0
    choke: void, // len = 1, ID = 0
    unchoke: void, // len = 1, ID = 1
    interested: void, // len = 1, ID = 2
    not_interested: void, // len = 1, ID = 3
    bitfield: []const u8, // len = 1 + X, ID = 5, bitfield

    // len = 5, ID = 4, piece_index
    have: struct {
        piece_index: u32,
    },
    // len = 9 + X, ID = 7, index,begin,block
    piece: struct {
        index: u32,
        begin: u32,
        block: []const u8, // usually 2^14 bytes
    },
    // len = 13, ID = 6, index,begin,end
    request: struct {
        index: u32,
        begin: u32,
        end: u32,
    },
    // len = 13, id = 8, index,begin,length
    cancel: struct {
        index: u32,
        begin: u32,
        length: u32,
    },

    /// Creates a message from a given buffer.
    /// Caller does not own the returned memory.
    /// Message memory layout: |`message_len`(4bytes)|`messageid`(1byte)|`payload`(any)|
    pub fn init(buff: []const u8) !Self {
        const len: u32 = std.mem.readInt(u32, buff[0..4], .big);
        return switch (len) {
            0 => .keep_alive,
            1 => {
                const message_id: u8 = buff[4];
                return switch (message_id) {
                    0 => .choke,
                    1 => .unchoke,
                    2 => .interested,
                    3 => .not_interested,
                    else => MessageError.UnexpectedId,
                };
            },
            5 => {
                const message_id: u8 = buff[4];
                return switch (message_id) {
                    4 => .{ .have = .{ .piece_index = readInt(u32, buff[5..9], .big) } },
                    else => MessageError.UnexpectedId,
                };
            },
            13 => {
                const message_id: u8 = buff[4];
                return switch (message_id) {
                    6 => .{
                        .request = .{
                            .index = readInt(u32, buff[5..9], .big),
                            .begin = readInt(u32, buff[9..13], .big),
                            .end = readInt(u32, buff[13..17], .big),
                        },
                    },
                    8 => .{
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
                const message_id: u8 = buff[4];
                return switch (message_id) {
                    5 => .{
                        .bitfield = buff[5 .. 5 + len - 1],
                    },
                    7 => .{
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
            0, 0, 64, 164, // end = 16548
        };
        const msg = try Message.init(&buf);
        try expectEqual(.request, std.meta.activeTag(msg));
        try expectEqual(1125, msg.request.index);
        try expectEqual(2981, msg.request.begin);
        try expectEqual(16548, msg.request.end);
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
