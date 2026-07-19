// Stable C-facing types for the native DarkPanda embedding API.
//
// Keep every public structure `extern`, sized explicitly where practical, and
// guarded by both `abi_version` and `struct_size`.  Callers may zero any tail
// they do not understand; new fields can therefore be appended without
// changing the ABI of existing binaries.

const std = @import("std");

pub const version: u32 = 1;
pub const invalid_handle: u64 = 0;

pub const ClientProfile = enum(u32) {
    /// Select the target default (Chrome149 on every supported platform).
    default = 0,
    darkpanda = 1,
    chrome149 = 149,
};

pub const CanvasDriver = enum(u32) {
    /// Preserve the legacy CLI/environment mechanics for an older caller.
    environment = 0,
    software = 1,
    dynamic = 2,
};

pub const CanvasFallback = enum(u32) {
    disabled = 0,
    software = 1,
};

pub const Status = enum(i32) {
    ok = 0,
    invalid_argument = 1,
    invalid_handle = 2,
    closed = 3,
    busy = 4,
    out_of_memory = 5,
    initialization_failed = 6,
    navigation_failed = 7,
    evaluation_failed = 8,
    cancelled = 9,
    timeout = 10,
    internal_error = 11,
};

pub const Slice = extern struct {
    ptr: ?[*]const u8 = null,
    len: usize = 0,

    pub fn bytes(self: Slice) ?[]const u8 {
        if (self.len == 0) return "";
        return (self.ptr orelse return null)[0..self.len];
    }
};

pub const Bytes = extern struct {
    ptr: ?[*]u8 = null,
    len: usize = 0,

    pub fn take(slice: []u8) Bytes {
        return .{ .ptr = slice.ptr, .len = slice.len };
    }
};

pub const Error = extern struct {
    code: Status = .ok,
    message: Bytes = .{},
};

pub const RuntimeOptions = extern struct {
    abi_version: u32 = version,
    struct_size: u32 = @sizeOf(RuntimeOptions),
    /// Optional absolute path to wreq.dll/libwreq. The Python binding resolves
    /// the platform filename beside the main DarkPanda library by default.
    wreq_transport_path: Slice = .{},
    navigation_timeout_ms: u32 = 30_000,
    /// Reserved bytes are retained in-place so binaries compiled against the
    /// original 56-byte ABI v1 structure remain layout-compatible.
    reserved: [28]u8 = [_]u8{0} ** 28,
    /// Optional UTF-8 BCP-47 application locale. Empty uses en-US.
    application_locale: Slice = .{},
    /// Optional UTF-8 IANA timezone. Empty/null uses the system timezone.
    timezone: Slice = .{},
    /// One coherent HTTP/Navigator identity. Zero selects the target default.
    client_profile: u32 = @intFromEnum(ClientProfile.default),
    reserved_tail: u32 = 0,
    /// Optional strict ResolvedFingerprintProfile schema-v2 JSON. The native
    /// runtime parses and validates this before reserving V8, then deep-copies
    /// it for the physical runtime/App lifetime. Empty preserves the catalog
    /// legacy profile selected by client_profile.
    fingerprint_profile_json: Slice = .{},
    /// Optional LF-separated IP-literal DNS endpoints for the Windows wreq
    /// backend. Empty preserves the operating-system resolver.
    wreq_dns_nameservers: Slice = .{},
    /// Optional absolute rust-skia backend path. Empty with dynamic selection
    /// loads the platform library adjacent to darkpanda.dll/libdarkpanda.
    canvas_backend_path: Slice = .{},
    /// New sized callers default to the packaged dynamic rust-skia backend.
    canvas_driver: u32 = @intFromEnum(CanvasDriver.dynamic),
    canvas_fallback: u32 = @intFromEnum(CanvasFallback.disabled),
};

/// Size of the original ABI-v1 RuntimeOptions prefix.  The unsized
/// dp_runtime_options_init symbol must never write beyond this boundary: an
/// already-compiled caller may still have allocated only this much storage.
pub const runtime_options_v1_size: usize = @offsetOf(RuntimeOptions, "application_locale");

