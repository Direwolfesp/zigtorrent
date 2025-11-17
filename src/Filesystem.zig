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
//!

const Self = @This();

pub const IOAction = enum {
    /// The piece needs to be checked
    check_integrity,
    /// The piece has been verified and finished
    piece_completed,
    /// The filesystem thread should send this message to the network thread when
    /// all pieces have been verified succesfully for a clean shutdown.
    shutdown,
    /// piece didn't pass the integrity check
    integrity_failed,
};

pub const IOMessage = struct {
    status: IOAction,
    /// piece index
    index: u32,
    /// client who submitted this message
    sender: *PeerConnection,
};

const FileInfo = struct {
    fd: std.fs.File,
    end_offset: i64,
    mmap_file: []align(std.heap.page_size_min) u8,
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
/// Keeps track of how many pieces did it hash already
count: usize = 0,
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

    for (self.files.items) |file_info| {
        std.posix.msync(file_info.mmap_file, std.posix.MSF.SYNC) catch |err| {
            log.err("Couldn't sync files to disk. Error: {t}", .{err});
        };
        std.posix.munmap(file_info.mmap_file);
        file_info.fd.close();
    }
    self.files.deinit(self.alloc);
}

/// Add a message to the queue. Blocks if full
pub fn submit(self: *Self, task: IOMessage) !void {
    log.debug("got a new submission: action = {t}, piece = {d}", .{ task.status, task.index });
    self.submission_queue.push(IOMessage{
        .status = task.status,
        .index = task.index,
        .sender = task.sender,
    });
}

/// Pop from completion queue, null if empty
pub fn receive(self: *Self) ?IOMessage {
    if (self.completion_queue.front()) |ret| {
        defer self.completion_queue.pop();
        return ret.*;
    }
    return null;
}

/// Pop's from the submission queue and
/// processes the task, which consists of:
/// - checking piece integrity
/// - notifying back the result
/// - keep count of hashed pieces
pub fn processTask(self: *Self) !void {
    log.info("Spawned filesystem main loop...", .{});

    while (true) {
        var task: IOMessage = (self.submission_queue.front() orelse {
            std.Thread.sleep(30 * std.time.ns_per_ms);
            continue;
        }).*;
        self.submission_queue.pop();

        log.debug("Processing task with id: {t}", .{task.status});

        switch (task.status) {
            .check_integrity => {
                defer self.completion_queue.push(task);

                if (try self.checkIntegrity(task.index)) {
                    log.debug("Piece #{d} verified successfully", .{task.index});
                    task.status = .piece_completed;
                    self.count += 1;

                    // if we hashed all pieces, notify the main thread we
                    // want to shutdown
                    if (self.count == self.torr.getNumPieces()) {
                        task.status = .shutdown;
                        break;
                    }
                } else {
                    task.status = .integrity_failed;
                    log.warn("Piece #{d} failed integrity check", .{task.index});
                }
            },
            else => @panic("got unhandled submission"),
        }
    }
}

/// Write the given block to the mmaped memory
pub fn writeBlock(self: Self, block: Block) void {
    // global byte offsets of the block within the logical file
    const write_start: i64 = block.index * self.torr.info.piece_length + block.begin;
    const write_end: i64 = write_start + @as(i64, @intCast(block.payload.len));

    var left = block.payload.len;
    var start_offset: i64 = 0;

    for (self.files.items) |file| {
        defer start_offset = file.end_offset;

        // safe to write region inside the file
        const region_start: i64 = @max(write_start, start_offset);
        const region_end: i64 = @min(write_end, file.end_offset);

        // block is another file
        if (region_end <= region_start)
            continue;

        const file_offset: usize = @intCast(region_start - start_offset);
        const payload_start: usize = @intCast(region_start - write_start);
        const payload_end: usize = @intCast(region_end - write_start);
        const written_len = payload_end - payload_start;

        @memcpy(
            file.mmap_file[file_offset .. file_offset + written_len],
            block.payload[payload_start..payload_end],
        );

        left -= written_len;
        if (left == 0) break;
    }

    std.debug.assert(left == 0);
}

/// Calculates SHA1 hash on the mmaped piece,
/// returns true on success, false on fail
fn checkIntegrity(self: *Self, piece_index: u32) !bool {
    const piece_len = try self.torr.calculatePieceSize(piece_index);
    const hash_start: i64 = piece_index * self.torr.info.piece_length;
    const hash_end: i64 = hash_start + piece_len;

    var sha1 = Sha1.init(.{});
    var left = piece_len; // number of bytes to be hased
    var file_start_offset: i64 = 0; // starting byte of the current file

    for (self.files.items) |*file| {
        defer file_start_offset = file.end_offset;

        const region_start: i64 = @max(hash_start, file_start_offset);
        const region_end: i64 = @min(hash_end, file.end_offset);

        // hash region is in other file
        if (region_end <= region_start)
            continue;

        const file_offset: usize = @intCast(region_start - file_start_offset);
        const payload_len: usize = @intCast(region_end - region_start);
        sha1.update(file.mmap_file[file_offset .. file_offset + payload_len]);

        left -= @intCast(payload_len);
        if (left == 0) break;
    }

    std.debug.assert(left == 0);
    return std.mem.eql(u8, &sha1.finalResult(), &self.torr.info.pieces[piece_index]);
}

/// It makes sure the file/files
/// are created in the filesystem. If they already
/// exist thats considered an error
pub fn ensureFsStructure(self: *Self) !void {
    switch (self.torr.getType()) {
        .single_file => try self.ensureSingleFile(),
        .multi_file => try self.ensureMultiFile(),
    }
    log.info("file structure created successfully", .{});
}

/// Creates the downloading file
fn ensureSingleFile(self: *Self) !void {
    const filename = self.torr.info.name;
    const file = std.fs.cwd().createFile(filename, .{
        .exclusive = true,
        .read = true,
    }) catch |err| switch (err) {
        error.PathAlreadyExists => {
            log.warn("File '{s}' already exists. Delete it first before downloading it again", .{filename});
            return err;
        },
        else => {
            log.warn("Could not create file: '{t}'", .{err});
            return err;
        },
    };

    try file.setEndPos(@intCast(self.torr.download_size));
    const mmap_file = try std.posix.mmap(
        null,
        @intCast(self.torr.download_size),
        std.posix.PROT.WRITE,
        .{ .TYPE = .SHARED },
        file.handle,
        0,
    );

    try self.files.append(self.alloc, .{
        .fd = file,
        .end_offset = self.torr.download_size,
        .mmap_file = mmap_file,
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

        const fd = std.fs.cwd().createFile(fullpath, .{
            .exclusive = true,
            .read = true,
        }) catch |err| switch (err) {
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

        try fd.setEndPos(@intCast(file.length));
        const mmap_file = try std.posix.mmap(
            null,
            @intCast(file.length),
            std.posix.PROT.WRITE,
            .{ .TYPE = .SHARED },
            fd.handle,
            0,
        );

        self.files.appendAssumeCapacity(.{
            .end_offset = file_sum,
            .fd = fd,
            .mmap_file = mmap_file,
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
const Block = @import("PiecePicker.zig").Block;
const TorrentFile = @import("TorrentFile.zig");
const PeerConnection = @import("peer.zig").PeerConnection;
const MessageQueue = spsc.SpscQueueUnmanaged(IOMessage, false);
