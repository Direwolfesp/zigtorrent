const std = @import("std");
const Torrent = @import("Torrent.zig");

const stdout = std.io.getStdOut().writer();
const stderr = std.io.getStdErr().writer();

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    var thread_safe = std.heap.ThreadSafeAllocator{ .child_allocator = gpa.allocator() };
    const allocator = thread_safe.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const i_file = args[1];
    const o_file = args[2];

    var meta_managed = try Torrent.open(allocator, i_file);
    // try meta_managed.meta.printMetaInfo(); // TESTING PRINT
    defer meta_managed.deinit(allocator);

    try meta_managed.meta.download(allocator, o_file);
}