/// Initialize exactly the storage the caller explicitly made available.
/// Returns false when even the original ABI-v1 prefix cannot fit.
pub fn initRuntimeOptions(out: ?[*]u8, capacity: usize) bool {
    const destination = out orelse return false;
    if (capacity < runtime_options_v1_size) return false;

    @memset(destination[0..capacity], 0);
    var defaults: RuntimeOptions = .{};
    const initialized_size = @min(capacity, @sizeOf(RuntimeOptions));
    defaults.struct_size = @intCast(initialized_size);
    @memcpy(destination[0..initialized_size], std.mem.asBytes(&defaults)[0..initialized_size]);
    return true;
}

pub const NavigationOptions = extern struct {
    abi_version: u32 = version,
    struct_size: u32 = @sizeOf(NavigationOptions),
    /// Zero selects the runtime default.
    timeout_ms: u32 = 0,
    reserved: [20]u8 = [_]u8{0} ** 20,
};

pub const EvaluateOptions = extern struct {
    abi_version: u32 = version,
    struct_size: u32 = @sizeOf(EvaluateOptions),
    /// Zero selects lp.Evaluate.default_promise_timeout_ms.
    promise_timeout_ms: u32 = 0,
    reserved: [20]u8 = [_]u8{0} ** 20,
};

pub const ClickOptions = extern struct {
    abi_version: u32 = version,
    struct_size: u32 = @sizeOf(ClickOptions),
    /// Zero selects the root frame represented by the page handle.
    frame_id: u32 = 0,
    /// Zero selects the runtime's navigation timeout.
    timeout_ms: u32 = 0,
    /// Non-zero permits browser-internal traversal of open and closed roots.
    /// Page JavaScript remains unable to observe a closed ShadowRoot.
    pierce_shadow: u8 = 0,
    reserved0: [3]u8 = [_]u8{0} ** 3,
    /// Delay from the completed hover task to pointerdown. Zero selects 16 ms.
    move_delay_ms: u32 = 16,
    /// Delay from the completed press task to pointerup. Zero selects 60 ms.
    press_delay_ms: u32 = 60,
    reserved: [4]u8 = [_]u8{0} ** 4,
};

pub const EvaluateResult = extern struct {
    value: Bytes = .{},
    /// Non-zero means JavaScript compilation/execution rejected.  This is
    /// intentionally in-band: the UTF-8 diagnostic remains available in value.
    is_error: u8 = 0,
    reserved: [7]u8 = [_]u8{0} ** 7,
};

pub fn clearError(out: ?*Error) void {
    if (out) |err| err.* = .{};
}

pub fn setError(out: ?*Error, status: Status, detail: []const u8) void {
    const err = out orelse return;
    err.* = .{ .code = status };
    if (detail.len == 0) return;
    const owned = std.heap.c_allocator.dupe(u8, detail) catch return;
    err.message = .take(owned);
}

pub fn freeBytes(bytes: *Bytes) void {
    if (bytes.ptr) |ptr| {
        if (bytes.len > 0) std.heap.c_allocator.free(ptr[0..bytes.len]);
    }
    bytes.* = .{};
}

pub fn validVersionedOptions(comptime T: type, options: *const T, minimum_size: u32) bool {
    return options.abi_version == version and options.struct_size >= minimum_size;
}

