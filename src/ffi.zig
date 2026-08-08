// Native DarkPanda C ABI entry point.
//
// This library embeds DarkPanda directly. It does not start CDP, bind a
// localhost port, or spawn a helper process. All browser/V8 work is serialized
// onto Runtime.workerMain; the exported functions are synchronous command
// submissions suitable for ctypes and other FFIs.

const std = @import("std");
const builtin = @import("builtin");
const lp = @import("darkpanda");
const abi = @import("ffi/abi.zig");
const runtime_mod = @import("ffi/Runtime.zig");
const FingerprintProfile = lp.FingerprintProfile;

const Runtime = runtime_mod.Runtime;
const PageRef = runtime_mod.PageRef;
const Command = runtime_mod.Command;
const allocator = std.heap.c_allocator;
const ffi_build_version: [:0]const u8 = lp.build_config.version ++ "\x00";

// Zig supplies the PE entry point for a shared library.  Its generated
// _DllMainCRTStartup deliberately does not run the MSVC static CRT startup
// sequence, while the Chromium/V8 archive is built /MT and therefore carries
// its own UCRT/VCRuntime.  Initialize that CRT before the first allocation or
// ICU call made through the embedding ABI.  Without this, getenv() enters an
// uninitialized __acrt_environment_lock during V8 ICU setup.
//
// This is process-lifetime state.  It intentionally is not torn down when a
// Runtime is destroyed: the DLL remains callable and a later Runtime may be
// created from the same loaded module.
const crt_state_uninitialized: u8 = 0;
const crt_state_ready: u8 = 1;
const crt_state_failed: u8 = 2;
var windows_static_crt_state: std.atomic.Value(u8) = .init(crt_state_uninitialized);
var windows_static_crt_once = std.once(initializeWindowsStaticCrt);

extern fn __scrt_initialize_crt(module_type: c_int) callconv(.c) bool;
extern fn __scrt_dllmain_before_initialize_c() callconv(.c) bool;
extern fn __scrt_dllmain_after_initialize_c() callconv(.c) bool;

const CInitializer = ?*const fn () callconv(.c) c_int;
const CppInitializer = ?*const fn () callconv(.c) void;
extern var __xi_a: CInitializer;
extern var __xi_z: CInitializer;
extern var __xc_a: CppInitializer;
extern var __xc_z: CppInitializer;
extern fn _initterm_e(first: *CInitializer, last: *CInitializer) callconv(.c) c_int;
extern fn _initterm(first: *CppInitializer, last: *CppInitializer) callconv(.c) void;

fn initializeWindowsStaticCrt() void {
    if (comptime builtin.os.tag != .windows) return;

    var final_state: u8 = crt_state_failed;
    defer windows_static_crt_state.store(final_state, .release);

    // __scrt_module_type::dll
    if (!__scrt_initialize_crt(1)) return;
    if (!__scrt_dllmain_before_initialize_c()) return;

    // The V8 archive contains dynamically initialized libc++ globals
    // (including callback registries).  They live in the module's CRT
    // initializer ranges and are not initialized by __acrt_initialize.
    if (_initterm_e(&__xi_a, &__xi_z) != 0) return;
    if (!__scrt_dllmain_after_initialize_c()) return;
    _initterm(&__xc_a, &__xc_z);
    final_state = crt_state_ready;
}

fn ensureWindowsStaticCrt() bool {
    if (comptime builtin.os.tag != .windows) return true;

    // Every exported ABI function uses this guard. Once initialized, the hot
    // path is a single acquire load and does not enter std.once again.
    switch (windows_static_crt_state.load(.acquire)) {
        crt_state_ready => return true,
        crt_state_failed => return false,
        else => {},
    }
    windows_static_crt_once.call();
    return windows_static_crt_state.load(.acquire) == crt_state_ready;
}

fn crtInitializationFailure(out_error: ?*abi.Error) abi.Status {
    // CRT initialization failed, so do not call abi.setError/c_allocator here.
    if (out_error) |err| {
        err.code = .initialization_failed;
        err.message.ptr = null;
        err.message.len = 0;
    }
    return .initialization_failed;
}

