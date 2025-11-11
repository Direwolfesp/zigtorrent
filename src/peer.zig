//!

const EventType = enum {
    READ,
    WRITE,
};

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
    /// we are waiting for disk_io to finish hashing.
    /// TODO: Dont block the current peer, just pick another block and watch
    /// out for previous disk_io piece results. To achieve that, all on-fly
    /// piece buffers must be keept until the piece is hashed, then we can
    /// free them on demand. Maybe: `hashMap(u32, []u8)` that maps piece_index
    /// -> piece_buffer.
    /// FIXME: the `IOMessages` are received out of order, so the main loop
    /// that received the `IOMessages`, must identify the `PeerConnection`
    /// who sent it in the first place, we could just attach another field
    /// to `IOMessage` like `client: *PeerConnection`, and call back the
    /// `PeerConnection` like `p.onIOMessage(.store_success)` so the peer can:
    /// free the buffer for that piece, notify the `piece_picker` about the
    /// piece status (download correctly, inttegrity failed, etc...)
    is_pending: bool = false,
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

    // this fields might be encapsulated in a higher entity
    // later and pass it as a pointer, because they are common
    // for all peers
    peer_id: [20]u8,
    torrent: *const TorrentFile,
    piece_picker: *PiecePicker,
    disk_io: *Filesystem,
    //

    // fields related to the current download state
    piece_buf: []u8,
    current_request_pipeline: u32 = 0,
    target_request_pipeline: u32 = 10,
    requested: u32 = 0, // bytes requested for that piece
    downloaded: u32 = 0, // bytes received from peer
    curr_piece: ?u32 = null,
    curr_piece_len: ?u32 = null,

    reader: Reader,
    writer: Writer,

    const Self = @This();

    pub fn init(
        alloc: std.mem.Allocator,
        addr: std.net.Address,
        num_pieces: usize,
        //
        peer_id: [20]u8,
        torrent: *const TorrentFile,
        piece_picker: *PiecePicker,
        disk_io: Filesystem,
        //
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
            .peer_id = peer_id,
            .torrent = torrent,
            .piece_picker = piece_picker,
            .disk_io = disk_io,
        };
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

    pub fn parseBitfield(self: *Self, bitfield: Message) void {
        std.debug.assert(bitfield.id == .bitfield);
        var index = 0;
        for (bitfield.payload.?) |bf_byte| {
            var mask: u8 = 0b1000_0000;
            for (0..8) |_| {
                if (mask & bf_byte != 0 and index < self.torrent.getNumPieces()) {
                    self.peer_bitfield.set(index);
                }
                mask >>= 1;
            }
            index += 1;
        }
        self.session.state = .normal;
        try self.loop.?.writeMode(self); // we want to write interested
    }

    pub fn parseHave(self: *Self, have: Message) void {
        std.debug.assert(have.id == .have);
        const piece: u32 = std.mem.readInt(u32, have.payload[0..4], .little);
        self.peer_bitfield.set(piece);
        try self.piece_picker.inc_piece_refcount(piece);
        self.session.state = .normal;
        try self.loop.?.writeMode(self); // we want to write interested
    }

    // TODO:
    pub fn handle_read(self: *Self, alloc: std.mem.Allocator) !void {
        switch (self.session.state) {
            .disconnected => {},
            .connecting => {},
            .connected => {},
            .waiting_handshake => self.recv_handshake(self.peer_id, self.torrent) catch |err|
                switch (err) {
                    error.InvalidHandshake => {
                        log.err(
                            "[{any}] Peer sent an invalid handshake, closing...",
                            .{self.addr},
                        );
                        try self.deinit(alloc);
                    },
                    error.WouldBlock => {},
                    else => return err,
                },
            .sending_handshake => {},
            .waiting_availability => {
                if (self.reader.readMessage(alloc)) |msg| {
                    if (msg) |m| {
                        defer m.deinit(alloc);

                        switch (m.id) {
                            .bitfield => self.parseBitfield(m),
                            .have => self.parseHave(m),
                            else => log.err(
                                "[{any}] Expected bitfield but found '{t}'",
                                .{ self.addr, m.id },
                            ),
                        }
                        // register pieces
                        self.piece_picker.register_peer_pieces(self.peer_bitfield);
                    }
                } else |err| switch (err) {
                    error.Closed => log.warn(
                        "[{any}] Peer closed the connection",
                        .{self.addr},
                    ),
                    else => return err,
                }
            },
            .normal => try self.handleNormal(alloc, .READ),
        }
    }

    // TODO:
    pub fn handle_write(self: *Self, alloc: std.mem.Allocator) !void {
        switch (self.session.state) {
            .disconnected => {},
            .connecting => try self.connect(self.loop.?),
            .connected => try self.init_handshake(),
            .sending_handshake => try self.init_handshake(),
            .waiting_handshake => {},
            .waiting_availability => {},
            .normal => try self.handleNormal(alloc, .WRITE),
        }
    }

    // FIXME: maybe I should:
    // - create more SessionState fields, for each possible state like
    //   waiting_unchoke, etc...
    // and/or
    // - pass to each handler function like handleNormal() and aditional
    //   parameter like .READ, .WRITE so it has more context of the caller
    pub fn handleNormal(self: *Self, alloc: std.mem.Allocator, event: EventType) !void {
        // for now, if this peer for a disk request, just wait
        if (self.session.is_pending) {
            return;
        }

        if (event == .WRITE) {
            // write interested
            if (!self.session.is_interested and self.session.is_choked) {
                const written = try self.writer.writeMessage(.{
                    .id = .interested,
                    .payload = null,
                });

                if (written) {
                    // wait for unchoke
                    try self.loop.?.readMode(self);
                    self.session.is_interested = true;
                }
            }
            // request blocks
            else if (self.session.is_interested and !self.session.is_choked) {
                // if we are not downloading a piece, ask the picker one to download
                if (self.curr_piece == null) {
                    self.curr_piece = try self.piece_picker.pickPiece(self.peer_bitfield).?;
                    self.curr_piece_len = try self.torrent.calculatePieceSize(self.curr_piece);
                    self.requested = 0;
                    // realloc cuz this buffer might have been allocated before
                    self.piece_buf = try alloc.realloc(u8, self.curr_piece_len);
                }

                // request pipeline
                while (self.current_request_pipeline < self.target_request_pipeline and
                    self.requested < self.curr_piece_len)
                {
                    const block_size = @min(16 * 1024, self.current_piece_len - self.requested);
                    try self.sendRequest(self.curr_piece, self.requested, block_size);
                    self.requested += block_size;
                    self.current_request_pipeline += 1;
                }
                // wait for piece
                self.loop.?.readMode(self);
            }
        } else if (type == .READ) {
            // wait for unchoke
            if (self.session.is_interested and self.session.is_choked) {
                const message = try self.reader.readMessage(alloc);
                if (message) |msg| {
                    defer msg.deinit(alloc);
                    if (msg.id == .unchoke) {
                        // we can start requesting blocks
                        self.session.is_choked = false;
                        self.loop.?.writeMode(self);
                    }
                }
            }
            // try to read piece
            else if (self.session.is_interested and !self.session.is_choked) {
                const msg = (try self.reader.readMessage(alloc)).?;
                defer msg.deinit(alloc);

                if (msg.id == .piece) {
                    const index = std.mem.readInt(u32, msg.payload.?[0..4], .little);
                    const begin = std.mem.readInt(u32, msg.payload.?[4..8], .little);
                    const block: []const u8 = msg.payload.?[8..];

                    if (index == self.curr_piece) {
                        // write piece to buffer
                        @memcpy(self.piece_buf[begin..][0..block.len], block);

                        self.downloaded += @intCast(block.len);
                        self.current_request_pipeline -= 1;

                        // we downloaded a piece
                        if (self.downloaded == self.curr_piece_len) {
                            // submit store and hash request to filesystem thread
                            self.disk_io.submit(.{
                                .status = .request_store,
                                .index = self.curr_piece,
                                .payload = self.piece_buf,
                            });

                            // TODO: fix the IOMessage stuff
                            self.requested = 0;
                            self.downloaded = 0;
                            self.curr_piece = null;
                            self.curr_piece_len = null;
                            self.session.is_pending = true;

                            // we want to write requests now
                            self.loop.?.writeMode(self);
                        }
                    } else {
                        log.err("[{any}] peer send block from piece {d}, while we requested piece {d}", .{
                            self.addr,
                            index,
                            self.curr_piece,
                        });
                    }
                }
            }
        }
    }

    pub fn onIOMessage(self: *Self, io_message: Filesystem.IOAction) void {
        _ = self;
        _ = io_message;
        @panic("TODO: read FIXME on top.");
    }

    pub fn sendRequest(self: *Self, index: u32, begin: u32, length: u32) !void {
        var req_payload: [12]u8 = undefined;
        std.mem.writeInt(u32, req_payload[0..4], index, .little);
        std.mem.writeInt(u32, req_payload[4..8], begin, .little);
        std.mem.writeInt(u32, req_payload[8..12], length, .little);
        _ = try self.writer.writeMessage(.{
            .id = .request,
            .payload = &req_payload,
        });
    }

    pub fn connect(self: *Self, loop: *Epoll) !void {
        const sock_flags = std.posix.SOCK.STREAM | std.posix.SOCK.NONBLOCK | std.posix.SOCK.CLOEXEC;
        const sockfd = try std.posix.socket(self.addr.any.family, sock_flags, std.posix.IPPROTO.TCP);

        // connect non-blocking
        self.session.state = .connecting;
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

    pub fn init_handshake(self: *Self) !void {
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
        const written = try self.writer.writeHandshake(self.peer_id, self.torrent);

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

const log = std.log.scoped(.peer);

const std = @import("std");
const linux = std.os.linux;

const Epoll = @import("Epoll.zig");
const Message = @import("Message.zig");
const PiecePicker = @import("PiecePicker.zig");
const Reader = @import("Reader.zig");
const TorrentFile = @import("TorrentFile.zig");
const Filesystem = @import("Filesystem.zig");
const Tracker = @import("Tracker.zig");
const Writer = @import("Writer.zig");
