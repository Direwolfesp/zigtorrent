const std = @import("std");
const Io = std.Io;
const net = std.Io.net;
const Allocator = std.mem.Allocator;

const Bencode = @import("bencode.zig");
const Torrent = @import("Torrent.zig");
const MetaInfo = Torrent.MetaInfo;

//-----------------------------------------------------------------------------
// BitTorrent Peer Messaging:
// https://wiki.theory.org/BitTorrentSpecification#Peer_wire_protocol_.28TCP.29
//-----------------------------------------------------------------------------

pub const ID = "-ZIG666-weoiuv8324ns".*;

pub const HandShake = extern struct {
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
pub fn connectToPeer(
    io: Io,
    peer_ip: net.Ip4Address,
    peer_id: [20]u8,
    meta: *const MetaInfo,
) !net.Stream {
    const peer_addr: net.IpAddress = .{ .ip4 = peer_ip };
    var conn = try peer_addr.connect(io, .{ .mode = .stream, .protocol = .tcp });
    errdefer conn.close(io);

    var wr_buf: [512]u8 = undefined;
    var conn_wr = conn.writer(io, &wr_buf);

    var r_buf: [512]u8 = undefined;
    var conn_r = conn.reader(io, &r_buf);

    const hndshk: HandShake = .create(peer_id, meta);
    try conn_wr.interface.writeStruct(hndshk, .big);
    try conn_wr.interface.flush();

    const resp_handshake = try conn_r.interface.takeStruct(HandShake, .big);

    if (!std.mem.eql(u8, &resp_handshake.pstr, &hndshk.pstr) or
        resp_handshake.pstrlen != 19 or
        !std.mem.eql(u8, &resp_handshake.info_hash, &hndshk.info_hash))
    {
        return error.HandShakeError;
    }

    return conn;
}

/// Parses peers from a torrent in dictionary form and returns the ips
pub fn parsePeersDict(gpa: Allocator, data: *const std.ArrayList(Bencode.Value)) ![]net.Ip4Address {
    var peers: std.ArrayList(net.Ip4Address) = .empty;
    defer peers.deinit(gpa);

    try peers.ensureTotalCapacityPrecise(gpa, data.items.len);

    for (data.items) |d| switch (d) {
        .dict => |dict| {
            const ip = dict.get("ip") orelse return error.MissingIp;
            const port = dict.get("port") orelse return error.MissingPort;
            const addr = net.Ip4Address.parse(ip.string, @intCast(port.integer)) catch
                return error.InvalidIpFormat;
            peers.appendAssumeCapacity(addr);
        },
        else => return error.ParsePeersDict,
    };

    return peers.items;
}

/// Parses peers from a torrent in binary form and returns the ips
pub fn parsePeersBinary(gpa: Allocator, data: []const u8) ![]net.Ip4Address {
    // Each address is 6 bytes.
    if (data.len % 6 != 0)
        return error.InvalidPeers;

    var peers: std.ArrayList(net.Ip4Address) = .empty;
    errdefer peers.deinit(gpa);

    try peers.ensureTotalCapacityPrecise(gpa, data.len / 6);

    var i: usize = 0;
    while (i + 5 < data.len) : (i += 6) {
        const port: u16 = std.mem.readInt(u16, data[i + 4 .. i + 6][0..2], .big);
        const ip = data[i..][0..4];
        const address = net.Ip4Address{ .bytes = ip.*, .port = port };
        peers.appendAssumeCapacity(address);
    }
    return peers.items;
}
