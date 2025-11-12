pub const Session = struct {
    alloc: std.mem.Allocator,

    peer_id: [20]u8,

    torrent: TorrentFile,

    tracker: Tracker,

    fs: Filesystem,

    picker: PiecePicker,

    epoll: Epoll,

    // socketfd -> *Peer
    peers: std.AutoHashMapUnmanaged(u64, *PeerConnection),

    running: bool,

    stop_signal: std.atomic.Value(bool),

    const Self = @This();

    pub fn init(
        alloc: std.mem.Allocator,
        torrent_path: []const u8,
    ) !Self {
        var torrent = try TorrentFile.open(alloc, torrent_path);
        errdefer torrent.deinit(alloc);

        var tracker = try Tracker.init(&torrent.meta);
        errdefer tracker.deinit(alloc);

        var fs_manager = try Filesystem.init(alloc, &torrent.meta, 1024);
        errdefer fs_manager.deinit();

        var picker = try PiecePicker.init(&torrent.meta, alloc);
        errdefer picker.deinit();

        // initialize rest of the modules
        fs_manager.ensureFsStructure() catch |err| {
            log.err("{t}. Exiting.", .{err});
            std.process.exit(1);
        };
        try tracker.announce(alloc);
        const expected_peer_capacity = @min(128, tracker.peers.?.len);

        var peers_map: std.AutoHashMapUnmanaged(u64, *PeerConnection) = .empty;
        try peers_map.ensureTotalCapacity(alloc, expected_peer_capacity);
        const ep = try Epoll.init();

        return Self{
            .peer_id = tracker.peer_id,
            .alloc = alloc,
            .torrent = torrent.meta,
            .tracker = tracker,
            .fs = fs_manager,
            .picker = picker,
            .epoll = ep,
            .peers = peers_map,
            .running = false,
            .stop_signal = .init(false),
        };
    }

    pub fn deinit(self: *Self) void {
        self.stop_signal.store(true, .seq_cst);

        // Close peers
        var it = self.peers.iterator();
        while (it.next()) |entry| {
            const peer = entry.value_ptr.*;
            self.epoll.removeClient(peer) catch |err| {
                log.err("[{f}] Error while removing peer from eloop: {t} ", .{ peer.addr, err });
            };
            peer.deinit(self.alloc) catch |err| {
                log.err("[{f}] Error while deinitializating peer: {t} ", .{ peer.addr, err });
            };
        }

        self.peers.deinit(self.alloc);

        self.fs.deinit();

        self.tracker.deinit(self.alloc);

        self.epoll.deinit();
    }

    /// Add a prepared peer (PeerConnection already created and connected).
    pub fn addPeer(self: *Self, peer: *PeerConnection) !void {
        const fd_key: u64 = @intCast(peer.socket);
        _ = try self.peers.put(self.alloc, fd_key, peer);
        try self.epoll.newClient(peer);
    }

    pub fn removePeer(self: *Self, peer: *PeerConnection) !void {
        const fd_key: u64 = @intCast(peer.socket);

        // we already do this in peer.deinit()
        // self.picker.unregister_peer_pieces(peer.peer_bitfield);
        _ = self.peers.remove(fd_key);
        try self.epoll.removeClient(peer);

        peer.deinit(self.alloc) catch |err| {
            log.err("peer.deinit failed: {t}", .{err});
        };
    }

    pub fn connectToPeers(self: *Self) !void {
        const peer_list = self.tracker.peers orelse return error.NoPeersFound;
        if (peer_list.len == 0) return error.NoPeersFound;

        // epoll uses 128 max so its appropiate
        const max_concurrent: usize = @intCast(@min(128, peer_list.len));
        var tried: usize = 0;
        var connected: usize = 0;

        var start_index: usize = 0;
        // random starting index
        if (peer_list.len > 1)
            start_index = @as(usize, @intCast(std.time.nanoTimestamp())) % peer_list.len;

        // iterate peers and connect, wrap around if neeeded.
        var i: usize = start_index;
        while (tried < peer_list.len and connected < max_concurrent) : (i = (i + 1) % peer_list.len) {
            const tracker_peer = peer_list[i];

            var p = try self.alloc.create(PeerConnection);

            const init_result = PeerConnection.init(
                self.alloc,
                .{ .in = tracker_peer },
                self.torrent.getNumPieces(),
                self,
                16 * 1024,
                16 * 1024,
            ) catch |err| {
                log.err("Error initializing peer with address {f}: {t}", .{ tracker_peer, err });
                self.alloc.destroy(p);
                tried += 1;
                continue;
            };
            p.* = init_result;

            // Attempt to connect
            p.connect(&self.epoll) catch |err| {
                log.err("[{f}] Connect error: {t}", .{ p.addr, err });

                // deinit peer
                p.deinit(self.alloc) catch |deinit_err| {
                    log.err("[{f}] error deinit after connect failure: {t}", .{ tracker_peer.addr, deinit_err });
                };
                self.alloc.destroy(p);
                tried += 1;
                continue;
            };

            // add peer to eloop
            self.addPeer(p) catch |err| {
                log.err("Error while registering peer to event loop: {t}", .{err});

                self.epoll.removeClient(p) catch |rem_err| {
                    log.err("[{f}] removeClient failed during cleanup: {t}", .{ p.addr, rem_err });
                    p.deinit(self.alloc) catch |deinit_err| {
                        log.err("[{f}] deinit after map put failure: {t}", .{ p.addr, deinit_err });
                    };
                    self.alloc.destroy(p);
                    tried += 1;
                    continue;
                };
            };

            // success:
            connected += 1;
            tried += 1;
        }

        log.info("tried to connect to {d} peers, connected {d}", .{ tried, connected });
    }

    /// Main loop. This pumps epoll and the filesystem completion queue.
    /// It returns when stop() is called (sets stop_signal) or on fatal error.
    pub fn run(self: *Self) !void {
        // try to spawn filesystem thread
        const fs_thread = try std.Thread.spawn(.{}, Filesystem.processTask, .{&self.fs});
        defer fs_thread.join();

        try self.connectToPeers();

        self.running = true;
        const poll_timeout_ms = 100;

        while (true) {
            if (self.stop_signal.load(.seq_cst)) break;

            const events = self.epoll.wait(poll_timeout_ms);
            for (events) |r| {
                const peer: *PeerConnection = @ptrFromInt(r.data.ptr);

                if ((r.events & (linux.EPOLL.HUP | linux.EPOLL.ERR)) != 0) {
                    log.warn("epoll: peer hup/err {d}", .{peer.socket});
                    _ = try self.removePeer(peer);
                    continue;
                }

                if ((r.events & linux.EPOLL.IN) != 0) {
                    peer.handle_read(self.alloc) catch |err| {
                        log.err("peer.handle_read error: {t}", .{err});
                        _ = try self.removePeer(peer);
                        continue;
                    };
                } else if ((r.events & linux.EPOLL.OUT) != 0) {
                    peer.handle_write(self.alloc) catch |err| {
                        log.err("peer.handle_write error: {t}", .{err});
                        _ = try self.removePeer(peer);
                        continue;
                    };
                }
            }

            // process fs competions
            while (self.fs.receive()) |io_msg| {
                io_msg.sender.onIOMessage(io_msg);
            }
        }
        self.running = false;
    }

    pub fn stop(self: *Self) void {
        self.stop_signal.store(true, .SeqCst);
    }
};

const log = std.log.scoped(.manager);

const std = @import("std");
const linux = std.os.linux;

const Epoll = @import("Epoll.zig");
const Filesystem = @import("Filesystem.zig");
const PeerConnection = @import("peer.zig").PeerConnection;
const PiecePicker = @import("PiecePicker.zig");
const TorrentFile = @import("TorrentFile.zig");
const Tracker = @import("Tracker.zig");
