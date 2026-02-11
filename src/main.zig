const std = @import("std");
const assert = std.debug.assert;
const builtin = @import("builtin");

const Session = @import("manager.zig").Session;
const logger = @import("tests/logger.zig");

const log = std.log.scoped(.main);

pub const std_options: std.Options = .{
    .log_level = switch (builtin.mode) {
        .Debug => .debug,
        .ReleaseSafe, .ReleaseFast, .ReleaseSmall => .info,
    },
    .logFn = logger.logFn,
};

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    const gpa = if (builtin.mode != .ReleaseFast) debug_allocator.allocator() else std.heap.smp_allocator;
    defer if (builtin.mode != .ReleaseFast) std.debug.assert(debug_allocator.deinit() == .ok);

    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    const filename: []u8 = blk: {
        if (args.len == 2) {
            break :blk args[1];
        } else {
            log.err("Usage: .{s} <torrent>", .{args[0]});
            std.process.exit(1);
        }
    };

    var session: Session = try .init(gpa, filename);
    defer session.deinit();
    try session.run();
}

test {
    _ = std.testing.refAllDecls(@This());
}
