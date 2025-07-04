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
const stderr = std.io.getStdErr().writer();

const Commands = enum {
    help,
    decode,
    info,
    peers,
    handshake,
    download_piece,

    const help_str =
        \\Usage:
        \\   ./program help
        \\   ./program decode <bencoded_string>
        \\   ./program info <torrent>
        \\   ./program peers <torrent>
        \\   ./program handshake <torrent> <peer_ip>:<peer_port>
        \\   ./program download_piece <output_file> <torrent> <piece_index>
    ;

    pub fn printHelp() !void {
        try stdout.print("{s}\n", .{help_str});
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        try Commands.printHelp();
        std.process.exit(1);
    }

    const cmd = std.meta.stringToEnum(Commands, args[1]) orelse Commands.help;
    if (switch (cmd) {
        .decode, .info, .peers => args.len != 3,
        .handshake => args.len != 4,
        .download_piece => args.len != 5,
        else => args.len != 2,
    }) {
        try Commands.printHelp();
        std.process.exit(1);
    }

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

            // calculate the piece length according to the index,
            // the last index might get a piece smaller than the other pieces
            // this is only necesary one per piece
            const num_full_pieces = try std.math.divFloor(
                i64,
                meta.info.length,
                meta.info.piece_length,
            );
            const piece_length: i64 = if (p_piece_index < num_full_pieces)
                meta.info.piece_length
            else
                meta.info.length - num_full_pieces * meta.info.piece_length;

            var piece_byte_index: u32 = 0;
            const block_length: u32 = 16 * 1024;
            var res = std.ArrayList(u8).init(allocator);
            defer res.deinit();
            try res.ensureTotalCapacityPrecise(@intCast(piece_length));

            // while we havent download the piece yet
            while (piece_byte_index != piece_length) {
                const left = piece_length - piece_byte_index;
                const bytes = if (left >= block_length) block_length else left;

                const request: Message = .{
                    .request = .{
                        .index = p_piece_index,
                        .begin = piece_byte_index,
                        .length = @intCast(bytes),
                    },
                };

                // request block
                try request.write(conn_writer);

                // wait for the piece message
                const read = try Message.init(allocator, conn_reader);
                defer read.deinit(allocator);
                if (read != .piece) return MessageError.Invalid;

                // we should've got what we requested
                std.debug.assert(read.piece.index == p_piece_index);
                std.debug.assert(read.piece.begin == piece_byte_index);
                std.debug.assert(read.piece.block.len == bytes);

                try res.appendSlice(read.piece.block);
                piece_byte_index += @intCast(bytes);

                try stdout.print("Progress: {} of {} for this piece\r", .{
                    std.fmt.fmtIntSizeDec(piece_byte_index),
                    std.fmt.fmtIntSizeDec(@intCast(piece_length)),
                });
            }
            try stdout.print("\n", .{});

            // check piece integrity
            var sha1 = Sha1.init(.{});
            sha1.update(res.items);
            const piece_hash = sha1.finalResult();
            const start_index = p_piece_index * 20;
            if (std.mem.eql(u8, &piece_hash, meta.info.pieces[start_index .. start_index + 20])) {
                try stdout.print("Piece SHA1 hash verified correctly\n", .{});
            } else {
                try stderr.print("Piece SHA1 hash failed\n", .{});
            }

            // store piece in file
            var file = try std.fs.cwd().createFile(p_ofile, .{ .read = true });
            defer file.close();
            const file_writer = file.writer();
            try file_writer.writeAll(res.items);
            try stdout.print("Piece contents written into file '{s}'", .{p_ofile});
        },
        .help => {
            try Commands.printHelp();
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
