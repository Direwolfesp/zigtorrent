pub const std_options: std.Options = .{
    .log_level = switch (builtin.mode) {
        .Debug => .debug,
        .ReleaseSafe => .info,
        .ReleaseFast, .ReleaseSmall => .warn,
    },
    .logFn = logger.logFn,
};

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    const alloc = gpa.allocator();
    defer std.debug.assert(gpa.deinit() == .ok);

    var buf: [2048]u8 = undefined;
    var stdout_w = std.fs.File.stdout().writer(&buf);
    const stdout = &stdout_w.interface;

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    const filename: []u8 = blk: {
        if (args.len == 2) {
            break :blk args[1];
        } else {
            log.err("usage: ./program <torrent>", .{});
            std.process.exit(1);
        }
    };

    var timer = try std.time.Timer.start();
    var torrent = try TorrentFile.open(alloc, filename);
    defer torrent.deinit(alloc);
    const parse_torrent_time = timer.lap();

    var tracker = try Tracker.init(&torrent.meta);
    defer tracker.deinit(alloc);
    timer.reset();
    try tracker.announce(alloc);
    const get_peers_timer = timer.lap();

    var fs_manager = try Filesystem.init(alloc, &torrent.meta, 1024);
    defer fs_manager.deinit();

    fs_manager.ensureFsStructure() catch |err| {
        log.err("Could not create torrent structure in de filesystem: {t}", .{err});
    };

    log.debug("Parsed torrent in {D}", .{parse_torrent_time});
    log.debug("Got peers from tracker in {D}", .{get_peers_timer});

    try tracker.printState(stdout);
    try stdout.flush();
}

test {
    _ = std.testing.refAllDecls(@This());
    _ = Message;
    _ = Filesystem;
}

const log = std.log.scoped(.main);

const std = @import("std");
const assert = std.debug.assert;
const builtin = @import("builtin");

const logger = @import("tests/logger.zig");
const bencode = @import("bencode.zig");
const Message = @import("Message.zig");
const TorrentFile = @import("TorrentFile.zig");
const Tracker = @import("Tracker.zig");
const Filesystem = @import("Filesystem.zig");
