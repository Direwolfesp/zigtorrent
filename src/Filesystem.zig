//! This struct is reponsible of managing all filesystem operations
//! such as verifying the piece hashes and writing each piece to the apropiate
//! file. It should run in a different thread from the main loop and
//! comunicate via two queues to the user.
//!
//! Downloaded torrent might look like this:
//!
//! + --------------------------- + 0kB
//! |                             |
//! |        /path/file1          | (real: 21kB)
//! |                             |
//! + --------------------------- + 21kB
//! |                             |
//! |        /path/file2          | (real: 32kB)
//! |                             |
//! + --------------------------- + 53kB
//! |                             |
//! |        /path/file3          | (real: 5kB)
//! |                             |
//! + --------------------------- + 58kB
//! |                             |
//! |        /path/file4          | (real: 5kB)
//! |                             |
//! + --------------------------- + 62kB
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
        store_success,
        /// Tells it wants to write the downloaded piece to disk
        request_store,
        /// Used to comunicate to the filesystem thread to stop all activity
        shutdown,
        /// piece didnt pass the integrity check
        integrity_failed,
        /// other fs error
        write_failed,
    },
    /// piece index
    index: u32,
    /// piece contents
    payload: []const u8,
};

const FileInfo = struct {
    fd: std.fs.File,
    end_offset: i64,
};

const Error = error{
    WriteFailed,
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

pub fn init(alloc: std.mem.Allocator, torr: *const TorrentFile, queue_bufsize: usize) !Self {
    return .{
        .alloc = alloc,
        .torr = torr,
        .completion_queue = try .initCapacity(alloc, queue_bufsize),
        .submission_queue = try .initCapacity(alloc, queue_bufsize),
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
pub fn receive(self: Self) ?IOMessage {
    if (self.completion_queue.front()) |ret| {
        defer self.completion_queue.pop();
        return ret.*;
    }
    return null;
}

/// TEST:
/// Pop's from the submission queue and
/// processes the task, which consists of:
/// - checking piece integrity
/// - writing it to disk
/// Once is done, push message to completion
/// queue, otherwise mark it as incomplete.
pub fn processTask(self: Self) void {
    while (true) {
        const task: *IOMessage = self.submission_queue.front() orelse {
            std.Thread.sleep(30 * std.time.ns_per_ms);
            continue;
        };
        self.submission_queue.pop();

        switch (task.status) {
            .request_store => {
                defer self.completion_queue.push(task.*);
                if (!self.checkIntegrity(task)) {
                    log.warn("Piece #{d} failed integrity check.", .{task.index});
                    task.status = .integrity_failed;
                    continue;
                }
                self.writePiece(task.*) catch |err| {
                    log.err("Could not write piece #{d}. Error: {t}", .{ task.index, err });
                    task.status = .write_failed;
                    continue;
                };
                task.status = .store_success;
            },
            .shutdown => break,
            else => unreachable,
        }
    }
}

/// Attempts to write piece content to the corresponding file(s).
/// In case of failure, caller might want to update the `task` status
/// to something appropiate.
fn writePiece(self: Self, task: IOMessage) !void {
    std.debug.assert(try self.torr.calculatePieceSize(task.index) == task.payload.len);

    // global byte offsets of the piece within the logical file
    const write_start: i64 = task.index * self.torr.info.piece_length;
    const write_end: i64 = write_start + task.payload.len;

    // number of bytes to be written
    var left = task.payload.len;

    var file_start_offset: i64 = 0; // starting byte of the current file
    var file_buf: [8192]u8 = undefined;

    for (self.files.items) |*file| {
        var writer = file.fd.writer(&file_buf);
        const file_writer = &writer.interface;

        defer file_start_offset = file.end_offset;

        const region_start: i64 = @max(write_start, file_start_offset);
        const region_end: i64 = @min(write_end, file.end_offset);

        // piece is another file
        if (region_end <= region_start)
            continue;

        const file_offset = region_start - file_start_offset;
        const payload_start = region_start - write_start;
        const payload_end = region_end - write_start;

        try writer.seekTo(file_offset);
        try file_writer.writeAll(task.payload[payload_start..payload_end]);
        try file_writer.flush();

        left -= payload_end - payload_start;
        if (left == 0) break;
    }

    std.debug.assert(left == 0);
}

/// Calculates SHA1 on the piece payload
fn checkIntegrity(self: *Self, task: *const IOMessage) bool {
    std.debug.assert(self.torr.calculatePieceSize(task.index) == task.payload.len);
    std.debug.assert(task.status == .request_store);
    var result: [Sha1.digest_length]u8 = undefined;
    Sha1.hash(task.payload, &result, .{});
    return std.mem.eql(u8, &result, &self.torr.info.pieces[task.index]);
}

/// It makes sure the file/files
/// are created in the filesystem. If they already
/// exist thats considered an error
pub fn ensureFsStructure(self: *Self) !void {
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
            log.warn("File '{s}' already exists. Delete it first before downloading it again", .{filename});
            return err;
        },
        else => {
            log.warn("Could not create file: '{t}'", .{err});
            return err;
        },
    };

    try self.files.append(self.alloc, .{
        .fd = file,
        .end_offset = self.torr.download_size,
    });
}

/// Creates the directory structure specfied in the multifile torrent and stores
/// references to the files in the same order the appear in the torrent
fn ensureMultiFile(self: *Self) !void {
    try self.files.ensureTotalCapacityPrecise(self.alloc, self.torr.info.mode.files.len);

    var path_buf: [std.posix.PATH_MAX]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&path_buf);
    const buffer_alloc = fba.allocator();
    var file_sum: i64 = 0;

    for (self.torr.info.mode.files) |file| {
        const path_components = try self.alloc.alloc([]const u8, file.path.len + 1); // +1 for the base
        defer self.alloc.free(path_components);

        // first path component is always the torrent name
        path_components[0] = self.torr.info.name;
        @memcpy(path_components[1..], file.path);

        const fullpath = try std.fs.path.join(buffer_alloc, path_components);
        defer buffer_alloc.free(fullpath);

        // the torrent name always acts as a dirname, so its safe to unwrap
        try std.fs.cwd().makePath(std.fs.path.dirname(fullpath).?);

        const fd = std.fs.cwd().createFile(fullpath, .{ .exclusive = true }) catch |err| switch (err) {
            error.PathAlreadyExists => {
                log.warn("File '{s}' already exists. Delete it first before downloading it again", .{fullpath});
                return err;
            },
            else => {
                log.warn("Could not create file: '{t}'", .{err});
                return err;
            },
        };
        log.debug("Created file '{s}'", .{fullpath});
        file_sum += file.length;

        self.files.appendAssumeCapacity(.{
            .end_offset = file_sum,
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

const log = std.log.scoped(.filesystem);

const std = @import("std");
const Sha1 = std.crypto.hash.Sha1;
const testing = std.testing;

const spsc = @import("spsc_queue");
const TorrentFile = @import("TorrentFile.zig");
const MessageQueue = spsc.SpscQueueUnmanaged(IOMessage, false);
