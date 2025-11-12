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

    // parent entity
    man: *manager.Session,

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
        man: *manager.Session,
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
            .man = man,
            .piece_buf = &.{},
        };
    }

    pub fn deinit(self: *Self, alloc: std.mem.Allocator) !void {
        self.reader.deinit(alloc);
        self.writer.deinit(alloc);

        self.man.picker.unregister_peer_pieces(self.peer_bitfield);
        self.peer_bitfield.deinit(alloc);

        // if (self.loop) |l|
        //     try l.removeClient(self);

        if (self.socket != -1)
            std.posix.close(self.socket);
    }

    pub fn parseBitfield(self: *Self, bitfield: Message) !void {
        std.debug.assert(bitfield.id == .bitfield);
        var index: u32 = 0;
        for (bitfield.payload.?) |bf_byte| {
            var mask: u8 = 0b1000_0000;
            for (0..8) |_| {
                if (mask & bf_byte != 0 and index < self.man.torrent.getNumPieces()) {
                    self.peer_bitfield.set(index);
                }
                mask >>= 1;
            }
            index += 1;
        }
        self.session.state = .normal;
        try self.loop.?.writeMode(self); // we want to write interested
    }

    pub fn parseHave(self: *Self, have: Message) !void {
        std.debug.assert(have.id == .have);
        const piece: u32 = std.mem.readInt(u32, have.payload.?[0..4], .little);
        self.peer_bitfield.set(piece);
        try self.man.picker.inc_piece_refcount(piece);
        self.session.state = .normal;
        try self.loop.?.writeMode(self); // we want to write interested
    }

    pub fn handle_read(self: *Self, alloc: std.mem.Allocator) !void {
        switch (self.session.state) {
            .disconnected => {},
            .connecting => {},
            .connected => {},
            .waiting_handshake => self.recv_handshake(
                self.man.peer_id,
                &self.man.torrent,
            ) catch |err|
                switch (err) {
                    error.InvalidHandshake => {
                        log.err(
                            "[{f}] Peer sent an invalid handshake, closing...",
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
                            .bitfield => try self.parseBitfield(m),
                            .have => try self.parseHave(m),
                            else => {
                                log.err("[{f}] Expected bitfield but found '{t}'", .{
                                    self.addr,
                                    m.id,
                                });
                                return;
                            },
                        }
                        log.info("[{f}] received bitfiled from peer, registering pieces...", .{self.addr});
                        try self.man.picker.register_peer_pieces(self.peer_bitfield);
                    }
                } else |err| {
                    log.warn("[{f}] Error while waiting availability: {t}", .{
                        self.addr,
                        err,
                    });
                }
            },
            .normal => try self.handleNormal(alloc, .READ),
        }
    }

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

    pub fn handleNormal(self: *Self, alloc: std.mem.Allocator, event: EventType) !void {
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
                    self.curr_piece = (try self.man.picker.pickPiece(self.peer_bitfield)).?;
                    self.curr_piece_len = @intCast(try self.man.torrent.calculatePieceSize(self.curr_piece.?));
                    self.requested = 0;
                    // NOTE: realloc the previous piece with the new size, the
                    // filesystem will still keep a copy of the previous one
                    self.piece_buf = try alloc.realloc(self.piece_buf, @intCast(self.curr_piece_len.?));
                }

                // request pipeline
                while (self.current_request_pipeline < self.target_request_pipeline and
                    self.requested < self.curr_piece_len.?)
                {
                    const block_size = @min(16 * 1024, self.curr_piece_len.? - self.requested);
                    try self.sendRequest(self.curr_piece.?, self.requested, block_size);
                    self.requested += block_size;
                    self.current_request_pipeline += 1;
                }
                // wait for piece
                try self.loop.?.readMode(self);
            }
        } else if (event == .READ) {
            // wait for unchoke
            if (self.session.is_interested and self.session.is_choked) {
                const message = try self.reader.readMessage(alloc);
                if (message) |msg| {
                    defer msg.deinit(alloc);
                    if (msg.id == .unchoke) {
                        // we can start requesting blocks
                        self.session.is_choked = false;
                        try self.loop.?.writeMode(self);
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
                            try self.man.fs.submit(.{
                                .sender = self,
                                .status = .request_store,
                                .index = @intCast(self.curr_piece.?),
                                .payload = self.piece_buf,
                            });

                            self.requested = 0;
                            self.downloaded = 0;
                            self.curr_piece = null;
                            self.curr_piece_len = null;

                            // we want to write requests now
                            try self.loop.?.writeMode(self);
                        }
                    } else {
                        log.err("[{f}] peer send block from piece {d}, while we requested piece {d}", .{
                            self.addr,
                            index,
                            self.curr_piece.?,
                        });
                    }
                }
            }
        }
    }

    /// callback to handle the io_message from the completion queue.
    pub fn onIOMessage(self: *Self, io_message: Filesystem.IOMessage) void {
        switch (io_message.status) {
            .store_success => {
                self.man.picker.updateAllBlockStates(io_message.index, .finished);
                self.man.picker.markPieceCompleted(io_message.index);
            },
            .integrity_failed, .write_failed => {
                self.man.picker.updateAllBlockStates(io_message.index, .pending);
            },
            else => {},
        }
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
        std.posix.connect(
            sockfd,
            &self.addr.any,
            self.addr.getOsSockLen(),
        ) catch |err| switch (err) {
            error.WouldBlock => {},
            else => return err,
        };

        self.socket = sockfd;
        self.loop = loop;
        self.writer.socket = sockfd;
        self.reader.socket = sockfd;
        self.session.state = .connected;
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
        const written = try self.writer.writeHandshake(self.man.peer_id, &self.man.torrent);

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
                !std.mem.eql(u8, &hs.info_hash, &torrent.info_hash))
            {
                log.warn("Invalid handshake from peer {f}, wrong protocol or info hash", .{self.addr});
                return error.InvalidHandshake;
            }

            if (std.mem.eql(u8, &peer_id, &hs.peer_id)) {
                log.warn("Invalid handshake from peer {f}, peer sent our same id.", .{self.addr});
                return error.InvalidHandshake;
            }

            log.debug("handshaked with peer {f}", .{self.addr});

            const n_bytes: usize = (self.man.torrent.getNumPieces() + 7) / 8;
            const empty_bytes = try self.man.alloc.alloc(u8, n_bytes);
            defer self.man.alloc.free(empty_bytes);

            // we try to start by sending out bitfield
            const written_bt = try self.writer.writeMessage(.{
                .id = .bitfield,
                .payload = empty_bytes,
            });

            //
            if (written_bt) {
                try self.loop.?.readMode(self);
                log.debug("[{f}] Bitfield sent successfully, going to read mode", .{self.addr});
                self.session.state = .waiting_availability;
                try self.loop.?.readMode(self);
            } else {
                log.debug("[{f}] bitfiled not sent completely", .{self.addr});
                try self.loop.?.writeMode(self);
            }

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
const manager = @import("manager.zig");
