const std = @import("std");
const Peer = @import("Peer.zig");
const MetaInfo = @import("Torrent.zig").MetaInfo;
const Messages = @import("Messages.zig");
const Message = Messages.Message;

const stdout = std.io.getStdOut().writer();
const stderr = std.io.getStdErr().writer();
const Allocator = std.mem.Allocator;

pub const Client = struct {
    conn: std.net.Stream,
    choked: bool = true,
    peer: std.net.Ip4Address,
    bitfield: Message = undefined,
    info_hash: [20]u8 = undefined,
    peerID: [20]u8 = undefined,

    /// Caller owns returned memory and resources.
    /// Must call deinit().
    pub fn new(
        allocator: Allocator,
        peer_ip: std.net.Ip4Address,
        peer_id: [20]u8,
        meta: MetaInfo,
    ) !@This() {
        const conn = Peer.connectToPeer(peer_ip, peer_id, meta) catch {
            stderr.print("Handshake failed with peer {}", .{peer_ip}) catch {};
            return error.HandShakeFailed;
        };

        // received bitfield
        const bf: Message = try Message.read(allocator, conn.reader());
        if (bf != .bitfield) return error.ClientConnFailed;

        return .{
            .conn = conn,
            .bitfield = bf,
            .peer = peer_ip,
            .info_hash = meta.info_hash,
            .peerID = peer_id,
        };
    }

    pub fn deinit(self: @This(), allocator: Allocator) void {
        self.conn.close();
        self.bitfield.deinit(allocator);
    }

    pub fn hasPiece(self: @This(), index: u32) !bool {
        const byte_index = index / 8;
        if (byte_index < 0 or byte_index >= self.bitfield.bitfield.len)
            return error.InvalidPieceIndex;
        const byte_offset: u3 = @intCast(index % 8);
        return 1 == ((self.bitfield.bitfield[byte_index] >> (7 - byte_offset)) & 1);
    }

    pub fn setPiece(self: *@This(), index: u32) !void {
        const byte_index = index / 8;
        if (byte_index < 0 or byte_index >= self.bitfield.bitfield.len)
            return error.InvalidPieceIndex;
        const byte_offset: u3 = @intCast(index % 8);
        self.bitfield.bitfield[byte_index] |= (@as(u8, 1) << (7 - byte_offset));
    }

    pub fn sendRequest(self: @This(), index: u32, begin: u32, length: u32) !void {
        const rqst = Message{ .request = .{
            .begin = begin,
            .index = index,
            .length = length,
        } };
        try rqst.write(self.conn.writer());
    }

    pub fn sendInterested(self: @This()) !void {
        try Messages.Interested.write(self.conn.writer());
    }

    pub fn sendNotInterested(self: @This()) !void {
        try Messages.NotInterested.write(self.conn.writer());
    }

    pub fn sendUnchoke(self: @This()) !void {
        try Messages.Unchoke.write(self.conn.writer());
    }

    pub fn sendHave(self: @This(), index: u32) !void {
        const have = Message{ .have = .{ .piece_index = index } };
        try have.write(self.conn.writer());
    }
};