fn assertAbiLayout() void {
    const pointer_64 = @sizeOf(usize) == 8;
    if (!pointer_64 and @sizeOf(usize) != 4) @compileError("unsupported C ABI pointer size");

    if (@sizeOf(Status) != 4) @compileError("Status ABI size changed");
    if (@sizeOf(Slice) != (if (pointer_64) 16 else 8)) @compileError("Slice ABI size changed");
    if (@offsetOf(Slice, "ptr") != 0) @compileError("Slice.ptr ABI offset changed");
    if (@offsetOf(Slice, "len") != (if (pointer_64) 8 else 4)) @compileError("Slice.len ABI offset changed");
    if (@sizeOf(Bytes) != @sizeOf(Slice)) @compileError("Bytes ABI size changed");
    if (@sizeOf(Error) != (if (pointer_64) 24 else 12)) @compileError("Error ABI size changed");
    if (@offsetOf(Error, "code") != 0) @compileError("Error.code ABI offset changed");
    if (@offsetOf(Error, "message") != (if (pointer_64) 8 else 4)) @compileError("Error.message ABI offset changed");

    if (@sizeOf(RuntimeOptions) != (if (pointer_64) 152 else 104)) @compileError("RuntimeOptions ABI size changed");
    if (@offsetOf(RuntimeOptions, "abi_version") != 0) @compileError("RuntimeOptions.abi_version ABI offset changed");
    if (@offsetOf(RuntimeOptions, "struct_size") != 4) @compileError("RuntimeOptions.struct_size ABI offset changed");
    if (@offsetOf(RuntimeOptions, "wreq_transport_path") != 8) @compileError("RuntimeOptions.wreq_transport_path ABI offset changed");
    if (@offsetOf(RuntimeOptions, "navigation_timeout_ms") != (if (pointer_64) 24 else 16)) @compileError("RuntimeOptions.navigation_timeout_ms ABI offset changed");
    if (@offsetOf(RuntimeOptions, "reserved") != (if (pointer_64) 28 else 20)) @compileError("RuntimeOptions.reserved ABI offset changed");
    if (@offsetOf(RuntimeOptions, "application_locale") != (if (pointer_64) 56 else 48)) @compileError("RuntimeOptions.application_locale ABI offset changed");
    if (@offsetOf(RuntimeOptions, "timezone") != (if (pointer_64) 72 else 56)) @compileError("RuntimeOptions.timezone ABI offset changed");
    if (@offsetOf(RuntimeOptions, "client_profile") != (if (pointer_64) 88 else 64)) @compileError("RuntimeOptions.client_profile ABI offset changed");
    if (@offsetOf(RuntimeOptions, "reserved_tail") != (if (pointer_64) 92 else 68)) @compileError("RuntimeOptions.reserved_tail ABI offset changed");
    if (@offsetOf(RuntimeOptions, "fingerprint_profile_json") != (if (pointer_64) 96 else 72)) @compileError("RuntimeOptions.fingerprint_profile_json ABI offset changed");
    if (@offsetOf(RuntimeOptions, "wreq_dns_nameservers") != (if (pointer_64) 112 else 80)) @compileError("RuntimeOptions.wreq_dns_nameservers ABI offset changed");
    if (@offsetOf(RuntimeOptions, "canvas_backend_path") != (if (pointer_64) 128 else 88)) @compileError("RuntimeOptions.canvas_backend_path ABI offset changed");
    if (@offsetOf(RuntimeOptions, "canvas_driver") != (if (pointer_64) 144 else 96)) @compileError("RuntimeOptions.canvas_driver ABI offset changed");
    if (@offsetOf(RuntimeOptions, "canvas_fallback") != (if (pointer_64) 148 else 100)) @compileError("RuntimeOptions.canvas_fallback ABI offset changed");

    if (@sizeOf(NavigationOptions) != 32) @compileError("NavigationOptions ABI size changed");
    if (@offsetOf(NavigationOptions, "timeout_ms") != 8) @compileError("NavigationOptions.timeout_ms ABI offset changed");
    if (@sizeOf(EvaluateOptions) != 32) @compileError("EvaluateOptions ABI size changed");
    if (@offsetOf(EvaluateOptions, "promise_timeout_ms") != 8) @compileError("EvaluateOptions.promise_timeout_ms ABI offset changed");
    if (@sizeOf(ClickOptions) != 32) @compileError("ClickOptions ABI size changed");
    if (@offsetOf(ClickOptions, "frame_id") != 8) @compileError("ClickOptions.frame_id ABI offset changed");
    if (@offsetOf(ClickOptions, "timeout_ms") != 12) @compileError("ClickOptions.timeout_ms ABI offset changed");
    if (@offsetOf(ClickOptions, "pierce_shadow") != 16) @compileError("ClickOptions.pierce_shadow ABI offset changed");
    if (@offsetOf(ClickOptions, "move_delay_ms") != 20) @compileError("ClickOptions.move_delay_ms ABI offset changed");
    if (@offsetOf(ClickOptions, "press_delay_ms") != 24) @compileError("ClickOptions.press_delay_ms ABI offset changed");
    if (@sizeOf(EvaluateResult) != (if (pointer_64) 24 else 16)) @compileError("EvaluateResult ABI size changed");
    if (@offsetOf(EvaluateResult, "value") != 0) @compileError("EvaluateResult.value ABI offset changed");
    if (@offsetOf(EvaluateResult, "is_error") != (if (pointer_64) 16 else 8)) @compileError("EvaluateResult.is_error ABI offset changed");
}

comptime {
    assertAbiLayout();
}

test "C ABI public structures have stable field offsets" {
    assertAbiLayout();
}

