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

const Self = @This();

const IOMessage = struct {
    status: enum(u8) {
        /// The piece has been written to disk succesfully
        StoreSuccess,
        /// Tells it wants to write the downloaded piece to disk
        RequestStore,
        /// piece didnt pass the integrity check
        IntegrityFailed,
        /// other fs error
        WriteFailed,
    },
    /// piece index
    index: u32,
    /// piece contents
    payload: []const u8,
};

alloc: std.mem.Allocator,
/// The current torrent
torr: *const TorrentFile,
/// file structure fo the torrent. Files sorted in the same order they appear in the torrent.
/// Directories are omitted
files: std.ArrayList(FileInfo),
/// lock free SCSP queues
submission_queue: MessageQueue,
completion_queue: MessageQueue,

const FileInfo = struct {
    fd: std.fs.File,
    size: i64,
};

pub fn init(alloc: std.mem.Allocator, torr: *const TorrentFile) !Self {
    return .{
        .alloc = alloc,
        .torr = torr,
        .completion_queue = try .initCapacity(alloc, 1024),
        .submission_queue = try .initCapacity(alloc, 1024),
        .files = .empty,
    };
}

/// Releases resources like queues and handles
pub fn deinit(self: *Self) void {
    self.completion_queue.deinit(self.alloc);
    self.submission_queue.deinit(self.alloc);

    for (self.files.items) |file_info|
        file_info.fd.close();
    self.files.deinit(self.alloc);
}

/// Add a message to the queue. Blocks if full
pub fn submit(self: *Self, task: IOMessage) void {
    std.debug.assert(task.payload.len <= self.torr.info.piece_length);
    self.submission_queue.push(task);
}

// Pop from completion queue, null if empty
pub fn receive(self: Self) ?*IOMessage {
    if (self.completion_queue.front()) |ret| {
        self.completion_queue.pop();
        return ret;
    }
    return null;
}

pub fn processTask() void {
    // TODO: pop from the submission queue and
    // process the task, which will be: hashing the piece,
    // check integrity and write it to disk.
    // Once is done, push message to completion
    // queue
}

pub fn ensureFsStructure(self: Self) !void {
    // TODO: it should make sure the file/files
    // are created in the filesystem. If they already
    // existed, that might considered an error
    switch (self.torr.getType()) {
        .SingleFile => try self.ensureSingleFile(),
        .MultiFile => {},
    }
}

/// Creates the downloading file
fn ensureSingleFile(self: *Self) !void {
    const filename = self.torr.info.name;
    const file = std.fs.cwd().createFile(filename, .{ .exclusive = true }) catch |err| switch (err) {
        error.PathAlreadyExists => {
            log.err("File '{s}' already exists. Delete it first before downloading it again", .{filename});
            return err;
        },
        else => {
            log.err("Could not create file: '{t}'", .{err});
            return err;
        },
    };

    try self.files.append(self.alloc, .{
        .fd = file,
        .size = self.torr.info.mode.length,
    });
}

fn ensureMultiFile(self: Self) !void {
    // TODO:
    _ = self;
}

test "disk_io: create single file" {
    const alloc = std.testing.allocator;

    var torr = try TorrentFile.open(alloc, "src/tests/torrents/debian-12.11.0-amd64-netinst.iso.torrent");
    defer torr.deinit(alloc);

    var fs_manager = try Self.init(alloc, &torr.meta);
    defer fs_manager.deinit();

    try fs_manager.ensureSingleFile();
    defer std.fs.cwd().deleteFile("debian-12.11.0-amd64-netinst.iso") catch {
        log.err("Could not delete test file...", .{});
    };

    try testing.expectEqual(fs_manager.files.items.len, 1);
}

const log = std.log.scoped(.disk_io);

const std = @import("std");
const testing = std.testing;

const spsc = @import("spsc_queue");
const TorrentFile = @import("TorrentFile.zig");
const MessageQueue = spsc.SpscQueueUnmanaged(IOMessage, false);
