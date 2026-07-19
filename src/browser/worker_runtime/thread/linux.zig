const std = @import("std");
const builtin = @import("builtin");
const common = @import("common.zig");

pub const max_name_bytes = 15;

pub const LibcKind = enum { glibc, musl, other };

pub const StackPlan = struct {
    size: ?usize,
    preserve_default_guard: bool = true,
};

pub fn nativeLibcKind() LibcKind {
    if (builtin.target.abi.isGnu()) return .glibc;
    if (builtin.target.abi.isMusl()) return .musl;
    return .other;
}

pub fn stackPlanFor(request: common.StackRequest, libc_kind: LibcKind) StackPlan {
    const base: ?usize = switch (request.policy) {
        .explicit => request.explicit_size.?,
        .chromium_worker => switch (libc_kind) {
            // Chromium relies on glibc's process/default pthread stack policy.
            .glibc => null,
            .musl, .other => common.chromium_posix_fallback,
        },
    };

    return .{
        .size = if (request.thread_sanitizer)
            common.withSanitizerMinimum(base orelse 0, true)
        else
            base,
    };
}

pub fn configureAttr(attr: *std.c.pthread_attr_t, request: common.StackRequest) error{
    InvalidStackSize,
    StackSizeOverflow,
    Unexpected,
}!void {
    const plan = stackPlanFor(request, nativeLibcKind());
    if (plan.size) |raw_size| {
        const size = try common.alignStackSize(raw_size, std.heap.pageSize());
        switch (std.c.pthread_attr_setstacksize(attr, size)) {
            .SUCCESS => {},
            .INVAL => return error.InvalidStackSize,
            else => return error.Unexpected,
        }
    }
    // Intentionally do not call pthread_attr_setguardsize: retain libc's
    // default guard page policy.
}

pub fn currentId() u64 {
    return @intCast(std.os.linux.gettid());
}

pub fn setCurrentName(name: []const u8) common.StartupError!void {
    var buffer: [max_name_bytes + 1]u8 = @splat(0);
    @memcpy(buffer[0..name.len], name);
    if (std.c.pthread_setname_np(std.c.pthread_self(), @ptrCast(&buffer)) != 0) {
        return error.ThreadNameSetupFailed;
    }
}

test "Linux chromium stack plans retain libc guard defaults" {
    const testing = std.testing;
    const request: common.StackRequest = .{
        .policy = .chromium_worker,
        .explicit_size = null,
        .thread_sanitizer = false,
    };

    const glibc = stackPlanFor(request, .glibc);
    try testing.expectEqual(@as(?usize, null), glibc.size);
    try testing.expect(glibc.preserve_default_guard);

    const musl = stackPlanFor(request, .musl);
    try testing.expectEqual(@as(?usize, 2 * 1024 * 1024), musl.size);
    try testing.expect(musl.preserve_default_guard);

    const tsan = stackPlanFor(.{
        .policy = .chromium_worker,
        .explicit_size = null,
        .thread_sanitizer = true,
    }, .glibc);
    try testing.expectEqual(@as(?usize, 16 * 1024 * 1024), tsan.size);
}
