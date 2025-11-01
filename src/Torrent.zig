const std = @import("std");
const Sha1 = std.crypto.hash.Sha1;
const Allocator = std.mem.Allocator;
const expectEqualStrings = std.testing.expectEqualStrings;
const expect = std.testing.expect;

const ansi = @import("ansi.zig");
const reset = ansi.reset;
const bencode = @import("bencode.zig");
const Value = bencode.Value;

const title_style = ansi.bold ++ ansi.blue;
const content_style = ansi.brightWhite ++ ansi.dim;

const TorrentError = error{
    FileNotFound,
    WrongType,
    MisingField,
    IlegalStructure,
};

const TorrentType = enum(u8) {
    SingleFile,
    MultiFile,
};

const stdout = std.fs.File.stdout();
var stderr = std.fs.File.stderr().writer(&.{});
const err = &stderr.interface;

const Torrent = @This();

/// contents memory
value: bencode.Value,
/// tracker url
announce: []const u8 = undefined,
/// creation time of the torrent, in standard UNIX epoch format
creation_date: ?i64,
/// free-form textual comments of the author
comment: ?[]const u8,
/// name and version of the program used to create the .torrent
created_by: ?[]const u8,
/// info dictionary
info: Info,
/// hash of the info dictionary
info_hash: [Sha1.digest_length]u8,

const Info = struct {
    /// number of bytes in each piece
    piece_length: i64,
    /// concatenation of all 20-byte SHA1 hash values, one per piece
    pieces: []const [20]u8,
    /// name of the file or directory (depends if its single or multi file)
    name: []const u8,

    mode: union(enum) {
        //  ----- Single File -----
        /// length of the file in bytes
        length: i64,

        //  ----- Multi File -----
        /// A list of dictionaries, one for each file
        /// ```
        /// .list{
        ///     .dict{
        ///         length: i64,
        ///         path: .list{ .string, .string, ...},
        ///     },
        ///     .dict{
        ///         ...
        ///     },
        ///     .dict{
        ///         ...
        ///     },
        /// }
        /// ```
        files: []File,
    },
};

const File = struct {
    /// length of the file in bytes
    length: i64,
    /// one or more string elements that together represent the path and filename
    path: [][]const u8,

    /// sort-by length decreasing order
    pub fn ord_func(ctx: void, a: File, b: File) bool {
        _ = ctx;
        return a.length > b.length;
    }
};

