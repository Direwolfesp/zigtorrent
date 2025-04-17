const std = @import("std");
const stdout = std.io.getStdOut().writer();
const allocator = std.heap.page_allocator;

const BencodeValueType = enum {
    dict,
    lst,
    str,
    int,
};

const BencodeValue = union(BencodeValueType) {
    dict: std.StringArrayHashMap(BencodeValue),
    lst: std.ArrayList(BencodeValue),
    str: []const u8,
    int: i64,
};

const BencodeResponse = struct {
    read: usize,
    value: BencodeValue,
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
            const decodedStr = decode(encodedStr) catch |err| {
                try stdout.print("Invalid encoded value {}\n", .{err});
                std.process.exit(1);
            };
            var string = std.ArrayList(u8).init(allocator);
            defer string.deinit();
            try printBencodeValue(&string, decodedStr.value);
            const value = try string.toOwnedSlice();
            try stdout.print("{s}\n", .{value});
        },
        .info => {
            const fileName = args[2];
            const file = try std.fs.cwd().openFile(fileName, .{});
            defer file.close();
            const encodedStr = try file.readToEndAlloc(allocator, 1024 * 1024);
            const decodedStr: BencodeResponse = decode(encodedStr) catch |err| {
                try stdout.print("Invalid encoded value {}\n", .{err});
                std.process.exit(1);
            };
            const dict = decodedStr.value.dict;
            const announce = dict.get("announce").?;
            const info = dict.get("info").?;
            const length = info.dict.get("length").?;
            var string = std.ArrayList(u8).init(allocator);
            defer string.deinit();
            try encodeBencodeValue(&string, info);
            var hash: [std.crypto.hash.Sha1.digest_length]u8 = undefined;
            std.crypto.hash.Sha1.hash(try string.toOwnedSlice(), &hash, .{});
            try stdout.print("Tracker URL: {s}\nLength: {d}\nInfo Hash: {s}", .{ announce.str, length.int, std.fmt.fmtSliceHexLower(&hash) });
        },
    }
}
fn encodeBencodeValue(string: *std.ArrayList(u8), toEncode: BencodeValue) !void {
    switch (toEncode) {
        .str => |str| {
            try std.json.stringify(str.len, .{}, string.writer());
            try string.append(':');
            try string.appendSlice(str);
        },
        .int => |int| {
            try string.append('i');
            try std.json.stringify(int, .{}, string.writer());
            try string.append('e');
        },
        .lst => |lst| {
            try string.append('l');
            for (lst.items) |item| {
                try encodeBencodeValue(string, item);
            }
            try string.append('e');
        },
        .dict => |dict| {
            try string.append('d');
            var it = dict.iterator();
            while (it.next()) |kv| {
                try encodeBencodeValue(string, BencodeValue{ .str = kv.key_ptr.* });
                try encodeBencodeValue(string, kv.value_ptr.*);
            }
            try string.append('e');
        },
    }
}
fn printBencodeValue(string: *std.ArrayList(u8), val: BencodeValue) !void {
    switch (val) {
        .int => |int| {
            try std.json.stringify(int, .{}, string.writer());
        },
        .str => |str| {
            try std.json.stringify(str, .{}, string.writer());
        },
        .lst => |lst| {
            try string.append('[');
            var ctr: usize = 0;
            for (lst.items) |item| {
                if (ctr > 0) {
                    try string.append(',');
                }
                try printBencodeValue(string, item);
                ctr += 1;
            }
            try string.append(']');
        },
        .dict => |dict| {
            try string.append('{');
            var ctr: usize = 0;
            var it = dict.iterator();
            while (it.next()) |kv| {
                if (ctr > 0) {
                    try string.append(',');
                }
                try printBencodeValue(string, BencodeValue{ .str = kv.key_ptr.* });
                try string.append(':');
                try printBencodeValue(string, kv.value_ptr.*);
                ctr += 1;
            }
            try string.append('}');
        },
    }
}
fn decode(encodedValue: []const u8) !BencodeResponse {
    switch (encodedValue[0]) {
        'i' => {
            const integerIdentifier = std.mem.indexOf(u8, encodedValue, "e");
            if (integerIdentifier == null) {
                return error.InvalidArgument;
            }
            const decodedValue = try std.fmt.parseInt(i64, encodedValue[1..integerIdentifier.?], 10);
            return BencodeResponse{ .value = BencodeValue{ .int = decodedValue }, .read = integerIdentifier.? + 1 };
        },
        'l' => {
            if (encodedValue[encodedValue.len - 1] != 'e') {
                return error.InvalidArgument;
            }
            var list = std.ArrayList(BencodeValue).init(allocator);
            var startIdx: usize = 1;
            while (encodedValue[startIdx] != 'e') {
                const decoded = try decode(encodedValue[startIdx..]);
                if (decoded.read == 0) {
                    break;
                }
                try list.append(decoded.value);
                startIdx += decoded.read;
            }
            return BencodeResponse{ .value = BencodeValue{ .lst = list }, .read = startIdx + 1 };
        },
        '0'...'9' => {
            const firstColon = std.mem.indexOf(u8, encodedValue, ":");
            if (firstColon == null) {
                return error.InvalidArgument;
            }
            const lengthStr = encodedValue[0..firstColon.?];
            const length = try std.fmt.parseInt(u64, lengthStr, 10);
            const decodedStr = encodedValue[firstColon.? + 1 .. length + 1 + firstColon.?];
            return BencodeResponse{ .value = BencodeValue{ .str = decodedStr }, .read = length + 1 + firstColon.? };
        },
        'd' => {
            if (encodedValue[encodedValue.len - 1] != 'e') {
                return error.InvalidArgument;
            }
            var dict = std.StringArrayHashMap(BencodeValue).init(allocator);
            var startIdx: usize = 1;
            while (encodedValue[startIdx] != 'e') {
                const decodedKey = try decode(encodedValue[startIdx..]);
                if (decodedKey.value != .str) {
                    try stdout.print("Unsupported key: {any}\n", .{decodedKey});
                    return error.InvalidArgument;
                }
                startIdx += decodedKey.read;
                const decodedValue = try decode(encodedValue[startIdx..]);
                startIdx += decodedValue.read;
                try dict.put(decodedKey.value.str, decodedValue.value);
            }
            return BencodeResponse{ .value = BencodeValue{ .dict = dict }, .read = startIdx + 1 };
        },
        else => {
            try stdout.print("Unsupported value: {s}\n", .{encodedValue});
            return error.InvalidArgument;
        },
    }
}
