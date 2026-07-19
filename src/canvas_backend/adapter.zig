const std = @import("std");
const builtin = @import("builtin");
const module_path = @import("../sys/module_path.zig");

pub const abi_version: u32 = 2;

pub const Status = enum(i32) {
    ok = 0,
    invalid_argument = 1,
    unsupported_abi = 2,
    unsupported_backend = 3,
    out_of_memory = 4,
    size_overflow = 5,
    out_of_bounds = 6,
    buffer_too_small = 7,
    wrong_thread = 8,
    backend_failure = 9,
    rust_panic = 10,
};

pub const BackendKind = enum(i32) {
    skia = 1,
    fake = 2,
};

pub const PixelFormat = enum(i32) {
    rgba8_premul_srgb = 1,
};

pub const RGBA8 = extern struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8,
};

pub const SurfaceDescriptor = extern struct {
    struct_size: u32 = @sizeOf(SurfaceDescriptor),
    abi_version: u32 = adapter_abi_version,
    backend_kind: BackendKind,
    width: u32,
    height: u32,
    flags: u32 = 0,
    profile_seed: u64,
    canvas_seed: u64,
    reserved: [4]u64 = @splat(0),

    const adapter_abi_version = abi_version;
};

pub const SurfaceInfo = extern struct {
    struct_size: u32 = @sizeOf(SurfaceInfo),
    backend_kind: BackendKind = .skia,
    width: u32 = 0,
    height: u32 = 0,
    canonical_row_bytes: u32 = 0,
    pixel_format: PixelFormat = .rgba8_premul_srgb,
    profile_seed: u64 = 0,
    canvas_seed: u64 = 0,
};

const OpaqueSurface = opaque {};

const AbiVersionFn = *const fn () callconv(.c) u32;
const VersionFn = *const fn () callconv(.c) ?[*:0]const u8;
const CreateFn = *const fn (*const SurfaceDescriptor, *?*OpaqueSurface) callconv(.c) i32;
const FreeFn = *const fn (?*OpaqueSurface) callconv(.c) i32;
const GetInfoFn = *const fn (*OpaqueSurface, *SurfaceInfo) callconv(.c) i32;
const ResizeFn = *const fn (*OpaqueSurface, u32, u32) callconv(.c) i32;
const ClearFn = *const fn (*OpaqueSurface, RGBA8) callconv(.c) i32;
const FillRectFn = *const fn (*OpaqueSurface, f64, f64, f64, f64, RGBA8, f64) callconv(.c) i32;
const ClearRectFn = *const fn (*OpaqueSurface, f64, f64, f64, f64) callconv(.c) i32;
const ReadPixelsFn = *const fn (*OpaqueSurface, u32, u32, u32, u32, ?[*]u8, usize, usize) callconv(.c) i32;
const WritePixelsFn = *const fn (*OpaqueSurface, u32, u32, u32, u32, ?[*]const u8, usize, usize) callconv(.c) i32;

pub const Error = error{
    InvalidArgument,
    UnsupportedAbi,
    UnsupportedBackend,
    OutOfMemory,
    SizeOverflow,
    OutOfBounds,
    BufferTooSmall,
    WrongThread,
    BackendFailure,
    RustPanic,
    UnknownStatus,
    MissingSymbol,
    AbiVersionMismatch,
};

pub const Api = struct {
    library: std.DynLib,
    create_fn: CreateFn,
    free_fn: FreeFn,
    get_info_fn: GetInfoFn,
    resize_fn: ResizeFn,
    clear_fn: ClearFn,
    fill_rect_fn: FillRectFn,
    clear_rect_fn: ClearRectFn,
    read_pixels_fn: ReadPixelsFn,
    write_pixels_fn: WritePixelsFn,
    version_fn: VersionFn,
    abi_version_fn: AbiVersionFn,

    pub fn open(path: []const u8) !Api {
        var library = try std.DynLib.open(path);
        errdefer library.close();

        const self: Api = .{
            .library = library,
            .create_fn = try lookup(&library, CreateFn, "dp_canvas_surface_create"),
            .free_fn = try lookup(&library, FreeFn, "dp_canvas_surface_free"),
            .get_info_fn = try lookup(&library, GetInfoFn, "dp_canvas_surface_get_info"),
            .resize_fn = try lookup(&library, ResizeFn, "dp_canvas_surface_resize"),
            .clear_fn = try lookup(&library, ClearFn, "dp_canvas_surface_clear"),
            .fill_rect_fn = try lookup(&library, FillRectFn, "dp_canvas_surface_fill_rect"),
            .clear_rect_fn = try lookup(&library, ClearRectFn, "dp_canvas_surface_clear_rect"),
            .read_pixels_fn = try lookup(&library, ReadPixelsFn, "dp_canvas_surface_read_pixels"),
            .write_pixels_fn = try lookup(&library, WritePixelsFn, "dp_canvas_surface_write_pixels"),
            .version_fn = try lookup(&library, VersionFn, "dp_canvas_backend_version"),
            .abi_version_fn = try lookup(&library, AbiVersionFn, "dp_canvas_backend_abi_version"),
        };
        if (self.abi_version_fn() != abi_version) return error.AbiVersionMismatch;
        return self;
    }

    pub fn openConfigured(allocator: std.mem.Allocator) !Api {
        const configured = std.process.getEnvVarOwned(
            allocator,
            "DARKPANDA_CANVAS_BACKEND_LIBRARY",
        ) catch |err| switch (err) {
            error.EnvironmentVariableNotFound, error.InvalidWtf8 => null,
            error.OutOfMemory => return error.OutOfMemory,
        };
        defer if (configured) |path| allocator.free(path);
        if (configured) |path| {
            if (!std.fs.path.isAbsolute(path)) return error.CanvasBackendPathMustBeAbsolute;
            return open(path);
        }

        return openAdjacent(allocator);
    }

    /// Load only from the directory containing the DarkPanda native image.
    /// FFI configuration uses this path so a process-wide environment variable
    /// cannot silently replace the artifact-set member selected by the caller.
    pub fn openAdjacent(allocator: std.mem.Allocator) !Api {
        const adjacent = try module_path.adjacentPathAlloc(allocator, libraryName());
        defer allocator.free(adjacent);
        return open(adjacent);
    }

    pub fn close(self: *Api) void {
        self.library.close();
        self.* = undefined;
    }

    pub fn version(self: *const Api) []const u8 {
        return if (self.version_fn()) |raw| std.mem.span(raw) else "";
    }

    pub fn create(self: *const Api, descriptor: *const SurfaceDescriptor) Error!OwnedSurface {
        var raw: ?*OpaqueSurface = null;
        try expectOk(self.create_fn(descriptor, &raw));
        return .{
            .raw = raw orelse return error.BackendFailure,
            .free_fn = self.free_fn,
            .get_info_fn = self.get_info_fn,
            .resize_fn = self.resize_fn,
            .clear_fn = self.clear_fn,
            .fill_rect_fn = self.fill_rect_fn,
            .clear_rect_fn = self.clear_rect_fn,
            .read_pixels_fn = self.read_pixels_fn,
            .write_pixels_fn = self.write_pixels_fn,
        };
    }
};

