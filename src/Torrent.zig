const std = @import("std");
const Sha1 = std.crypto.hash.Sha1;
const Allocator = std.mem.Allocator;

const stdout = std.io.getStdOut().writer();
const stderr = std.io.getStdErr().writer();
const Thread = std.Thread;

const Bencode = @import("Bencode.zig");
const Tracker = @import("Tracker.zig");
const Client = @import("Client.zig").Client;
const Message = @import("Messages.zig").Message;

const Context = struct {
    meta: *MetaInfo,
    allocator: Allocator,
    peer: std.net.Ip4Address,
    tasks: *Tasks,
    results: *Results,
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

const PieceStatus = struct {
    index: u32,
    client: *Client,
    requested: u32,
    downloaded: u32,
    pipeline_length: u32,
};

/// Data type that hold a fifo queue protected by a mutex and condition.
/// With blocking I/O.
fn AtomicQueue(comptime T: type) type {
    return struct {
        queue: std.fifo.LinearFifo(T, .Dynamic),
        mutex: Thread.Mutex,
        cond: Thread.Condition,

        /// Caller owns the returned memory, call deinit()
        pub fn init(allocator: Allocator) @This() {
            return .{
                .mutex = .{},
                .cond = .{},
                .queue = std.fifo.LinearFifo(T, .Dynamic).init(allocator),
            };
        }

        pub fn deinit(self: @This()) void {
            self.queue.deinit();
        }

        pub fn isEmpty(self: *@This()) bool {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.queue.count == 0;
        }

        pub fn getCount(self: *@This()) usize {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.queue.count;
        }

        /// Enqueues T
        pub fn enqueueElem(self: *@This(), elem: T) !void {
            self.mutex.lock();
            defer self.mutex.unlock();
            const e: [1]T = .{elem};
            _ = try self.queue.write(e[0..]);
            self.cond.signal();
        }

        /// reads and dequeus T. Blocking
        pub fn dequeueElem(self: *@This()) T {
            self.mutex.lock();
            defer self.mutex.unlock();

            var buf: [1]T = undefined;
            while (self.queue.read(buf[0..]) == 0)
                self.cond.wait(&self.mutex);
            return buf[0];
        }
    };
}

const Tasks = AtomicQueue(PieceTask);
const Results = AtomicQueue(PieceCompleted);

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
    values: Bencode.Value,

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
    fn init(allocator: Allocator, value: Bencode.Value) !MetaInfo {
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

    /// Downloads a torrent file into ofile
    pub fn download(self: *MetaInfo, allocator: Allocator, ofile: []const u8) !void {
        const peers = try Tracker.getPeersFromResponse(allocator, self.*);
        defer allocator.free(peers);

        var tasks = Tasks.init(allocator);
        defer tasks.deinit();

        // Fill in piece tasks
        try tasks.queue.ensureTotalCapacity(self.info.pieces.len);
        for (self.info.pieces, 0..) |piece, i| {
            try tasks.enqueueElem(PieceTask{
                .hash = piece,
                .index = @intCast(i),
                .length = @intCast(try self.calculatePieceSize(i)),
            });
        }

        // atomic queue that will hold the results procuded by the workers
        var res = Results.init(allocator);
        defer res.deinit();

        // Spawn workers
        const num_workers: u64 = @min(self.info.pieces.len, try Thread.getCpuCount() * 2, peers.len);
        var workers: []Thread = try allocator.alloc(Thread, num_workers);
        defer allocator.free(workers);
        for (workers, 0..) |_, i| {
            const peer = peers[i];
            const ctx: *Context = try allocator.create(Context);

            ctx.* = .{
                .meta = self,
                .allocator = allocator,
                .peer = peer,
                .tasks = &tasks,
                .results = &res,
            };

            workers[i] = try Thread.spawn(.{}, downloadWorkerThreadFn, .{ctx});
        }

        // copy the results into a buffer
        var buff: []u8 = try allocator.alloc(u8, @intCast(self.info.length));
        defer allocator.free(buff);

        // main thread will keep reading the result queue and
        // copy each PieceResult into the buffer
        var pieces_downloaded: u64 = 0;
        while (pieces_downloaded < self.info.pieces.len) : (pieces_downloaded += 1) {
            const piece_res: PieceCompleted = res.dequeueElem();

            const start: usize = @as(usize, @intCast(piece_res.index)) * @as(usize, @intCast(self.info.piece_length));
            const end: usize = @as(usize, @intCast(start)) + @as(usize, @intCast(try self.calculatePieceSize(piece_res.index)));

            @memcpy(buff[start..end], piece_res.buf);
            allocator.free(piece_res.buf);

            const percent: f64 = @as(f64, @floatFromInt(pieces_downloaded)) / @as(f64, @floatFromInt(self.info.pieces.len)) * 100.0;
            try stdout.print("[{d:.2}%] Downloaded piece #{d}. {} of {}\n", .{
                percent,
                piece_res.index,
                pieces_downloaded,
                self.info.pieces.len,
            });
        }

        // wait for threads
        for (workers) |*worker|
            worker.join();

        // copy buffer into file
        var file = std.fs.cwd().createFile(ofile, .{}) catch {
            try stdout.print("Could not create file '{s}'\n", .{ofile});
            return;
        };
        defer file.close();
        try file.writer().writeAll(buff);
    }

    pub fn downloadWorker(
        self: @This(),
        allocator: Allocator,
        peer: std.net.Ip4Address,
        tasks: *Tasks,
        results: *Results,
    ) !void {
        var client = Client.new(
            allocator,
            peer,
            "-qB6666-weoiuv8324ns".*,
            self,
        ) catch {
            try stderr.print("Could not handshake with {}\n", .{peer});
            return;
        };
        defer client.deinit(allocator);

        try client.sendUnchoke();
        try client.sendInterested();

        while (!tasks.isEmpty()) {
            const task: PieceTask = tasks.dequeueElem();

            // if client doesnt have the piece, requeue it
            if (!try client.hasPiece(task.index)) {
                try tasks.enqueueElem(task);
                continue;
            }

            // allocate mem for the piece
            const piece_buffer = try allocator.alloc(u8, task.length);
            const piece_downloaded: bool = try downloadPiece(
                allocator,
                &client,
                task,
                piece_buffer,
            );

            if (!piece_downloaded) {
                try tasks.enqueueElem(task); // try again later
                continue;
            }

            if (!checkIntegrity(task, piece_buffer)) {
                stderr.print("Piece {} failed integrity\n", .{task.index}) catch {};
                try tasks.enqueueElem(task);
                continue;
            }

            // Successful: enqueue the result
            try results.enqueueElem(PieceCompleted{
                .index = task.index,
                .buf = piece_buffer,
            });
        }
    }

    /// Checks if the downloaded piece in ´buf´ has the same
    /// hash as the ´task´.
    fn checkIntegrity(task: PieceTask, buf: []const u8) bool {
        var hash = Sha1.init(.{});
        hash.update(buf);
        const result = hash.finalResult();
        return std.mem.eql(u8, &result, &task.hash);
    }

    fn downloadPiece(
        allocator: Allocator,
        client: *Client,
        task: PieceTask,
        buf: []u8, // will be filled with the downloaded piece
    ) !bool {
        const MAX_BACKLOG: usize = 5; // requests pipeline length
        var downloaded: usize = 0;
        var requested: usize = 0;
        var backlog: usize = 0;

        const deadline = std.time.nanoTimestamp() + std.time.ns_per_s * 30;
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
            const now = std.time.nanoTimestamp();
            if (now > deadline)
                return false;

            const msg = try Message.read(allocator, client.conn.reader());
            defer msg.deinit(allocator);
            switch (msg) {
                .piece => |p| {
                    std.debug.assert(p.index == task.index); //DEBUG
                    std.debug.assert(p.block.len + p.begin <= buf.len); // received more bytes than available in onepice

                    // important to note that blocks may not be received in order
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
        return true;
    }

    /// calculate the piece length according to the index,
    /// the last index might get a piece smaller than the other pieces
    /// this is only necesary one per piece
    pub fn calculatePieceSize(self: @This(), index: usize) !i64 {
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
    pub fn printMetaInfo(self: @This()) !void {
        try stdout.print(
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
        try self.printPieceHashes();
    }

    fn printPieceHashes(self: @This()) !void {
        try stdout.print("Piece Hashes: \n", .{});
        for (self.info.pieces, 0..) |piece_hash, i| {
            const hex = std.fmt.fmtSliceHexLower(&piece_hash);
            try stdout.print("{s}\n", .{hex});
            if (i > 8) {
                try stdout.print("...\n", .{});
                break;
            }
        }
    }
};

/// wrapper so it can be used by a thread (direct function pointer, not attached to an instance)
fn downloadWorkerThreadFn(ctx: *Context) !void {
    try ctx.meta.downloadWorker(ctx.allocator, ctx.peer, ctx.tasks, ctx.results);
}

/// Parses the given torrent file and retreives its contents.
/// Caller owns the returned memory. (call deinit())
pub fn open(allocator: Allocator, path: []const u8) !MetaInfoManaged {
    var file = std.fs.cwd().openFile(path, .{}) catch |err| {
        try stdout.print("Could not open file '{s}', error: {?}", .{ path, err });
        return MetaInfoError.FileNotFound;
    };
    defer file.close();
    const contents: []const u8 = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    const bencode = try Bencode.decodeBencode(allocator, contents);
    return .{
        .meta = try MetaInfo.init(allocator, bencode),
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
