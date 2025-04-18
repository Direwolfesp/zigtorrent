const std = @import("std");
const Bencode = @import("Bencode.zig");
const BencodeValue = @import("Bencode.zig").BencodeValue;

const stdout = std.io.getStdOut().writer();
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const allocator = gpa.allocator();
const Map = std.StringArrayHashMap(Bencode);
const File = std.fs.File;
const Sha1 = std.crypto.hash.Sha1;

pub const ParseError = error{
    InvalidArgument,
};

const Commands = enum {
    decode,
    info,
    peers,
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
            var decodedStr = Bencode.decodeBencode(encodedStr) catch {
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

            var meta: BencodeValue = try Bencode.decodeBencode(content);
            defer meta.deinit();

            const metaDict = if (meta == .dict) meta.dict else @panic("Invalid torrent file.\n");
            const announce: BencodeValue = metaDict.get("announce").?;
            try stdout.print("Tracker URL: {s}\n", .{announce.string});

            // info dict and length
            const info: BencodeValue = metaDict.get("info") orelse @panic("info dictionary not found\n");
            const l: BencodeValue = info.dict.get("length") orelse {
                try stdout.print("Error: Only supports single file torrents\nFound: ", .{});
                const files = info.dict.get("files").?;
                try print(files, stdout, false);
                std.process.exit(1);
            };
            const length: i64 = l.integer;
            try stdout.print("Length: {d}\n", .{length});

            // Bencoded Info dictionary hashed
            var string = std.ArrayList(u8).init(allocator);
            defer string.deinit();
            try info.encodeBencode(&string);

            var sha1 = Sha1.init(.{});
            sha1.update(string.items);
            const hash_bytes: [Sha1.digest_length]u8 = sha1.finalResult();
            const hash_hex = std.fmt.fmtSliceHexLower(&hash_bytes);
            try stdout.print("Info Hash: {s}\n", .{hash_hex});

            // Piece length
            const piece_length: BencodeValue = info.dict.get("piece length").?;
            try stdout.print("Piece Length: {}\n", .{piece_length.integer});

            // Piece Hashes
            const pieces_hashes: []const u8 = info.dict.get("pieces").?.string;
            var hashes = std.ArrayList(u8).init(allocator);
            defer hashes.deinit();

            try stdout.print("Piece Hashes: \n", .{});
            var i: usize = 0;
            while (i < pieces_hashes.len) : (i += 20) {
                hashes.clearRetainingCapacity();
                try hashes.appendSlice(pieces_hashes[i .. i + 20]);
                const piece_hash_hex = std.fmt.fmtSliceHexLower(hashes.items);
                try stdout.print("{s}\n", .{piece_hash_hex});
            }
        },
        .peers => {
            // TODO
        },
    }
}

// Just for the annoying nested '\n' to pass the tests
fn print(val: BencodeValue, writer: anytype, nested: bool) !void {
    try val.format("", .{}, writer, nested);
}
