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
/// file structure of the torrent. Files have the same order as they appear in the metainfo.
/// Directories are omitted
files: std.ArrayList(FileInfo),
/// disk requests are stored here
submission_queue: MessageQueue,
/// written pieces are notified back here to the client
completion_queue: MessageQueue,
/// for checking integrity
hasher: std.crypto.hash.Sha1,

const FileInfo = struct {
    fd: std.fs.File,
    size: i64,
};

pub fn init(alloc: std.mem.Allocator, torr: *const TorrentFile, queue_bufsize: usize) !Self {
    return .{
        .alloc = alloc,
        .torr = torr,
        .completion_queue = try .initCapacity(alloc, queue_bufsize),
        .submission_queue = try .initCapacity(alloc, queue_bufsize),
        .files = .empty,
        .hasher = .init(.{}),
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

/// Calculates SHA1 on the piece payload
fn checkIntegrity(self: *Self, task: IOMessage) bool {
    std.debug.assert(self.torr.calculatePieceSize(task.index) == task.payload.len);
    std.debug.assert(task.status == .RequestStore);
    self.hasher.update(task.payload);
    const result = self.hasher.finalResult();
    return std.mem.eql(u8, &result, &self.torr.info.pieces[task.index]);
}

/// TODO: it should make sure the file/files
/// are created in the filesystem. If they already
/// existed, that might considered an error
pub fn ensureFsStructure(self: Self) !void {
    switch (self.torr.getType()) {
        .SingleFile => try self.ensureSingleFile(),
        .MultiFile => try self.ensureMultiFile(),
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

/// Creates the directory structure specfied in the multifile torrent and stores
/// references to the files in the same order the appear in the torrent
fn ensureMultiFile(self: *Self) !void {
    try self.files.ensureTotalCapacityPrecise(self.alloc, self.torr.info.mode.files.len);

    for (self.torr.info.mode.files) |file| {
        const path_components = try self.alloc.alloc([]const u8, file.path.len + 1); // +1 for the base
        defer self.alloc.free(path_components);

        // first path component is always the torrent name
        path_components[0] = self.torr.info.name;
        @memcpy(path_components[1..], file.path);

        const fullpath = try std.fs.path.join(self.alloc, path_components);
        defer self.alloc.free(fullpath);

        // the torrent name always acts as a dirname, so its safe to unwrap
        try std.fs.cwd().makePath(std.fs.path.dirname(fullpath).?);

        const fd = std.fs.cwd().createFile(fullpath, .{ .exclusive = true }) catch |err| switch (err) {
            error.PathAlreadyExists => {
                log.err("File '{s}' already exists. Delete it first before downloading it again", .{fullpath});
                return err;
            },
            else => {
                log.err("Could not create file: '{t}'", .{err});
                return err;
            },
        };

        self.files.appendAssumeCapacity(.{
            .size = file.length,
            .fd = fd,
        });
    }
}

test "fs_manager: ensure multi file" {
    const alloc = std.testing.allocator;

    var torr = try TorrentFile.open(alloc, "src/tests/torrents/BigBuckBunny_124_archive.torrent");
    defer torr.deinit(alloc);

    var fs_manager = try Self.init(alloc, &torr.meta, 1024);
    defer fs_manager.deinit();

    try fs_manager.ensureMultiFile();
    defer std.fs.cwd().deleteTree(torr.meta.info.name) catch |err| {
        log.err("Could not delete test dir... Error: {t}", .{err});
    };

    try testing.expectEqual(fs_manager.files.items.len, fs_manager.torr.info.mode.files.len);
}

test "fs_manager: ensure single file" {
    const alloc = std.testing.allocator;

    var torr = try TorrentFile.open(alloc, "src/tests/torrents/debian-12.11.0-amd64-netinst.iso.torrent");
    defer torr.deinit(alloc);

    var fs_manager = try Self.init(alloc, &torr.meta, 1024);
    defer fs_manager.deinit();

    try fs_manager.ensureSingleFile();
    defer std.fs.cwd().deleteFile("debian-12.11.0-amd64-netinst.iso") catch |err| {
        log.err("Could not delete test file... Error: {t}", .{err});
    };

    try testing.expectEqual(fs_manager.files.items.len, 1);
}

const log = std.log.scoped(.disk_io);

const std = @import("std");
const testing = std.testing;

const spsc = @import("spsc_queue");
const TorrentFile = @import("TorrentFile.zig");
const MessageQueue = spsc.SpscQueueUnmanaged(IOMessage, false);
