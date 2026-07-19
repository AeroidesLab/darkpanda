const std = @import("std");
const builtin = @import("builtin");
const common = @import("common.zig");

const os = switch (builtin.os.tag) {
    .linux => @import("linux.zig"),
    .macos => @import("macos.zig"),
    else => @compileError("WorkerThread POSIX backend currently supports Linux and macOS"),
};

pub const max_name_bytes = os.max_name_bytes;

pub const SpawnError = error{
    OutOfMemory,
    SystemResources,
    InvalidStackSize,
    StackSizeOverflow,
    Unexpected,
};

pub const Handle = struct {
    raw: std.c.pthread_t,
};

fn threadEntry(raw: ?*anyopaque) callconv(.c) ?*anyopaque {
    const start: *const common.OsStart = @ptrCast(@alignCast(raw.?));
    start.run();
    return null;
}

pub fn spawn(request: common.StackRequest, start: *const common.OsStart) SpawnError!Handle {
    var attr: std.c.pthread_attr_t = undefined;
    switch (std.c.pthread_attr_init(&attr)) {
        .SUCCESS => {},
        .NOMEM => return error.OutOfMemory,
        else => return error.SystemResources,
    }
    defer std.debug.assert(std.c.pthread_attr_destroy(&attr) == .SUCCESS);

    try os.configureAttr(&attr, request);

    var raw: std.c.pthread_t = undefined;
    switch (std.c.pthread_create(&raw, &attr, threadEntry, @ptrCast(@constCast(start)))) {
        .SUCCESS => return .{ .raw = raw },
        .AGAIN => return error.SystemResources,
        .NOMEM => return error.OutOfMemory,
        else => return error.Unexpected,
    }
}

pub fn join(handle: Handle) void {
    switch (std.c.pthread_join(handle.raw, null)) {
        .SUCCESS => {},
        .DEADLK, .INVAL, .SRCH => unreachable,
        else => unreachable,
    }
}

pub fn currentId() u64 {
    return os.currentId();
}

pub fn setCurrentName(name: []const u8) common.StartupError!void {
    return os.setCurrentName(name);
}
