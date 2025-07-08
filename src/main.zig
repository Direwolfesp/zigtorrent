const std = @import("std");
const Torrent = @import("Torrent.zig");

const stdout = std.io.getStdOut().writer();

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    var thread_safe = std.heap.ThreadSafeAllocator{ .child_allocator = gpa.allocator() };
    const allocator = thread_safe.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // For testing
    if (std.mem.eql(u8, args[1], "info")) {
        const i_file = args[2];
        var torrent = try Torrent.open(allocator, i_file);
        defer torrent.deinit(allocator);
        try torrent.meta.printMetaInfo();
        return;
    }

    const i_file = args[1];
    const o_file = args[2];

    var torrent = try Torrent.open(allocator, i_file);
    defer torrent.deinit(allocator);

    if (try torrent.meta.download(allocator, o_file))
        try stdout.print("Torrent file downloaded succesfully to '{s}'\n", .{o_file});
}