pub export fn dp_abi_version() callconv(.c) u32 {
    return if (ensureWindowsStaticCrt()) abi.version else 0;
}

pub export fn dp_version() callconv(.c) ?[*:0]const u8 {
    if (!ensureWindowsStaticCrt()) return null;
    return ffi_build_version.ptr;
}

pub export fn dp_runtime_options_init(out: ?*abi.RuntimeOptions) callconv(.c) void {
    if (!ensureWindowsStaticCrt()) return;
    _ = abi.initRuntimeOptions(if (out) |options| @ptrCast(options) else null, abi.runtime_options_v1_size);
}

pub export fn dp_runtime_options_init_sized(out: ?*anyopaque, capacity: usize) callconv(.c) abi.Status {
    if (!ensureWindowsStaticCrt()) return .initialization_failed;
    return if (abi.initRuntimeOptions(if (out) |options| @ptrCast(options) else null, capacity))
        .ok
    else
        .invalid_argument;
}

pub export fn dp_navigation_options_init(out: ?*abi.NavigationOptions) callconv(.c) void {
    if (!ensureWindowsStaticCrt()) return;
    if (out) |options| options.* = .{};
}

pub export fn dp_evaluate_options_init(out: ?*abi.EvaluateOptions) callconv(.c) void {
    if (!ensureWindowsStaticCrt()) return;
    if (out) |options| options.* = .{};
}

pub export fn dp_click_options_init(out: ?*abi.ClickOptions) callconv(.c) void {
    if (!ensureWindowsStaticCrt()) return;
    if (out) |options| options.* = .{};
}

pub export fn dp_bytes_free(bytes: ?*abi.Bytes) callconv(.c) void {
    if (!ensureWindowsStaticCrt()) return;
    if (bytes) |value| abi.freeBytes(value);
}

pub export fn dp_error_free(err: ?*abi.Error) callconv(.c) void {
    if (!ensureWindowsStaticCrt()) return;
    const value = err orelse return;
    abi.freeBytes(&value.message);
    value.* = .{};
}

pub export fn dp_evaluate_result_free(result: ?*abi.EvaluateResult) callconv(.c) void {
    if (!ensureWindowsStaticCrt()) return;
    const value = result orelse return;
    abi.freeBytes(&value.value);
    value.* = .{};
}

