const std = @import("std");
const File = std.fs.File;
const Sha1 = std.crypto.hash.Sha1;

const Bencode = @import("Bencode.zig");
const MetaInfo = @import("MetaInfo.zig").MetaInfo;
const Peer = @import("Peer.zig");
const Message = Peer.Message;
const MessageError = Peer.MessageError;
const HandShake = Peer.HandShake;
const Tracker = @import("Tracker.zig");

const stdout = std.io.getStdOut().writer();

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

            // Connect to peer
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
            const p_torrent = args[3];
            const p_ofile = args[2];
            const p_piece_index: u32 = try std.fmt.parseInt(u32, args[4], 10);

            var bencode = try Bencode.decodeBencodeFromFile(allocator, p_torrent);
            defer bencode.deinit(allocator);
            const meta = try MetaInfo.init(allocator, bencode.value);

            const total_pieces = meta.info.pieces.len / 20;
            if (p_piece_index >= total_pieces) {
                std.log.err(
                    "Invalid piece index {}. Max is {}",
                    .{ p_piece_index, total_pieces },
                );
                return;
            }

            var trckr_response: Bencode.ValueManaged = try Tracker.getResponse(allocator, meta);
            defer trckr_response.deinit(allocator);

            const peers = try Tracker.getPeersFromResponse(allocator, trckr_response.value);
            const peer = peers[0]; // we will just use the first peer for simplicity

            // conect to peer
            var connection = try std.net.tcpConnectToAddress(std.net.Address{ .in = peer });
            defer connection.close();
            std.log.info("Connected to peer", .{});
            const conn_writer = connection.writer();
            const conn_reader = connection.reader();

            // send and receive handshake
            const handshake = HandShake.createFromMeta(meta);
            try conn_writer.writeStruct(handshake);
            _ = try conn_reader.readStruct(HandShake);
            std.log.info("Done handshake with peer", .{});

            const msg = try Message.init(allocator, conn_reader);
            defer msg.deinit(allocator);
            if (msg != .bitfield) return MessageError.Invalid;
            std.log.info("Received 'bitfield'", .{});

            const int: Message = .interested;
            try int.write(conn_writer);
            std.log.info("Sent 'interested'", .{});

            const unchk = try Message.init(allocator, conn_reader);
            defer unchk.deinit(allocator);
            if (unchk != .unchoke) return MessageError.Invalid;
            std.log.info("Received 'unchoke'", .{});

            const piece_length: u32 = @intCast(meta.info.piece_length);
            var piece_byte_index: u32 = 0;
            const block_length: u32 = 16 * 1024;
            var res = std.ArrayList(u8).init(allocator);
            defer res.deinit();

            // while we havent download the piece yet
            while (piece_byte_index != piece_length) {
                const left: u32 = piece_length - piece_byte_index;
                const bytes: u32 = if (left >= block_length) block_length else left;
                const request: Message = .{
                    .request = .{
                        .index = p_piece_index,
                        .begin = piece_byte_index,
                        .length = bytes,
                    },
                };

                // request block
                request.write(conn_writer) catch |err| {
                    try stdout.print(
                        \\Bad request for piece_index: {}, block byte start: {},
                        \\requested length: {}
                        \\Error: {?}
                    , .{ p_piece_index, piece_byte_index, bytes, err });
                    return;
                };
                std.log.info("Sent 'request'", .{});

                // wait for the piece message
                const read = try Message.init(allocator, conn_reader);
                defer read.deinit(allocator);
                if (read != .piece) return MessageError.Invalid;
                std.log.info("Received 'piece'", .{});

                // we should've got what we requested
                std.debug.assert(read.piece.index == p_piece_index);
                std.debug.assert(read.piece.begin == piece_byte_index);
                std.debug.assert(read.piece.block.len == bytes);

                try res.appendSlice(read.piece.block);
                piece_byte_index += bytes;

                std.log.info("Received {}", .{std.fmt.fmtIntSizeDec(bytes)});
                std.log.info("Progress: {} of {} for this piece", .{
                    std.fmt.fmtIntSizeDec(piece_byte_index),
                    std.fmt.fmtIntSizeDec(piece_length),
                });
            }

            // check piece integrity
            var sha1 = Sha1.init(.{});
            sha1.update(res.items);
            const piece_hash = sha1.finalResult();
            const start_index = p_piece_index * 20;
            if (std.mem.eql(u8, &piece_hash, meta.info.pieces[start_index .. start_index + 20])) {
                std.log.info("Piece SHA1 hash verified correctly", .{});
            } else {
                std.log.err("Piece SHA1 hash failed", .{});
            }

            // store piece in file
            var file = try std.fs.cwd().createFile(p_ofile, .{ .read = true });
            defer file.close();
            const file_writer = file.writer();
            try file_writer.writeAll(res.items);
            std.log.info("Piece contents written into file '{s}'", .{p_ofile});
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
