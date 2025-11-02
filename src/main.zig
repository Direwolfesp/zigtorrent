pub const std_options: std.Options = .{
    .log_level = switch (builtin.mode) {
        .Debug => .debug,
        .ReleaseSafe => .info,
        .ReleaseFast, .ReleaseSmall => .err,
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

    const start = try std.time.Instant.now();
    var torrent = try TorrentFile.open(alloc, filename);
    const end = try std.time.Instant.now();
    defer torrent.deinit(alloc);
    log.debug("Parsed torrent in {D}", .{end.since(start)});

    const tracker = try Tracker.init(&torrent.meta);
    try tracker.announce(alloc);
}

test {
    _ = std.testing.refAllDecls(@This());
}

const log = std.log.scoped(.main);

const std = @import("std");
const assert = std.debug.assert;
const builtin = @import("builtin");

const bencode = @import("bencode.zig");
const Message = @import("Message.zig");
const TorrentFile = @import("TorrentFile.zig");
const Tracker = @import("Tracker.zig");