pub export fn dp_runtime_create(
    options_ptr: ?*const abi.RuntimeOptions,
    out_handle: ?*u64,
    out_error: ?*abi.Error,
) callconv(.c) abi.Status {
    if (!ensureWindowsStaticCrt()) {
        return crtInitializationFailure(out_error);
    }
    abi.clearError(out_error);
    const handle = out_handle orelse return fail(out_error, .invalid_argument, "out_handle is null");
    handle.* = abi.invalid_handle;

    const default_options: abi.RuntimeOptions = .{};
    const options = options_ptr orelse &default_options;
    const runtime_options_v1_size = @offsetOf(abi.RuntimeOptions, "navigation_timeout_ms") + @sizeOf(u32);
    if (!abi.validVersionedOptions(abi.RuntimeOptions, options, runtime_options_v1_size)) {
        return fail(out_error, .invalid_argument, "unsupported RuntimeOptions ABI or struct_size");
    }
    const path_bytes = options.wreq_transport_path.bytes() orelse {
        return fail(out_error, .invalid_argument, "wreq_transport_path has a null pointer with non-zero length");
    };
    if (std.mem.indexOfScalar(u8, path_bytes, 0) != null) {
        return fail(out_error, .invalid_argument, "wreq_transport_path contains NUL");
    }
    if (path_bytes.len > 0 and !std.fs.path.isAbsolute(path_bytes)) {
        return fail(out_error, .invalid_argument, "wreq_transport_path must be absolute");
    }

    const locale_field_end: u32 = @intCast(@offsetOf(abi.RuntimeOptions, "application_locale") + @sizeOf(abi.Slice));
    const locale_view: abi.Slice = if (options.struct_size >= locale_field_end)
        options.application_locale
    else
        .{};
    const locale_bytes = locale_view.bytes() orelse {
        return fail(out_error, .invalid_argument, "application_locale has a null pointer with non-zero length");
    };
    if (std.mem.indexOfScalar(u8, locale_bytes, 0) != null or !std.unicode.utf8ValidateSlice(locale_bytes)) {
        return fail(out_error, .invalid_argument, "application_locale must be valid UTF-8 without NUL");
    }

    const timezone_field_end: u32 = @intCast(@offsetOf(abi.RuntimeOptions, "timezone") + @sizeOf(abi.Slice));
    const timezone_view: abi.Slice = if (options.struct_size >= timezone_field_end)
        options.timezone
    else
        .{};
    const timezone_bytes = timezone_view.bytes() orelse {
        return fail(out_error, .invalid_argument, "timezone has a null pointer with non-zero length");
    };
    if (std.mem.indexOfScalar(u8, timezone_bytes, 0) != null or !std.unicode.utf8ValidateSlice(timezone_bytes)) {
        return fail(out_error, .invalid_argument, "timezone must be valid UTF-8 without NUL");
    }

    const profile_field_end: u32 = @intCast(@offsetOf(abi.RuntimeOptions, "client_profile") + @sizeOf(u32));
    const profile_raw: u32 = if (options.struct_size >= profile_field_end)
        options.client_profile
    else
        @intFromEnum(abi.ClientProfile.default);
    const client_profile: lp.ClientProfile.Id = if (profile_raw == @intFromEnum(abi.ClientProfile.default))
        lp.ClientProfile.target_default
    else
        lp.ClientProfile.fromInt(profile_raw) orelse
            return fail(out_error, .invalid_argument, "unknown client_profile; expected 0, 1, or 149");

    const fingerprint_field_end: u32 = @intCast(
        @offsetOf(abi.RuntimeOptions, "fingerprint_profile_json") + @sizeOf(abi.Slice),
    );
    const fingerprint_view: abi.Slice = if (options.struct_size >= fingerprint_field_end)
        options.fingerprint_profile_json
    else
        .{};
    const fingerprint_bytes = fingerprint_view.bytes() orelse {
        return fail(out_error, .invalid_argument, "fingerprint_profile_json has a null pointer with non-zero length");
    };
    if (fingerprint_bytes.len > 0 and !std.unicode.utf8ValidateSlice(fingerprint_bytes)) {
        return fail(out_error, .invalid_argument, "fingerprint_profile_json must be valid UTF-8");
    }

    const dns_field_end: u32 = @intCast(
        @offsetOf(abi.RuntimeOptions, "wreq_dns_nameservers") + @sizeOf(abi.Slice),
    );
    const dns_view: abi.Slice = if (options.struct_size >= dns_field_end)
        options.wreq_dns_nameservers
    else
        .{};
    const dns_bytes = dns_view.bytes() orelse {
        return fail(out_error, .invalid_argument, "wreq_dns_nameservers has a null pointer with non-zero length");
    };
    if (dns_bytes.len > 0 and
        (!std.unicode.utf8ValidateSlice(dns_bytes) or std.mem.indexOfScalar(u8, dns_bytes, 0) != null))
    {
        return fail(out_error, .invalid_argument, "wreq_dns_nameservers must be valid UTF-8 without NUL");
    }

    const canvas_path_field_end: u32 = @intCast(
        @offsetOf(abi.RuntimeOptions, "canvas_backend_path") + @sizeOf(abi.Slice),
    );
    const canvas_path_view: abi.Slice = if (options.struct_size >= canvas_path_field_end)
        options.canvas_backend_path
    else
        .{};
    const canvas_path_bytes = canvas_path_view.bytes() orelse {
        return fail(out_error, .invalid_argument, "canvas_backend_path has a null pointer with non-zero length");
    };
    if (std.mem.indexOfScalar(u8, canvas_path_bytes, 0) != null or
        !std.unicode.utf8ValidateSlice(canvas_path_bytes))
    {
        return fail(out_error, .invalid_argument, "canvas_backend_path must be valid UTF-8 without NUL");
    }
    if (canvas_path_bytes.len > 0 and !std.fs.path.isAbsolute(canvas_path_bytes)) {
        return fail(out_error, .invalid_argument, "canvas_backend_path must be absolute");
    }

    const canvas_driver_field_end: u32 = @intCast(
        @offsetOf(abi.RuntimeOptions, "canvas_driver") + @sizeOf(u32),
    );
    const canvas_driver = if (options.struct_size >= canvas_driver_field_end)
        std.meta.intToEnum(abi.CanvasDriver, options.canvas_driver) catch
            return fail(out_error, .invalid_argument, "unknown canvas_driver; expected 0, 1, or 2")
    else
        abi.CanvasDriver.environment;
    const canvas_fallback_field_end: u32 = @intCast(
        @offsetOf(abi.RuntimeOptions, "canvas_fallback") + @sizeOf(u32),
    );
    const canvas_fallback = if (options.struct_size >= canvas_fallback_field_end)
        std.meta.intToEnum(abi.CanvasFallback, options.canvas_fallback) catch
            return fail(out_error, .invalid_argument, "unknown canvas_fallback; expected 0 or 1")
    else
        abi.CanvasFallback.disabled;
    switch (canvas_driver) {
        .dynamic => {},
        .software, .environment => {
            if (canvas_path_bytes.len != 0) {
                return fail(out_error, .invalid_argument, "canvas_backend_path requires canvas_driver dynamic");
            }
            if (canvas_fallback != .disabled) {
                return fail(out_error, .invalid_argument, "canvas_fallback is only valid with canvas_driver dynamic");
            }
        },
    }

    const webrtc_path_field_end: u32 = @intCast(
        @offsetOf(abi.RuntimeOptions, "webrtc_backend_path") + @sizeOf(abi.Slice),
    );
    const webrtc_path_view: abi.Slice = if (options.struct_size >= webrtc_path_field_end)
        options.webrtc_backend_path
    else
        .{};
    const webrtc_path_bytes = webrtc_path_view.bytes() orelse {
        return fail(out_error, .invalid_argument, "webrtc_backend_path has a null pointer with non-zero length");
    };
    if (std.mem.indexOfScalar(u8, webrtc_path_bytes, 0) != null or
        !std.unicode.utf8ValidateSlice(webrtc_path_bytes))
    {
        return fail(out_error, .invalid_argument, "webrtc_backend_path must be valid UTF-8 without NUL");
    }
    if (webrtc_path_bytes.len > 0 and !std.fs.path.isAbsolute(webrtc_path_bytes)) {
        return fail(out_error, .invalid_argument, "webrtc_backend_path must be absolute");
    }

    const webrtc_bind_field_end: u32 = @intCast(
        @offsetOf(abi.RuntimeOptions, "webrtc_tun_bind_address") + @sizeOf(abi.Slice),
    );
    const webrtc_bind_view: abi.Slice = if (options.struct_size >= webrtc_bind_field_end)
        options.webrtc_tun_bind_address
    else
        .{};
    const webrtc_bind_bytes = webrtc_bind_view.bytes() orelse {
        return fail(out_error, .invalid_argument, "webrtc_tun_bind_address has a null pointer with non-zero length");
    };
    if (std.mem.indexOfScalar(u8, webrtc_bind_bytes, 0) != null or
        !std.unicode.utf8ValidateSlice(webrtc_bind_bytes))
    {
        return fail(out_error, .invalid_argument, "webrtc_tun_bind_address must be valid UTF-8 without NUL");
    }
    const webrtc_mode_field_end: u32 = @intCast(
        @offsetOf(abi.RuntimeOptions, "webrtc_mode") + @sizeOf(u32),
    );
    const webrtc_mode = if (options.struct_size >= webrtc_mode_field_end)
        std.meta.intToEnum(abi.WebRtcMode, options.webrtc_mode) catch
            return fail(out_error, .invalid_argument, "unknown webrtc_mode; expected 0 or 1")
    else
        abi.WebRtcMode.disabled;
    switch (webrtc_mode) {
        .disabled => {
            if (webrtc_path_bytes.len != 0 or webrtc_bind_bytes.len != 0) {
                return fail(out_error, .invalid_argument, "WebRTC path/address require webrtc_mode tun_bound");
            }
        },
        .tun_bound => {
            if (webrtc_bind_bytes.len == 0) {
                return fail(out_error, .invalid_argument, "webrtc_tun_bind_address is required in tun_bound mode");
            }
        },
    }

    // Strict parsing happens before reserveRuntime and before wreq/V8 startup.
    // A rejected custom profile therefore cannot mutate either the logical
    // handle registry or the cached physical runtime.
    var parsed_fingerprint: ?FingerprintProfile.Owned = null;
    defer if (parsed_fingerprint) |*profile| profile.deinit();
    if (fingerprint_bytes.len > 0) {
        if (client_profile != .chrome149) {
            return fail(out_error, .invalid_argument, "a custom fingerprint profile requires client_profile chrome149");
        }
        parsed_fingerprint = FingerprintProfile.Owned.parseJson(
            allocator,
            fingerprint_bytes,
        ) catch |err| return fail(
            out_error,
            if (err == error.OutOfMemory) .out_of_memory else .invalid_argument,
            @errorName(err),
        );
    }

    const effective_locale: ?[]const u8 = if (parsed_fingerprint) |*owned| blk: {
        const profile_locale = owned.get().locale.locale;
        if (locale_bytes.len > 0 and !std.mem.eql(u8, locale_bytes, profile_locale)) {
            return fail(out_error, .invalid_argument, "application_locale conflicts with fingerprint_profile_json");
        }
        break :blk profile_locale;
    } else if (locale_bytes.len == 0) null else locale_bytes;
    const effective_timezone: ?[]const u8 = if (parsed_fingerprint) |*owned| blk: {
        const profile_timezone = owned.get().locale.timezone;
        if (timezone_bytes.len > 0 and !std.mem.eql(u8, timezone_bytes, profile_timezone)) {
            return fail(out_error, .invalid_argument, "timezone conflicts with fingerprint_profile_json");
        }
        break :blk profile_timezone;
    } else if (timezone_bytes.len == 0) null else timezone_bytes;

    if (!runtime_mod.reserveRuntime()) {
        return fail(out_error, .busy, "only one native runtime may own the process-global V8 platform");
    }

    const runtime = Runtime.start(
        if (path_bytes.len == 0) null else path_bytes,
        effective_locale,
        effective_timezone,
        client_profile,
        if (fingerprint_bytes.len == 0) null else fingerprint_bytes,
        if (parsed_fingerprint) |*owned| owned.get().observable_digest else null,
        if (dns_bytes.len == 0) null else dns_bytes,
        if (canvas_path_bytes.len == 0) null else canvas_path_bytes,
        canvas_driver,
        canvas_fallback,
        if (webrtc_path_bytes.len == 0) null else webrtc_path_bytes,
        if (webrtc_bind_bytes.len == 0) null else webrtc_bind_bytes,
        webrtc_mode,
        options.navigation_timeout_ms,
    ) catch |err| {
        runtime_mod.cancelRuntimeReservation();
        return fail(out_error, mapCreateError(err), @errorName(err));
    };

    const runtime_handle = runtime_mod.registerRuntime(runtime) catch |err| {
        runtime_mod.discardCachedRuntime(runtime);
        runtime.stop();
        runtime_mod.cancelRuntimeReservation();
        return fail(out_error, mapCommonError(err), @errorName(err));
    };
    handle.* = runtime_handle;
    return .ok;
}

