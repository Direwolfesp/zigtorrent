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
            .string => |str| try writer.print("\"{s}\"", .{str}),
            .integer => |int| try writer.print("{}", .{int}),
            .list => |list_opt| {
                if (list_opt) |list| {
                    try writer.print("[", .{});
                    for (list.items, 0..) |elem, i| {
                        try elem.format(fmt, options, writer);
                        if (i < list.items.len - 1)
                            try writer.print(",", .{});
                    }
                    try writer.print("]", .{});
                }
            },
        }
    }

    pub fn deinit(self: *@This()) void {
        switch (self.*) {
            .list => |*list_ptr| {
                if (list_ptr.*) |*list| list.deinit();
            },
            else => {},
        }
    }

    // Returns how many bytes does the bencoded value occupies
    // @example 12.len() == 4bytes == "i12e"
    pub fn len(self: *const @This()) !usize {
        return switch (self.*) {
            .integer => |int| {
                var digits: usize = 0;
                var num: i64 = int;
                while (num != 0) {
                    digits += 1;
                    num = @divFloor(num, 10);
                }
                const symbols: u8 = if (num >= 0) 2 else 3;
                return digits + symbols;
            },
            .string => |str| {
                return str.len + 1 + std.fmt.count("{}", .{str.len});
            },
            .list => error.Unimplemented,
        };
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
        var decodedStr = decodeBencode(encodedStr) catch {
            try stdout.print("Invalid encoded value\n", .{});
            std.process.exit(1);
        };
        defer decodedStr.deinit();
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
            if (encodedValue[i] == 'e')
                break;
            const res = try decodeBencode(encodedValue[i..]);
            try decodedList.append(res);
            i += try res.len();
        }
        return .{ .list = decodedList };
    } else {
        try stdout.print("Only Strings, Integers and Lists are available at this moment\n", .{});
        std.process.exit(1);
    }
}
