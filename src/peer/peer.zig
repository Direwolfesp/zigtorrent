pub const State = struct {
    is_choked: bool = true,
    is_interested: bool = false,
    in_endgame: bool = false,
    connection: enum {
        /// initial state
        disconnected,
        /// tcp connection stablished
        stablished,
        /// interchanging handshakes
        handshaking,
        /// registering peer bitfield/have
        waiting_availability,
        /// normal operation mode
        normal,
    } = .disconected,
};

pub const Connection = struct {
    loop: *Epoll,
    addr: std.net.Address,
    socket: std.posix_fd_t,
    peer_bitfield: std.DynamicBitSetUnmanaged,
    state: State = .{},

    reader: Reader,
    writer: Writer,

    /// If we are in slowstart, we increment by one when a block arrives.
    target_req_queue_len: u32 = 1,
    /// default queue len
    current_req_queue_len: u32 = 5,
    /// last time we received a block
    last_incoming_block_time: std.time.Instant,
    /// last time we requested a block
    last_outgoing_request_time: std.time.Instant,

    const Self = @This();

    pub fn connect(alloc: std.mem.Allocator, addr: std.net.Address, loop: *Epoll) Self {
        const sock_flags = std.posix.SOCK.STREAM | std.posix.SOCK.NONBLOCK | std.posix.SOCK.CLOEXEC;
        const sockfd = try std.posix.socket(addr.any.family, sock_flags, std.posix.IPPROTO.TCP);
        try std.posix.connect(sockfd, &addr.any, addr.getOsSockLen());

        var writer: Writer = try .init(alloc);
        errdefer writer.deinit(alloc);

        var reader: Reader = try .init(alloc);
        errdefer reader.deinit(alloc);

        var conn = Self{
            .loop = loop,
            .addr = addr,
            .socket = sockfd,
            .writer = writer,
            .reader = reader,
        };

        // update state
        conn.state.connection = .stablished;
        // register this connection to the event loop
        try conn.loop.newClient(&conn);

        return conn;
    }

    pub fn disconnect(self: Self, alloc: std.mem.Allocator) void {
        self.writer.deinit(alloc);
        try self.loop.removeClient(&self);
        std.posix.close(self.socket);
    }

    pub fn handshake(self: *Self, peer_id: [20]u8, torrent: *const TorrentFile) !void {
        self.state.connection = .handshaking;
        try self.writer.writeHandshake(peer_id, torrent);
    }
};

const std = @import("std");
const Message = @import("Message.zig");
const Reader = @import("Reader.zig");
const Writer = @import("Writer.zig");
const Epoll = @import("../Epoll.zig");
const TorrentFile = @import("../TorrentFile.zig");
