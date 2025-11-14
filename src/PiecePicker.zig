//! The operations of the piece picker are:
//! - pick one or more pieces for peer p
//!   (this is to determine what to download from a peer)
//! - increment availability counter for piece i
//!   (when a peer announces that it just completed downloading a new piece)
//! - decrement availability counters for all pieces of peer p
//!   (when a peer leaves the swarm)
//! - increment availability counters for all pieces of peer p
//!   (when a peer joins the swarm)

const Self = @This();

const PiecePos = struct {
    /// availability
    peer_count: u32 = 0,
    /// partial or not (there is entry in `self.downloading`)
    state: bool = false,
    /// index in `self.pieces`, null means we already have it
    index: ?u32,
};

/// Metadata only for currently downloading pieces
const DownloadingPiece = struct {
    /// piece_index
    index: u32,
    /// keep track of each block state
    block_state: std.ArrayList(BlockState),
};

pub const BlockState = enum(u8) {
    /// block needs to be requested
    pending,
    /// block has been requested from the peer
    requested,
    /// block already verified and written to disk
    finished,
};

/// the torrent this piece picker is working for
torrent: *const TorrentFile,
/// internal allocator
alloc: std.mem.Allocator,
/// piece_index -> index into pieces
piece_map: std.ArrayList(PiecePos),
/// Flattened (for cache locality) bucket list, each bucket contains pieces with the same priority
/// level. To access it, first check the priority boundarie of the piece.
pieces: std.ArrayList(u32),
/// stores the starting index of each priority level of `pieces`
priority_boundaries: std.ArrayList(u32),
/// Stores information about each currently downloading piece. The key is the piece index.
downloading: std.AutoHashMap(u32, DownloadingPiece),

pub fn init(torrent: *const TorrentFile, alloc: std.mem.Allocator) !Self {
    const num_pieces = torrent.getNumPieces();
    std.debug.assert(num_pieces != 0);

    var piece_map: std.ArrayList(PiecePos) = try .initCapacity(alloc, num_pieces);
    errdefer piece_map.deinit(alloc);

    var pieces: std.ArrayList(u32) = try .initCapacity(alloc, num_pieces);
    errdefer pieces.deinit(alloc);

    // fill in pieces with all the pieces and set its index and availability in
    // piece_map
    for (0..num_pieces) |i| {
        piece_map.appendAssumeCapacity(.{
            .index = @intCast(i),
            .peer_count = 0,
            .state = false,
        });
        pieces.appendAssumeCapacity(@intCast(i));
    }

    const downloading: std.AutoHashMap(u32, DownloadingPiece) = .init(alloc);

    // initially all pieces belong to the first bucket of availability = 0
    var priority_boundaries: std.ArrayList(u32) = .empty;
    try priority_boundaries.append(alloc, 0);
    try priority_boundaries.append(alloc, @intCast(num_pieces));

    return .{
        .downloading = downloading,
        .priority_boundaries = priority_boundaries,
        .pieces = pieces,
        .piece_map = piece_map,
        .alloc = alloc,
        .torrent = torrent,
    };
}

pub fn deinit(self: *Self) void {
    self.piece_map.deinit(self.alloc);
    self.pieces.deinit(self.alloc);
    self.priority_boundaries.deinit(self.alloc);

    var values = self.downloading.valueIterator();
    while (values.next()) |elem|
        elem.block_state.deinit(self.alloc);
    self.downloading.deinit();
}

/// Finding a rare piece for a peer:
pub fn pickPiece(self: *Self, have: std.DynamicBitSetUnmanaged) !?u32 {
    for (self.pieces.items, 0..) |piece, i| {
        // if the piece is in `pieces`, the index of the piece must match the one
        // from `piece_map`
        std.debug.assert(self.piece_map.items[piece].index.? == i);

        // Only pick pieces that the peer have
        // and that they havent already been picked.
        // NOTE: maybe we should pick pieces that have been already picked by
        // other connections but just requesting blocks that have not been requested.
        // basically separating the piece picking from block picking logic.
        if (have.isSet(piece)) {
            // Once we have the piece, we either look-up the `DownloadingPiece`
            // object, or create a new one (and update the state in `piece_map` by
            // setting it to true). In the `DownloadingPiece` we mark the blocks
            // we pick as requested, to avoid picking them again.
            if (self.downloading.get(piece) == null) {
                const num_blocks = try self.torrent.calculateNumBlocks(piece);
                var block_state: std.ArrayList(BlockState) = try .initCapacity(self.alloc, @intCast(num_blocks));
                errdefer block_state.deinit(self.alloc);
                block_state.appendNTimesAssumeCapacity(.pending, @intCast(num_blocks));

                try self.downloading.put(piece, DownloadingPiece{
                    .index = @intCast(i),
                    .block_state = block_state,
                });
                self.piece_map.items[piece].state = true;
                return piece;
            }
        }
    }
    log.warn("Couldn't pick a piece", .{});
    // we might want to enter end-game mode or drop the connection
    return null;
}

