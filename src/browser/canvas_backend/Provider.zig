const std = @import("std");
const builtin = @import("builtin");

const adapter = @import("../../canvas_backend/adapter.zig");
const Surface = @import("Surface.zig");

pub const BackendKind = Surface.BackendKind;
pub const Driver = enum { software, dynamic };
pub const Fallback = enum { disabled, software };

pub const Identity = struct {
    kind: BackendKind,
    profile_seed: u64,
    canvas_seed: u64,
};

pub const Options = struct {
    kind: BackendKind = .skia,
    /// chrome-skia ABI v5 is the default driver. Software fallback is opt-in
    /// so a missing or incompatible production backend is visible.
    driver: Driver = .dynamic,
    fallback: Fallback = .disabled,
    library_path: ?[]const u8 = null,
    profile_seed: u64 = 0x4450_5052_4f46_494c,
    canvas_seed: u64 = 0x4450_4341_4e56_4153,
};

const Provider = @This();

allocator: std.mem.Allocator,
options: Options,
actual_driver: Driver,
api: ?adapter.Api = null,
surfaces: std.ArrayList(*Surface) = .empty,
next_canvas_sequence: u64 = 0,

pub fn init(allocator: std.mem.Allocator, options: Options) !Provider {
    var result: Provider = .{
        .allocator = allocator,
        .options = options,
        .actual_driver = options.driver,
    };
    if (options.driver == .dynamic) {
        // chrome-skia ABI v5 backend (full Canvas 2D state machine) from an explicit
        // path or the library adjacent to the darkpanda image.
        result.api = if (options.library_path) |path| blk: {
            if (!std.fs.path.isAbsolute(path)) return error.CanvasBackendPathMustBeAbsolute;
            break :blk adapter.Api.open(path) catch |err| switch (options.fallback) {
                .disabled => return err,
                .software => null,
            };
        } else adapter.Api.openAdjacent(allocator) catch |err| switch (options.fallback) {
            .disabled => return err,
            .software => null,
        };
        if (result.api == null) result.actual_driver = .software;
    }
    // The library path is consumed synchronously while opening the module.
    // Do not retain a borrowed configuration slice in each Page provider.
    result.options.library_path = null;
    return result;
}

/// Environment configuration owns only implementation mechanics. Observable
/// kind/seeds come from ResolvedFingerprintProfile through configureIdentity;
/// environment variables must never be able to replace that identity.
pub fn initFromEnvironment(allocator: std.mem.Allocator) !Provider {
    const driver_text = try getEnvironment(allocator, "DARKPANDA_CANVAS_DRIVER");
    defer if (driver_text) |value| allocator.free(value);
    const fallback_text = try getEnvironment(allocator, "DARKPANDA_CANVAS_BACKEND_FALLBACK");
    defer if (fallback_text) |value| allocator.free(value);
    const library_path = try getEnvironment(allocator, "DARKPANDA_CANVAS_BACKEND_LIBRARY");
    defer if (library_path) |value| allocator.free(value);

    var options: Options = .{};
    if (driver_text) |value| {
        options.driver = if (std.ascii.eqlIgnoreCase(value, "software"))
            .software
        else if (std.ascii.eqlIgnoreCase(value, "dynamic"))
            .dynamic
        else
            return error.InvalidCanvasBackendConfig;
    }
    if (fallback_text) |value| {
        options.fallback = if (std.ascii.eqlIgnoreCase(value, "disabled"))
            .disabled
        else if (std.ascii.eqlIgnoreCase(value, "software"))
            .software
        else
            return error.InvalidCanvasBackendConfig;
    }
    if (library_path) |path| {
        if (!std.fs.path.isAbsolute(path)) return error.CanvasBackendPathMustBeAbsolute;
        options.library_path = path;
    }
    return init(allocator, options);
}

pub fn deinit(self: *Provider) void {
    for (self.surfaces.items) |surface| {
        surface.deinit() catch |err| {
            std.log.err("Canvas backend surface teardown failed: {s}", .{@errorName(err)});
        };
        self.allocator.destroy(surface);
    }
    self.surfaces.deinit(self.allocator);
    self.surfaces = .empty;
    if (self.api) |*api| api.close();
    self.api = null;
}

pub fn configure(self: *Provider, options: Options) !void {
    if (self.surfaces.items.len != 0) return error.CanvasBackendAlreadyInUse;
    var replacement = try Provider.init(self.allocator, options);
    errdefer replacement.deinit();
    self.deinit();
    self.* = replacement;
}

/// Install immutable observable identity without rebuilding or replacing the
/// selected driver, loaded library, or fallback policy. Page calls this after
/// environment driver initialization and before Frame can create a surface.
pub fn configureIdentity(self: *Provider, identity: Identity) !void {
    if (self.surfaces.items.len != 0) return error.CanvasBackendAlreadyInUse;
    self.options.kind = identity.kind;
    self.options.profile_seed = identity.profile_seed;
    self.options.canvas_seed = identity.canvas_seed;
    self.next_canvas_sequence = 0;
}

