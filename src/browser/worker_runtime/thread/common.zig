const std = @import("std");

pub const chromium_windows_reserve = 1 * 1024 * 1024;
pub const chromium_posix_fallback = 2 * 1024 * 1024;
pub const thread_sanitizer_minimum = 16 * 1024 * 1024;
pub const minimum_explicit_stack = 64 * 1024;
pub const max_thread_name_bytes = 63;

pub const StackPolicy = enum {
    /// Match the platform policy used for Chromium-style worker threads.
    chromium_worker,
    /// Use `Config.stack_size` (subject to platform and sanitizer minimums).
    explicit,
};

pub const Config = struct {
    stack_policy: StackPolicy = .chromium_worker,
    stack_size: ?usize = null,
    /// Zig does not expose the module's `-fsanitize-thread` setting through
    /// `@import("builtin")`. The build integration must set this bit from its
    /// existing `-Dtsan` option when WorkerThread is wired into the browser.
    thread_sanitizer: bool = false,
    name: []const u8 = "DedicatedWorker",
};

pub const StackRequest = struct {
    policy: StackPolicy,
    explicit_size: ?usize,
    thread_sanitizer: bool,
};

pub const ConfigError = error{
    ExplicitStackSizeRequired,
    UnexpectedStackSize,
    StackSizeTooSmall,
    EmptyThreadName,
    ThreadNameTooLong,
    InvalidThreadName,
};

pub const StartupError = error{ThreadNameSetupFailed};

pub const OsStart = struct {
    context: *anyopaque,
    function: *const fn (*anyopaque) void,

    pub fn run(self: *const OsStart) void {
        self.function(self.context);
    }
};

pub fn validateConfig(config: Config, platform_name_limit: usize) ConfigError!StackRequest {
    if (config.name.len == 0) return error.EmptyThreadName;
    if (config.name.len > @min(platform_name_limit, max_thread_name_bytes)) {
        return error.ThreadNameTooLong;
    }
    if (!std.unicode.utf8ValidateSlice(config.name) or
        std.mem.indexOfScalar(u8, config.name, 0) != null)
    {
        return error.InvalidThreadName;
    }

    const explicit_size = switch (config.stack_policy) {
        .chromium_worker => blk: {
            if (config.stack_size != null) return error.UnexpectedStackSize;
            break :blk null;
        },
        .explicit => blk: {
            const size = config.stack_size orelse return error.ExplicitStackSizeRequired;
            if (size < minimum_explicit_stack) return error.StackSizeTooSmall;
            break :blk size;
        },
    };

    return .{
        .policy = config.stack_policy,
        .explicit_size = explicit_size,
        .thread_sanitizer = config.thread_sanitizer,
    };
}

pub fn withSanitizerMinimum(size: usize, enabled: bool) usize {
    return if (enabled) @max(size, thread_sanitizer_minimum) else size;
}

pub fn alignStackSize(size: usize, alignment: usize) error{StackSizeOverflow}!usize {
    std.debug.assert(std.math.isPowerOfTwo(alignment));
    if (size > std.math.maxInt(usize) - (alignment - 1)) return error.StackSizeOverflow;
    return std.mem.alignForward(usize, size, alignment);
}

test "stack policy validation is unambiguous" {
    const testing = std.testing;

    const chromium = try validateConfig(.{}, max_thread_name_bytes);
    try testing.expectEqual(StackPolicy.chromium_worker, chromium.policy);
    try testing.expectEqual(@as(?usize, null), chromium.explicit_size);

    const explicit = try validateConfig(.{
        .stack_policy = .explicit,
        .stack_size = 2 * 1024 * 1024,
    }, max_thread_name_bytes);
    try testing.expectEqual(@as(?usize, 2 * 1024 * 1024), explicit.explicit_size);

    try testing.expectError(error.ExplicitStackSizeRequired, validateConfig(.{
        .stack_policy = .explicit,
    }, max_thread_name_bytes));
    try testing.expectError(error.UnexpectedStackSize, validateConfig(.{
        .stack_size = chromium_windows_reserve,
    }, max_thread_name_bytes));
    try testing.expectError(error.StackSizeTooSmall, validateConfig(.{
        .stack_policy = .explicit,
        .stack_size = minimum_explicit_stack - 1,
    }, max_thread_name_bytes));
}

test "thread names reject hidden terminators and platform overflow" {
    const testing = std.testing;

    try testing.expectError(error.EmptyThreadName, validateConfig(.{ .name = "" }, 15));
    try testing.expectError(error.InvalidThreadName, validateConfig(.{ .name = "bad\x00name" }, 15));
    try testing.expectError(error.ThreadNameTooLong, validateConfig(.{ .name = "sixteen-byte-name" }, 15));
}
