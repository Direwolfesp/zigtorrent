const std = @import("std");
const Allocator = std.mem.Allocator;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;
const activeTag = std.meta.activeTag;
const intToEnum = std.meta.intToEnum;
const readInt = std.mem.readInt;

const Torrent = @import("Torrent.zig");
const Bencode = @import("Bencode.zig");
const MetaInfo = Torrent.MetaInfo;

const stdout = std.io.getStdOut().writer();
const stderr = std.io.getStdErr().writer();

//-----------------------------------------------------------------------------
// BitTorrent Peer Messaging:
// https://wiki.theory.org/BitTorrentSpecification#Peer_wire_protocol_.28TCP.29
//-----------------------------------------------------------------------------

pub const ID = "-ZIG666-weoiuv8324ns".*;

pub const HandShake = extern struct {
    // layout matters
    pstrlen: u8 align(1) = 19,
    pstr: [19]u8 align(1) = "BitTorrent protocol".*,
    reserved: [8]u8 align(1) = std.mem.zeroes([8]u8),
    info_hash: [20]u8 align(1) = undefined,
    peer_id: [20]u8 align(1) = undefined,

    pub fn create(peer_id: [20]u8, meta: *const MetaInfo) HandShake {
        return HandShake{
            .info_hash = meta.info_hash,
            .peer_id = peer_id,
        };
    }
};

/// Connects to the given peer and returns the net.Stream
pub fn connectToPeer(peer_ip: std.net.Ip4Address, peer_id: [20]u8, meta: *const MetaInfo) !std.net.Stream {
    var conn = try std.net.tcpConnectToAddress(std.net.Address{ .in = peer_ip });
    const hndshk = HandShake.create(peer_id, meta);
    try conn.writer().writeStruct(hndshk);
    const resp_handshake = try conn.reader().readStruct(HandShake);

    if (!std.mem.eql(u8, &resp_handshake.pstr, &hndshk.pstr) or
        resp_handshake.pstrlen != 19 or
        !std.mem.eql(u8, &resp_handshake.info_hash, &hndshk.info_hash))
    {
        return error.HandShakeError;
    }
    return conn;
}

/// Parses peers from a torrent in dictionary form and returns the ips
pub fn parsePeersDict(allocator: Allocator, data: *const std.ArrayList(Bencode.Value)) ![]std.net.Ip4Address {
    var peers = std.ArrayList(std.net.Ip4Address).init(allocator);
    defer peers.deinit();
    try peers.ensureTotalCapacityPrecise(data.items.len);

    for (data.items) |d| {
        if (d != .dict) return error.ParsePeersDict;

        const dict = d.dict;
        const addr = try std.net.Address.resolveIp(
            dict.get("ip").?.string,
            @intCast(dict.get("port").?.integer),
        );
        peers.appendAssumeCapacity(addr.in);
    }

    return peers.toOwnedSlice();
}

/// Parses peers from a torrent in binary form and returns the ips
pub fn parsePeersBinary(allocator: Allocator, data: []const u8) ![]std.net.Ip4Address {
    // Each address is 6 bytes.
    if (data.len % 6 != 0) return error.InvalidPeers;
    var peers = std.ArrayList(std.net.Ip4Address).init(allocator);
    defer peers.deinit();

    var i: usize = 0;
    while (i + 5 < data.len) : (i += 6) {
        const ip: []const u8 = data[i .. i + 4];
        const port: u16 = std.mem.readInt(u16, data[i + 4 .. i + 6][0..2], .big);

        var ipa: [4]u8 = undefined;
        inline for (0..4) |j|
            ipa[j] = ip[j];

        const address = std.net.Address.initIp4(ipa, port);
        try peers.append(address.in);
    }
    return peers.toOwnedSlice();
}
