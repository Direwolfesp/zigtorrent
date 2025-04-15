const std = @import("std");
const stdout = std.io.getStdOut().writer();
const allocator = std.heap.page_allocator;
const Map = std.StringArrayHashMapUnmanaged(Value);

const ParseError = error{
    InvalidArgument,
};

// For sorting the key strings of the hash table
const Ctx = struct {
    map: Map,
    pub fn lessThan(self: @This(), a: usize, b: usize) bool {
        return std.mem.order(u8, self.map.keys()[a], self.map.keys()[b])
            .compare(.lt);
    }
};

const Tokens = enum(u8) {
    List = 'l',
    Dict = 'd',
    Integer = 'i',
    End = 'e',

    fn isValid(token: u8) bool {
        _ = std.meta.intToEnum(@This(), token) catch {
            return std.ascii.isDigit(token);
        };
        return true;
    }
};

test "token is valid" {
    try std.testing.expect(Tokens.isValid('f') == false);
    try std.testing.expect(Tokens.isValid('i') == true);
    try std.testing.expect(Tokens.isValid('e') == true);
    try std.testing.expect(Tokens.isValid('d') == true);
    try std.testing.expect(Tokens.isValid('z') == false);
    try std.testing.expect(Tokens.isValid('2') == true);
}

const Value = union(enum) {
    string: []const u8,
    integer: i64,
    list: ?std.ArrayList(Value),
    dict: ?Map,

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
            .dict => |dict_opt| {
                if (dict_opt) |dict| {
                    try writer.print("{{", .{});
                    var iter = dict.iterator();
                    var i: usize = 0;
                    while (iter.next()) |entry| : (i += 1) {
                        const key = Value{ .string = entry.key_ptr.* };
                        const val = entry.value_ptr.*;
                        try key.format(fmt, options, writer, true);
                        try writer.print(":", .{});
                        try val.format(fmt, options, writer, true);
                        if (i < dict.count() - 1) try writer.print(",", .{});
                    }
                    try writer.print("}}", .{});
                    if (!nested) try writer.print("\n", .{});
                }
            },
        }
    }

    pub fn deinit(self: *@This()) void {
        switch (self.*) {
            .list => |list_opt| {
                if (list_opt) |list| {
                    for (list.items) |*item| {
                        item.deinit();
                    }
                    list.deinit();
                }
            },
            .dict => |dict_opt| {
                if (dict_opt) |*dict| {
                    for (dict.values()) |*val| {
                        val.deinit();
                    }
                    var tmp = dict.*;
                    tmp.deinit(allocator);
                }
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
            .dict => |optDict| {
                var dict_len: usize = 2;
                if (optDict) |dict| {
                    var iter = dict.iterator();
                    while (iter.next()) |entry| {
                        const key = Value{ .string = entry.key_ptr.* };
                        dict_len += try key.len() + try entry.value_ptr.*.len();
                    }
                }
                return dict_len;
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
    if (std.ascii.isDigit(encodedValue[0])) {
        if (std.mem.indexOf(u8, encodedValue, ":")) |firstColon| {
            const strlen: u32 = try std.fmt.parseInt(u32, encodedValue[0..firstColon], 10);
            return .{ .string = encodedValue[firstColon + 1 .. (firstColon + 1 + strlen)] };
        } else return ParseError.InvalidArgument;
    }
    // Integers
    else if (encodedValue[0] == @as(u8, @intFromEnum(Tokens.Integer))) {
        const endIndex = std.mem.indexOf(u8, encodedValue, "e") orelse return ParseError.InvalidArgument;
        if ((endIndex - 1) > 0 and encodedValue[1] != '0') {
            return .{ .integer = try std.fmt.parseInt(i64, encodedValue[1..endIndex], 10) };
        } else {
            return ParseError.InvalidArgument;
        }
    }
    // Lists
    else if (encodedValue[0] == @as(u8, @intFromEnum(Tokens.List))) {
        var decodedList = std.ArrayList(Value).init(allocator);
        errdefer decodedList.deinit();

        var i: usize = 1; // i points to the beginning of a Bencode Value
        while (i < encodedValue.len and encodedValue[i] != @as(u8, @intFromEnum(Tokens.End))) {
            const res = try decodeBencode(encodedValue[i..]);
            try decodedList.append(res);
            i += try res.len();

            if (i < encodedValue.len and !Tokens.isValid(encodedValue[i])) {
                return ParseError.InvalidArgument;
            }
        }
        return .{ .list = decodedList };
    }
    // Dict
    else if (encodedValue[0] == @as(u8, @intFromEnum(Tokens.Dict))) {
        var decodedDict: Map = .empty;
        errdefer decodedDict.deinit(allocator);

        var i: usize = 1;
        while (i < encodedValue.len and encodedValue[i] != @as(u8, @intFromEnum(Tokens.End))) {
            const key = try decodeBencode(encodedValue[i..]);
            i += try key.len();
            const val = try decodeBencode(encodedValue[i..]);
            try decodedDict.put(allocator, key.string, val);
            i += try val.len();

            if (i < encodedValue.len and !Tokens.isValid(encodedValue[i])) {
                return ParseError.InvalidArgument;
            }
        }
        decodedDict.sort(Ctx{ .map = decodedDict });
        return .{ .dict = decodedDict };
    } else {
        try stdout.print("Only Strings, Integers, Lists and Dictionaries are available at the moment: {c}\n", .{encodedValue[0]});
        std.process.exit(1);
    }
}
