//!

const SessionState = enum {
    /// initial state
    disconnected,
    /// waiting for the peer to accept our connect()
    connecting,
    /// tcp connection stablished
    connected,
    /// interchanging handshakes
    sending_handshake,
    /// wating for his handshake
    waiting_handshake,
    /// registering peer bitfield/have
    waiting_availability,
    /// normal operation mode
    normal,
};

pub const ConnectionStatus = struct {
    is_choked: bool = true,
    is_interested: bool = false,
    in_endgame: bool = false,
    state: SessionState = .disconnected,
};

pub const PeerConnection = struct {
    loop: ?*Epoll,
    addr: std.net.Address,
    socket: std.posix.fd_t = -1,
    peer_bitfield: std.DynamicBitSetUnmanaged,
    session: ConnectionStatus = .{},

    reader: Reader,
    writer: Writer,

    const Self = @This();

    pub fn init(
        alloc: std.mem.Allocator,
        addr: std.net.Address,
        num_pieces: usize,
        write_buf_len: usize,
        read_buf_len: usize,
    ) !Self {
        const writer: Writer = try .init(alloc, write_buf_len, -1); // placeholder fd
        errdefer writer.deinit(alloc);

        const reader: Reader = try .init(alloc, read_buf_len);
        errdefer reader.deinit(alloc);

        const bitfield: std.DynamicBitSetUnmanaged = try .initEmpty(alloc, num_pieces);

        return Self{
            .loop = null,
            .addr = addr,
            .writer = writer,
            .reader = reader,
            .peer_bitfield = bitfield,
            .session = .{},
        };
    }

    pub fn connect(self: *Self, loop: *Epoll) !void {
        const sock_flags = std.posix.SOCK.STREAM | std.posix.SOCK.NONBLOCK | std.posix.SOCK.CLOEXEC;
        const sockfd = try std.posix.socket(self.addr.any.family, sock_flags, std.posix.IPPROTO.TCP);

        // connect non-blocking
        while (true) {
            std.posix.connect(
                sockfd,
                &self.addr.any,
                self.addr.getOsSockLen(),
            ) catch |err| switch (err) {
                error.WouldBlock => {
                    std.Thread.sleep(100 * std.time.ns_per_ms);
                    break;
                },
                else => return err,
            };
        }

        self.socket = sockfd;
        self.loop = loop;
        self.writer.socket = sockfd;
        self.reader.socket = sockfd;
        self.session.state = .connected;
        try self.loop.?.newClient(self); // OUT

        std.debug.print("New client added {f}\n", .{self.addr});
    }

    pub fn deinit(self: *Self, alloc: std.mem.Allocator) !void {
        self.reader.deinit(alloc);
        self.writer.deinit(alloc);
        self.peer_bitfield.deinit(alloc);

        if (self.loop) |l|
            try l.removeClient(self);

        if (self.socket != -1)
            std.posix.close(self.socket);
    }

    pub fn init_handshake(self: *Self, peer_id: [20]u8, torrent: *const TorrentFile) !void {
        std.debug.assert(self.socket != -1);
        std.debug.assert(self.session.state == .connected);

        // start handshake, if there is already a pending write, return
        // PendingMessage
        if (self.writer.to_write.len > 0) {
            // we already have an outgoing message; ensure we're in write mode
            // and wait for EPOLLOUT
            self.loop.?.writeMode(self) catch |err| {
                log.err("Could not set socket {d} for writing: {t}", .{ self.socket, err });
            };
            return;
        }

        self.session.state = .sending_handshake;
        const written = try self.writer.writeHandshake(peer_id, torrent);

        // if we didnt manage to write the handshake keep writing
        if (!written) {
            self.loop.?.writeMode(self) catch |err| {
                log.err("Could not set socket {d} for writing: {t}", .{ self.socket, err });
            };
        } else {
            // switch to reading his handshake
            self.session.state = .waiting_handshake;
            self.loop.?.readMode(self) catch |err| {
                log.err("Could not set socket {d} for reading: {t}", .{ self.socket, err });
            };
        }
    }

    pub fn recv_handshake(self: *Self, peer_id: [20]u8, torrent: *const TorrentFile) !void {
        std.debug.assert(self.socket != -1);
        std.debug.assert(self.session.state == .waiting_handshake);

        const handshake = try self.reader.readHandshake();

        if (handshake) |hs| {
            if (hs.pstrlen != 19 or
                !std.mem.eql(u8, &hs.pstr, "BitTorrent protocol") or
                !std.mem.eql(u8, &hs.info_hash, &torrent.info_hash) or
                !std.mem.eql(u8, &hs.peer_id, &peer_id))
            {
                log.err("Invalid handshake from peer {f}", .{self.addr});
                return error.InvalidHandshake;
            }
            log.debug("Handshake received successfully, going to read mode", .{});
            self.session.state = .waiting_availability;
            try self.loop.?.readMode(self);
            return;
        } else {
            // Not enough bytes yet to form a full handshake. Caller should wait
            // for more data.
            return error.WouldBlock;
        }
    }
};

