const std = @import("std");
const http = std.http;
const Bencode = @import("Bencode.zig");
const MetaInfo = @import("MetaInfo.zig").MetaInfo;
const BencodeValue = @import("Bencode.zig").BencodeValue;
const RequestParams = @import("Request.zig");

const stdout = std.io.getStdOut().writer();
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const allocator = gpa.allocator();
const Map = std.StringArrayHashMap(Bencode);
const File = std.fs.File;
const Sha1 = std.crypto.hash.Sha1;

const Commands = enum {
    decode,
    info,
    peers,
    handshake,
};

pub fn main() !void {
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 3) {
        try stdout.print("Usage: your_bittorrent.zig <command> <args>\n", .{});
        std.process.exit(1);
    }

    const command = std.meta.stringToEnum(Commands, args[1]) orelse return;

    switch (command) {
        .decode => {
            const encodedStr = args[2];
            var decodedStr = Bencode.decodeBencode(encodedStr) catch {
                try stdout.print("Invalid encoded value\n", .{});
                std.process.exit(1);
            };
            defer decodedStr.deinit();
            try print(decodedStr, stdout, false);
        },
        .info => {
            const filename = args[2];
            var file: File = try std.fs.cwd().openFile(filename, .{});
            defer file.close();

            const content = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
            defer allocator.free(content);

            var meta: BencodeValue = try Bencode.decodeBencode(content);
            defer meta.deinit();

            var parsedMeta: MetaInfo = undefined;
            try parsedMeta.init(meta);
            try parsedMeta.printMetaInfo();
        },
        .peers => {
            const filename = args[2];
            var file: File = try std.fs.cwd().openFile(filename, .{});
            defer file.close();

            const content = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
            defer allocator.free(content);

            // decode bencode
            var value: BencodeValue = try Bencode.decodeBencode(content);
            defer value.deinit();

            // parse metainfo
            var parsedMeta: MetaInfo = undefined;
            try parsedMeta.init(value);

            // request Params
            var req_params = try RequestParams.create(parsedMeta);

            // Serialize to URI
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
            const body = try req.reader().readAllAlloc(allocator, std.math.maxInt(usize));
            defer allocator.free(body);

            // decode response and print
            const bodyDecoded: BencodeValue = try Bencode.decodeBencode(body);
            const peers = bodyDecoded.dict.get("peers").?.string;

            var i: usize = 0;
            while (i + 5 < peers.len) : (i += 6) {
                const peer_ip = peers[i .. i + 4];
                const peer_port: u16 = std.mem.readInt(u16, peers[i + 4 .. i + 6][0..2], .big);

                try stdout.print("{d}.{d}.{d}.{d}:{d}\n", .{
                    peer_ip[0],
                    peer_ip[1],
                    peer_ip[2],
                    peer_ip[3],
                    peer_port,
                });
            }
        },
        .handshake => {},
    }
}

// Just for the annoying nested '\n' to pass the tests
fn print(val: BencodeValue, writer: anytype, nested: bool) !void {
    try val.format("", .{}, writer, nested);
}
