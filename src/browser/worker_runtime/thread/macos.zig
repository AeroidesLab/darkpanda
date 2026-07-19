const std = @import("std");
const common = @import("common.zig");

pub const max_name_bytes = common.max_thread_name_bytes;
pub const pthread_stack_min = 16 * 1024;

pub const StackPlan = struct {
    size: usize,
    preserve_default_guard: bool = true,
};

extern "c" fn pthread_attr_getstacksize(
    attr: *const std.c.pthread_attr_t,
    stack_size: *usize,
) std.c.E;

pub fn selectStackSize(
    pthread_default: usize,
    finite_rlimit: ?usize,
    request: common.StackRequest,
) StackPlan {
    var size = switch (request.policy) {
        .explicit => request.explicit_size.?,
        .chromium_worker => @max(pthread_default, pthread_stack_min),
    };
    if (request.policy == .chromium_worker) {
        if (finite_rlimit) |limit| size = @max(size, limit);
    }
    size = common.withSanitizerMinimum(size, request.thread_sanitizer);
    return .{ .size = size };
}

pub fn configureAttr(attr: *std.c.pthread_attr_t, request: common.StackRequest) error{
    InvalidStackSize,
    StackSizeOverflow,
    Unexpected,
}!void {
    var pthread_default: usize = 0;
    if (pthread_attr_getstacksize(attr, &pthread_default) != .SUCCESS) {
        return error.Unexpected;
    }

    const finite_rlimit: ?usize = blk: {
        const limits = std.posix.getrlimit(.STACK) catch break :blk null;
        if (limits.cur == std.posix.RLIM.INFINITY) break :blk null;
        break :blk std.math.cast(usize, limits.cur);
    };
    const plan = selectStackSize(pthread_default, finite_rlimit, request);
    const size = try common.alignStackSize(plan.size, std.heap.pageSize());
    if (size != pthread_default) {
        switch (std.c.pthread_attr_setstacksize(attr, size)) {
            .SUCCESS => {},
            .INVAL => return error.InvalidStackSize,
            else => return error.Unexpected,
        }
    }
    // Do not call pthread_attr_setguardsize. Darwin's default guard remains.
}

pub fn currentId() u64 {
    var id: u64 = 0;
    if (std.c.pthread_threadid_np(null, &id) != 0) unreachable;
    return id;
}

pub fn setCurrentName(name: []const u8) common.StartupError!void {
    var buffer: [max_name_bytes + 1]u8 = @splat(0);
    @memcpy(buffer[0..name.len], name);
    if (std.c.pthread_setname_np(@ptrCast(&buffer)) != 0) {
        return error.ThreadNameSetupFailed;
    }
}

test "macOS chromium policy takes the finite RLIMIT_STACK maximum" {
    const testing = std.testing;
    const request: common.StackRequest = .{
        .policy = .chromium_worker,
        .explicit_size = null,
        .thread_sanitizer = false,
    };

    const plan = selectStackSize(512 * 1024, 8 * 1024 * 1024, request);
    try testing.expectEqual(@as(usize, 8 * 1024 * 1024), plan.size);
    try testing.expect(plan.preserve_default_guard);

    const no_limit = selectStackSize(512 * 1024, null, request);
    try testing.expectEqual(@as(usize, 512 * 1024), no_limit.size);
}
