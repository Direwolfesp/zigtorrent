const std = @import("std");
const stdout = std.io.getStdOut().writer();
const testing = std.testing;
const Allocator = std.mem.Allocator;

/// For sorting the key strings of the hash table
const Ctx = struct {
    map: std.StringArrayHashMap(Value),
    pub fn lessThan(self: @This(), a: usize, b: usize) bool {
        return std.mem.order(u8, self.map.keys()[a], self.map.keys()[b])
            .compare(.lt);
    }
};

pub const ParseError = error{
    InvalidArgument,
    IntegerNotFound,
    IllegalInteger,
    StringError,
};

pub const Value = union(enum) {
    string: []const u8,
    integer: i64,
    list: std.ArrayList(Value),
    dict: std.StringArrayHashMap(Value),

    /// Givan a Value -> JSON string
    pub fn format(
        self: @This(),
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
        nested: bool,
    ) !void {
        switch (self) {
            .string => |str| {
                try std.json.stringify(str, .{}, writer);
                if (!nested) try writer.print("\n", .{});
            },
            .integer => |int| {
                try std.json.stringify(int, .{}, writer);
                if (!nested) try writer.print("\n", .{});
            },
            .list => |list| {
                try writer.print("[", .{});
                for (list.items, 0..) |elem, i| {
                    try elem.format(fmt, options, writer, true);
                    if (i < list.items.len - 1)
                        try writer.print(",", .{});
                }
                try writer.print("]", .{});
                if (!nested) try writer.print("\n", .{});
            },
            .dict => |dict| {
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
            },
        }
    }

    pub fn deinit(self: *@This()) void {
        switch (self.*) {
            .list => |list| {
                for (list.items) |*item| {
                    item.deinit();
                }
                list.deinit();
            },
            .dict => |dict| {
                for (dict.values()) |*val| {
                    val.deinit();
                }
                var tmp = dict;
                tmp.deinit();
            },
            else => {},
        }
    }

    /// Returns how many bytes does the bencoded value occupies
    pub fn len(self: *const @This()) !usize {
        return switch (self.*) {
            .integer => |int| {
                const abs = @abs(int);
                const digits: usize = if (abs == 0) 1 else std.math.log10(abs) + 1;
                const symbols: u8 = if (int >= 0) 2 else 3;
                return digits + symbols;
            },
            .string => |str| 1 + str.len + std.fmt.count("{}", .{str.len}),
            .list => |list| {
                var list_len: usize = 2;
                for (list.items) |elem|
                    list_len += try elem.len();
                return list_len;
            },
            .dict => |dict| {
                var dict_len: usize = 2;
                var iter = dict.iterator();
                while (iter.next()) |entry| {
                    const key = Value{ .string = entry.key_ptr.* };
                    dict_len += try key.len() + try entry.value_ptr.len();
                }
                return dict_len;
            },
        };
    }

    /// Returns the Bencoded string from a BencodedValue
    pub fn encodeBencode(self: @This(), string: *std.ArrayList(u8)) !void {
        switch (self) {
            .string => |str| {
                try std.json.stringify(str.len, .{}, string.writer());
                try string.append(':');
                try string.appendSlice(str);
            },
            .integer => |int| {
                try string.append('i');
                try std.json.stringify(int, .{}, string.writer());
                try string.append('e');
            },
            .list => |list| {
                try string.append('l');
                for (list.items) |item|
                    try item.encodeBencode(string);
                try string.append('e');
            },
            .dict => |dict| {
                try string.append('d');
                var it = dict.iterator();
                while (it.next()) |kv| {
                    const key = Value{ .string = kv.key_ptr.* };
                    const val = kv.value_ptr.*;
                    try key.encodeBencode(string);
                    try val.encodeBencode(string);
                }
                try string.append('e');
            },
        }
    }
}; // end BencodeValue

/// Given a Bencoded string -> BencodeValue
pub fn decodeBencode(allocator: Allocator, encodedValue: []const u8) !Value {
    switch (encodedValue[0]) {
        '0'...'9' => {
            if (std.mem.indexOf(u8, encodedValue, ":")) |firstColon| {
                const strlen: u32 = try std.fmt.parseInt(
                    u32,
                    encodedValue[0..firstColon],
                    10,
                );
                return .{
                    .string = encodedValue[firstColon + 1 .. (firstColon + 1 + strlen)],
                };
            } else return ParseError.StringError;
        },
        'i' => {
            const endIndex = std.mem.indexOf(u8, encodedValue, "e");
            if (endIndex) |index| {
                if (index - 1 > 0) {
                    return .{
                        .integer = try std.fmt.parseInt(i64, encodedValue[1..index], 10),
                    };
                }
                return ParseError.IllegalInteger;
            }
            return ParseError.IntegerNotFound;
        },
        'l' => {
            var decodedList = std.ArrayList(Value).init(allocator);
            errdefer decodedList.deinit();

            var i: usize = 1; // i points to the beginning of a Bencode Value
            while (i < encodedValue.len and encodedValue[i] != 'e') {
                const res = try decodeBencode(allocator, encodedValue[i..]);
                try decodedList.append(res);
                i += try res.len();
            }
            return .{ .list = decodedList };
        },
        'd' => {
            var decodedDict = std.StringArrayHashMap(Value).init(allocator);
            errdefer decodedDict.deinit();

            var i: usize = 1;
            while (i < encodedValue.len and encodedValue[i] != 'e') {
                const key = try decodeBencode(allocator, encodedValue[i..]);
                i += try key.len();
                const val = try decodeBencode(allocator, encodedValue[i..]);
                try decodedDict.put(key.string, val);
                i += try val.len();
            }
            decodedDict.sort(Ctx{ .map = decodedDict });
            return .{ .dict = decodedDict };
        },
        else => {
            try stdout.print(
                "Only Strings, Integers, Lists and Dictionaries are available at the moment: {c}\n",
                .{encodedValue[0]},
            );
            std.process.exit(1);
        },
    }
}

/// Owns the content from the file,
/// thus requires freeing memory with deinit()
pub const ValueManaged = struct {
    value: Value,
    backing_buffer: []u8,

    pub fn deinit(self: *@This(), allocator: Allocator) void {
        self.value.deinit();
        allocator.free(self.backing_buffer);
    }
};

/// Parses a file and returns its decoded content.
/// Caller owns the returned memory
pub fn decodeBencodeFromFile(allocator: Allocator, path: []const u8) !ValueManaged {
    var file: std.fs.File = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const content: []u8 = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    return .{
        .value = try decodeBencode(allocator, content),
        .backing_buffer = content,
    };
}

test "len" {
    const alloc = std.testing.allocator;
    {
        const val = "i-34e";
        const ben = try decodeBencode(alloc, val);
        try testing.expect(try ben.len() == 5);
    }

    {
        const val = "i0e";
        const ben = try decodeBencode(alloc, val);
        try testing.expect(try ben.len() == 3);
    }

    {
        const val = "i773e";
        const ben = try decodeBencode(alloc, val);
        try testing.expect(try ben.len() == 5);
    }

    {
        const val = "10:HelloWorld";
        const ben = try decodeBencode(alloc, val);
        try testing.expect(try ben.len() == 13);
    }

    {
        const val = "l10:HelloWorldi773ee";
        var ben = try decodeBencode(alloc, val);
        defer ben.deinit();
        try testing.expect(try ben.len() == 20);
    }
}
