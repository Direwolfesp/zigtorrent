const std = @import("std");
const Allocator = std.mem.Allocator;
const readInt = std.mem.readInt;

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

pub const KeepAlive: Message = .keep_alive;
pub const Choke: Message = .choke;
pub const Unchoke: Message = .unchoke;
pub const Interested: Message = .interested;
pub const NotInterested: Message = .not_interested;

/// Message memory layout: |`message_len`(4bytes)|`messageid`(1byte)|`payload`(any)|
/// message_len = @sizeof(messageid) + @sizeof(payload).
pub const Message = union(enum) {
    const Self = @This();

    keep_alive: void, // no id, len = 0
    choke: void,
    unchoke: void,
    interested: void,
    not_interested: void,
    bitfield: []u8,

    have: struct {
        piece_index: u32,
    },
    piece: struct {
        index: u32,
        begin: u32,
        block: []const u8, // usually 2^14 bytes
    },
    request: struct {
        /// zero-based piece index
        index: u32,
        /// zero-based byte offset within the piece
        begin: u32,
        /// requested length.
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