test "peer: two way handshake with peer demo" {
    const alloc = std.testing.allocator;

    var torr = try TorrentFile.open(alloc, "tests/torrents/debian-12.11.0-amd64-netinst.iso.torrent");
    defer torr.deinit(alloc);

    var tr: Tracker = try .init(&torr.meta);
    defer tr.deinit(alloc);
    try tr.announce(alloc);

    var loop: Epoll = try .init();
    defer loop.deinit();

    const addr = std.net.Address{ .in = tr.peers.?[0] };

    var client: PeerConnection = try PeerConnection.init(
        alloc,
        addr,
        torr.meta.getNumPieces(),
        1024, // write buffer
        0x4000, // read buffer
    );
    defer client.deinit(alloc) catch |err| {
        log.err("Error shutting down client '{f}': {t}", .{ client.addr, err });
    };

    try client.connect(&loop);

    while (true) {
        const ready = loop.wait(-1);
        std.debug.print("epoll wait returned {d} events\n", .{ready.len});
        for (ready) |r| {
            const c: *PeerConnection = @ptrFromInt(r.data.ptr);

            if (r.events & linux.EPOLL.OUT != 0) {
                // If there is pending outgoing bytes, flush them first.
                if (c.writer.to_write.len > 0) {
                    const finished = try c.writer.flush();
                    if (!finished) continue;
                }

                switch (c.session.state) {
                    .connected => {
                        std.debug.print("handling connected: initiating handshake\n", .{});
                        c.init_handshake(tr.peer_id, &torr.meta) catch |err| {
                            log.err("Error could not handshake with peer '{f}': {t}", .{ c.addr, err });
                            break;
                        };
                    },
                    else => std.debug.print("unhandled state {t}\n", .{c.session.state}),
                }
            } else if (r.events & linux.EPOLL.IN != 0) {
                switch (c.session.state) {
                    .waiting_handshake => {
                        std.debug.print("handling state 'waiting_handshake'\n", .{});
                        c.recv_handshake(tr.peer_id, &torr.meta) catch |err| switch (err) {
                            error.WouldBlock => {}, // incomplete handshake read
                            else => {
                                log.err("Error could not receive handshake from peer '{f}': {t}", .{ c.addr, err });
                                try c.loop.?.removeClient(c);
                                break;
                            },
                        };
                        std.debug.print("handshake verified successfully !! \n", .{});
                        return; // TEST: END
                    },
                    else => @panic("unhandled state \n"),
                }
            }
        }
    }
}

const log = std.log.scoped(.peer);

const std = @import("std");
const linux = std.os.linux;

const Epoll = @import("Epoll.zig");
const Message = @import("Message.zig");
const PiecePicker = @import("PiecePicker.zig");
const Reader = @import("Reader.zig");
const TorrentFile = @import("TorrentFile.zig");
const Tracker = @import("Tracker.zig");
const Writer = @import("Writer.zig");
