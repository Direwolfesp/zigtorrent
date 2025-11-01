const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

var err = std.fs.File.stderr().writer(&.{});
const stderr = &err.interface;

/// For sorting the key strings of the hash table
const Ctx = struct {
    map: std.StringArrayHashMap(Value),
    pub fn lessThan(self: @This(), a: usize, b: usize) bool {
        return std.mem.order(u8, self.map.keys()[a], self.map.keys()[b])
            .compare(.lt);
    }
};

pub const ParseError = error{
    /// Input begins with a character that is not a recognized Bencode type ([0-9], 'i', 'l', 'd').
    UnknownBencodeType,
    /// missing ':' or insufficient data.
    InvalidStringFormat,
    /// 'i' not followed by 'e', or bad data.
    InvalidIntegerFormat,
} || std.fmt.ParseIntError || Allocator.Error;

pub const Value = union(enum) {
    string: []const u8,
    integer: i64,
    list: std.ArrayList(Value),
    dict: std.StringArrayHashMap(Value),

    /// Givan a Value -> JSON string
    /// TODO: refactor this
    pub fn format(self: *const @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        const nested = if (false) "\n" else "";
        var json = std.json.Stringify{ .writer = writer };

        switch (self.*) {
            .string => |str| {
                try json.print("{s}{s}", .{ str, nested });
            },
            .integer => |int| {
                try json.print("{d}{s}", .{ int, nested });
            },
            .list => |list| {
                try writer.print("[", .{});
                for (list.items, 0..) |elem, i| {
                    try elem.format(writer);
                    if (i < list.items.len - 1)
                        try writer.print(",", .{});
                }
                try writer.print("]{s}", .{nested});
            },
            .dict => |dict| {
                try writer.print("{{", .{});
                var iter = dict.iterator();
                var i: usize = 0;
                while (iter.next()) |entry| : (i += 1) {
                    const key = Value{ .string = entry.key_ptr.* };
                    const val = entry.value_ptr.*;
                    try key.format(writer);
                    try writer.print(":", .{});
                    try val.format(writer);
                    if (i < dict.count() - 1) try writer.print(",", .{});
                }
                try writer.print("}}{s}", .{nested});
            },
        }
    }

    pub fn deinit(self: *@This(), allocator: Allocator) void {
        switch (self.*) {
            .list => |*list| {
                for (list.items) |*item| item.deinit(allocator);
                list.deinit(allocator);
            },
            .dict => |dict| {
                for (dict.values()) |*val| val.deinit(allocator);
                var tmp = dict;
                tmp.deinit();
            },
            else => {},
        }
    }

    /// Returns how many bytes does the bencoded value occupies
    pub fn len(self: *const @This()) usize {
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
                    list_len += elem.len();
                return list_len;
            },
            .dict => |dict| {
                var dict_len: usize = 2;
                var iter = dict.iterator();
                while (iter.next()) |entry| {
                    const key = Value{ .string = entry.key_ptr.* };
                    dict_len += key.len() + entry.value_ptr.len();
                }
                return dict_len;
            },
        };
    }

    /// Returns the Bencoded string from a BencodedValue
    pub fn encodeBencode(self: *const @This(), writer: *std.Io.Writer) !void {
        switch (self.*) {
            .string => |str| {
                try writer.print("{d}", .{str.len});
                try writer.writeByte(':');
                _ = try writer.write(str);
            },
            .integer => |int| {
                try writer.writeByte('i');
                try writer.print("{d}", .{int});
                try writer.writeByte('e');
            },
            .list => |list| {
                try writer.writeByte('l');
                for (list.items) |item|
                    try item.encodeBencode(writer);
                try writer.writeByte('e');
            },
            .dict => |dict| {
                try writer.writeByte('d');
                var it = dict.iterator();
                while (it.next()) |kv| {
                    const key = Value{ .string = kv.key_ptr.* };
                    const val = kv.value_ptr.*;
                    try key.encodeBencode(writer);
                    try val.encodeBencode(writer);
                }
                try writer.writeByte('e');
            },
        }
        try writer.flush(); // dont forget to flush
    }
}; // end BencodeValue

/// Given a Bencoded string -> BencodeValue
/// Caller owns the returned memory
pub fn decodeBencode(allocator: Allocator, encodedValue: []const u8) ParseError!Value {
    switch (encodedValue[0]) {
        '0'...'9' => {
            if (std.mem.indexOf(u8, encodedValue, ":")) |firstColon| {
                const strlen = try std.fmt.parseInt(
                    u32,
                    encodedValue[0..firstColon],
                    10,
                );
                return .{ .string = encodedValue[firstColon + 1 .. (firstColon + 1 + strlen)] };
            } else return ParseError.InvalidStringFormat;
        },
        'i' => {
            const endIndex = std.mem.indexOf(u8, encodedValue, "e") orelse return ParseError.InvalidIntegerFormat;
            return if (endIndex - 1 > 0)
                Value{ .integer = try std.fmt.parseInt(i64, encodedValue[1..endIndex], 10) }
            else
                ParseError.InvalidIntegerFormat;
        },
        'l' => {
            var decodedList: std.ArrayList(Value) = try .initCapacity(allocator, 0);
            errdefer decodedList.deinit(allocator);

            var i: usize = 1; // i points to the beginning of a Bencode Value
            while (i < encodedValue.len and encodedValue[i] != 'e') {
                var res = try decodeBencode(allocator, encodedValue[i..]);
                errdefer res.deinit(allocator);
                try decodedList.append(allocator, res);
                i += res.len();
            }
            return .{ .list = decodedList };
        },
        'd' => {
            var decodedDict = std.StringArrayHashMap(Value).init(allocator);
            errdefer decodedDict.deinit();

            var i: usize = 1;
            while (i < encodedValue.len and encodedValue[i] != 'e') {
                const key = try decodeBencode(allocator, encodedValue[i..]);
                std.debug.assert(key == .string);
                i += key.len();
                const val = try decodeBencode(allocator, encodedValue[i..]);
                try decodedDict.put(key.string, val);
                i += val.len();
            }
            decodedDict.sort(Ctx{ .map = decodedDict });
            return .{ .dict = decodedDict };
        },
        else => return ParseError.UnknownBencodeType,
    }
}

test "len" {
    const alloc = std.testing.allocator;
    {
        const val = "i-34e";
        const ben = try decodeBencode(alloc, val);
        try testing.expect(ben.len() == 5);
    }
    {
        const val = "i0e";
        const ben = try decodeBencode(alloc, val);
        try testing.expect(ben.len() == 3);
    }
    {
        const val = "i773e";
        const ben = try decodeBencode(alloc, val);
        try testing.expect(ben.len() == 5);
    }
    {
        const val = "10:HelloWorld";
        const ben = try decodeBencode(alloc, val);
        try testing.expect(ben.len() == 13);
    }
    {
        const val = "l10:HelloWorldi773ee";
        var ben = try decodeBencode(alloc, val);
        defer ben.deinit(alloc);
        try testing.expect(ben.len() == 20);
    }
}
