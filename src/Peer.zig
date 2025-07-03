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

    /// Creates a message from a given `reader`.
    /// Caller owns the returned memory, must call deinit()
    /// Message memory layout: |`message_len`(4bytes)|`messageid`(1byte)|`payload`(any)|
    pub fn init(allocator: Allocator, reader: anytype) !Self {
        const len: u32 = try reader.readInt(u32, .big);
        const msg_id: ?MessageID = if (len > 0) try reader.readEnum(MessageID, .big) else null;
        const payload: ?[]u8 = if (len > 1) try allocator.alloc(u8, len - 1) else null;

        // copy the payload into the buffer
        if (payload) |p| try reader.readNoEof(p);
        defer if (payload) |p| allocator.free(p);

        return switch (len) {
            0 => .keep_alive,
            1 => {
                return switch (msg_id.?) {
                    .Choke => .choke,
                    .Unchoke => .unchoke,
                    .Interested => .interested,
                    .NotInterested => .not_interested,
                    else => MessageError.UnexpectedId,
                };
            },
            5 => {
                return switch (msg_id.?) {
                    .Have => .{ .have = .{ .piece_index = readInt(u32, payload.?[0..4], .big) } },
                    else => MessageError.UnexpectedId,
                };
            },
            13 => {
                return switch (msg_id.?) {
                    .Request => .{
                        .request = .{
                            .index = readInt(u32, payload.?[0..4], .big),
                            .begin = readInt(u32, payload.?[4..8], .big),
                            .length = readInt(u32, payload.?[8..12], .big),
                        },
                    },
                    .Cancel => .{
                        .cancel = .{
                            .index = readInt(u32, payload.?[0..4], .big),
                            .begin = readInt(u32, payload.?[4..8], .big),
                            .length = readInt(u32, payload.?[8..12], .big),
                        },
                    },
                    else => MessageError.UnexpectedId,
                };
            },
            else => {
                return switch (msg_id.?) {
                    .Bitfield => .{
                        .bitfield = try allocator.dupe(u8, payload.?),
                    },
                    .Piece => .{
                        .piece = .{
                            .index = readInt(u32, payload.?[0..4], .big),
                            .begin = readInt(u32, payload.?[4..8], .big),
                            .block = try allocator.dupe(u8, payload.?[8..]),
                        },
                    },
                    else => MessageError.UnexpectedId,
                };
            },
        };
    }

    /// Frees the corresponding payload if necessary
    pub fn deinit(self: Self, allocator: Allocator) void {
        switch (self) {
            .bitfield => |bitf| allocator.free(bitf),
            .piece => |piece| allocator.free(piece.block),
            else => {},
        }
    }

    /// little hack to cast usize to u32 :3
    fn @"u32"(x: usize) u32 {
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

pub const MessageError = error{
    UnexpectedId,
    Invalid,
};

test "message init" {
    const allocator = std.testing.allocator;
    {
        const buffer = [_]u8{ 0, 0, 0, 0 };
        var stream = std.io.fixedBufferStream(&buffer);
        const reader = stream.reader();
        const msg = try Message.init(allocator, reader);
        defer msg.deinit(allocator);
        try expectEqual(.keep_alive, std.meta.activeTag(msg));
    }
    {
        const buffer = [_]u8{ 0, 0, 0, 1, 0 };
        var stream = std.io.fixedBufferStream(&buffer);
        const reader = stream.reader();
        const msg = try Message.init(allocator, reader);
        defer msg.deinit(allocator);
        try expectEqual(.choke, std.meta.activeTag(msg));
    }
    {
        const buffer = [_]u8{ 0, 0, 0, 1, 1 };
        var stream = std.io.fixedBufferStream(&buffer);
        const reader = stream.reader();
        const msg = try Message.init(allocator, reader);
        defer msg.deinit(allocator);
        try expectEqual(.unchoke, std.meta.activeTag(msg));
    }
    {
        const buffer = [_]u8{ 0, 0, 0, 1, 2 };
        var stream = std.io.fixedBufferStream(&buffer);
        const reader = stream.reader();
        const msg = try Message.init(allocator, reader);
        defer msg.deinit(allocator);
        try expectEqual(.interested, std.meta.activeTag(msg));
    }
    {
        const buffer = [_]u8{ 0, 0, 0, 1, 3 };
        var stream = std.io.fixedBufferStream(&buffer);
        const reader = stream.reader();
        const msg = try Message.init(allocator, reader);
        defer msg.deinit(allocator);
        try expectEqual(.not_interested, std.meta.activeTag(msg));
    }
    {
        const buffer = [_]u8{ 0, 0, 0, 5, 4, 0, 0, 0, 222 };
        var stream = std.io.fixedBufferStream(&buffer);
        const reader = stream.reader();
        const msg = try Message.init(allocator, reader);
        defer msg.deinit(allocator);
        try expectEqual(.have, std.meta.activeTag(msg));
        try expectEqual(222, msg.have.piece_index);
    }
    {
        const buffer = [_]u8{
            0, 0, 0, 13,
            6,
            0, 0, 4, 101, // index = 1125
            0, 0, 11, 165, // begin = 2981
            0, 0, 64, 164, // length = 16548
        };
        var stream = std.io.fixedBufferStream(&buffer);
        const reader = stream.reader();
        const msg = try Message.init(allocator, reader);
        defer msg.deinit(allocator);
        try expectEqual(.request, std.meta.activeTag(msg));
        try expectEqual(1125, msg.request.index);
        try expectEqual(2981, msg.request.begin);
        try expectEqual(16548, msg.request.length);
    }
    {
        const buffer = [_]u8{
            0, 0, 0, 13,
            8,
            0, 0, 4, 101, // index = 1125
            0, 0, 11, 165, // begin = 2981
            0, 0, 64, 164, // end = 16548
        };
        var stream = std.io.fixedBufferStream(&buffer);
        const reader = stream.reader();
        const msg = try Message.init(allocator, reader);
        defer msg.deinit(allocator);
        try expectEqual(.cancel, std.meta.activeTag(msg));
        try expectEqual(1125, msg.cancel.index);
        try expectEqual(2981, msg.cancel.begin);
        try expectEqual(16548, msg.cancel.length);
    }
    {
        const buffer = [_]u8{
            0, 0, 0, 6,
            5,
            0b01010001, 0, 0, 222, 0, // bitfield
        };
        var stream = std.io.fixedBufferStream(&buffer);
        const reader = stream.reader();
        const msg = try Message.init(allocator, reader);
        defer msg.deinit(allocator);
        try expectEqual(.bitfield, std.meta.activeTag(msg));
        try expectEqual(1, 1 & msg.bitfield[0]);
        try expectEqual(0, 1 & msg.bitfield[1]);
    }
}

test "round trip" {
    const t_allocator = std.testing.allocator;
    {
        const buffer = [_]u8{
            0, 0, 0, 6,
            5,
            0b01010001, 0, 0, 222, 0, // bitfield
        };

        // read message from buffer
        var stream = std.io.fixedBufferStream(&buffer);
        const reader = stream.reader();
        const msg = try Message.init(t_allocator, reader);
        defer msg.deinit(t_allocator);

        // write message to new buffer
        var res = std.ArrayList(u8).init(t_allocator);
        defer res.deinit();
        const writer = res.writer();
        try msg.write(writer);

        // they should be the same
        const actual: []const u8 = try res.toOwnedSlice();
        defer t_allocator.free(actual);
        try expectEqualSlices(u8, &buffer, actual);
    }
}