pub const OwnedSurface = struct {
    raw: *OpaqueSurface,
    free_fn: FreeFn,
    get_info_fn: GetInfoFn,
    resize_fn: ResizeFn,
    clear_fn: ClearFn,
    fill_rect_fn: FillRectFn,
    clear_rect_fn: ClearRectFn,
    read_pixels_fn: ReadPixelsFn,
    write_pixels_fn: WritePixelsFn,

    pub fn deinit(self: *OwnedSurface) Error!void {
        try expectOk(self.free_fn(self.raw));
        self.* = undefined;
    }

    pub fn info(self: *OwnedSurface) Error!SurfaceInfo {
        var result: SurfaceInfo = .{};
        try expectOk(self.get_info_fn(self.raw, &result));
        return result;
    }

    pub fn resize(self: *OwnedSurface, width: u32, height: u32) Error!void {
        try expectOk(self.resize_fn(self.raw, width, height));
    }

    pub fn clear(self: *OwnedSurface, color: RGBA8) Error!void {
        try expectOk(self.clear_fn(self.raw, color));
    }

    pub fn fillRect(
        self: *OwnedSurface,
        x: f64,
        y: f64,
        width: f64,
        height: f64,
        color: RGBA8,
        opacity: f64,
    ) Error!void {
        try expectOk(self.fill_rect_fn(self.raw, x, y, width, height, color, opacity));
    }

    pub fn clearRect(
        self: *OwnedSurface,
        x: f64,
        y: f64,
        width: f64,
        height: f64,
    ) Error!void {
        try expectOk(self.clear_rect_fn(self.raw, x, y, width, height));
    }

    pub fn readPixels(
        self: *OwnedSurface,
        x: u32,
        y: u32,
        width: u32,
        height: u32,
        destination: []u8,
        row_bytes: usize,
    ) Error!void {
        try expectOk(self.read_pixels_fn(
            self.raw,
            x,
            y,
            width,
            height,
            destination.ptr,
            destination.len,
            row_bytes,
        ));
    }

    pub fn writePixels(
        self: *OwnedSurface,
        x: u32,
        y: u32,
        width: u32,
        height: u32,
        source: []const u8,
        row_bytes: usize,
    ) Error!void {
        try expectOk(self.write_pixels_fn(
            self.raw,
            x,
            y,
            width,
            height,
            source.ptr,
            source.len,
            row_bytes,
        ));
    }
};

pub fn libraryName() []const u8 {
    return switch (builtin.os.tag) {
        .windows => "darkpanda_canvas_backend.dll",
        .macos => "libdarkpanda_canvas_backend.dylib",
        else => "libdarkpanda_canvas_backend.so",
    };
}

fn lookup(library: *std.DynLib, comptime T: type, name: [:0]const u8) Error!T {
    return library.lookup(T, name) orelse error.MissingSymbol;
}

fn expectOk(raw: i32) Error!void {
    const status = std.meta.intToEnum(Status, raw) catch return error.UnknownStatus;
    return switch (status) {
        .ok => {},
        .invalid_argument => error.InvalidArgument,
        .unsupported_abi => error.UnsupportedAbi,
        .unsupported_backend => error.UnsupportedBackend,
        .out_of_memory => error.OutOfMemory,
        .size_overflow => error.SizeOverflow,
        .out_of_bounds => error.OutOfBounds,
        .buffer_too_small => error.BufferTooSmall,
        .wrong_thread => error.WrongThread,
        .backend_failure => error.BackendFailure,
        .rust_panic => error.RustPanic,
    };
}

comptime {
    if (@sizeOf(RGBA8) != 4) @compileError("Canvas RGBA ABI layout changed");
    if (@sizeOf(SurfaceDescriptor) != 72) @compileError("Canvas descriptor ABI layout changed");
    if (@sizeOf(SurfaceInfo) != 40) @compileError("Canvas info ABI layout changed");
}
