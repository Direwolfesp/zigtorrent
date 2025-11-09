pub const State = struct {
    is_choked: bool = true,
    is_interested: bool = false,
    in_endgame: bool = false,
    connection: enum {
        /// initial state
        disconnected,
        /// waiting for the peer to accept our connect()
        connecting,
        /// tcp connection stablished
        connected,
        /// interchanging handshakes
        handshaking,
        /// registering peer bitfield/have
        waiting_availability,
        /// normal operation mode
        normal,
    } = .disconnected,
};

pub const Connection = struct {
    loop: ?*Epoll,
    addr: std.net.Address,
    socket: std.posix.fd_t = -1,
    peer_bitfield: std.DynamicBitSetUnmanaged,
    state: State = .{},

    reader: Reader,
    writer: Writer,

    /// If we are in slowstart, we increment by one when a block arrives.
    //target_req_queue_len: u32 = 1,
    /// default queue len
    //current_req_queue_len: u32 = 5,
    /// last time we received a block
    //last_incoming_block_time: std.time.Instant,
    /// last time we requested a block
    //last_outgoing_request_time: std.time.Instant,

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
            .state = .{},
        };
    }

    pub fn connect(self: *Self, loop: *Epoll) !void {
        const sock_flags = std.posix.SOCK.STREAM | std.posix.SOCK.NONBLOCK | std.posix.SOCK.CLOEXEC;
        const sockfd = try std.posix.socket(self.addr.any.family, sock_flags, std.posix.IPPROTO.TCP);

        // connect non-blocking
        const res: ?void = std.posix.connect(
            sockfd,
            &self.addr.any,
            self.addr.getOsSockLen(),
        ) catch |err| switch (err) {
            error.WouldBlock => null,
            else => return err,
        };

        self.socket = sockfd;
        self.loop = loop;

        if (res == null) {
            self.state.connection = .connecting;
            try loop.writeMode(self); // wait for EPOLLOUT
        } else {
            self.state.connection = .connected;
            try loop.newClient(self); // register EPOLLIN
        }
    }

    pub fn disconnect(self: *Self, alloc: std.mem.Allocator) !void {
        self.writer.deinit(alloc);
        self.peer_bitfield.deinit(alloc);
        if (self.loop) |l| {
            try l.removeClient(self);
        }
        std.posix.close(self.socket);
    }

    pub fn handshake(self: *Self, peer_id: [20]u8, torrent: *const TorrentFile) !void {
        self.state.connection = .handshaking;
        if (!(try self.writer.writeHandshake(peer_id, torrent))) {
            try self.loop.?.writeMode(self);
        } else {
            self.state.connection = .normal;
            try self.loop.?.readMode(self);
        }
    }
};

test "peer: handshake with peer (init + connect)" {
    const alloc = std.testing.allocator;

    var torr = try TorrentFile.open(alloc, "src/tests/torrents/debian-12.11.0-amd64-netinst.iso.torrent");
    defer torr.deinit(alloc);

    var tr: Tracker = try .init(&torr.meta);
    defer tr.deinit(alloc);
    try tr.announce(alloc);

    var picker: PiecePicker = try .init(torr.meta, alloc);
    defer picker.deinit();

    var loop: Epoll = try .init();
    defer loop.deinit();

    const addr = std.net.Address{ .in = tr.peers.?[0] };

    var client: Connection = try Connection.init(
        alloc,
        addr,
        torr.meta.getNumPieces(),
        1024, // write buffer
        0x4000, // read buffer
    );
    defer client.disconnect(alloc) catch |err| {
        log.err("Error shutting down client '{any}': {t}", .{ client.addr, err });
    };

    try client.connect(&loop);

    client.handshake(tr.peer_id, &torr.meta) catch |err| {
        log.err("Could not handshake with peer '{any}': {t}", .{ addr, err });
    };

    try std.testing.expectEqual(client.state.connection, .normal);
}

const log = std.log.scoped(.peer);

const std = @import("std");
const Message = @import("Message.zig");
const Reader = @import("Reader.zig");
const Writer = @import("Writer.zig");
const Epoll = @import("Epoll.zig");
const TorrentFile = @import("TorrentFile.zig");
const Tracker = @import("Tracker.zig");
const PiecePicker = @import("PiecePicker.zig");
