pub const Connection = struct {
    addr: std.net.Address,
    socket: std.posix_fd_t,
    state: State = .{},

    /// If we are in slowstart, we increment by one when a block arrives.
    target_req_queue_len: u32 = 1,
    /// default queue len
    current_req_queue_len: u32 = 5,
    /// last time we received a block
    last_incoming_block_time: std.time.Instant,
    /// last time we requested a block
    last_outgoing_request_time: std.time.Instant,

    const Self = @This();
    pub fn handshake() Self {}
};

pub const State = struct {
    is_choked: bool = true,
    is_interested: bool = false,
    in_endgame: bool = false,
    in_slowstart: bool = true,
    connection: enum {
        /// initial state
        disconnected,
        /// stabishing tcp connection
        connecting,
        /// interchanging handshakes
        handshaking,
        /// registering peer bitfield/have
        waiting_availability,
        /// normal operation mode
        connected,
    } = .disconected,
};

const std = @import("std");
const TorrentFile = @import("TorrentFile.zig");
const PiecePicker = @import("PiecePicker.zig");
const FileSystem = @import("Filesystem.zig");
const Tracker = @import("Tracker.zig");
