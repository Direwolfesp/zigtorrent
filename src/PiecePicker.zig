const Self = @This();

const PiecePos = struct {
    /// availability
    peer_count: u32,
    /// partial or not (there is entry in `self.downloading`)
    state: bool,
    // index in `self.pieces`, null means we already have it
    index: ?u32,
};

const DownloadingPiece = struct {
    // piece_index
    index: u32,
    // keep track of each block state
    block_state: std.ArrayList(BlockState),

    const BlockState = enum(u8) {
        Open,
        Requested,
        Writing,
        Finished,
    };
};

/// piece_index -> index into pieces
piece_map: std.ArrayList(PiecePos),
/// pieces sorted by priority. Not meant to be indexed directly
pieces: std.ArrayList(u32),
/// priority_level -> starting index of that priority level in `pieces`
priority_boundaries: std.ArrayList(u32),
/// piece_index -> DownloadingPiece
downloading: std.AutoHashMap(u32, DownloadingPiece), // TODO: use a tree or something

/// Finding a rare piece for a peer:
pub fn pick_piece(self: *const Self, have: std.DynamicBitSet) ?u32 {
    for (self.pieces.items) |p| {
        if (have.isSet(p))
            return p;
    }
    return null; // we might want to enter end-game mode
}

/// Incrementing piece availability
pub fn inc_piece_refcount(self: *Self, piece: u32) void {
    const pieces = self.pieces.items;
    const piece_map = self.piece_map.items;
    const priority_boundaries = self.priority_boundaries.items;
    const prev_avail = piece_map[piece].peer_count;

    priority_boundaries[prev_avail] -= 1;

    // inc the availability of the piece
    piece_map.items[piece].peer_count += 1;

    const index = piece_map[piece].index;
    const other_index = priority_boundaries[prev_avail];
    const other_piece = pieces[other_index];

    std.mem.swap(u32, pieces[other_index], pieces[index]);
    std.mem.swap(?u32, piece_map[other_piece].index, piece_map[piece].index);
}

const std = @import("std");
const log = std.log.scoped(.PiecePicker);
