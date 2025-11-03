//! This struct is reponsible of managing all filesystem operations
//! such as verifying the piece hashes and writing each piece to the apropiate
//! file. It should run in a different thread from the main loop and
//! comunicate via two queues to the user.
//!
//! Downloaded torrent might look like this:
//!
//! + --------------------------- +
//! |                             |
//! |        /path/file1          |
//! |                             |
//! + --------------------------- +
//! |                             |
//! |        /path/file2          |
//! |                             |
//! + --------------------------- +
//! |                             |
//! |        /path/file3          |
//! |                             |
//! + --------------------------- +
//! |                             |
//! |        /path/file4          |
//! |                             |
//! + --------------------------- +
//!
//! But the problem is that a file might:
//! - be made of one piece (for small files)
//! - be made of multiple pieces
//!
//!          + --------------------------- +
//!          |                             |
//! Piece 0  |            file1            |
//!          |                             |
//!          + --------+------------------ +
//!          |         |                   |
//! Piece 1  |  file1  |        file2      |
//!          |         |                   |
//!          + --------+------------------ +
//!          |                             |
//! Piece 2  |           file2             |
//!          |                             |
//!          + --------+---------+-------- +
//!          |         |         |         |
//! Piece 3  |  file2  |  file3  |  file4  |
//!          |         |         |         |
//!          + --------+---------+-------- +

alloc: std.mem.Allocator,
torr: *const TorrentFile,
submission_queue: undefined,
completion_queue: undefined, // TODO: add some queue

const Self = @This();

const IOMessage = struct {
    status: enum {
        PieceStored,
        IntegrityFailed,
        RequestStore,
    },
    index: u32,
    payload: ?[]const u8,
};

pub fn init(alloc: std.mem.Allocator, torr: *const TorrentFile) Self {
    return .{ .alloc = alloc, .torr = torr };
}

pub fn submit() void {
    // TODO:
}

pub fn receive() ?IOMessage {
    // TODO
}

fn processTask(self: Self) void {
    // TODO: pop from the submission queue and
    // process the task, which will be: hashing the piece,
    // check integrity and write it to disk.
    // Once is done, enqueue message back to completion
    // queue
}

pub fn ensureFsStructure(self: Self) !void {
    // TODO: it should make sure the file/files
    // are created in the filesystem. If they already
    // existed, that might considered an error
    switch (self.torr.getType()) {
        .SingleFile => {},
        .MultiFile => {},
    }
}

const std = @import("std");
const TorrentFile = @import("TorrentFile.zig");
