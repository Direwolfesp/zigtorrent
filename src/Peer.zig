const std = @import("std");
const Allocator = std.mem.Allocator;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;
const activeTag = std.meta.activeTag;
const intToEnum = std.meta.intToEnum;
const readInt = std.mem.readInt;

const Torrent = @import("Torrent.zig");
const MetaInfo = Torrent.MetaInfo;

const stdout = std.io.getStdOut().writer();
const stderr = std.io.getStdErr().writer();

//-----------------------------------------------------------------------------
// BitTorrent Peer Messaging:
// https://wiki.theory.org/BitTorrentSpecification#Peer_wire_protocol_.28TCP.29
//-----------------------------------------------------------------------------

pub const HandShake = extern struct {
    // layout matters
    pstrlen: u8 align(1) = 19,
    pstr: [19]u8 align(1) = "BitTorrent protocol".*,
    reserved: [8]u8 align(1) = std.mem.zeroes([8]u8),
    info_hash: [20]u8 align(1) = undefined,
    peer_id: [20]u8 align(1) = undefined,

    pub fn create(peer_id: [20]u8, meta: MetaInfo) HandShake {
        return HandShake{
            .info_hash = meta.info_hash,
            .peer_id = peer_id,
        };
    }
};

/// Connects to the given peer and returns the net.Stream
pub fn connectToPeer(peer_ip: std.net.Ip4Address, peer_id: [20]u8, meta: MetaInfo) !std.net.Stream {
    std.log.info("Trying to connect to peer...", .{});
    var conn = try std.net.tcpConnectToAddress(std.net.Address{ .in = peer_ip });
    std.log.info("Connected to peer", .{});

    std.log.info("Sending handshake to peer...", .{});
    const hndshk = HandShake.create(peer_id, meta);
    try conn.writer().writeStruct(hndshk);
    std.log.info("Waiting for response...", .{});
    const resp_handshake = try conn.reader().readStruct(HandShake);
    std.log.info("Got a response from peer ", .{});

    if (!std.mem.eql(u8, &resp_handshake.pstr, &hndshk.pstr) or
        resp_handshake.pstrlen != 19 or
        !std.mem.eql(u8, &resp_handshake.info_hash, &hndshk.info_hash))
    {
        return error.HandShakeError;
    }
    return conn;
}
