const std = @import("std");
const stdout = std.io.getStdOut().writer();
const File = std.fs.File;
const Sha1 = std.crypto.hash.Sha1;

const Bencode = @import("Bencode.zig");
const Peer = @import("Peer.zig");
const HandShake = Peer.HandShake;
const MetaInfo = @import("MetaInfo.zig").MetaInfo;
const Tracker = @import("Tracker.zig");

const Commands = enum {
    decode,
    info,
    peers,
    handshake,
    download_piece,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 3) {
        try stdout.print("Usage: ./program <command> <args>\n", .{});
        std.process.exit(1);
    }
    const cmd = std.meta.stringToEnum(Commands, args[1]).?;
    switch (cmd) {
        .decode => {
            const encodedStr = args[2];
            var decodedStr = Bencode.decodeBencode(allocator, encodedStr) catch {
                try stdout.print("Invalid encoded value\n", .{});
                std.process.exit(1);
            };
            defer decodedStr.deinit();
            try print(decodedStr, stdout, false);
        },
        .info => {
            var bencode = try Bencode.decodeBencodeFromFile(allocator, args[2]);
            defer bencode.deinit(allocator);
            const parsedMeta = try MetaInfo.init(allocator, bencode.value);
            try parsedMeta.printMetaInfo();
        },
        .peers => {
            var bencode = try Bencode.decodeBencodeFromFile(allocator, args[2]);
            defer bencode.deinit(allocator);
            const meta = try MetaInfo.init(allocator, bencode.value);

            var bodyDecoded = try Tracker.getResponse(allocator, meta);
            defer bodyDecoded.deinit(allocator);

            const peers: []std.net.Ip4Address = try Tracker.getPeersFromResponse(
                allocator,
                bodyDecoded.value,
            );
            for (peers) |peer| try stdout.print("{}\n", .{peer});
        },
        .handshake => {
            if (args.len != 4) {
                try stdout.print("Usage: $ ./program handshake <torrent> <peer_ip>:<peer_port>\n", .{});
                std.process.exit(1);
            }

            var bencode = try Bencode.decodeBencodeFromFile(allocator, args[2]);
            defer bencode.deinit(allocator);
            const meta = try MetaInfo.init(allocator, bencode.value);
            const handshake = HandShake.createFromMeta(meta);
            std.log.info("Created handshake struct", .{});

            // create ipv4 address
            const addr: std.net.Address = try parseAddressArg(args[3]);
            std.log.info("Trying to connect to peer...", .{});
            var connection = try std.net.tcpConnectToAddress(addr);
            defer connection.close();
            std.log.info("Connected to peer", .{});
            const writer = connection.writer();
            const reader = connection.reader();

            // send and receive handshake
            std.log.info("Sending handshake to peer...", .{});
            try writer.writeStruct(handshake);
            std.log.info("Waiting for response...", .{});
            const resp_handshake = try reader.readStruct(HandShake);
            std.log.info("Got a response from peer ", .{});
            const peer_id = std.fmt.fmtSliceHexLower(&resp_handshake.peer_id);
            try stdout.print("Peer ID: {s}\n", .{peer_id});
        },
        .download_piece => {
            if (args.len != 5) {
                try stdout.print("Usage: ./program download_piece <output_file> <torrent> <piece_index>", .{});
                return;
            }
            var bencode = try Bencode.decodeBencodeFromFile(allocator, args[2]);
            defer bencode.deinit(allocator);
            const meta = try MetaInfo.init(allocator, bencode.value);

            var bodyDecoded: Bencode.ValueManaged = try Tracker.getResponse(allocator, meta);
            defer bodyDecoded.deinit(allocator);
            // const peers: []const u8 = bodyDecoded.value.dict.get("peers").?.string;
            // const peer = peers[0]; // we will just use the first peer
            // _ = peer;
            // const addres = parseAddresIpv4(peer);
        },
    }
}

/// Parses a slice of bytes to an Ipv4 address
pub fn parseAddressArg(address: []const u8) !std.net.Address {
    var it = std.mem.splitScalar(u8, address, ':');
    const ip: []const u8 = it.first();
    const port = try std.fmt.parseInt(u16, it.next().?, 10);
    const res = try std.net.Address.resolveIp(ip, port);
    std.log.info("Peer ip: {?}", .{res});
    return res;
}

/// Just for the annoying nested '\n' to pass the tests
fn print(val: Bencode.Value, writer: anytype, nested: bool) !void {
    try val.format("", .{}, writer, nested);
}

// Run all the test of the types that are attached to main
test {
    std.testing.refAllDecls(@This());
}