pub fn markPieceCompleted(self: *Self, piece: u32) void {
    // if we didnt alredy have that piece
    if (self.piece_map.items[piece].index) |index| {
        // we grab its availability
        const avail = self.piece_map.items[piece].peer_count;

        // find bucket end
        const end_index = self.priority_boundaries.items[avail + 1];

        // save the last piece that is at end of its bucket
        const other_piece = self.pieces.items[end_index - 1];

        // swap the piece with the last piece from the pieces
        std.mem.swap(
            u32,
            &self.pieces.items[index],
            &self.pieces.items[end_index - 1],
        );
        // swap the indices from the PiecePos.index
        std.mem.swap(
            ?u32,
            &self.piece_map.items[other_piece].index,
            &self.piece_map.items[piece].index,
        );

        // shrink bucket
        self.priority_boundaries.items[avail + 1] -= 1;

        self.piece_map.items[piece].index = null;

        if (self.downloading.get(piece)) |dl_piece| {
            for (dl_piece.block_state.items) |block|
                std.debug.assert(block == .finished);
        } else log.warn("A piece ({d}) that didn't finished downloading was marked as completed", .{piece});

        _ = self.downloading.remove(piece);
    }
}

/// Updates the BlockState for the given `block` from `piece`.
/// asserts the block exists
pub fn updateBlockState(self: *Self, piece: u32, block: i64, state: BlockState) !bool {
    if (self.downloading.get(piece)) |dl| {
        const num_blocks = try self.torrent.calculateNumBlocks(piece);
        std.debug.assert(num_blocks > block);
        std.debug.assert(dl.block_state.items.len == num_blocks);
        dl.block_state.items[@intCast(block)] = state;
        log.info("updated block {d} from piece {d} to {t}", .{ block, piece, state });
        return true;
    } else {
        log.warn("Could not update block state, Piece {d} doesn't have block {d}", .{ piece, block });
        return false;
    }
}

/// Updates all the BlockState for the given `piece`.
pub fn updateAllBlockStates(self: *Self, piece: u32, new_state: BlockState) void {
    if (self.downloading.get(piece)) |p| {
        for (p.block_state.items) |*block| {
            block.* = new_state;
        }
    }
}

// For each set bit in bitfield, increment piece availabity
pub fn register_peer_pieces(self: *Self, bitfield: std.DynamicBitSetUnmanaged) !void {
    std.debug.assert(bitfield.count() > 0);

    log.debug("peer has {d} pieces out of {d}", .{
        bitfield.count(),
        self.torrent.getNumPieces(),
    });

    var iter = bitfield.iterator(.{ .kind = .set });
    while (iter.next()) |piece_index| {
        std.debug.assert(piece_index >= 0 and piece_index < self.torrent.getNumPieces());
        try self.inc_piece_refcount(@intCast(piece_index));
    }
}

// For each set bit in bitfield, decrement piece availabity
pub fn unregister_peer_pieces(self: *Self, bitfield: std.DynamicBitSetUnmanaged) void {
    var iter = bitfield.iterator(.{ .kind = .set });
    while (iter.next()) |piece_index| {
        std.debug.assert(piece_index >= 0 and piece_index < self.torrent.getNumPieces());
        self.dec_piece_refcount(@intCast(piece_index));
    }
}

/// Incrementing piece availability
pub fn inc_piece_refcount(self: *Self, piece: u32) !void {
    // aliases
    var pieces = self.pieces.items;
    var piece_map = self.piece_map.items;
    var boundaries = self.priority_boundaries.items;

    const old_avail = piece_map[piece].peer_count;
    const new_avail = old_avail + 1;

    // we want to ensure a bucket exists
    while (self.priority_boundaries.items.len <= new_avail + 1) {
        const last = boundaries[boundaries.len - 1];
        try self.priority_boundaries.append(self.alloc, last);
        boundaries = self.priority_boundaries.items;
    }

    const old_index = piece_map[piece].index.?;
    const move_to = boundaries[new_avail] - 1; // end of next bucket

    // move the piece up into the next bucket
    const other_piece = pieces[move_to];
    std.mem.swap(u32, &pieces[old_index], &pieces[move_to]);
    std.mem.swap(?u32, &piece_map[other_piece].index, &piece_map[piece].index);

    // update boundaries
    boundaries[new_avail] -= 1;
    piece_map[piece].peer_count = new_avail;
}

/// Decrement piece availability
pub fn dec_piece_refcount(self: *Self, piece: u32) void {
    var pieces = self.pieces.items;
    var piece_map = self.piece_map.items;
    var boundaries = self.priority_boundaries.items;

    const old_avail = piece_map[piece].peer_count;
    if (old_avail == 0) return;

    const new_avail = old_avail - 1;
    const old_index = piece_map[piece].index.?;

    // find where the lower bucket starts
    const move_to = boundaries[new_avail];

    const other_piece = pieces[move_to];
    std.mem.swap(u32, &pieces[old_index], &pieces[move_to]);
    std.mem.swap(?u32, &piece_map[other_piece].index, &piece_map[piece].index);

    // expand the lower bucket
    boundaries[new_avail] += 1;
    piece_map[piece].peer_count = new_avail;
}

const std = @import("std");
const log = std.log.scoped(.PiecePicker);
const TorrentFile = @import("TorrentFile.zig");
