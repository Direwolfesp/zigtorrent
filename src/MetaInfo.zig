const std = @import("std");
const Bencode = @import("Bencode.zig");
const BencodeValue = @import("Bencode.zig").BencodeValue;
const ParseError = @import("main.zig").ParseError;

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const allocator = gpa.allocator();
const stdout = std.io.getStdOut().writer();
const testing = std.testing;

// MetaInfo dictionary for bittorrent
// Single File Only
pub const MetaInfo = struct {};
