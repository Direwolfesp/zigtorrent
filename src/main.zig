const std = @import("std");
const stdout = std.io.getStdOut().writer();
const allocator = std.heap.page_allocator;

const ParseError = error{
    InvalidArgument,
};

const Value = union(enum) {
    string: []const u8,
    integer: i64,
    list: ?std.ArrayList(Value),

    pub fn format(self: @This(), comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        switch (self) {
            .string => |str| try writer.print("\"{s}\"\n", .{str}),
            .integer => |int| try writer.print("{}\n", .{int}),
            .list => |list_opt| {
                if (list_opt) |list| {
                    try writer.print("[", .{});
                    for (list.items) |elem| try elem.format(fmt, options, writer);
                    try writer.print("]", .{});
                }
            },
        }
    }

    pub fn deinit(self: *Value) void {
        switch (self.*) {
            .list => |*list_ptr| {
                if (list_ptr.*) |*list| list.deinit();
            },
            else => {},
        }
    }
};

pub fn main() !void {
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 3) {
        try stdout.print("Usage: your_bittorrent.zig <command> <args>\n", .{});
        std.process.exit(1);
    }

    const command = args[1];

    if (std.mem.eql(u8, command, "decode")) {
        std.debug.print("Logs from your program will appear here\n", .{});

        const encodedStr = args[2];
        const decodedStr = decodeBencode(encodedStr) catch {
            try stdout.print("Invalid encoded value\n", .{});
            std.process.exit(1);
        };
        try stdout.print("{}", .{decodedStr});
    }
}

fn decodeBencode(encodedValue: []const u8) !Value {
    // Strings
    if (encodedValue[0] >= '0' and encodedValue[0] <= '9') {
        const strlen: u32 = try std.fmt.parseInt(u32, encodedValue[0..1], 10);
        if (std.mem.indexOf(u8, encodedValue, ":")) |firstColon| {
            return .{ .string = encodedValue[firstColon + 1 .. (firstColon + 1 + strlen)] };
        } else return ParseError.InvalidArgument;
    }
    // Integers
    else if (encodedValue[0] == 'i') {
        const endIndex = std.mem.indexOf(u8, encodedValue, "e") orelse return ParseError.InvalidArgument;
        if ((endIndex - 1) > 0 and encodedValue[1] != '0') {
            return .{ .integer = try std.fmt.parseInt(i64, encodedValue[1..endIndex], 10) };
        } else {
            return ParseError.InvalidArgument;
        }
    }
    // Lists
    else if (encodedValue[0] == 'l') {
        var decodedList = std.ArrayList(Value).init(allocator);
        errdefer decodedList.deinit();

        var i: usize = 1;
        while (i < encodedValue.len) {
            if (encodedValue[i] == 'e') {
                break;
            }
            const res = try decodeBencode(encodedValue[i..]);
            try decodedList.append(res);

            switch (res) {
                .integer => |int| {
                    var digits: usize = 0;
                    var num: i64 = int;
                    while (num != 0) {
                        digits += 1;
                        num = @divFloor(num, 10);
                    }
                    i += (digits + 2);
                },
                .string => |str| {
                    i += str.len + 1 + std.fmt.count("{}", .{str.len});
                },
                .list => i += 1,
            }
        }

        return .{ .list = decodedList };
    } else {
        try stdout.print("Only Strings, Integers and Lists are available at this moment\n", .{});
        std.process.exit(1);
    }
}
