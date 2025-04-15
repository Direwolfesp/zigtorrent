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

    pub fn format(self: @This(), comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype, nested: bool) !void {
        switch (self) {
            .string => |str| {
                try writer.print("\"{s}\"", .{str});
                if (!nested) try writer.print("\n", .{});
            },
            .integer => |int| {
                try writer.print("{}", .{int});
                if (!nested) try writer.print("\n", .{});
            },
            .list => |list_opt| {
                if (list_opt) |list| {
                    try writer.print("[", .{});
                    for (list.items, 0..) |elem, i| {
                        try elem.format(fmt, options, writer, true);
                        if (i < list.items.len - 1) try writer.print(",", .{});
                    }
                    try writer.print("]", .{});
                    if (!nested) try writer.print("\n", .{});
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
                var num: u64 = @abs(int);
                while (num != 0) {
                    digits += 1;
                    num = @divFloor(num, 10);
                }
                const symbols: u8 = if (int >= 0) 2 else 3;
                return digits + symbols;
            },
            .string => |str| {
                return str.len + 1 + std.fmt.count("{}", .{str.len});
            },
            .list => |optList| {
                var list_len: usize = 2;
                if (optList) |list| {
                    for (list.items) |elem| {
                        list_len += try elem.len();
                    }
                }
                return list_len;
            },
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
        try print(decodedStr, stdout, false);
    }
}

// Just for the annoying nested '\n' to pass the tests
fn print(val: Value, writer: anytype, nested: bool) !void {
    try val.format("", .{}, writer, nested);
}

fn decodeBencode(encodedValue: []const u8) !Value {
    // Strings
    if (encodedValue[0] >= '0' and encodedValue[0] <= '9') {
        if (std.mem.indexOf(u8, encodedValue, ":")) |firstColon| {
            const strlen: u32 = try std.fmt.parseInt(u32, encodedValue[0..firstColon], 10);
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

        var i: usize = 1; // i points to the beginning of a Bencode Value
        while (i < encodedValue.len and encodedValue[i] != 'e') {
            const res = try decodeBencode(encodedValue[i..]);
            try decodedList.append(res);
            i += try res.len();

            if (i < encodedValue.len and encodedValue[i] != 'e' and encodedValue[i] != 'i' and
                !(encodedValue[i] >= '0' and encodedValue[i] <= '9') and encodedValue[i] != 'l')
            {
                return ParseError.InvalidArgument;
            }
        }
        return .{ .list = decodedList };
    } else {
        try stdout.print("Only Strings, Integers and Lists are available at this moment\n", .{});
        std.process.exit(1);
    }
}