pub export fn dp_runtime_destroy(handle: u64, out_error: ?*abi.Error) callconv(.c) abi.Status {
    if (!ensureWindowsStaticCrt()) return crtInitializationFailure(out_error);
    abi.clearError(out_error);
    const runtime = runtime_mod.unregisterRuntime(handle) orelse {
        return fail(out_error, .invalid_handle, "invalid or already-destroyed runtime handle");
    };
    runtime.waitForNoReferences();
    const reset_status = runtime.resetForReuse(out_error);
    runtime_mod.finishRuntime(runtime);
    return reset_status;
}

pub export fn dp_runtime_identity_manifest(
    handle: u64,
    out_json: ?*abi.Bytes,
    out_error: ?*abi.Error,
) callconv(.c) abi.Status {
    if (!ensureWindowsStaticCrt()) return crtInitializationFailure(out_error);
    abi.clearError(out_error);
    const output = out_json orelse
        return fail(out_error, .invalid_argument, "out_json is null");
    output.* = .{};

    const runtime = runtime_mod.acquireRuntime(handle) orelse {
        return fail(out_error, .invalid_handle, "invalid or closing runtime handle");
    };
    defer runtime.release();

    var command = Command.init(.{ .identity_manifest = {} });
    runtime.dispatch(&command);
    if (command.status != .ok) {
        if (out_error) |err| {
            err.* = .{ .code = command.status, .message = command.detail };
            command.detail = .{};
        } else {
            abi.freeBytes(&command.detail);
        }
        abi.freeBytes(&command.output);
        return command.status;
    }
    output.* = command.output;
    command.output = .{};
    abi.freeBytes(&command.detail);
    return .ok;
}

