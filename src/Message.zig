//! Represents a message from the Bittorrent peer protocol.
//! https://wiki.theory.org/BitTorrentSpecification#Messages

const log = std.log.scoped(.Message);

/// Contains the different message IDs of the protocol.
/// KeepAlive is not considered an ID but is here for convenience.
/// Order matters.
const Type = enum(i8) {
    keep_alive = -1,
    choke = 0,
    unchoke = 1,
    interested = 2,
    not_interested = 3,
    have = 4,
    bitfield = 5,
    request = 6,
    piece = 7,
    cancel = 8,
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
    if (self.payload) |payload| {
        alloc.free(payload);
    }
}

/// Reads a valid bittorrent peer message from raw bytes.
/// `bytes` must not have the 4byte len prefix.
/// Caller owns the returned memory
pub fn fromBytes(alloc: std.mem.Allocator, bytes: []const u8) !Self {
    if (bytes.len == 0) {
        return .{
            .id = .keep_alive,
            .payload = null,
        };
    }

    const id = std.enums.fromInt(Type, bytes[0]) orelse return Error.InvalidMessageId;
    const payload = if (bytes.len > 1)
        try alloc.dupe(u8, bytes[1..])
    else
        null;

    return .{
        .id = id,
        .payload = payload,
    };
}

test "message: read keep alive" {
    const alloc = testing.allocator;
    const msg = try Self.fromBytes(alloc, &.{});
    try testing.expect(msg.id == .keep_alive);
    try testing.expect(msg.payload == null);
}

test "message: read choke, unchoke... (messages with no payload but with Id)" {
    const alloc = testing.allocator;
    {
        const msg = try Self.fromBytes(alloc, &.{0x00});
        defer msg.deinit(alloc);
        try testing.expect(msg.id == .choke);
        try testing.expect(msg.payload == null);
    }
    {
        const msg = try Self.fromBytes(alloc, &.{0x01});
        defer msg.deinit(alloc);
        try testing.expect(msg.id == .unchoke);
        try testing.expect(msg.payload == null);
    }
    {
        const msg = try Self.fromBytes(alloc, &.{0x02});
        defer msg.deinit(alloc);
        try testing.expect(msg.id == .interested);
        try testing.expect(msg.payload == null);
    }
}

test "message: read have" {
    const alloc = testing.allocator;
    const msg = try Self.fromBytes(alloc, &.{ 0x04, 0x0b, 0xee, 0xee, 0xef });
    defer msg.deinit(alloc);
    try testing.expect(msg.id == .have);
    try testing.expect(msg.payload != null);
    try testing.expect(msg.payload.?.len == 4);
    try testing.expect(std.mem.readInt(u32, msg.payload.?[0..4], .little) == 4025413131);
}

test "message: read piece" {
    const alloc = testing.allocator;
    const piece_message = &.{
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
    };
    const msg = try Self.fromBytes(alloc, piece_message);
    defer msg.deinit(alloc);
    try testing.expect(msg.id == .piece);
    try testing.expect(msg.payload != null);
    try testing.expect(msg.payload.?.len == 36);
    try testing.expect(std.mem.readInt(u32, msg.payload.?[0..4], .little) == 500);
    try testing.expect(std.mem.readInt(u32, msg.payload.?[4..8], .little) == 24);
}

//test "message: roundtrip request" {
//    const alloc = std.testing.allocator;
//    var buf: [1024]u8 = undefined;
//    var r: std.Io.Reader = .fixed(&buf);
//    var w: std.Io.Writer = .fixed(&buf);
//
//    const msg = Self{
//        .id = .request,
//        .payload = &.{
//            0x12, 0x00, 0x00, 0x00, // index
//            0x00, 0x12, 0x00, 0x00, // begin
//            0x00, 0x00, 0x12, 0x00, // length
//        },
//    };
//
//    try msg.write(&w);
//    const new = try Self.read(&r, alloc);
//    defer new.deinit(alloc);
//
//    try testing.expect(msg.id == new.id);
//    try testing.expect(mem.eql(u8, msg.payload.?[0..4], new.payload.?[0..4]));
//    try testing.expect(mem.eql(u8, msg.payload.?[4..8], new.payload.?[4..8]));
//    try testing.expect(mem.eql(u8, msg.payload.?[8..12], new.payload.?[8..12]));
//}

const std = @import("std");
const mem = std.mem;
const testing = std.testing;
