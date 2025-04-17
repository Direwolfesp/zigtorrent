const std = @import("std");
const stdout = std.io.getStdOut().writer();
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const allocator = gpa.allocator();
const Map = std.StringArrayHashMap(Value);
const File = std.fs.File;
const Sha1 = std.crypto.hash.Sha1;

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

const Value = union(enum) {
    string: []const u8,
    integer: i64,
    list: std.ArrayList(Value),
    dict: Map,

    // Givan a Value -> JSON string
    pub fn format(self: @This(), comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype, nested: bool) !void {
        switch (self) {
            .string => |str| try std.json.stringify(str, .{}, writer),
            .integer => |int| try std.json.stringify(int, .{}, writer),
            .list => |list| {
                try writer.print("[", .{});
                for (list.items, 0..) |elem, i| {
                    try elem.format(fmt, options, writer, true);
                    if (i < list.items.len - 1) try writer.print(",", .{});
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
            .string => |str| 1 + str.len + std.fmt.count("{}", .{str.len}),
            .list => |list| {
                var list_len: usize = 2;
                for (list.items) |elem| {
                    list_len += try elem.len();
                }
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
};

const Commands = enum {
    decode,
    info,
};

pub fn main() !void {
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 3) {
        try stdout.print("Usage: your_bittorrent.zig <command> <args>\n", .{});
        std.process.exit(1);
    }

    const command = std.meta.stringToEnum(Commands, args[1]) orelse return;

    switch (command) {
        .decode => {
            const encodedStr = args[2];
            var decodedStr = decodeBencode(encodedStr) catch {
                try stdout.print("Invalid encoded value\n", .{});
                std.process.exit(1);
            };
            defer decodedStr.deinit();
            try print(decodedStr, stdout, false);
        },
        .info => {
            const filename = args[2];
            var file: File = try std.fs.cwd().openFile(filename, .{});
            defer file.close();

            const content = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
            defer allocator.free(content);

            var meta: Value = try decodeBencode(content);
            defer meta.deinit();

            const metaDict = if (meta == .dict) meta.dict else @panic("Invalid torrent file.\n");
            const announce: Value = metaDict.get("announce").?;
            try stdout.print("Tracker URL: {s}\n", .{announce.string});

            const info: Value = metaDict.get("info") orelse @panic("info field not found\n");
            const length: i64 = info.dict
                .get("length").?
                .integer;
            try stdout.print("Length: {d}\n", .{length});

            var string = std.ArrayList(u8).init(allocator);
            defer string.deinit();
            try encodeBencodeValue(&string, info);

            var sha1 = Sha1.init(.{});
            sha1.update(string.items);
            const hash_bytes: [Sha1.digest_length]u8 = sha1.finalResult();
            const hash_hex = std.fmt.fmtSliceHexLower(&hash_bytes);
            try stdout.print("Info Hash: {s}\n", .{hash_hex});
        },
    }
}

// Just for the annoying nested '\n' to pass the tests
fn print(val: Value, writer: anytype, nested: bool) !void {
    try val.format("", .{}, writer, nested);
}

// Given a Bencoded string -> Value
fn decodeBencode(encodedValue: []const u8) !Value {
    switch (encodedValue[0]) {
        '0'...'9' => {
            if (std.mem.indexOf(u8, encodedValue, ":")) |firstColon| {
                const strlen: u32 = try std.fmt.parseInt(u32, encodedValue[0..firstColon], 10);
                return .{ .string = encodedValue[firstColon + 1 .. (firstColon + 1 + strlen)] };
            } else return ParseError.InvalidArgument;
        },
        'i' => {
            const endIndex = std.mem.indexOf(u8, encodedValue, "e") orelse return ParseError.InvalidArgument;
            if ((endIndex - 1) > 0 and encodedValue[1] != '0') {
                return .{ .integer = try std.fmt.parseInt(i64, encodedValue[1..endIndex], 10) };
            } else {
                return ParseError.InvalidArgument;
            }
        },
        'l' => {
            var decodedList = std.ArrayList(Value).init(allocator);
            errdefer decodedList.deinit();

            var i: usize = 1; // i points to the beginning of a Bencode Value
            while (i < encodedValue.len and encodedValue[i] != 'e') {
                const res = try decodeBencode(encodedValue[i..]);
                try decodedList.append(res);
                i += try res.len();
            }
            return .{ .list = decodedList };
        },
        'd' => {
            var decodedDict: Map = Map.init(allocator);
            errdefer decodedDict.deinit();

            var i: usize = 1;
            while (i < encodedValue.len and encodedValue[i] != 'e') {
                const key = try decodeBencode(encodedValue[i..]);
                i += try key.len();
                const val = try decodeBencode(encodedValue[i..]);
                try decodedDict.put(key.string, val);
                i += try val.len();
            }
            decodedDict.sort(Ctx{ .map = decodedDict });
            return .{ .dict = decodedDict };
        },
        else => {
            try stdout.print("Only Strings, Integers, Lists and Dictionaries are available at the moment: {c}\n", .{encodedValue[0]});
            std.process.exit(1);
        },
    }
}

// Given a Value -> Bencoded string
fn encodeBencodeValue(string: *std.ArrayList(u8), toEncode: Value) !void {
    switch (toEncode) {
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
            for (list.items) |item| {
                try encodeBencodeValue(string, item);
            }
            try string.append('e');
        },
        .dict => |dict| {
            try string.append('d');
            var it = dict.iterator();
            while (it.next()) |kv| {
                try encodeBencodeValue(string, Value{ .string = kv.key_ptr.* });
                try encodeBencodeValue(string, kv.value_ptr.*);
            }
            try string.append('e');
        },
    }
}
