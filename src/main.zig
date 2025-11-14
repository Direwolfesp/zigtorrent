pub const std_options: std.Options = .{
    .log_level = switch (builtin.mode) {
        .Debug => .debug,
        .ReleaseSafe, .ReleaseFast, .ReleaseSmall => .info,
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

    var session: manager.Session = try .init(alloc, filename);
    defer session.deinit();

    try session.run();

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
const manager = @import("manager.zig");
