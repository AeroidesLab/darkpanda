//! Owned OS thread for a DedicatedWorker V8 isolate.
//!
//! This phase deliberately contains no Worker/V8 integration. The native
//! handle stays private, detaching and forced termination are not supported,
//! and every successful spawn must be paired with `join`.

const std = @import("std");
const builtin = @import("builtin");
const common = @import("thread/common.zig");

const Platform = switch (builtin.os.tag) {
    .windows => @import("thread/windows.zig"),
    .linux, .macos => @import("thread/posix.zig"),
    else => @compileError("WorkerThread supports Windows, Linux, and macOS"),
};

const WorkerThread = @This();

pub const StackPolicy = common.StackPolicy;
pub const Config = common.Config;
pub const ThreadId = u64;
pub const Entry = *const fn (*anyopaque) void;
/// Runs on the new owner thread before `spawnWithBootstrap` publishes ready.
/// Only the error value crosses the thread boundary; its error trace does not.
pub const Bootstrap = *const fn (*anyopaque) anyerror!void;

pub const SpawnError = common.ConfigError || common.StartupError || Platform.SpawnError || error{OutOfMemory};

const StartupState = enum { starting, ready, failed };

const Control = struct {
    startup_mutex: std.Thread.Mutex = .{},
    startup_condition: std.Thread.Condition = .{},
    startup_state: StartupState = .starting,
    startup_error: ?anyerror = null,
    owner_id: ThreadId = 0,
    name_buffer: [common.max_thread_name_bytes]u8 = undefined,
    name_len: usize,
    user_context: *anyopaque,
    user_bootstrap: ?Bootstrap,
    user_entry: Entry,
    os_start: common.OsStart = undefined,

    fn name(self: *const Control) []const u8 {
        return self.name_buffer[0..self.name_len];
    }
};

handle: ?Platform.Handle,
control: ?*Control,

pub fn spawn(config: Config, context: *anyopaque, entry: Entry) SpawnError!WorkerThread {
    return spawnImpl(false, config, context, {}, entry);
}

/// Like `spawn`, but initialization that must happen on the worker's owner
/// thread runs before ready is published. A bootstrap failure is returned only
/// after the native thread has exited and its handle has been joined/closed.
pub fn spawnWithBootstrap(
    config: Config,
    context: *anyopaque,
    bootstrap_fn: Bootstrap,
    entry: Entry,
) anyerror!WorkerThread {
    return spawnImpl(true, config, context, bootstrap_fn, entry);
}

fn spawnImpl(
    comptime has_user_bootstrap: bool,
    config: Config,
    context: *anyopaque,
    bootstrap_fn: if (has_user_bootstrap) Bootstrap else void,
    entry: Entry,
) (if (has_user_bootstrap) anyerror else SpawnError)!WorkerThread {
    if (builtin.single_threaded) @compileError("WorkerThread cannot be used in single-threaded builds");

    const stack_request = try common.validateConfig(config, Platform.max_name_bytes);
    const control = try std.heap.page_allocator.create(Control);
    errdefer std.heap.page_allocator.destroy(control);

    control.* = .{
        .name_len = config.name.len,
        .user_context = context,
        .user_bootstrap = if (has_user_bootstrap) bootstrap_fn else null,
        .user_entry = entry,
    };
    @memcpy(control.name_buffer[0..config.name.len], config.name);
    control.os_start = .{
        .context = control,
        .function = threadBootstrap,
    };

    const handle = try Platform.spawn(stack_request, &control.os_start);

    control.startup_mutex.lock();
    while (control.startup_state == .starting) {
        control.startup_condition.wait(&control.startup_mutex);
    }
    const startup_error = control.startup_error;
    control.startup_mutex.unlock();

    if (startup_error) |err| {
        Platform.join(handle);
        if (has_user_bootstrap) return err;
        return switch (err) {
            error.ThreadNameSetupFailed => error.ThreadNameSetupFailed,
            else => unreachable,
        };
    }

    return .{
        .handle = handle,
        .control = control,
    };
}

fn threadBootstrap(raw: *anyopaque) void {
    const control: *Control = @ptrCast(@alignCast(raw));

    Platform.setCurrentName(control.name()) catch |err| {
        control.startup_mutex.lock();
        control.startup_error = err;
        control.startup_state = .failed;
        control.startup_condition.signal();
        control.startup_mutex.unlock();
        return;
    };

    if (control.user_bootstrap) |bootstrap_fn| {
        bootstrap_fn(control.user_context) catch |err| {
            publishStartupFailure(control, err);
            return;
        };
    }

    control.startup_mutex.lock();
    control.owner_id = Platform.currentId();
    control.startup_state = .ready;
    control.startup_condition.signal();
    control.startup_mutex.unlock();

    control.user_entry(control.user_context);
}

fn publishStartupFailure(control: *Control, err: anyerror) void {
    control.startup_mutex.lock();
    control.startup_error = err;
    control.startup_state = .failed;
    control.startup_condition.signal();
    control.startup_mutex.unlock();
}

/// Wait for completion, release the native handle, then release bootstrap
/// storage. There is intentionally no detach or forced-termination API.
pub fn join(self: *WorkerThread) void {
    const handle = self.handle orelse @panic("WorkerThread joined more than once");
    std.debug.assert(!self.isCurrent());

    Platform.join(handle);
    self.handle = null;

    const control = self.control.?;
    self.control = null;
    std.heap.page_allocator.destroy(control);
}

pub fn currentId() ThreadId {
    return Platform.currentId();
}

pub fn ownerId(self: *const WorkerThread) ThreadId {
    return self.control.?.owner_id;
}

pub fn name(self: *const WorkerThread) []const u8 {
    return self.control.?.name();
}

