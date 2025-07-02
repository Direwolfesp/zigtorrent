const std = @import("std");
const Sha1 = std.crypto.hash.Sha1;
const Allocator = std.mem.Allocator;
const testing = std.testing;
const stdout = std.io.getStdOut().writer();

const Bencode = @import("Bencode.zig");

const MetaInfoError = error{
    WrongType,
    MisingField,
    NotSingleFile,
};

/// MetaInfo dictionary for bittorrent
/// Single File Only
pub const MetaInfo = struct {
    announce: []const u8 = undefined,
    info: Info,
    info_hash: [Sha1.digest_length]u8,

    /// Info dictionary for single file
    const Info = struct {
        piece_length: i64,
        pieces: []const u8,
        length: i64,
    };

    /// functions owns the memory, no need to  free
    pub fn init(allocator: Allocator, value: Bencode.Value) !MetaInfo {
        if (value != .dict) return MetaInfoError.WrongType;
        const metaDict = value.dict;

        // announce
        const announce: Bencode.Value = metaDict.get("announce") orelse return MetaInfoError.MisingField;
        if (announce != .string) return MetaInfoError.WrongType;

        // info
        const info = metaDict.get("info") orelse return MetaInfoError.MisingField;
        if (info != .dict) return MetaInfoError.WrongType;
        const infoDict = info.dict;

        var string = std.ArrayList(u8).init(allocator);
        defer string.deinit();

        try info.encodeBencode(&string);
        var sha1 = Sha1.init(.{});
        sha1.update(string.items);

        // length
        const length = infoDict.get("length") orelse return MetaInfoError.NotSingleFile;
        if (length != .integer) return MetaInfoError.WrongType;

        // piece length
        const piece_length = infoDict.get("piece length") orelse return MetaInfoError.MisingField;
        if (piece_length != .integer) return MetaInfoError.WrongType;

        // pieces
        const pieces = infoDict.get("pieces") orelse return MetaInfoError.MisingField;
        if (pieces != .string) return MetaInfoError.WrongType;

        return MetaInfo{
            .announce = announce.string,
            .info = .{
                .pieces = pieces.string,
                .piece_length = piece_length.integer,
                .length = length.integer,
            },
            .info_hash = sha1.finalResult(),
        };
    }

    pub fn printMetaInfo(self: @This()) !void {
        try stdout.print(
            \\Tracker URL: {s}
            \\Length: {d}
            \\Info Hash: {s}
            \\Piece Length: {d}
            \\
        , .{
            self.announce,
            self.info.length,
            std.fmt.fmtSliceHexLower(&self.info_hash),
            self.info.piece_length,
        });
        try self.printPieceHashes();
    }

    fn printPieceHashes(self: @This()) !void {
        try stdout.print("Piece Hashes: \n", .{});
        var win = std.mem.window(u8, self.info.pieces, 20, 20);
        while (win.next()) |hash| {
            const piece_hash_hex = std.fmt.fmtSliceHexLower(hash);
            try stdout.print("{s}\n", .{piece_hash_hex});
        }
    }
};
