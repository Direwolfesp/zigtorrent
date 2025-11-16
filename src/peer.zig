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
    current_request_pipeline: u32 = 0,
    target_request_pipeline: u32 = 10,

    reader: Reader,
    writer: Writer,

    const Self = @This();
    /// default size for writer buffer
    pub const DEFAULT_WRITE_BUF = 0x4000;
    /// default size for reader buffer
    pub const DEFAULT_READ_BUF = 0x4000 * 2;

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
        };
    }

    pub fn deinit(self: *Self, alloc: std.mem.Allocator) !void {
        self.reader.deinit(alloc);
        self.writer.deinit(alloc);

        self.man.picker.unregister_peer_pieces(self.peer_bitfield);
        self.peer_bitfield.deinit(alloc);

        if (self.socket != -1)
            std.posix.close(self.socket);
    }

    pub fn parseBitfield(self: *Self, bitfield: Message) !void {
        std.debug.assert(bitfield.id == .bitfield);
        var index: u32 = 0;
        for (bitfield.payload.?) |bf_byte| {
            var mask: u8 = 0b1000_0000;
            for (0..8) |_| {
                if (mask & bf_byte != 0 and index < self.man.torrent.meta.getNumPieces()) {
                    self.peer_bitfield.set(index);
                }
                mask >>= 1;
                index += 1;
            }
        }
        self.session.state = .normal;
        log.debug("[{f}] parsed bitfield, going to normal mode", .{self.addr});
        try self.loop.?.writeMode(self); // we want to write interested
    }

    pub fn parseHave(self: *Self, have: Message) !void {
        std.debug.assert(have.id == .have);
        const piece: u32 = std.mem.readInt(u32, have.payload.?[0..4], .little);
        self.peer_bitfield.set(piece);
        try self.man.picker.inc_piece_refcount(piece);
        self.session.state = .normal;
        log.debug("[{f}] parsed have, going to normal mode", .{self.addr});
        try self.loop.?.writeMode(self); // we want to write interested
    }

    pub fn handle_read(self: *Self, alloc: std.mem.Allocator) !void {
        log.debug("[{f}] Entering handle read", .{self.addr});
        switch (self.session.state) {
            .disconnected => {},
            .connecting => {},
            .connected => {},
            .waiting_handshake => self.recv_handshake(
                self.man.peer_id,
                &self.man.torrent.meta,
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
                    const m = msg orelse return;
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
                    log.debug("[{f}] received bitfiled from peer, registering pieces...", .{self.addr});
                    self.man.picker.register_peer_pieces(self.peer_bitfield) catch |err| {
                        log.err("[{f}] Could not register peer pieces from his bitfield: {t}", .{ self.addr, err });
                    };
                } else |err| {
                    log.warn("[{f}] Error while waiting availability: {t}", .{
                        self.addr,
                        err,
                    });
                }
            },
            .normal => self.handleNormal(alloc, .READ) catch |err| switch (err) {
                error.Closed => {
                    log.warn("[{f}] handle normal: connection closed, removing peer", .{self.addr});
                    try self.man.removePeer(self);
                },
                else => return err,
            },
        }
    }

    pub fn handle_write(self: *Self, alloc: std.mem.Allocator) !void {
        log.debug("[{f}] Entering handle write", .{self.addr});
        switch (self.session.state) {
            .connecting => try self.connect(self.loop.?),
            .connected => try self.init_handshake(),
            .sending_handshake => try self.init_handshake(),
            .normal => try self.handleNormal(alloc, .WRITE),
            else => log.debug("[{f}] unhandled write: {t}", .{ self.addr, self.session.state }),
        }
    }

    pub fn handleNormal(self: *Self, alloc: std.mem.Allocator, event: EventType) !void {
        if (event == .WRITE) {
            // write interested
            if (!self.session.is_interested and self.session.is_choked) {
                log.debug("[{f}] sending interested\n", .{self.addr});
                const written = try self.writer.writeMessage(.{
                    .id = .interested,
                    .payload = null,
                });

                if (written) {
                    // wait for unchoke
                    log.debug("[{f}] sent interested\n", .{self.addr});
                    try self.loop.?.readMode(self);
                    self.session.is_interested = true;
                }
            }
            // request blocks
            else if (self.session.is_interested and !self.session.is_choked) {
                // request pipeline
                while (self.current_request_pipeline < self.target_request_pipeline) {
                    if (try self.man.picker.pickBlock(self)) |b| {
                        log.debug("[{f}] sending request {any}", .{ self.addr, b });
                        try self.sendRequest(b);
                        _ = try self.man.picker.updateBlockState(b.index, b.begin, .requested);
                        self.current_request_pipeline += 1;
                    } else {
                        // TODO: do something more usefull
                        log.warn("[{f}] request: could not pick block", .{self.addr});
                        break;
                    }
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
                        log.debug("[{f}] peer unchoked us", .{self.addr});
                        self.session.is_choked = false;
                        try self.loop.?.writeMode(self);
                    }
                }
            }
            // try to read piece
            else if (self.session.is_interested and !self.session.is_choked) {
                // if we didnt read any message return
                const msg = try self.reader.readMessage(alloc) orelse return;
                defer msg.deinit(alloc);

                if (msg.id == .piece) {
                    const block = Block{
                        .index = std.mem.readInt(u32, msg.payload.?[0..4], .big),
                        .begin = std.mem.readInt(u32, msg.payload.?[4..8], .big),
                        .payload = msg.payload.?[8..],
                    };
                    log.debug(
                        "[{f}] peer sent piece: {{ .index = {d}, .begin = {d}}}",
                        .{ self.addr, block.index, block.begin },
                    );

                    self.current_request_pipeline -= 1;

                    // write to disk
                    self.man.fs.writeBlock(block);

                    // mark it as downloaded
                    try self.man.picker.updateBlockState(block.index, block.begin, .downloaded);

                    // if we downloaded the whole piece already, mark blocks as verifying and
                    // enqueue task
                    if (self.man.picker.isPieceDownloaded(block.index)) {
                        self.man.picker.updateAllBlockStates(block.index, .verifying);
                        try self.man.fs.submit(.{
                            .status = .check_integrity,
                            .index = block.index,
                            .sender = self,
                        });
                    }

                    // if the request pipeline is empty, write again
                    // NOTE: this might not be very efficient
                    if (self.current_request_pipeline == 0) {
                        try self.loop.?.writeMode(self);
                    }
                }
            }
        }
    }

    pub fn sendRequest(self: *Self, block: BlockRequest) !void {
        var req_payload: [12]u8 = undefined;
        std.mem.writeInt(u32, req_payload[0..4], block.index, .big);
        std.mem.writeInt(u32, req_payload[4..8], block.begin, .big);
        std.mem.writeInt(u32, req_payload[8..12], block.length, .big);
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
        const written = try self.writer.writeHandshake(self.man.peer_id, &self.man.torrent.meta);

        // if we didnt manage to write the handshake keep writing
        if (!written) {
            log.debug("[{f}] handshake not fully sent", .{self.addr});
            self.loop.?.writeMode(self) catch |err| {
                log.err("Could not set socket {d} for writing: {t}", .{ self.socket, err });
            };
        } else {
            // switch to reading his handshake
            log.debug("[{f}] handshake sent", .{self.addr});
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
                log.warn("[{f}] invalid handshake: peer setn wrong protocol or info hash", .{self.addr});
                return error.InvalidHandshake;
            }

            if (std.mem.eql(u8, &peer_id, &hs.peer_id)) {
                log.warn("[{f}] invalid handshake: peer sent our same id.", .{self.addr});
                return error.InvalidHandshake;
            }

            log.debug("[{f}] handshaked successfully", .{self.addr});
            self.session.state = .waiting_availability;
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
const BlockRequest = PiecePicker.BlockRequest;
const Block = PiecePicker.Block;
const Reader = @import("Reader.zig");
const TorrentFile = @import("TorrentFile.zig");
const Filesystem = @import("Filesystem.zig");
const Tracker = @import("Tracker.zig");
const Writer = @import("Writer.zig");
const manager = @import("manager.zig");
