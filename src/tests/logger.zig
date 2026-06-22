const ansi = @import("../ansi.zig");
const std = @import("std");

pub fn logFn(
    comptime message_level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    comptime var buf: [10]u8 = undefined;
    const upper_level = comptime std.ascii.upperString(&buf, message_level.asText());
    const padded_plain = std.fmt.comptimePrint("{s}", .{upper_level});

    const colored_level = comptime switch (message_level) {
        .debug => ansi.brightWhite ++ padded_plain ++ ansi.reset,
        .info => ansi.blue ++ padded_plain ++ ansi.reset,
        .warn => ansi.brightYellow ++ padded_plain ++ ansi.reset,
        .err => ansi.brightRed ++ padded_plain ++ ansi.reset,
    };

    const level_txt = std.fmt.comptimePrint("[{s}] ", .{colored_level});
    const prefix2 = if (scope == .default) "" else @tagName(scope) ++ ": ";

    var buffer: [64]u8 = undefined;
    const stderr = std.debug.lockStderrWriter(&buffer);
    defer std.debug.unlockStderrWriter();

    nosuspend stderr.print(level_txt ++ ansi.grey ++ prefix2 ++ format ++ ansi.reset ++ "\n", args) catch return;
}
