//! Represents a message from the Bittorrent peer protocol.
//! https://wiki.theory.org/BitTorrentSpecification#Messages

const log = std.log.scoped(.Message);

/// Contains the different message IDs of the protocol.
/// KeepAlive is not considered an ID but is here for convenience.
/// Order matters.
const Type = enum(i8) {
    KeepAlive = -1,
    Choke = 0,
    Unchoke = 1,
    Interested = 2,
    NotInterested = 3,
    Have = 4,
    Bitfield = 5,
    Request = 6,
    Piece = 7,
    Cancel = 8,
};

const Self = @This();

/// the message id
id: Type,
/// the contents
payload: ?[]const u8,

const Error = error{
    InvalidMessageId,
    ReadFailed,
};

pub fn deinit(self: Self, alloc: std.mem.Allocator) void {
    switch (self.id) {
        .KeepAlive,
        .Choke,
        .Unchoke,
        .Interested,
        .NotInterested,
        => {},
        .Bitfield,
        .Have,
        .Piece,
        .Request,
        .Cancel,
        => alloc.free(self.payload.?),
    }
}

/// Reads a valid bittorrent peer message from the given reader
pub fn read(reader: *std.Io.Reader, alloc: std.mem.Allocator) !Self {
    const len = try reader.takeInt(u32, .big);
    if (len == 0) {
        return .{
            .id = .KeepAlive,
            .payload = null,
        };
    }

    const id = reader.takeEnum(Type, .big) catch |err| switch (err) {
        error.InvalidEnumTag => return Error.InvalidMessageId,
        else => return Error.ReadFailed,
    };
    const payload: ?[]u8 = if (len == 1) null else try reader.readAlloc(alloc, len - 1);

    return .{
        .id = id,
        .payload = payload,
    };
}

/// Writes the message to the given sink.
/// Flush is needed.
pub fn write(self: Self, writer: *std.Io.Writer) !void {
    switch (self.id) {
        .KeepAlive => {
            std.debug.assert(self.payload == null);
            try writer.writeInt(u32, 0, .big);
        },
        .Choke,
        .Unchoke,
        .Interested,
        .NotInterested,
        => {
            try writer.writeInt(u32, 1, .big);
            try writer.writeByte(@intCast(@intFromEnum(self.id)));
        },
        .Bitfield,
        .Have,
        .Piece,
        .Request,
        .Cancel,
        => {
            try writer.writeInt(u32, @intCast(self.payload.?.len + 1), .big);
            try writer.writeByte(@intCast(@intFromEnum(self.id)));
            try writer.writeAll(self.payload.?);
        },
    }
}

test "message: read keep alive" {
    const alloc = testing.allocator;
    var r: std.Io.Reader = .fixed(&.{ 0x00, 0x00, 0x00, 0x00 });
    const msg = try Self.read(&r, alloc);
    try testing.expect(msg.id == Type.KeepAlive);
    try testing.expect(msg.payload == null);
}

test "message: read choke, unchoke... (messages with no payload but with Id)" {
    const alloc = testing.allocator;
    {
        var r: std.Io.Reader = .fixed(&.{ 0x00, 0x00, 0x00, 0x01, 0x00 });
        const msg = try Self.read(&r, alloc);
        try testing.expect(msg.id == .Choke);
        try testing.expect(msg.payload == null);
    }
    {
        var r: std.Io.Reader = .fixed(&.{ 0x00, 0x00, 0x00, 0x01, 0x01 });
        const msg = try Self.read(&r, alloc);
        try testing.expect(msg.id == .Unchoke);
        try testing.expect(msg.payload == null);
    }
    {
        var r: std.Io.Reader = .fixed(&.{ 0x00, 0x00, 0x00, 0x01, 0x02 });
        const msg = try Self.read(&r, alloc);
        try testing.expect(msg.id == .Interested);
        try testing.expect(msg.payload == null);
    }
}

test "message: read have" {
    const alloc = testing.allocator;
    var r: std.Io.Reader = .fixed(&.{
        0x00, 0x00, 0x00, 0x05,
        0x04, // id
        0x0b, 0xee, 0xee, 0xef, // payload
    });
    const msg = try Self.read(&r, alloc);
    defer msg.deinit(alloc);
    try testing.expect(msg.id == .Have);
    try testing.expect(msg.payload != null);
    try testing.expect(msg.payload.?.len == 4);
    try testing.expect(std.mem.readInt(u32, msg.payload.?[0..4], .little) == 4025413131);
}

test "message: read piece" {
    const alloc = testing.allocator;
    var r: std.Io.Reader = .fixed(&.{
        0x00, 0x00, 0x00, 0x25, // 37
        0x07, // id
        0xf4, 0x01, 0x00, 0x00, // index
        0x18, 0x00, 0x00, 0x00, // begin
        0x00, 0x00, 0x00, 0x00, // block ...
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
    });
    const msg = try Self.read(&r, alloc);
    defer msg.deinit(alloc);
    try testing.expect(msg.id == .Piece);
    try testing.expect(msg.payload != null);
    try testing.expect(msg.payload.?.len == 36);
    try testing.expect(std.mem.readInt(u32, msg.payload.?[0..4], .little) == 500);
    try testing.expect(std.mem.readInt(u32, msg.payload.?[4..8], .little) == 24);
}

test "message: roundtrip request" {
    const alloc = std.testing.allocator;
    var buf: [1024]u8 = undefined;
    var r: std.Io.Reader = .fixed(&buf);
    var w: std.Io.Writer = .fixed(&buf);

    const msg = Self{
        .id = .Request,
        .payload = &.{
            0x12, 0x00, 0x00, 0x00, // index
            0x00, 0x12, 0x00, 0x00, // begin
            0x00, 0x00, 0x12, 0x00, // length
        },
    };

    try msg.write(&w);
    const new = try Self.read(&r, alloc);
    defer new.deinit(alloc);

    try testing.expect(msg.id == new.id);
    try testing.expect(mem.eql(u8, msg.payload.?[0..4], new.payload.?[0..4]));
    try testing.expect(mem.eql(u8, msg.payload.?[4..8], new.payload.?[4..8]));
    try testing.expect(mem.eql(u8, msg.payload.?[8..12], new.payload.?[8..12]));
}

const std = @import("std");
const mem = std.mem;
const testing = std.testing;
