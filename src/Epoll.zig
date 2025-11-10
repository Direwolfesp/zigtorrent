const std = @import("std");
const linux = std.os.linux;
const PeerConnection = @import("peer.zig").PeerConnection;

const Epoll = @This();

efd: std.posix.fd_t,
ready_list: [128]linux.epoll_event,

pub fn init() !Epoll {
    const efd = try std.posix.epoll_create1(0);
    return .{
        .efd = efd,
        .ready_list = undefined,
    };
}

pub fn deinit(self: Epoll) void {
    std.posix.close(self.efd);
}

pub fn wait(self: *Epoll, timeout_ms: i32) []linux.epoll_event {
    const count = std.posix.epoll_wait(self.efd, &self.ready_list, timeout_ms);
    return self.ready_list[0..count];
}

pub fn readMode(self: Epoll, client: *PeerConnection) !void {
    var event = linux.epoll_event{
        .events = linux.EPOLL.IN | linux.EPOLL.ET,
        .data = .{ .ptr = @intFromPtr(client) },
    };
    try std.posix.epoll_ctl(self.efd, linux.EPOLL.CTL_MOD, client.socket, &event);
}

pub fn writeMode(self: Epoll, client: *PeerConnection) !void {
    var event = linux.epoll_event{
        .events = linux.EPOLL.OUT | linux.EPOLL.ET,
        .data = .{ .ptr = @intFromPtr(client) },
    };
    try std.posix.epoll_ctl(self.efd, linux.EPOLL.CTL_MOD, client.socket, &event);
}

pub fn newClient(self: Epoll, client: *PeerConnection) !void {
    var event = linux.epoll_event{
        .events = linux.EPOLL.OUT | linux.EPOLL.ET,
        .data = .{ .ptr = @intFromPtr(client) },
    };
    try std.posix.epoll_ctl(self.efd, linux.EPOLL.CTL_ADD, client.socket, &event);
}

pub fn removeClient(self: Epoll, client: *PeerConnection) !void {
    try std.posix.epoll_ctl(self.efd, linux.EPOLL.CTL_DEL, client.socket, null);
}