test "ClickOptions defaults preserve Chrome task spacing" {
    const options: ClickOptions = .{};
    try std.testing.expectEqual(@as(u32, 16), options.move_delay_ms);
    try std.testing.expectEqual(@as(u32, 60), options.press_delay_ms);
    try std.testing.expectEqual(@as(u8, 0), options.pierce_shadow);
}

test "legacy RuntimeOptions initializer cannot overwrite an appended tail" {
    var storage: [runtime_options_v1_size + 16]u8 align(@alignOf(RuntimeOptions)) =
        [_]u8{0xa5} ** (runtime_options_v1_size + 16);
    try std.testing.expect(initRuntimeOptions(storage[0..].ptr, runtime_options_v1_size));

    const prefix: *const RuntimeOptions = @ptrCast(@alignCast(storage[0..].ptr));
    try std.testing.expectEqual(version, prefix.abi_version);
    try std.testing.expectEqual(@as(u32, @intCast(runtime_options_v1_size)), prefix.struct_size);
    try std.testing.expectEqualSlices(
        u8,
        &([_]u8{0xa5} ** 16),
        storage[runtime_options_v1_size..],
    );
}

test "sized RuntimeOptions initializer exposes the current tail" {
    var options: RuntimeOptions = undefined;
    try std.testing.expect(initRuntimeOptions(@ptrCast(&options), @sizeOf(RuntimeOptions)));
    try std.testing.expectEqual(version, options.abi_version);
    try std.testing.expectEqual(@as(u32, @sizeOf(RuntimeOptions)), options.struct_size);
    try std.testing.expectEqual(ClientProfile.default, @as(ClientProfile, @enumFromInt(options.client_profile)));
    try std.testing.expectEqual(@as(usize, 0), options.wreq_dns_nameservers.len);
    try std.testing.expectEqual(CanvasDriver.dynamic, @as(CanvasDriver, @enumFromInt(options.canvas_driver)));
    try std.testing.expectEqual(CanvasFallback.disabled, @as(CanvasFallback, @enumFromInt(options.canvas_fallback)));
}

test "pre-Canvas 128-byte RuntimeOptions remains a valid sized prefix" {
    if (@sizeOf(usize) != 8) return error.SkipZigTest;
    const previous_size = @offsetOf(RuntimeOptions, "canvas_backend_path");
    var storage: [previous_size + 16]u8 align(@alignOf(RuntimeOptions)) =
        [_]u8{0xa5} ** (previous_size + 16);
    try std.testing.expect(initRuntimeOptions(storage[0..].ptr, previous_size));

    const prefix: *const RuntimeOptions = @ptrCast(@alignCast(storage[0..].ptr));
    try std.testing.expectEqual(@as(u32, @intCast(previous_size)), prefix.struct_size);
    try std.testing.expectEqualSlices(u8, &([_]u8{0xa5} ** 16), storage[previous_size..]);
}

test "pre-DNS 112-byte RuntimeOptions remains a valid sized prefix" {
    if (@sizeOf(usize) != 8) return error.SkipZigTest;
    const previous_size = @offsetOf(RuntimeOptions, "wreq_dns_nameservers");
    var storage: [previous_size + 16]u8 align(@alignOf(RuntimeOptions)) =
        [_]u8{0xa5} ** (previous_size + 16);
    try std.testing.expect(initRuntimeOptions(storage[0..].ptr, previous_size));

    const prefix: *const RuntimeOptions = @ptrCast(@alignCast(storage[0..].ptr));
    try std.testing.expectEqual(@as(u32, @intCast(previous_size)), prefix.struct_size);
    try std.testing.expectEqualSlices(u8, &([_]u8{0xa5} ** 16), storage[previous_size..]);
}

test "pre-fingerprint 96-byte RuntimeOptions remains a valid sized prefix" {
    if (@sizeOf(usize) != 8) return error.SkipZigTest;
    const previous_size = @offsetOf(RuntimeOptions, "fingerprint_profile_json");
    var storage: [previous_size + 16]u8 align(@alignOf(RuntimeOptions)) =
        [_]u8{0xa5} ** (previous_size + 16);
    try std.testing.expect(initRuntimeOptions(storage[0..].ptr, previous_size));

    const prefix: *const RuntimeOptions = @ptrCast(@alignCast(storage[0..].ptr));
    try std.testing.expectEqual(@as(u32, @intCast(previous_size)), prefix.struct_size);
    try std.testing.expectEqualSlices(u8, &([_]u8{0xa5} ** 16), storage[previous_size..]);
}