pub export fn dp_page_create(
    runtime_handle: u64,
    out_page: ?*u64,
    out_error: ?*abi.Error,
) callconv(.c) abi.Status {
    if (!ensureWindowsStaticCrt()) return crtInitializationFailure(out_error);
    abi.clearError(out_error);
    const page_handle = out_page orelse return fail(out_error, .invalid_argument, "out_page is null");
    page_handle.* = abi.invalid_handle;

    const runtime = runtime_mod.acquireRuntime(runtime_handle) orelse {
        return fail(out_error, .invalid_handle, "invalid or closing runtime handle");
    };
    defer runtime.release();

    const page = allocator.create(PageRef) catch {
        return fail(out_error, .out_of_memory, "OutOfMemory");
    };
    page.* = .{ .runtime = runtime };
    runtime.addPage(page) catch {
        allocator.destroy(page);
        return fail(out_error, .out_of_memory, "OutOfMemory");
    };

    var command = Command.init(.{ .create_page = page });
    runtime.dispatch(&command);
    if (command.status != .ok) return finishCommand(&command, out_error);

    const registered = runtime_mod.registerPage(page) catch |err| {
        // The page is worker-owned now. Close it on the same worker before
        // returning; PageRef storage remains in Runtime.pages until teardown.
        page.state.store(PageRef.state_closing, .release);
        var close_command = Command.init(.{ .close_page = page });
        runtime.dispatch(&close_command);
        return fail(out_error, mapCommonError(err), @errorName(err));
    };
    page_handle.* = registered;
    return .ok;
}

