const std = @import("std");
const Torrent = @import("Torrent.zig");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = init.minimal.args.vector;

    const i_file: []const u8 = if (args.len >= 2)
        std.mem.span(args[1])
    else
        std.debug.panic("Expected a torrent file as first parameter\n", .{});

    var torrent = Torrent.open(io, gpa, i_file) catch return;
    defer torrent.deinit(gpa);

    const o_file: []const u8 = if (args.len >= 3)
        std.mem.span(args[2])
    else
        torrent.meta.info.name;

    if (try torrent.meta.download(io, gpa, o_file))
        std.debug.print("Torrent file downloaded succesfully to '{s}'\n", .{o_file});
}
