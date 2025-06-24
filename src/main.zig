const std = @import("std");
const stdout = std.io.getStdOut().writer();
const http = std.http;
const File = std.fs.File;
const Sha1 = std.crypto.hash.Sha1;

const Bencode = @import("Bencode.zig");
const BencodeValue = @import("Bencode.zig").BencodeValue;
const BencodeValueManaged = @import("Bencode.zig").BencodeValueManaged;
const HandShake = @import("Peer.zig").HandShake;
const MetaInfo = @import("MetaInfo.zig").MetaInfo;
const RequestParams = @import("Request.zig");

const Commands = enum {
    decode,
    info,
    peers,
    handshake,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 3) {
        try stdout.print("Usage: your_bittorrent.zig <command> <args>\n", .{});
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

            var parsedMeta: MetaInfo = undefined;
            try parsedMeta.init(allocator, bencode.value);
            try parsedMeta.printMetaInfo();
        },
        .peers => {
            var bencode = try Bencode.decodeBencodeFromFile(allocator, args[2]);
            defer bencode.deinit(allocator);

            var parsedMeta: MetaInfo = undefined;
            try parsedMeta.init(allocator, bencode.value);

            // request Params and create URI
            var req_params = RequestParams.create(parsedMeta);
            var queryBuf = std.ArrayList(u8).init(allocator);
            defer queryBuf.deinit();
            const uri: std.Uri = try req_params.toURI(&queryBuf, allocator);

            // create client
            var client = http.Client{ .allocator = allocator };
            defer client.deinit();

            // header buffer
            const server_header_buff: []u8 = try allocator.alloc(u8, 1024);
            defer allocator.free(server_header_buff);

            var req: std.http.Client.Request = try client.open(.GET, uri, .{
                .server_header_buffer = server_header_buff,
            });
            defer req.deinit();

            // make request
            try req.send();
            try req.finish();
            try req.wait();
            if (req.response.status != .ok)
                return error.RequestFailed;

            // read the bencoded response body
            const body: []u8 = try req.reader().readAllAlloc(
                allocator,
                std.math.maxInt(usize),
            );
            defer allocator.free(body);

            // decode response and print
            const bodyDecoded: BencodeValue = try Bencode.decodeBencode(allocator, body);
            const peers: []const u8 = bodyDecoded.dict.get("peers").?.string;
            try printPeers(peers);
        },
        .handshake => {
            if (args.len != 4) {
                try stdout.print("Usage: $ ./program handshake <torrent> <peer_ip>:<peer_port>\n", .{});
                std.process.exit(1);
            }
            var bencode = try Bencode.decodeBencodeFromFile(allocator, args[2]);
            std.log.info("Parsed file {s}", .{args[2]});
            defer bencode.deinit(allocator);

            // create handshake
            var parsedMeta: MetaInfo = undefined;
            try parsedMeta.init(allocator, bencode.value);
            var handshake = HandShake.createFromMeta(parsedMeta);
            std.log.info("Created handshake struct", .{});

            // create ipv4 address
            const address = args[3];
            var it = std.mem.splitScalar(u8, address, ':');
            const ip: []const u8 = it.first();
            const port = it.next() orelse return error.MissingPort;
            const addr = try std.net.Address.resolveIp(
                ip,
                try std.fmt.parseInt(u16, port, 10),
            );
            std.log.info("Peer ip: {?}", .{addr});

            std.log.info("Trying to connect to peer...", .{});
            var connection = try std.net.tcpConnectToAddress(addr);
            std.log.info("Connected to peer", .{});
            const writer = connection.writer();
            const reader = connection.reader();

            std.log.info("Sending handshake to peer...", .{});
            try handshake.dumpToWriter(writer);
            std.log.info("Waiting for response...", .{});
            const response: []u8 = try reader.readAllAlloc(
                allocator,
                std.math.maxInt(usize),
            );
            defer allocator.free(response);
            std.log.info("Got a response from peer ", .{});
            const resp_handshake = HandShake.createFromBuffer(response);
            const peer_id = std.fmt.fmtSliceHexLower(&resp_handshake.peer_id);
            std.log.info("Peer ID: {s}", .{peer_id});
        },
    }
}

// Just for the annoying nested '\n' to pass the tests
fn print(val: BencodeValue, writer: anytype, nested: bool) !void {
    try val.format("", .{}, writer, nested);
}

fn printPeers(peers: []const u8) !void {
    var i: usize = 0;
    while (i + 5 < peers.len) : (i += 6) {
        const peer_ip = peers[i .. i + 4];
        const peer_port: u16 = std.mem.readInt(
            u16,
            peers[i + 4 .. i + 6][0..2],
            .big,
        );
        try stdout.print("{d}.{d}.{d}.{d}:{d}\n", .{
            peer_ip[0],
            peer_ip[1],
            peer_ip[2],
            peer_ip[3],
            peer_port,
        });
    }
}

// Run all the test of the types that are attached to main
test {
    std.testing.refAllDecls(@This());
}