pub fn isCurrent(self: *const WorkerThread) bool {
    return self.ownerId() == currentId();
}

pub fn assertOwner(self: *const WorkerThread) void {
    std.debug.assert(self.isCurrent());
}

pub fn isJoined(self: *const WorkerThread) bool {
    return self.handle == null;
}

const OwnerTestContext = struct {
    release: std.Thread.ResetEvent = .{},
    thread: ?*WorkerThread = null,
    callback_id: ThreadId = 0,
    callback_saw_owner: bool = false,

    fn run(raw: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.callback_id = WorkerThread.currentId();
        self.release.wait();
        self.callback_saw_owner = self.thread.?.isCurrent();
        self.thread.?.assertOwner();
    }
};

test "spawn publishes owner and join consumes the handle" {
    const testing = std.testing;
    var context: OwnerTestContext = .{};
    var thread = try WorkerThread.spawn(.{}, &context, OwnerTestContext.run);

    const owner_id = thread.ownerId();
    try testing.expect(owner_id != 0);
    try testing.expect(owner_id != WorkerThread.currentId());
    try testing.expect(!thread.isCurrent());
    try testing.expectEqualStrings("DedicatedWorker", thread.name());

    context.thread = &thread;
    context.release.set();
    thread.join();

    try testing.expect(thread.isJoined());
    try testing.expectEqual(owner_id, context.callback_id);
    try testing.expect(context.callback_saw_owner);
}

const BootstrapTestContext = struct {
    initialized: bool = false,
    entry_ran: bool = false,

    fn initialize(raw: *anyopaque) !void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.initialized = true;
    }

    fn fail(_: *anyopaque) !void {
        return error.TestBootstrapFailure;
    }

    fn run(raw: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        std.debug.assert(self.initialized);
        self.entry_ran = true;
    }
};

test "worker-owned bootstrap publishes ready or propagates an error safely" {
    var success: BootstrapTestContext = .{};
    var thread = try WorkerThread.spawnWithBootstrap(
        .{},
        &success,
        BootstrapTestContext.initialize,
        BootstrapTestContext.run,
    );
    try std.testing.expect(success.initialized);
    thread.join();
    try std.testing.expect(success.entry_ran);

    var failure: BootstrapTestContext = .{};
    const handles_before = if (builtin.os.tag == .windows)
        try Platform.processHandleCount()
    else
        0;
    try std.testing.expectError(error.TestBootstrapFailure, WorkerThread.spawnWithBootstrap(
        .{},
        &failure,
        BootstrapTestContext.fail,
        BootstrapTestContext.run,
    ));
    try std.testing.expect(!failure.entry_ran);
    if (builtin.os.tag == .windows) {
        try std.testing.expectEqual(handles_before, try Platform.processHandleCount());
    }
}

const StressContext = struct {
    completed: *std.atomic.Value(usize),

    fn run(raw: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        _ = self.completed.fetchAdd(1, .monotonic);
    }
};

test "Windows CreateThread spawn/join survives 1000 rounds" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    var completed = std.atomic.Value(usize).init(0);

    // Warm lazy Win32/runtime initialization before taking the leak baseline.
    var warm_context: StressContext = .{ .completed = &completed };
    var warm_thread = try WorkerThread.spawn(.{}, &warm_context, StressContext.run);
    warm_thread.join();
    completed.store(0, .monotonic);
    const handles_before = try Platform.processHandleCount();

    for (0..1000) |_| {
        var context: StressContext = .{ .completed = &completed };
        var thread = try WorkerThread.spawn(.{}, &context, StressContext.run);
        thread.join();
    }
    try std.testing.expectEqual(@as(usize, 1000), completed.load(.monotonic));
    try std.testing.expectEqual(handles_before, try Platform.processHandleCount());
}

test "Windows chromium worker stack reserves 1 MiB and commits on demand" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const Probe = struct {
        info: ?Platform.StackInfo = null,
        failed: bool = false,

        fn run(raw: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.info = Platform.currentStackInfo() catch {
                self.failed = true;
                return;
            };
        }
    };

    var probe: Probe = .{};
    var thread = try WorkerThread.spawn(.{}, &probe, Probe.run);
    thread.join();

    try std.testing.expect(!probe.failed);
    const info = probe.info.?;
    try std.testing.expectEqual(@as(usize, 1024 * 1024), info.reservation_bytes);
    try std.testing.expect(info.current_region_committed);
    try std.testing.expect(info.committed_bytes > 0);
    try std.testing.expect(info.committed_bytes < info.reservation_bytes);

    var explicit_probe: Probe = .{};
    var explicit_thread = try WorkerThread.spawn(.{
        .stack_policy = .explicit,
        .stack_size = 2 * 1024 * 1024,
    }, &explicit_probe, Probe.run);
    explicit_thread.join();
    try std.testing.expect(!explicit_probe.failed);
    try std.testing.expectEqual(
        @as(usize, 2 * 1024 * 1024),
        explicit_probe.info.?.reservation_bytes,
    );
}

test "all platform stack policies have focused comptime coverage" {
    const linux = @import("thread/linux.zig");
    const macos = @import("thread/macos.zig");
    const request: common.StackRequest = .{
        .policy = .chromium_worker,
        .explicit_size = null,
        .thread_sanitizer = false,
    };

    try std.testing.expectEqual(@as(?usize, null), linux.stackPlanFor(request, .glibc).size);
    try std.testing.expectEqual(
        @as(?usize, 2 * 1024 * 1024),
        linux.stackPlanFor(request, .musl).size,
    );
    try std.testing.expectEqual(
        @as(usize, 8 * 1024 * 1024),
        macos.selectStackSize(512 * 1024, 8 * 1024 * 1024, request).size,
    );
}