/// Not meant to be called directly.
/// The allocator should hold the backing buffer of the `value`
/// thus the need to call deinit
fn init(allocator: Allocator, value: bencode.Value) !Torrent {
    if (value != .dict) return TorrentError.WrongType;
    const metaDict = &value.dict;

    // announce
    const announce: bencode.Value = metaDict.get("announce") orelse return TorrentError.MisingField;
    if (announce != .string) return TorrentError.WrongType;

    // Optional stuff
    const creation_date: ?i64 = blk: {
        if (metaDict.get("creation date")) |date| {
            if (date != .integer) {
                std.log.err("creation date: expected an integer.\n", .{});
                return TorrentError.WrongType;
            }
            break :blk date.integer;
        }
        break :blk null;
    };

    const comment: ?[]const u8 = blk: {
        if (metaDict.get("comment")) |comm| {
            if (comm != .string) {
                std.log.err("comment: expected a string.\n", .{});
                return TorrentError.WrongType;
            }
            break :blk comm.string;
        }
        break :blk null;
    };

    const created_by: ?[]const u8 = blk: {
        if (metaDict.get("created by")) |created| {
            if (created != .string) {
                std.log.err("created by: expected a string.\n", .{});
                return TorrentError.WrongType;
            }
            break :blk created.string;
        }
        break :blk null;
    };

    // info
    const info = metaDict.get("info") orelse return TorrentError.MisingField;
    if (info != .dict) return TorrentError.WrongType;
    const infoDict = &info.dict;

    // info hash
    var str_alloc = try std.Io.Writer.Allocating.initCapacity(allocator, info.len());
    defer str_alloc.deinit();
    const str_writer = &str_alloc.writer;
    try info.encodeBencode(str_writer);
    var sha1 = Sha1.init(.{});
    sha1.update(str_writer.buffer);
    const info_hash: [Sha1.digest_length]u8 = sha1.finalResult();

    // piece length
    const piece_length = infoDict.get("piece length") orelse return TorrentError.MisingField;
    if (piece_length != .integer) return TorrentError.WrongType;

    const pieces = infoDict.get("pieces") orelse return TorrentError.MisingField;
    if (pieces != .string) return TorrentError.WrongType;
    const num_pieces: usize = pieces.string.len / 20;

    // piece hashes
    const piece_hashes: [][20]u8 = try allocator.alloc([20]u8, num_pieces);
    errdefer allocator.free(piece_hashes);

    for (piece_hashes, 0..) |*hash, i|
        hash.* = pieces.string[i * 20 .. i * 20 + 20][0..20].*;

    // name
    const name = infoDict.get("name") orelse return TorrentError.MisingField;
    if (name != .string) return TorrentError.WrongType;

    // length (Only present in single file)
    const length: ?i64 = blk: {
        if (infoDict.get("length")) |l| {
            if (l != .integer) {
                std.log.err("length: expected an integer.\n", .{});
                return TorrentError.WrongType;
            }
            break :blk l.integer;
        }
        break :blk null;
    };

    // files (Only present in multiple file)
    const files: ?[]File = blk: {
        const f = infoDict.get("files") orelse break :blk null;
        if (f != .list) std.log.err("files: expected a list", .{});

        const file_list = &f.list;
        var files = try allocator.alloc(File, file_list.items.len);

        for (file_list.items, 0..) |file_dict, i| {
            std.debug.assert(file_dict == .dict);
            const file = &file_dict.dict;

            const file_length = file.get("length").?.integer;
            const list_of_paths = file.get("path") orelse return TorrentError.MisingField;
            std.debug.assert(list_of_paths == .list);

            const paths: [][]const u8 = try allocator.alloc([]const u8, list_of_paths.list.items.len);
            for (list_of_paths.list.items, 0..) |path_component, j| {
                std.debug.assert(path_component == .string);
                paths[j] = path_component.string;
            }

            files[i] = File{
                .length = file_length,
                .path = paths,
            };
        }
        break :blk files;
    };

    return Torrent{
        .value = value,
        .announce = announce.string,
        .creation_date = creation_date,
        .comment = comment,
        .created_by = created_by,
        .info_hash = info_hash,
        .info = .{
            .piece_length = piece_length.integer,
            .pieces = piece_hashes,
            .name = name.string,
            .mode = if (files != null and length == null)
                .{ .files = files.? }
            else if (files == null and length != null)
                .{ .length = length.? }
            else
                @panic("Torrentfile can't be single and multifile at the same time.\n"),
        },
    };
}

pub fn deinit(self: *Torrent, alloc: Allocator) void {
    alloc.free(self.info.pieces);

    if (self.getType() == .MultiFile) {
        for (self.info.mode.files) |file|
            alloc.free(file.path);
        alloc.free(self.info.mode.files);
    }

    self.value.deinit(alloc);
}

pub fn getType(self: *const Torrent) TorrentType {
    return switch (self.info.mode) {
        .files => .MultiFile,
        .length => .SingleFile,
    };
}

/// calculate the piece length according to the index,
/// the last index might get a piece smaller than the other pieces
/// this is only necesary one per piece
pub fn calculatePieceSize(self: *const Torrent, index: usize) !i64 {
    const num_whole_pieces = try std.math.divFloor(
        i64,
        self.info.length,
        self.info.piece_length,
    );
    std.debug.assert(index >= 0 and index <= num_whole_pieces);
    return if (index < num_whole_pieces)
        self.info.piece_length
    else
        self.info.length - num_whole_pieces * self.info.piece_length;
}

/// Parses the given torrent file and retreives its contents.
/// Caller owns the returned memory. (call deinit())
pub fn open(allocator: Allocator, path: []const u8) !TorrentManaged {
    var file = std.fs.cwd().openFile(path, .{}) catch |e| {
        try err.print("Could not open file '{s}'. Error: {t}\n", .{ path, e });
        std.process.exit(1);
    };
    defer file.close();

    const contents: []const u8 = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    var b: Value = bencode.decodeBencode(allocator, contents) catch |e| {
        try err.print("Could not parse bencode contents from file '{s}'\n", .{path});
        return e;
    };
    errdefer b.deinit(allocator);

    return .{
        .meta = try Torrent.init(allocator, b),
        .backing_buff = contents,
    };
}

