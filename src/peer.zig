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
    } = .disconnected,
};

pub const Connection = struct {
    loop: *Epoll,
    addr: std.net.Address,
    socket: std.posix.fd_t,
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

    pub fn connect(
        alloc: std.mem.Allocator,
        addr: std.net.Address,
        num_pieces: usize,
        loop: *Epoll,
        write_buf_len: usize,
        read_buf_len: usize,
    ) !Self {
        const sock_flags = std.posix.SOCK.STREAM | std.posix.SOCK.NONBLOCK | std.posix.SOCK.CLOEXEC;
        const sockfd = try std.posix.socket(addr.any.family, sock_flags, std.posix.IPPROTO.TCP);
        try std.posix.connect(sockfd, &addr.any, addr.getOsSockLen());

        var writer: Writer = try .init(alloc, write_buf_len, sockfd);
        errdefer writer.deinit(alloc);

        var reader: Reader = try .init(alloc, read_buf_len);
        errdefer reader.deinit(alloc);

        const bitfield: std.DynamicBitSetUnmanaged = try .initEmpty(alloc, num_pieces);

        var conn = Self{
            .loop = loop,
            .addr = addr,
            .socket = sockfd,
            .writer = writer,
            .reader = reader,
            .peer_bitfield = bitfield,
        };

        // update state
        conn.state.connection = .stablished;
        // register this connection to the event loop
        try conn.loop.newClient(&conn);

        return conn;
    }

    pub fn disconnect(self: *Self, alloc: std.mem.Allocator) !void {
        self.writer.deinit(alloc);
        self.peer_bitfield.deinit(alloc);
        try self.loop.removeClient(self);
        std.posix.close(self.socket);
    }

    pub fn handshake(self: *Self, peer_id: [20]u8, torrent: *const TorrentFile) !void {
        self.state.connection = .handshaking;
        if (!(try self.writer.writeHandshake(peer_id, torrent))) {
            try self.loop.writeMode(self);
        } else {
            self.state.connection = .normal;
            try self.loop.readMode(self);
        }
    }
};

test "peer: handshake with peer" {
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
    var client: Connection = try .connect(alloc, addr, torr.meta.getNumPieces(), &loop, 1024, 0x4000);
    defer client.disconnect(alloc) catch |err| {
        log.err("Error while shuting down client '{any}'. Error: {t}", .{ client.addr, err });
    };

    client.handshake(tr.peer_id, &torr.meta) catch |err| {
        log.err("Could not handshake with peer '{any}'. Error: {t}", .{ addr, err });
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
