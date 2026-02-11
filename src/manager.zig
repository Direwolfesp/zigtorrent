//! Top level entity that handles the main event loop and coordination
//! between all compontents: filesystem thread, tracker requests, piece_picker,
//! peer connections.

const std = @import("std");
const linux = std.os.linux;

const Epoll = @import("Epoll.zig");
const Filesystem = @import("Filesystem.zig");
const IOMessage = Filesystem.IOMessage;
const peer = @import("peer.zig");
const PeerConnection = peer.PeerConnection;
const PiecePicker = @import("PiecePicker.zig");
const TorrentFile = @import("TorrentFile.zig");
const Tracker = @import("Tracker.zig");

const log = std.log.scoped(.manager);

/// maybe make it atomic?
pub var running: std.atomic.Value(bool) = .init(true);

pub const Session = struct {
    alloc: std.mem.Allocator,
    /// Unique identifier for this client
    peer_id: [20]u8 = undefined,
    /// stores all metadata related to the torrent file
    torrent: TorrentFile.TorrentManaged,
    /// for peer discovery and communicating progress to the tracker
    tracker: Tracker,
    /// Handles piece validation, and disk writes in a separate thread
    fs: Filesystem,
    /// Implements rarest-first algorithm for piece picking and manages all downloaded blocks status
    picker: PiecePicker,
    /// (un)register clients to the global epoll instance
    epoll: Epoll,
    /// socketfd -> *Peer
    peers: std.AutoHashMapUnmanaged(u64, *PeerConnection),

    pub fn init(alloc: std.mem.Allocator, torrent_path: []const u8) !Session {
        var t = try TorrentFile.open(alloc, torrent_path);
        errdefer t.deinit(alloc);

        // register sigint handler
        const action = std.posix.Sigaction{
            .handler = .{ .handler = handleSigInt },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        std.posix.sigaction(std.posix.SIG.INT, &action, null);

        var ret = Session{
            .alloc = alloc,
            .torrent = t,
            .tracker = undefined,
            .fs = undefined,
            .picker = undefined,
            .epoll = try Epoll.init(),
            .peers = .empty,
        };

        // initialize rest of the modules
        var tracker = try Tracker.init(&ret.torrent.meta);
        errdefer tracker.deinit(alloc);

        var fs_manager = try Filesystem.init(alloc, &ret.torrent.meta, 1024);
        errdefer fs_manager.deinit();

        var picker = try PiecePicker.init(&ret.torrent.meta, alloc);
        errdefer picker.deinit();

        fs_manager.ensureFsStructure() catch |err| {
            log.err("{t}. Exiting.", .{err});
            std.process.exit(1);
        };

        // contact with the tracker via http request to gather all
        // peers and reserve memory for them in the hashmap. Epoll
        // is limited to 128 peers so we reserve the minimum available.
        try tracker.announce(alloc);
        const expected_peer_capacity = @min(128, tracker.peers.?.len);
        var peers_map: std.AutoHashMapUnmanaged(u64, *PeerConnection) = .empty;
        try peers_map.ensureTotalCapacity(alloc, expected_peer_capacity);

        ret.tracker = tracker;
        ret.fs = fs_manager;
        ret.picker = picker;
        ret.peers = peers_map;
        return ret;
    }

    pub fn deinit(self: *Session) void {
        log.info("Destroying session...", .{});

        // Close peers
        var it = self.peers.iterator();
        while (it.next()) |entry| {
            const p = entry.value_ptr.*;
            self.epoll.removeClient(p) catch |err| {
                log.err("[{f}] Error while removing peer from eloop: {t} ", .{ p.addr, err });
            };
            p.deinit(self.alloc);
            self.alloc.destroy(p);
        }

        self.torrent.deinit(self.alloc);
        self.peers.deinit(self.alloc);
        self.fs.deinit();
        self.tracker.deinit(self.alloc);
        self.picker.deinit();
        self.epoll.deinit();
    }

    /// SIGIN handler, just stop it
    fn handleSigInt(sig: c_int) callconv(.c) void {
        if (sig == std.posix.SIG.INT)
            stop();
    }

    /// Add a prepared peer (PeerConnection already created and connected).
    pub fn addPeer(self: *Session, p: *PeerConnection) !void {
        const fd_key: u64 = @intCast(p.socket);
        _ = try self.peers.put(self.alloc, fd_key, p);
        try self.epoll.newClient(p);
    }

    pub fn removePeer(self: *Session, p: *PeerConnection) !void {
        const fd_key: u64 = @intCast(p.socket);

        _ = self.peers.remove(fd_key);
        try self.epoll.removeClient(p);

        p.deinit(self.alloc);
        self.alloc.destroy(p);
        log.info("{f} peer removed from session.", .{p.addr});

        if (self.peers.capacity() == 0) {
            log.info("{f} Peer count is 0, attempting to connecto to peers", .{p.addr});
            try self.connectToPeers();
        }
    }

    pub fn connectToPeers(self: *Session) !void {
        const peer_list = self.tracker.peers orelse return error.NoPeersFound;
        if (peer_list.len == 0) return error.NoPeersFound;

        // epoll uses 128 max so its appropiate
        const max_clients: usize = @intCast(@min(128, peer_list.len));

        // iterate peers and connect, wrap around if neeeded.
        var i: usize = @as(usize, @intCast(std.time.nanoTimestamp())) % peer_list.len;
        var tried: usize = 0;
        var connected: usize = 0;

        while (tried < peer_list.len and connected < max_clients) : ({
            i = (i + 1) % peer_list.len;
            tried += 1;
        }) {
            const peer_addr = peer_list[i];
            var p = try self.alloc.create(PeerConnection);
            errdefer self.alloc.destroy(p);

            p.* = PeerConnection.init(
                self.alloc,
                .{ .in = peer_addr },
                self.torrent.meta.getNumPieces(),
                self,
                PeerConnection.DEFAULT_WRITE_BUF,
                PeerConnection.DEFAULT_READ_BUF,
            ) catch |err| {
                log.err("Error initializing peer with address {f}: {t}", .{ peer_addr, err });
                self.alloc.destroy(p);
                continue;
            };

            // Attempt to connect
            p.connect(&self.epoll) catch |err| {
                log.err("[{f}] Connect error: {t}", .{ p.addr, err });
                p.deinit(self.alloc);
                self.alloc.destroy(p);
                continue;
            };

            // add peer to eloop
            self.addPeer(p) catch |err| {
                log.err("Error while registering peer to event loop: {t}", .{err});
                self.epoll.removeClient(p) catch |rem_err| {
                    log.err("[{f}] removeClient failed during cleanup: {t}", .{
                        p.addr,
                        rem_err,
                    });
                    p.deinit(self.alloc);
                    self.alloc.destroy(p);
                    continue;
                };
            };

            connected += 1;
        }

        log.info("attempted to connect with {d} peers, connected {d}", .{ tried, connected });
    }

    /// Main loop. This pumps epoll and the filesystem completion queue.
    /// It returns when stop() is called or on fatal error.
    pub fn run(self: *Session) !void {
        // try to spawn filesystem thread
        const fs_thread = try std.Thread.spawn(.{}, Filesystem.processTask, .{&self.fs});
        defer fs_thread.join();

        try self.connectToPeers();
        const poll_timeout_ms = 100;

        while (running.load(.monotonic)) {
            const events = self.epoll.wait(poll_timeout_ms);
            for (events) |r| {
                const socket_fd: u64 = @intCast(r.data.fd);
                const peer_conn: *PeerConnection = self.peers.get(socket_fd).?;

                if ((r.events & (linux.EPOLL.HUP | linux.EPOLL.ERR)) != 0) {
                    log.warn("[{f}] epoll HUP or ERR, this socket might have been closed. Disconnecting peer...", .{peer_conn.addr});
                    _ = try self.removePeer(peer_conn);
                    continue;
                }

                const ev: peer.EventType = if ((r.events & linux.EPOLL.IN) != 0)
                    .READ
                else if ((r.events & linux.EPOLL.OUT) != 0)
                    .WRITE
                else
                    continue;

                peer_conn.handle(self.alloc, ev) catch |err| {
                    log.err("[{f}] handle {t} error: {t}", .{ peer_conn.addr, ev, err });
                    _ = try self.removePeer(peer_conn);
                    continue;
                };
            }

            // process a fs completion
            if (self.fs.receive()) |io_msg| {
                self.onIOMessage(io_msg);
            }
        }
        log.info("exiting event loop", .{});
    }

    /// for now, it simply stops the `run()` loop
    pub fn stop() void {
        running.store(false, .monotonic);
        log.info("stopping manager...", .{});
    }

    /// callback to handle the io_message from the completion queue.
    pub fn onIOMessage(self: *Session, io_message: IOMessage) void {
        switch (io_message.status) {
            // The piece has been verified and finished
            .piece_completed => {
                log.info("Downloaded piece #{d} (total: {d}, connected peers: {d})", .{
                    io_message.index,
                    self.torrent.meta.getNumPieces(),
                    self.peers.count(),
                });
                self.picker.markPieceCompleted(io_message.index);
                self.tracker.onDownload(@intCast(self.torrent.meta.calculatePieceSize(io_message.index) catch 0));
            },
            // piece didn't pass the integrity check
            .integrity_failed => {
                @panic("TODO: maybe create a markPieceFailed(io_message.index");
            },
            // all pieces have been verified succesfully
            .shutdown => stop(),
            else => @panic("filesystem submitted a wrong message to the completion queue"),
        }
    }
};
