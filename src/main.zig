const std = @import("std");
const assert = std.debug.assert;
const builtin = @import("builtin");

const bencode = @import("bencode.zig");
const Torrent = @import("Torrent.zig");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    const alloc = gpa.allocator();
    defer std.debug.assert(gpa.deinit() == .ok);

    var buf: [2048]u8 = undefined;
    var out = std.fs.File.stdout().writer(&buf);
    const stdout = &out.interface;

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    const filename: []u8 = blk: {
        if (args.len == 2) {
            break :blk args[1];
        } else {
            std.log.err("usage: ./program <torrent>", .{});
            std.process.exit(1);
        }
    };

    const start = try std.time.Instant.now();
    var torrent = try Torrent.open(alloc, filename);
    const end = try std.time.Instant.now();
    defer torrent.deinit(alloc);
    try torrent.meta.printMetaInfo(alloc, stdout);
    try stdout.print("Parsed torrent in {D}\n", .{end.since(start)});
    try stdout.flush();
}

test {
    _ = bencode;
    _ = Torrent;
    _ = @import("Message.zig");
}
