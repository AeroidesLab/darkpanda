const std = @import("std");
const builtin = @import("builtin");
const common = @import("common.zig");

const windows = std.os.windows;
const kernel32 = windows.kernel32;

pub const max_name_bytes = common.max_thread_name_bytes;
pub const chromium_worker_stack_reserve = common.chromium_windows_reserve;

const stack_size_param_is_a_reservation: windows.DWORD = 0x0001_0000;

pub const SpawnError = error{
    OutOfMemory,
    SystemResources,
    StackSizeOverflow,
    UnsupportedArchitecture,
    Unexpected,
};

pub const Handle = struct {
    raw: windows.HANDLE,
    id: windows.DWORD,
    reserve_bytes: usize,
};

pub const StackInfo = struct {
    reservation_bytes: usize,
    committed_bytes: usize,
    current_region_committed: bool,
};

extern "kernel32" fn SetThreadDescription(
    thread: windows.HANDLE,
    description: [*:0]const u16,
) callconv(.winapi) i32;

extern "kernel32" fn GetProcessHandleCount(
    process: windows.HANDLE,
    count: *windows.DWORD,
) callconv(.winapi) windows.BOOL;

fn threadEntry(raw: windows.LPVOID) callconv(.winapi) windows.DWORD {
    const start: *const common.OsStart = @ptrCast(@alignCast(raw));
    start.run();
    return 0;
}

pub fn spawn(request: common.StackRequest, start: *const common.OsStart) SpawnError!Handle {
    if (comptime builtin.cpu.arch != .x86_64 and builtin.cpu.arch != .aarch64) {
        return error.UnsupportedArchitecture;
    }

    const reserve = switch (request.policy) {
        .chromium_worker => chromium_worker_stack_reserve,
        .explicit => request.explicit_size.?,
    };
    const effective_reserve = common.withSanitizerMinimum(reserve, request.thread_sanitizer);

    var id: windows.DWORD = 0;
    const handle = kernel32.CreateThread(
        null,
        effective_reserve,
        threadEntry,
        @ptrCast(@constCast(start)),
        stack_size_param_is_a_reservation,
        &id,
    ) orelse return switch (windows.GetLastError()) {
        .NOT_ENOUGH_MEMORY, .OUTOFMEMORY, .COMMITMENT_LIMIT => error.OutOfMemory,
        .MAX_THRDS_REACHED, .NOT_ENOUGH_QUOTA => error.SystemResources,
        else => error.Unexpected,
    };

    return .{
        .raw = handle,
        .id = id,
        .reserve_bytes = effective_reserve,
    };
}

pub fn join(handle: Handle) void {
    windows.WaitForSingleObject(handle.raw, windows.INFINITE) catch unreachable;
    windows.CloseHandle(handle.raw);
}

pub fn currentId() u64 {
    return windows.GetCurrentThreadId();
}

pub fn setCurrentName(name: []const u8) common.StartupError!void {
    var wide: [common.max_thread_name_bytes + 1]u16 = @splat(0);
    const written = std.unicode.utf8ToUtf16Le(&wide, name) catch {
        return error.ThreadNameSetupFailed;
    };
    wide[written] = 0;

    const result = SetThreadDescription(windows.GetCurrentThread(), @ptrCast(&wide));
    if (result < 0) return error.ThreadNameSetupFailed;
}

/// Diagnostic used by the native Windows smoke test. `StackLimit` describes
/// the currently committed portion, while VirtualQuery's AllocationBase is
/// the bottom of the reservation created by CreateThread.
pub fn currentStackInfo() error{Unexpected}!StackInfo {
    var marker: u8 = 0;
    var memory: windows.MEMORY_BASIC_INFORMATION = undefined;
    if (kernel32.VirtualQuery(
        @ptrCast(&marker),
        &memory,
        @sizeOf(windows.MEMORY_BASIC_INFORMATION),
    ) == 0) return error.Unexpected;

    const tib = &windows.teb().NtTib;
    const allocation_base = @intFromPtr(memory.AllocationBase);
    const stack_base = @intFromPtr(tib.StackBase);
    const stack_limit = @intFromPtr(tib.StackLimit);
    if (allocation_base >= stack_base or stack_limit >= stack_base) return error.Unexpected;

    return .{
        .reservation_bytes = stack_base - allocation_base,
        .committed_bytes = stack_base - stack_limit,
        .current_region_committed = memory.State == windows.MEM_COMMIT,
    };
}

pub fn processHandleCount() error{Unexpected}!u32 {
    var count: windows.DWORD = 0;
    if (GetProcessHandleCount(windows.GetCurrentProcess(), &count) == 0) {
        return error.Unexpected;
    }
    return count;
}

test "Windows stack request is reserve size, not initial commit size" {
    const testing = std.testing;

    const request: common.StackRequest = .{
        .policy = .chromium_worker,
        .explicit_size = null,
        .thread_sanitizer = false,
    };
    const reserve = switch (request.policy) {
        .chromium_worker => chromium_worker_stack_reserve,
        .explicit => request.explicit_size.?,
    };
    try testing.expectEqual(@as(usize, 1024 * 1024), reserve);
    try testing.expectEqual(@as(usize, 16 * 1024 * 1024), common.withSanitizerMinimum(reserve, true));
}
