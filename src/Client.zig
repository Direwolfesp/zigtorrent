const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const Messages = @import("Messages.zig");
const Message = Messages.Message;
const MetaInfo = @import("Torrent.zig").MetaInfo;
const Peer = @import("Peer.zig");

pub const Client = struct {
    conn: std.Io.net.Stream,

    write_buf: []u8,
    conn_writer: std.Io.net.Stream.Writer,

    read_buf: []u8,
    conn_reader: std.Io.net.Stream.Reader,

    choked: bool = true,
    peer: std.Io.net.Ip4Address,
    bitfield: Message = undefined,
    info_hash: [20]u8 = undefined,
    peerID: [20]u8 = undefined,

    /// Caller owns returned memory and resources.
    /// Must call deinit().
    pub fn new(io: Io, gpa: Allocator, peer_ip: std.Io.net.Ip4Address, peer_id: [20]u8, meta: *const MetaInfo) !Client {
        const conn = Peer.connectToPeer(io, peer_ip, peer_id, meta) catch
            return error.HandShakeFailed;

        const read_buf = try gpa.alloc(u8, 4096);
        errdefer gpa.free(read_buf);

        const write_buf = try gpa.alloc(u8, 4096);
        errdefer gpa.free(write_buf);

        var conn_reader = conn.reader(io, read_buf);
        const conn_writer = conn.writer(io, write_buf);

        const bf: Message = try Message.read(gpa, &conn_reader.interface);
        if (bf != .bitfield) return error.ClientConnFailed;

        return .{
            .conn = conn,
            .read_buf = read_buf,
            .write_buf = write_buf,
            .conn_reader = conn_reader,
            .conn_writer = conn_writer,
            .bitfield = bf,
            .peer = peer_ip,
            .info_hash = meta.info_hash,
            .peerID = peer_id,
        };
    }

    pub fn deinit(self: *const Client, io: Io, gpa: Allocator) void {
        self.conn.close(io);
        self.bitfield.deinit(gpa);
    }

    pub fn hasPiece(self: *const Client, index: u32) !bool {
        const byte_index = index / 8;
        if (byte_index < 0 or byte_index >= self.bitfield.bitfield.len)
            return error.InvalidPieceIndex;
        const byte_offset: u3 = @intCast(index % 8);
        return 1 == ((self.bitfield.bitfield[byte_index] >> (7 - byte_offset)) & 1);
    }

    pub fn setPiece(self: *Client, index: u32) !void {
        const byte_index = index / 8;
        if (byte_index < 0 or byte_index >= self.bitfield.bitfield.len)
            return error.InvalidPieceIndex;
        const byte_offset: u3 = @intCast(index % 8);
        self.bitfield.bitfield[byte_index] |= (@as(u8, 1) << (7 - byte_offset));
    }

    pub fn sendRequest(self: *Client, index: u32, begin: u32, length: u32) !void {
        const rqst = Message{ .request = .{
            .begin = begin,
            .index = index,
            .length = length,
        } };
        try rqst.write(&self.conn_writer.interface);
    }

    pub fn sendInterested(self: *Client) !void {
        try Messages.Interested.write(&self.conn_writer.interface);
    }

    pub fn sendNotInterested(self: *Client) !void {
        try Messages.NotInterested.write(&self.conn_writer.interface);
    }

    pub fn sendUnchoke(self: *Client) !void {
        try Messages.Unchoke.write(&self.conn_writer.interface);
    }

    pub fn sendHave(self: *Client, index: u32) !void {
        const have = Message{ .have = .{ .piece_index = index } };
        try have.write(&self.conn_writer.interface);
    }

    pub fn sendCancel(self: *Client, index: u32, begin: u32, length: u32) !void {
        const cancel = Message{ .cancel = .{
            .index = index,
            .begin = begin,
            .length = length,
        } };
        try cancel.write(&self.conn_writer.interface);
    }
};