pub export fn dp_page_close(handle: u64, out_error: ?*abi.Error) callconv(.c) abi.Status {
    if (!ensureWindowsStaticCrt()) return crtInitializationFailure(out_error);
    abi.clearError(out_error);
    const page = runtime_mod.unregisterPage(handle) orelse {
        return fail(out_error, .invalid_handle, "invalid or already-closed page handle");
    };
    defer page.runtime.release();

    var command = Command.init(.{ .close_page = page });
    page.runtime.dispatch(&command);
    return finishCommand(&command, out_error);
}

pub export fn dp_page_cancel(handle: u64) callconv(.c) abi.Status {
    if (!ensureWindowsStaticCrt()) return .initialization_failed;
    const page = runtime_mod.acquirePage(handle) orelse return .invalid_handle;
    defer page.runtime.release();
    _ = page.cancel_epoch.fetchAdd(1, .acq_rel);
    page.runtime.interrupt(page);
    return .ok;
}

pub export fn dp_page_navigate(
    handle: u64,
    url_value: abi.Slice,
    options_ptr: ?*const abi.NavigationOptions,
    out_error: ?*abi.Error,
) callconv(.c) abi.Status {
    if (!ensureWindowsStaticCrt()) return crtInitializationFailure(out_error);
    abi.clearError(out_error);
    const url = url_value.bytes() orelse {
        return fail(out_error, .invalid_argument, "url has a null pointer with non-zero length");
    };
    if (url.len == 0 or std.mem.indexOfScalar(u8, url, 0) != null) {
        return fail(out_error, .invalid_argument, "url must be non-empty and contain no NUL");
    }
    const default_options: abi.NavigationOptions = .{};
    const options = options_ptr orelse &default_options;
    const navigation_options_v1_size = @offsetOf(abi.NavigationOptions, "timeout_ms") + @sizeOf(u32);
    if (!abi.validVersionedOptions(abi.NavigationOptions, options, navigation_options_v1_size)) {
        return fail(out_error, .invalid_argument, "unsupported NavigationOptions ABI or struct_size");
    }

    const operation = runtime_mod.acquirePageOperation(handle) orelse {
        return fail(out_error, .invalid_handle, "invalid or closed page handle");
    };
    const page = operation.page;
    defer page.runtime.release();

    var command = Command.init(.{ .navigate = .{
        .page = page,
        .url = url,
        .timeout_ms = options.timeout_ms,
        .cancel_epoch = operation.cancel_epoch,
    } });
    page.runtime.dispatch(&command);
    return finishCommand(&command, out_error);
}

