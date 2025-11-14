const std = @import("std");
const posix = std.posix;
const Message = @import("Message.zig");
const HandShake = Message.HandShake;

const Reader = @This();

/// the peer socket
socket: std.posix.socket_t = -1,
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

pub fn readHandshake(self: *Reader) !?HandShake {
    var hs_bytes: [Message.HANDSHAKE_LEN]u8 = undefined;
    const n = posix.read(self.socket, &hs_bytes) catch |err| return switch (err) {
        error.WouldBlock => null,
        else => err,
    };

    if (n == 0) {
        return error.Closed;
    } else if (n < Message.HANDSHAKE_LEN) {
        return null;
    } else {
        const hs: *HandShake = @ptrCast(hs_bytes[0..Message.HANDSHAKE_LEN]);
        return hs.*;
    }
}

pub fn readMessage(self: *Reader, alloc: std.mem.Allocator) !?Message {
    if (try self.bufferedMessage()) |msg| {
        return try Message.fromBytes(alloc, msg);
    }

    const n = posix.read(self.socket, self.buf[self.pos..]) catch |err| switch (err) {
        error.WouldBlock => return null,
        else => return err,
    };
    if (n == 0) return error.Closed;
    self.pos += n;

    if (try self.bufferedMessage()) |msg| {
        return try Message.fromBytes(alloc, msg);
    }

    return null;
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
