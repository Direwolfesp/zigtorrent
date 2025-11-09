const std = @import("std");
const posix = std.posix;
const Message = @import("Message.zig");

const Reader = @This();

/// internal buffer to store unprocessed messages
buf: []u8,
/// the right most index, where new data will be placed
pos: usize = 0,
/// the left most index, where unprocessed data starts.
/// buf[start..pos] == unprocessed message
start: usize = 0,

pub fn init(allocator: std.mem.Allocator, size: usize) !Reader {
    const buf = try allocator.alloc(u8, size);
    return .{
        .pos = 0,
        .start = 0,
        .buf = buf,
    };
}

pub fn deinit(self: *const Reader, allocator: std.mem.Allocator) void {
    allocator.free(self.buf);
}

pub fn readMessage(self: *Reader, alloc: std.mem.Allocator, socket: posix.socket_t) !?Message {
    var buf = self.buf;

    while (true) {
        if (try self.bufferedMessage()) |msg| {
            // msg doesnt contain the len prefix
            return try Message.fromBytes(alloc, msg);
        }

        const pos = self.pos;
        const n = posix.read(socket, buf[pos..]) catch |err| switch (err) {
            error.WouldBlock => return null,
            else => return err,
        };
        if (n == 0) return error.Closed;
        self.pos = pos + n;
    }
}

fn bufferedMessage(self: *Reader) !?[]u8 {
    const buf = self.buf;
    const pos = self.pos;
    const start = self.start;

    std.debug.assert(pos >= start);
    const unprocessed = buf[start..pos];

    if (unprocessed.len < 4) {
        try self.ensureSpace(4);
        return null;
    }

    const message_len = std.mem.readInt(u32, unprocessed[0..4], .big);

    if (message_len == 0) { // keep-alive
        self.start += 4;
        return &[_]u8{};
    }

    const total_len = message_len + 4; // with the len prefix
    if (unprocessed.len < total_len) { // we dont have enough space yet
        try self.ensureSpace(total_len);
        return null;
    }
    self.start += total_len; // advance start index
    return unprocessed[4..total_len]; // return the message without the prefix len
}

fn ensureSpace(self: *Reader, space: usize) error{BufferTooSmall}!void {
    if (self.buf.len < space) {
        return error.BufferTooSmall;
    }

    const spare = self.buf.len - self.start;
    if (spare >= space) {
        return;
    }

    const unprocessed = self.buf[self.start..self.pos];
    @memmove(self.buf[0..unprocessed.len], unprocessed);
    self.start = 0;
    self.pos = unprocessed.len;
}

test "Reader: read entire message in the buffer" {
    const alloc = std.testing.allocator;
    var reader = try Reader.init(alloc, 64);
    defer reader.deinit(alloc);

    // choke message with len=1 (just the id=0)
    const data = [_]u8{ 0x00, 0x00, 0x00, 0x01, 0x00 };
    @memmove(reader.buf[0..data.len], &data);
    reader.pos = data.len;

    const maybe_msg = try reader.bufferedMessage();
    try std.testing.expect(maybe_msg != null);
    const msg_bytes = maybe_msg.?;

    // the message does not conaint the len prefix
    try std.testing.expectEqualSlices(u8, msg_bytes, &.{0});

    const msg = try Message.fromBytes(alloc, msg_bytes);
    defer msg.deinit(alloc);
    try std.testing.expect(msg.id == .choke);
    try std.testing.expect(msg.payload == null);
}

test "Reader: read keep-alive message (len=0)" {
    const alloc = std.testing.allocator;
    var reader = try Reader.init(alloc, 64);
    defer reader.deinit(alloc);

    const data = [_]u8{ 0x00, 0x00, 0x00, 0x00 };
    std.mem.copyForwards(u8, reader.buf[0..data.len], &data);
    reader.pos = data.len;

    const maybe_msg = try reader.bufferedMessage();
    try std.testing.expect(maybe_msg != null);
    const msg_bytes = maybe_msg.?;

    // keep-alive => empty slice
    try std.testing.expect(msg_bytes.len == 0);

    const msg = try Message.fromBytes(alloc, msg_bytes);
    try std.testing.expect(msg.id == .keep_alive);
    try std.testing.expect(msg.payload == null);
}

test "Reader: test buffered message" {
    const alloc = std.testing.allocator;
    var reader = try Reader.init(alloc, 64);
    defer reader.deinit(alloc);

    // simulate partial read, 5bytes in the len prefix but we send less
    const partial = [_]u8{ 0x00, 0x00, 0x00, 0x05, 0x01, 0xAA, 0xBB };
    @memmove(reader.buf[0..partial.len], &partial);
    reader.pos = partial.len;

    const maybe_msg = try reader.bufferedMessage();
    try std.testing.expect(maybe_msg == null);

    // we send the missing bytes
    const rest = [_]u8{ 0xCC, 0xDD };
    @memmove(reader.buf[reader.pos .. reader.pos + rest.len], &rest);
    reader.pos += rest.len;

    const complete_msg = try reader.bufferedMessage();
    try std.testing.expect(complete_msg != null);
    const msg_bytes = complete_msg.?;

    // full message
    try std.testing.expectEqualSlices(u8, msg_bytes, &.{ 0x01, 0xAA, 0xBB, 0xCC, 0xDD });
}

test "Reader: ensureSpace moves unprocessed bytes to the start of the buffer" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var reader = try Reader.init(alloc, 7);
    defer reader.deinit(alloc);

    // fill the buffer with known values
    const data = [_]u8{ 1, 2, 3, 4, 5, 6 };
    @memmove(reader.buf[0..data.len], &data);

    reader.pos = 6;
    reader.start = 4; // buf[0..3] already processed

    // the spare left is buf.len - start = 3 that is
    // less than 4, so we expect a move
    try reader.ensureSpace(4);
    try std.testing.expectEqualSlices(u8, reader.buf[0..2], &.{ 5, 6 });
    try std.testing.expectEqual(reader.start, 0);
    try std.testing.expectEqual(reader.pos, 2);
}