pub export fn dp_page_evaluate(
    handle: u64,
    script_value: abi.Slice,
    options_ptr: ?*const abi.EvaluateOptions,
    out_result: ?*abi.EvaluateResult,
    out_error: ?*abi.Error,
) callconv(.c) abi.Status {
    if (!ensureWindowsStaticCrt()) return crtInitializationFailure(out_error);
    abi.clearError(out_error);
    const output = out_result orelse return fail(out_error, .invalid_argument, "out_result is null");
    output.* = .{};
    const script = script_value.bytes() orelse {
        return fail(out_error, .invalid_argument, "script has a null pointer with non-zero length");
    };
    if (std.mem.indexOfScalar(u8, script, 0) != null) {
        return fail(out_error, .invalid_argument, "script contains NUL");
    }
    const default_options: abi.EvaluateOptions = .{};
    const options = options_ptr orelse &default_options;
    const evaluate_options_v1_size = @offsetOf(abi.EvaluateOptions, "promise_timeout_ms") + @sizeOf(u32);
    if (!abi.validVersionedOptions(abi.EvaluateOptions, options, evaluate_options_v1_size)) {
        return fail(out_error, .invalid_argument, "unsupported EvaluateOptions ABI or struct_size");
    }

    const operation = runtime_mod.acquirePageOperation(handle) orelse {
        return fail(out_error, .invalid_handle, "invalid or closed page handle");
    };
    const page = operation.page;
    defer page.runtime.release();

    var command = Command.init(.{ .evaluate = .{
        .page = page,
        .script = script,
        .promise_timeout_ms = options.promise_timeout_ms,
        .cancel_epoch = operation.cancel_epoch,
    } });
    page.runtime.dispatch(&command);
    if (command.status != .ok) return finishCommand(&command, out_error);

    output.value = command.output;
    output.is_error = @intFromBool(command.output_is_error);
    command.output = .{};
    return .ok;
}

pub export fn dp_page_frames(
    handle: u64,
    out_json: ?*abi.Bytes,
    out_error: ?*abi.Error,
) callconv(.c) abi.Status {
    if (!ensureWindowsStaticCrt()) return crtInitializationFailure(out_error);
    abi.clearError(out_error);
    const output = out_json orelse
        return fail(out_error, .invalid_argument, "out_json is null");
    output.* = .{};

    const operation = runtime_mod.acquirePageOperation(handle) orelse {
        return fail(out_error, .invalid_handle, "invalid or closed page handle");
    };
    const page = operation.page;
    defer page.runtime.release();

    var command = Command.init(.{ .frames = .{
        .page = page,
        .cancel_epoch = operation.cancel_epoch,
    } });
    page.runtime.dispatch(&command);
    if (command.status != .ok) return finishCommand(&command, out_error);
    output.* = command.output;
    command.output = .{};
    abi.freeBytes(&command.detail);
    return .ok;
}

pub export fn dp_page_network_observations(
    handle: u64,
    since_sequence: u64,
    out_json: ?*abi.Bytes,
    out_error: ?*abi.Error,
) callconv(.c) abi.Status {
    if (!ensureWindowsStaticCrt()) return crtInitializationFailure(out_error);
    abi.clearError(out_error);
    const output = out_json orelse
        return fail(out_error, .invalid_argument, "out_json is null");
    output.* = .{};

    const operation = runtime_mod.acquirePageOperation(handle) orelse {
        return fail(out_error, .invalid_handle, "invalid or closed page handle");
    };
    const page = operation.page;
    defer page.runtime.release();

    var command = Command.init(.{ .network_observations = .{
        .page = page,
        .since_sequence = since_sequence,
        .cancel_epoch = operation.cancel_epoch,
    } });
    page.runtime.dispatch(&command);
    if (command.status != .ok) return finishCommand(&command, out_error);
    output.* = command.output;
    command.output = .{};
    abi.freeBytes(&command.detail);
    return .ok;
}

