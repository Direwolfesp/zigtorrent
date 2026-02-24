const std = @import("std");
const Io = std.Io;
const Sha1 = std.crypto.hash.Sha1;
const Allocator = std.mem.Allocator;

const bencode = @import("bencode.zig");
const Tracker = @import("Tracker.zig");
const Client = @import("Client.zig").Client;
const Message = @import("Messages.zig").Message;
const Peer = @import("Peer.zig");

const log = std.log.scoped(.torrent);

const Context = struct {
    meta: *MetaInfo,
    allocator: Allocator,
    peer: std.net.Ip4Address,
    tasks: *Io.Queue(PieceTask),
    results: *Io.Queue(PieceCompleted),
};

const PieceTask = struct {
    /// piece index
    index: u32,
    /// piece hash
    hash: [20]u8,
    /// effective length of the piece
    length: u32,
};

const PieceCompleted = struct {
    /// index of the downloaded piece
    index: u32,
    /// its contents
    buf: []const u8,
};

const MetaInfoError = error{
    FileNotFound,
    WrongType,
    MisingField,
    NotSingleFile,
};

/// Torrent file information
/// Single File Only
pub const MetaInfo = struct {
    /// not meant to be accessed directly, this just points to memory created by allocator
    values: bencode.Value,

    /// tracker url
    announce: []const u8 = undefined,
    /// info dictionary
    info: Info,
    /// hash of the dictionary
    info_hash: [Sha1.digest_length]u8,

    /// Info dictionary for single file
    const Info = struct {
        /// number of bytes in each piece
        piece_length: i64,
        /// concatenation of all 20-byte SHA1 hash values, one per piece
        pieces: []const [20]u8,
        /// length of the file in bytes
        length: i64,
        /// name of the file
        name: []const u8,
    };

    pub fn deinit(self: *@This()) void {
        self.values.deinit();
    }

    /// Not meant to be called directly.
    /// The allocator should hold the backing buffer of the `value`
    /// thus the need to call deinit
    fn init(allocator: Allocator, value: bencode.Value) !MetaInfo {
        if (value != .dict) return MetaInfoError.WrongType;
        const metaDict = value.dict;

        // announce
        const announce: bencode.Value = metaDict.get("announce") orelse return MetaInfoError.MisingField;
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

        // piece hashes
        const pieces = infoDict.get("pieces") orelse return MetaInfoError.MisingField;
        if (pieces != .string)
            return MetaInfoError.WrongType;

        const num_pieces: usize = pieces.string.len / 20;
        const tmp_piece_hashes: [][20]u8 = try allocator.alloc([20]u8, num_pieces);
        for (tmp_piece_hashes, 0..) |*hash, i| {
            hash.* = pieces.string[i * 20 .. i * 20 + 20][0..20].*;
        }

        // name
        const name = infoDict.get("name") orelse return MetaInfoError.MisingField;
        if (name != .string) return MetaInfoError.WrongType;

        return MetaInfo{
            .values = value,
            .announce = announce.string,
            .info = .{
                .pieces = tmp_piece_hashes,
                .piece_length = piece_length.integer,
                .length = length.integer,
                .name = name.string,
            },
            .info_hash = sha1.finalResult(),
        };
    }

    fn fillTasks(self: MetaInfo, io: Io, tasks: *Io.Queue(PieceTask)) !void {
        for (self.info.pieces, 0..) |piece_hash, i| {
            try tasks.putOne(io, PieceTask{
                .hash = piece_hash,
                .index = @intCast(i),
                .length = @intCast(try self.calculatePieceSize(i)),
            });
        }
    }

    /// Downloads a torrent file into ofile
    /// returns true in success, false otherwise
    pub fn download(self: *MetaInfo, io: Io, allocator: Allocator, ofile: []const u8) !bool {
        log.info("Starting download for {s}", .{self.info.name});

        const peers = try Tracker.getPeersFromResponse(allocator, self);
        defer allocator.free(peers);

        var tasks_buf: [0x4000]u8 = undefined;
        var tasks_queue: Io.Queue(PieceTask) = .init(&tasks_buf);
        defer tasks_queue.close(io);

        // Fill in piece queue
        const producer_task = try io.concurrent(fillTasks, .{ self, io, &tasks_queue });
        defer producer_task.cancel(io) catch {};

        var results_buf: [0x4000]u8 = undefined;
        var results_queue: Io.Queue(PieceCompleted) = .init(&results_buf);
        defer results_queue.close(io);

        for (peers) |p| {
            try io.concurrent(downloadWorker, .{ self, io, allocator, p, &tasks_queue, &results_queue });
        }

        // Spawn workers
        // for (0..num_workers) |_| {
        //     const peer = peers[std.crypto.random.intRangeAtMost(usize, 0, peers.len - 1)];
        //     const ctx: *Context = try allocator.create(Context);

        //     ctx.* = .{
        //         .meta = self,
        //         .allocator = allocator,
        //         .peer = peer,
        //         .tasks = &tasks,
        //         .results = &res,
        //     };
        // }

        // copy the results into a buffer
        var downloaded_content: []u8 = try allocator.alloc(u8, @intCast(self.info.length));
        defer allocator.free(downloaded_content);

        // main thread will keep reading the result queue and
        // copy each PieceResult into the buffer
        var pieces_downloaded: u64 = 0;
        while (pieces_downloaded < self.info.pieces.len) : (pieces_downloaded += 1) {
            const piece_res: PieceCompleted = results_queue.dequeueElem();

            const start: usize = @as(usize, @intCast(piece_res.index)) * @as(usize, @intCast(self.info.piece_length));
            const end: usize = @as(usize, @intCast(start)) + @as(usize, @intCast(try self.calculatePieceSize(piece_res.index)));

            @memcpy(downloaded_content[start..end], piece_res.buf);
            allocator.free(piece_res.buf);

            const percent: f64 = @as(f64, @floatFromInt(pieces_downloaded)) / @as(f64, @floatFromInt(self.info.pieces.len)) * 100.0;
            log.info("[{d:0>5.2}%] Downloaded piece #{d}. {} of {}", .{
                percent,
                piece_res.index,
                pieces_downloaded,
                self.info.pieces.len,
            });
        }

        // copy buffer into file
        var file = Io.Dir.cwd().createFile(io, ofile, .{}) catch |err| {
            log.err("Could not create file '{s}', Err: '{?}'", .{ ofile, err });
            return false;
        };
        defer file.close(io);

        var file_buf: [0x4000]u8 = undefined;
        var wr = file.writer(io, &file_buf);
        try wr.interface.writeAll(&downloaded_content);
        return true;
    }

    /// Pumps PieceTask's from `tasks` and dumps the PieceResult's in `results` queue
    pub fn downloadWorker(
        self: MetaInfo,
        io: Io,
        gpa: Allocator,
        peer: Io.net.Ip4Address,
        tasks: *Io.Queue(PieceTask),
        results: *Io.Queue(PieceCompleted),
    ) !void {
        var client = try Client.new(io, gpa, peer, Peer.ID, &self);
        defer client.deinit(gpa);

        try client.sendUnchoke();
        try client.sendInterested();

        while (tasks.getOne(io)) |task| {
            // if client doesnt have the piece, requeue it
            if (!try client.hasPiece(task.index)) {
                try tasks.putOne(io, task);
                continue;
            }

            const piece_buffer = try gpa.alloc(u8, task.length);
            errdefer gpa.free(piece_buffer);

            downloadPiece(io, gpa, &client, task, piece_buffer) catch {
                log.err("Exiting", .{});
                try tasks.putOne(io, task);
                return;
            };

            if (!checkIntegrity(&task, piece_buffer)) {
                log.warn("Piece {} failed integrity\n", .{task.index}) catch {};
                try tasks.enqueueElem(task);
                continue;
            }

            try client.sendHave(task.index);

            // Success: enqueue the result
            try results.putOne(io, PieceCompleted{
                .index = task.index,
                .buf = piece_buffer,
            });
        } else |err| switch (err) {
            error.Closed => return,
            else => |e| return e,
        }
    }

    /// Checks if the downloaded piece in ´buf´ has the same
    /// hash as the ´task´.
    fn checkIntegrity(task: PieceTask, buf: []const u8) bool {
        var hash: Sha1 = .init(.{});
        hash.update(buf);
        const result = hash.finalResult();
        return std.mem.eql(u8, &result, &task.hash);
    }

    fn downloadPiece(
        io: Io,
        allocator: Allocator,
        client: *Client,
        task: PieceTask,
        buf: []u8, // will be filled with the downloaded piece
    ) !void {
        const MAX_BACKLOG: usize = 20; // requests pipeline length
        var downloaded: usize = 0;
        var requested: usize = 0;
        var backlog: usize = 0;

        const deadline = std.Io.Timestamp.now(io, .real).nanoseconds + std.time.ns_per_s * 30;
        while (downloaded < task.length) {
            if (!client.choked) {
                // request more blocks as long as pipeline is not full and we havent download all blocks
                while (backlog < MAX_BACKLOG and requested < task.length) {
                    const block_size = @min(16 * 1024, task.length - requested);
                    try client.sendRequest(task.index, @intCast(requested), block_size);
                    requested += block_size;
                    backlog += 1;
                }
            }

            // if the piece is not downloaded in 30sec, abort
            const now = Io.Timestamp.now(io, .real);
            if (now.nanoseconds > deadline)
                return error.Aborted;

            const msg = try Message.read(allocator, client.conn.reader());
            defer msg.deinit(allocator);

            switch (msg) {
                .piece => |p| {
                    std.debug.assert(p.block.len + p.begin <= buf.len); // received more bytes than available in onepice

                    // NOTE: blocks may not be received in order
                    const copied = p.block.len;
                    const offset = p.begin;
                    @memcpy(buf[offset..][0..copied], p.block[0..copied]);

                    downloaded += copied;
                    backlog -= 1;
                },
                .unchoke => client.choked = false,
                .choke => client.choked = true,
                .have => |idx| try client.setPiece(idx.piece_index),
                else => {},
            }
        }
    }

    /// calculate the piece length according to the index,
    /// the last index might get a piece smaller than the other pieces
    /// this is only necesary one per piece
    pub fn calculatePieceSize(self: *const @This(), index: usize) !i64 {
        const num_whole_pieces = try std.math.divFloor(
            i64,
            self.info.length,
            self.info.piece_length,
        );
        return if (index < num_whole_pieces)
            self.info.piece_length
        else
            self.info.length - num_whole_pieces * self.info.piece_length;
    }

    /// Prints meta info contents to stdout
    pub fn printMetaInfo(self: *const @This(), out: *std.Io.Writer) !void {
        try out.print(
            \\Tracker URL: {s}
            \\Torrent Name: {s}
            \\Length: {d}
            \\Info Hash: {s}
            \\Total pieces: {d}
            \\Piece Length: {d}
            \\
        , .{
            self.announce,
            self.info.name,
            std.fmt.fmtIntSizeDec(@intCast(self.info.length)),
            std.fmt.fmtSliceHexLower(&self.info_hash),
            self.info.pieces.len,
            std.fmt.fmtIntSizeDec(@intCast(self.info.piece_length)),
        });
        try self.printPieceHashes(out);
        try out.flush();
    }

    /// Does not flush
    fn printPieceHashes(self: *const @This(), out: *std.Io.Writer) !void {
        try out.print("Piece Hashes: \n", .{});
        for (self.info.pieces, 0..) |piece_hash, i| {
            const hex = std.fmt.fmtSliceHexLower(&piece_hash);
            try out.print("{s}\n", .{hex});
            if (i > 8) {
                try out.print("...\n", .{});
                break;
            }
        }
    }
};

/// Parses the given torrent file and retreives its contents.
/// Caller owns the returned memory. (call deinit())
pub fn open(io: Io, gpa: Allocator, path: []const u8) !MetaInfoManaged {
    const contents = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
    errdefer gpa.free(contents);

    const b = try bencode.decodeBencode(gpa, contents);
    errdefer b.deinit();

    return .{
        .meta = try MetaInfo.init(gpa, bencode),
        .backing_buff = contents,
    };
}

/// Meta Info File that owns its underlaying memory.
/// Must call deinit.
pub const MetaInfoManaged = struct {
    meta: MetaInfo,
    backing_buff: []const u8,

    pub fn deinit(self: *@This(), allocator: Allocator) void {
        allocator.free(self.backing_buff);
        self.meta.deinit();
    }
};
