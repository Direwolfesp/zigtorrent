pub const std_options: std.Options = .{
    .log_level = switch (builtin.mode) {
        .Debug => .debug,
        .ReleaseSafe => .info,
        .ReleaseFast, .ReleaseSmall => .warn,
    },
};

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    const alloc = gpa.allocator();
    defer std.debug.assert(gpa.deinit() == .ok);

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
    const parse_torrent_time = timer.lap();

    var tracker = try Tracker.init(&torrent.meta);
    defer tracker.deinit(alloc);
    timer.reset();
    try tracker.announce(alloc);
    const get_peers_timer = timer.lap();

    log.debug("Parsed torrent in {D}", .{parse_torrent_time});
    log.debug("Got peers from tracker in {D}", .{get_peers_timer});

    var stdout_w = std.fs.File.stdout().writer(&.{});
    const stdout = &stdout_w.interface;
    try tracker.printState(stdout);
    try stdout.flush();

    defer torrent.deinit(alloc);
}

test {
    _ = std.testing.refAllDecls(@This());
    _ = Message;
    _ = @import("DiskIO.zig");
}

const log = std.log.scoped(.main);

const std = @import("std");
const assert = std.debug.assert;
const builtin = @import("builtin");

const bencode = @import("bencode.zig");
const Message = @import("Message.zig");
const TorrentFile = @import("TorrentFile.zig");
const Tracker = @import("Tracker.zig");