pub export fn dp_page_click(
    handle: u64,
    selector_value: abi.Slice,
    options_ptr: ?*const abi.ClickOptions,
    out_error: ?*abi.Error,
) callconv(.c) abi.Status {
    if (!ensureWindowsStaticCrt()) return crtInitializationFailure(out_error);
    abi.clearError(out_error);
    const selector = selector_value.bytes() orelse {
        return fail(out_error, .invalid_argument, "selector has a null pointer with non-zero length");
    };
    if (selector.len == 0 or selector.len > 65_536 or
        std.mem.indexOfScalar(u8, selector, 0) != null or
        !std.unicode.utf8ValidateSlice(selector))
    {
        return fail(out_error, .invalid_argument, "selector must be 1..65536 bytes of UTF-8 without NUL");
    }

    const default_options: abi.ClickOptions = .{};
    const options = options_ptr orelse &default_options;
    const click_options_v1_size = @offsetOf(abi.ClickOptions, "pierce_shadow") + @sizeOf(u8);
    if (!abi.validVersionedOptions(abi.ClickOptions, options, click_options_v1_size)) {
        return fail(out_error, .invalid_argument, "unsupported ClickOptions ABI or struct_size");
    }
    if (options.pierce_shadow > 1) {
        return fail(out_error, .invalid_argument, "ClickOptions.pierce_shadow must be 0 or 1");
    }
    const click_options_delays_size = @offsetOf(abi.ClickOptions, "press_delay_ms") + @sizeOf(u32);
    const has_phase_delays = options.struct_size >= click_options_delays_size;
    const move_delay_ms = if (has_phase_delays) options.move_delay_ms else 0;
    const press_delay_ms = if (has_phase_delays) options.press_delay_ms else 0;
    if (move_delay_ms > 60_000 or press_delay_ms > 60_000) {
        return fail(out_error, .invalid_argument, "ClickOptions phase delays must not exceed 60000 ms");
    }

    const operation = runtime_mod.acquirePageOperation(handle) orelse {
        return fail(out_error, .invalid_handle, "invalid or closed page handle");
    };
    const page = operation.page;
    defer page.runtime.release();

    var command = Command.init(.{ .click = .{
        .page = page,
        .selector = selector,
        .frame_id = options.frame_id,
        .timeout_ms = options.timeout_ms,
        .pierce_shadow = options.pierce_shadow != 0,
        .move_delay_ms = move_delay_ms,
        .press_delay_ms = press_delay_ms,
        .cancel_epoch = operation.cancel_epoch,
    } });
    page.runtime.dispatch(&command);
    return finishCommand(&command, out_error);
}

fn finishCommand(command: *Command, out_error: ?*abi.Error) abi.Status {
    if (command.status == .ok) return .ok;
    if (out_error) |err| {
        err.* = .{
            .code = command.status,
            .message = command.detail,
        };
        command.detail = .{};
    } else {
        abi.freeBytes(&command.detail);
    }
    abi.freeBytes(&command.output);
    return command.status;
}

fn fail(out_error: ?*abi.Error, status: abi.Status, detail: []const u8) abi.Status {
    abi.setError(out_error, status, detail);
    return status;
}

fn mapCommonError(err: anyerror) abi.Status {
    return switch (err) {
        error.OutOfMemory => .out_of_memory,
        error.Closed => .closed,
        else => .internal_error,
    };
}

fn mapCreateError(err: anyerror) abi.Status {
    return switch (err) {
        error.OutOfMemory => .out_of_memory,
        else => .initialization_failed,
    };
}

test "ffi ABI version is non-zero" {
    try std.testing.expect(dp_abi_version() != 0);
}

test "ffi build version is exported" {
    try std.testing.expectEqualStrings(lp.build_config.version, std.mem.span(dp_version().?));
}