/// Meta Info File that owns its underlaying memory.
/// Must call deinit.
pub const TorrentManaged = struct {
    meta: Torrent,
    backing_buff: []const u8,

    pub fn deinit(self: *TorrentManaged, allocator: Allocator) void {
        allocator.free(self.backing_buff);
        self.meta.deinit(allocator);
    }
};

/// Prints information about the torrent into a writer
pub fn printMetaInfo(self: *const Torrent, alloc: Allocator, out: *std.Io.Writer) !void {
    const torr_type = self.getType();

    // Basic content
    try print_row(out, " > Torrent name:", "{s}\n", .{self.info.name});
    try print_row(out, " > Tracker URL:", "{s}\n", .{self.announce});
    try print_row(out, " > Info hash: ", "{x}\n", .{self.info_hash});
    try print_row(out, " > Pieces: ", "{d}\n", .{self.info.pieces.len});
    try print_row(out, " > Piece length: ", "{B}\n", .{@as(u64, @intCast(self.info.piece_length))});

    // Optional stuff
    if (self.creation_date) |date| {
        var es = std.time.epoch.EpochSeconds{ .secs = @intCast(date) };
        const day = es.getEpochDay();
        const day_info = day.calculateYearDay();
        const month_info = day_info.calculateMonthDay();
        const sec_of_day = es.getDaySeconds();

        // YYYY-MM-DD HH:MM:SS
        const date_fmt = try std.fmt.allocPrint(alloc, "{d:04}-{d:02}-{d:02} {d:02}:{d:02}:{d:02}", .{
            day_info.year,
            month_info.month.numeric(),
            month_info.day_index + 1,
            sec_of_day.getHoursIntoDay(),
            sec_of_day.getMinutesIntoHour(),
            sec_of_day.getSecondsIntoMinute(),
        });
        defer alloc.free(date_fmt);
        try print_row(out, " > Creation date:", "{s}\n", .{date_fmt});
    }

    if (self.comment) |comment|
        try print_row(out, " > Comment:", "{s}\n", .{comment});

    if (self.created_by) |created_by|
        try print_row(out, " > Created by:", "{s}\n", .{created_by});

    if (torr_type == .SingleFile) {
        try print_row(out, " > Size:", "{B}\n", .{@as(u64, @intCast(self.info.mode.length))});
    } else if (torr_type == .MultiFile) {
        try out.print("{s} > Multi-file:{s}\n", .{ title_style, reset });

        std.mem.sort(File, self.info.mode.files, {}, File.ord_func);
        for (self.info.mode.files) |file| {
            // size and first component
            try out.print("- {s}[{B:^10.2}] {s}/", .{
                content_style,
                @as(u64, @intCast(file.length)),
                self.info.name,
            });

            // rest of the paths
            for (file.path, 0..) |path, i| {
                try out.print("{s}{s}", .{
                    path,
                    if (i != file.path.len - 1) "/" else reset ++ "\n",
                });
            }
        }
    }
    try out.flush(); // Dont forget to flush!
}

pub fn printPieceHashes(self: *const Torrent, writer: *std.Io.Writer) !void {
    try writer.print("{s}{s:<14}{s}\n", .{ title_style, "Piece Hashes:", reset });
    for (self.info.pieces, 0..) |piece_hash, i| {
        const hex = std.fmt.fmtSliceHexLower(&piece_hash);
        try writer.print("{s}\n", .{hex});
        if (i > 8) {
            try writer.print("...\n", .{});
            break;
        }
    }
    try writer.flush(); // Dont forget to flush!
}

/// Wrapper funct to pretty print the torrent file.
/// Does not flush the writer.
fn print_row(writer: *std.Io.Writer, title: []const u8, comptime format: []const u8, contents: anytype) !void {
    try writer.print("{s}{s:<18}{s}{s}", .{ title_style, title, reset, content_style });
    try writer.print(format, contents);
    _ = try writer.write(reset);
}

test "parse single-file torrent" {
    const alloc = std.testing.allocator;
    const data = @embedFile("tests/torrents/sample.txt.torrent");

    const b_val = try bencode.decodeBencode(alloc, data);
    var torr = try Torrent.init(alloc, b_val);
    defer torr.deinit(alloc);

    try expectEqualStrings("sample.txt", torr.info.name);
    try expectEqualStrings("mktorrent 1.1", torr.created_by.?);
    try expectEqualStrings("http://bittorrent-test-tracker.codecrafters.io/announce", torr.announce);
    try expect(torr.getType() == .SingleFile);
}