pub fn configuredIdentity(self: *const Provider) Identity {
    return .{
        .kind = self.options.kind,
        .profile_seed = self.options.profile_seed,
        .canvas_seed = self.options.canvas_seed,
    };
}

pub fn createSurface(self: *Provider, width: u32, height: u32, flags: u32) !*Surface {
    const sequence = self.next_canvas_sequence;
    const per_canvas_seed = splitMix64(self.options.canvas_seed ^ sequence *% 0x9e37_79b9_7f4a_7c15);
    const surface = try self.allocator.create(Surface);
    errdefer self.allocator.destroy(surface);
    surface.* = if (self.api != null)
        try Surface.initDynamic(
            self.allocator,
            &(self.api orelse unreachable),
            self.options.kind,
            width,
            height,
            flags,
            self.options.profile_seed,
            per_canvas_seed,
        )
    else
        try Surface.initSoftware(
            self.allocator,
            self.options.kind,
            width,
            height,
            flags,
            self.options.profile_seed,
            per_canvas_seed,
        );
    errdefer surface.deinit() catch {};
    try self.surfaces.append(self.allocator, surface);
    self.next_canvas_sequence +%= 1;
    return surface;
}

pub fn requestedKind(self: *const Provider) BackendKind {
    return self.options.kind;
}

pub fn actualDriver(self: *const Provider) Driver {
    return self.actual_driver;
}

fn getEnvironment(allocator: std.mem.Allocator, name: []const u8) !?[]u8 {
    return std.process.getEnvVarOwned(allocator, name) catch |err| switch (err) {
        error.EnvironmentVariableNotFound, error.InvalidWtf8 => null,
        error.OutOfMemory => error.OutOfMemory,
    };
}

fn splitMix64(input: u64) u64 {
    var value = input +% 0x9e37_79b9_7f4a_7c15;
    value = (value ^ (value >> 30)) *% 0xbf58_476d_1ce4_e5b9;
    value = (value ^ (value >> 27)) *% 0x94d0_49bb_1331_11eb;
    return value ^ (value >> 31);
}

test "provider gives fake canvases distinct stable seeds" {
    var provider = try Provider.init(std.testing.allocator, .{
        .kind = .fake,
        .driver = .software,
        .profile_seed = 11,
        .canvas_seed = 22,
    });
    defer provider.deinit();
    const first = try provider.createSurface(1, 1, 0);
    const second = try provider.createSurface(1, 1, 0);
    var a: [4]u8 = undefined;
    var b: [4]u8 = undefined;
    try first.readPixels(0, 0, 1, 1, &a, 4);
    try second.readPixels(0, 0, 1, 1, &b, 4);
    try std.testing.expect(!std.mem.eql(u8, &a, &b));

    try first.resize(2, 1);
    try first.resize(1, 1);
    var repeated: [4]u8 = undefined;
    try first.readPixels(0, 0, 1, 1, &repeated, 4);
    try std.testing.expectEqual(a, repeated);
}

test "dynamic load failure is explicit unless software fallback is configured" {
    const missing = if (builtin.os.tag == .windows)
        "Z:\\definitely-missing-canvas.dll"
    else
        "/definitely-missing-libcanvas.so";
    if (Provider.init(std.testing.allocator, .{
        .kind = .skia,
        .driver = .dynamic,
        .fallback = .disabled,
        .library_path = missing,
    })) |provider_value| {
        var provider = provider_value;
        provider.deinit();
        return error.ExpectedCanvasBackendLoadFailure;
    } else |_| {}

    var fallback = try Provider.init(std.testing.allocator, .{
        .kind = .skia,
        .driver = .dynamic,
        .fallback = .software,
        .library_path = missing,
    });
    defer fallback.deinit();
    try std.testing.expectEqual(Driver.software, fallback.actualDriver());
    try std.testing.expectEqual(BackendKind.skia, fallback.requestedKind());
}

test "configureIdentity preserves driver and fallback selection" {
    const missing = if (builtin.os.tag == .windows)
        "Z:\\definitely-missing-canvas.dll"
    else
        "/definitely-missing-libcanvas.so";
    var provider = try Provider.init(std.testing.allocator, .{
        .kind = .skia,
        .driver = .dynamic,
        .fallback = .software,
        .library_path = missing,
        .profile_seed = 1,
        .canvas_seed = 2,
    });
    defer provider.deinit();
    try std.testing.expectEqual(Driver.software, provider.actualDriver());

    try provider.configureIdentity(.{
        .kind = .fake,
        .profile_seed = 0x0123_4567_89ab_cdef,
        .canvas_seed = 0xfedc_ba98_7654_3210,
    });
    try std.testing.expectEqual(Driver.software, provider.actualDriver());
    try std.testing.expectEqual(Fallback.software, provider.options.fallback);
    try std.testing.expectEqual(Driver.dynamic, provider.options.driver);
    try std.testing.expectEqual(BackendKind.fake, provider.requestedKind());
    try std.testing.expectEqual(@as(u64, 0x0123_4567_89ab_cdef), provider.options.profile_seed);
    try std.testing.expectEqual(@as(u64, 0xfedc_ba98_7654_3210), provider.options.canvas_seed);
}
