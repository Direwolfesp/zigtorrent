const std = @import("std");
const Torrent = @import("Torrent.zig");

const stdout = std.io.getStdOut().writer();

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    var thread_safe = std.heap.ThreadSafeAllocator{ .child_allocator = gpa.allocator() };
    const allocator = thread_safe.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const i_file: []const u8 = if (args.len >= 2)
        args[1]
    else
        std.debug.panic("Expected a torrent file as first parameter\n", .{});

    var torrent = Torrent.open(allocator, i_file) catch return;
    defer torrent.deinit(allocator);

    const o_file: []const u8 = if (args.len >= 3)
        args[2]
    else
        torrent.meta.info.name;

    if (try torrent.meta.download(allocator, o_file))
        try stdout.print("Torrent file downloaded succesfully to '{s}'\n", .{o_file});
}
