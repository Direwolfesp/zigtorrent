const std = @import("std");
const Message = @import("Message.zig");
const TorrentFile = @import("TorrentFile.zig");

const Self = @This();

/// the client socket
socket: std.posix.socket_t,
/// Buffer for storing our length-prefixed messaged
write_buf: []u8,
/// Bytes we still need to send. This is a slice of `write_buf`. When
/// empty, then we're in "read-mode" and are waiting for a message from the
/// client.
to_write: []u8,

pub fn init(alloc: std.mem.Allocator, size: usize, socket: std.posix.socket_t) !Self {
    const write_buf = try alloc.alloc(u8, size);
    errdefer alloc.free(write_buf);
    return .{
        .socket = socket,
        .write_buf = write_buf,
        .to_write = &.{},
    };
}

pub fn deinit(self: Self, alloc: std.mem.Allocator) void {
    alloc.free(self.write_buf);
}

/// Sends the handshake to the client.
/// Returns false if it didn't manage to write all the buffer,
/// true if it could, this can be used to change the event loop mode.
pub fn writeHandshake(self: *Self, peer_id: [20]u8, torrent: *const TorrentFile) !bool {
    const handshk = HandShake.create(peer_id, torrent);
    const handshake_bytes: []const u8 = std.mem.asBytes(&handshk);
    const handshake_len = handshake_bytes.len;

    std.debug.assert(handshake_len == 68);
    if (handshake_bytes.len > self.write_buf.len) return Error.BufferTooSmall;

    @memmove(self.write_buf[0..handshake_len], handshake_bytes);
    self.to_write = self.write_buf[0..handshake_len];
    return try self.flush();
}

const Error = error{
    BufferTooSmall,
    PendingMessage,
    Closed,
};

/// `msg` doesn't include the len prefix
/// Returns false if it didn't manage to write all the buffer,
/// true if it could, this can be used to change the event loop mode.
pub fn writeMessage(self: *Self, msg: Message) Error!bool {
    if (self.to_write.len > 0) {
        return Error.PendingMessage;
    }

    // id + body
    const total_len: u32 = 1 + if (msg.payload) |p| p.len else 0;
    if (total_len + 4 > self.write_buf.len) return Error.BufferTooSmall;

    std.mem.writeInt(u32, self.write_buf[0..4], total_len, .big);
    self.write_buf[4] = @intFromEnum(msg.id);

    if (msg.payload) |p| {
        @memmove(self.write_buf[5 .. 5 + p.len], p);
    }

    self.to_write = self.write_buf[0 .. 4 + total_len];
    return try self.flush();
}

/// dumps `to_write` into the socket
/// Returns false if it didn't manage to write all the buffer,
/// true if otherwise.
pub fn flush(self: *Self) !bool {
    var buf = self.to_write;
    defer self.to_write = buf;
    while (buf.len > 0) {
        const n = std.posix.write(self.socket, buf) catch |err| switch (err) {
            error.WouldBlock => return false,
            else => return err,
        };
        if (n == 0) return Error.Closed;
        buf = buf[n..];
    } else {
        return true;
    }
}

// we use extern struct for a defined memory layout
pub const HandShake = extern struct {
    pstrlen: u8 align(1) = 19,
    pstr: [19]u8 align(1) = "BitTorrent protocol".*,
    reserved: [8]u8 align(1) = std.mem.zeroes([8]u8),
    info_hash: [20]u8 align(1) = undefined,
    peer_id: [20]u8 align(1) = undefined,

    pub fn create(peer_id: [20]u8, meta: *const TorrentFile) HandShake {
        return HandShake{
            .info_hash = meta.info_hash,
            .peer_id = peer_id,
        };
    }
};
