//! Chrome Skia ABI v5 Canvas backend adapter.
//! (canvas.dll/libcanvas.*, cs_canvas_*). The backend keeps Canvas 2D
//! drawing state (styles, transforms, paths, shadows, filters, and blending)
//! behind a plain C ABI matching Chrome m149 semantics.

const std = @import("std");
const builtin = @import("builtin");
const module_path = @import("../sys/module_path.zig");

pub const abi_version: u32 = 5;

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

/// Explicit getImageData readback formats. Unlike the legacy canonical pixel
/// ABI these are straight-alpha and may request a target color space.
pub const ReadPixelFormat = enum(i32) {
    rgba8_unorm = 1,
    rgba_float16 = 2,
    rgba_float32 = 3,

    pub fn bytesPerPixel(self: ReadPixelFormat) usize {
        return switch (self) {
            .rgba8_unorm => 4,
            .rgba_float16 => 8,
            .rgba_float32 => 16,
        };
    }
};

pub const ColorSpace = enum(i32) {
    srgb = 0,
    display_p3 = 1,
};

pub const RGBA8 = extern struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8,
};

pub const Radius = extern struct {
    x: f64,
    y: f64,
};

/// One parsed CSS filter operation. The fixed-size POD keeps the C ABI simple;
/// fields not used by a particular kind are zero.
pub const FilterKind = enum(i32) {
    blur = 0,
    drop_shadow = 1,
    grayscale = 2,
    sepia = 3,
    saturate = 4,
    hue_rotate = 5,
    invert = 6,
    opacity = 7,
    brightness = 8,
    contrast = 9,
};

pub const FilterOperation = extern struct {
    kind: FilterKind,
    reserved: u32 = 0,
    amount: f64 = 0,
    offset_x: f64 = 0,
    offset_y: f64 = 0,
    color: [4]f32 = @splat(0),
};

/// Blend ops in Canvas-spec order (0 = source-over), the ABI's cs_canvas_blend.
pub const Blend = enum(i32) {
    src_over = 0,
    multiply = 1,
    screen = 2,
    overlay = 3,
    darken = 4,
    lighten = 5,
    color_dodge = 6,
    color_burn = 7,
    hard_light = 8,
    soft_light = 9,
    difference = 10,
    exclusion = 11,
    hue = 12,
    saturation = 13,
    color = 14,
    luminosity = 15,
    src_in = 16,
    src_out = 17,
    src_atop = 18,
    dst_over = 19,
    dst_in = 20,
    dst_out = 21,
    dst_atop = 22,
    xor = 23,
    plus = 24,
    src = 25,
};

pub const StyleKind = enum(i32) {
    color = 0,
    gradient = 1,
    pattern = 2,
};

pub const GradientKind = enum(i32) {
    linear = 0,
    radial = 1,
    conic = 2,
};

pub const PatternRepetition = enum(i32) {
    repeat = 0,
    repeat_x = 1,
    repeat_y = 2,
    no_repeat = 3,
};

/// cs_canvas_surface_desc.flags.
pub const SurfaceFlag = struct {
    pub const OPAQUE: u32 = 1 << 0;
    pub const DISPLAY_P3: u32 = 1 << 1;
    pub const FLOAT16: u32 = 1 << 2;
    pub const VALID_MASK: u32 = OPAQUE | DISPLAY_P3 | FLOAT16;
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
/// Opaque gradient/pattern style object, owned by the backend until freed with
/// freeStyleObject.
pub const StyleHandle = opaque {};
const OpaqueStyle = StyleHandle;

const AbiVersionFn = *const fn () callconv(.c) u32;
const VersionFn = *const fn () callconv(.c) ?[*:0]const u8;
const CreateFn = *const fn (*const SurfaceDescriptor, *?*OpaqueSurface) callconv(.c) i32;
const FreeFn = *const fn (?*OpaqueSurface) callconv(.c) i32;
const GetInfoFn = *const fn (*OpaqueSurface, *SurfaceInfo) callconv(.c) i32;
const ResizeFn = *const fn (*OpaqueSurface, u32, u32) callconv(.c) i32;
const ReadPixelsFn = *const fn (*OpaqueSurface, u32, u32, u32, u32, ?[*]u8, usize, usize) callconv(.c) i32;
const ReadPixelsFormatFn = *const fn (*OpaqueSurface, u32, u32, u32, u32, ?*anyopaque, usize, usize, ReadPixelFormat, ColorSpace) callconv(.c) i32;
const WritePixelsFn = *const fn (*OpaqueSurface, u32, u32, u32, u32, ?[*]const u8, usize, usize) callconv(.c) i32;
const SaveFn = *const fn (*OpaqueSurface) callconv(.c) i32;
const RestoreFn = *const fn (*OpaqueSurface) callconv(.c) i32;
const SetTransformFn = *const fn (*OpaqueSurface, f64, f64, f64, f64, f64, f64) callconv(.c) i32;
const TranslateFn = *const fn (*OpaqueSurface, f64, f64) callconv(.c) i32;
const ScaleFn = *const fn (*OpaqueSurface, f64, f64) callconv(.c) i32;
const RotateFn = *const fn (*OpaqueSurface, f64) callconv(.c) i32;
const BeginPathFn = *const fn (*OpaqueSurface) callconv(.c) i32;
const MoveToFn = *const fn (*OpaqueSurface, f64, f64) callconv(.c) i32;
const LineToFn = *const fn (*OpaqueSurface, f64, f64) callconv(.c) i32;
const QuadToFn = *const fn (*OpaqueSurface, f64, f64, f64, f64) callconv(.c) i32;
const BezierToFn = *const fn (*OpaqueSurface, f64, f64, f64, f64, f64, f64) callconv(.c) i32;
const ArcFn = *const fn (*OpaqueSurface, f64, f64, f64, f64, f64, i32) callconv(.c) i32;
const ArcToFn = *const fn (*OpaqueSurface, f64, f64, f64, f64, f64) callconv(.c) i32;
const EllipseFn = *const fn (*OpaqueSurface, f64, f64, f64, f64, f64, f64, f64, i32) callconv(.c) i32;
const RectFn = *const fn (*OpaqueSurface, f64, f64, f64, f64) callconv(.c) i32;
const RoundRectFn = *const fn (*OpaqueSurface, f64, f64, f64, f64, f64) callconv(.c) i32;
const RoundRectRadiiFn = *const fn (*OpaqueSurface, f64, f64, f64, f64, *const [4]Radius) callconv(.c) i32;
const ClosePathFn = *const fn (*OpaqueSurface) callconv(.c) i32;
const IsPointInPathFn = *const fn (*OpaqueSurface, f64, f64, i32, *i32) callconv(.c) i32;
const IsPointInStrokeFn = *const fn (*OpaqueSurface, f64, f64, *i32) callconv(.c) i32;
const SetStyleFn = *const fn (*OpaqueSurface, i32, RGBA8, ?*OpaqueStyle) callconv(.c) i32;
const SetStyleFFn = *const fn (*OpaqueSurface, i32, [*]const f32, ?*OpaqueStyle) callconv(.c) i32;
const SetStyleColorSpaceFFn = *const fn (*OpaqueSurface, i32, [*]const f32, ColorSpace, ?*OpaqueStyle) callconv(.c) i32;
const SetLineWidthFn = *const fn (*OpaqueSurface, f64) callconv(.c) i32;
const SetLineCapFn = *const fn (*OpaqueSurface, i32) callconv(.c) i32;
const SetLineJoinFn = *const fn (*OpaqueSurface, i32) callconv(.c) i32;
const SetMiterLimitFn = *const fn (*OpaqueSurface, f64) callconv(.c) i32;
const SetLineDashFn = *const fn (*OpaqueSurface, ?[*]const f32, u32, f64) callconv(.c) i32;
const SetGlobalAlphaFn = *const fn (*OpaqueSurface, f64) callconv(.c) i32;
const SetCompositeFn = *const fn (*OpaqueSurface, i32) callconv(.c) i32;
const SetSmoothingQualityFn = *const fn (*OpaqueSurface, i32) callconv(.c) i32;
const SetShadowFn = *const fn (*OpaqueSurface, f64, f64, f64, RGBA8) callconv(.c) i32;
const SetShadowFFn = *const fn (*OpaqueSurface, f64, f64, f64, [*]const f32) callconv(.c) i32;
const SetFilterFn = *const fn (*OpaqueSurface, ?[*]const FilterOperation, u32) callconv(.c) i32;
const ClipFn = *const fn (*OpaqueSurface, i32) callconv(.c) i32;
const ClipRectFn = *const fn (*OpaqueSurface, f64, f64, f64, f64) callconv(.c) i32;
const FillFn = *const fn (*OpaqueSurface, i32) callconv(.c) i32;
const StrokeFn = *const fn (*OpaqueSurface) callconv(.c) i32;
const FillRectFn = *const fn (*OpaqueSurface, f64, f64, f64, f64) callconv(.c) i32;
const StrokeRectFn = *const fn (*OpaqueSurface, f64, f64, f64, f64) callconv(.c) i32;
const ClearRectFn = *const fn (*OpaqueSurface, f64, f64, f64, f64) callconv(.c) i32;
const DrawImageFn = *const fn (*OpaqueSurface, [*]const u8, u32, u32, usize, f64, f64, f64, f64, f64, f64, f64, f64, i32) callconv(.c) i32;
const CreateGradientFn = *const fn (*OpaqueSurface, i32, [*]const f32, [*]const RGBA8, ?[*]const f32, u32, i32, *?*OpaqueStyle) callconv(.c) i32;
const CreateGradientFFn = *const fn (*OpaqueSurface, i32, [*]const f32, [*]const f32, ?[*]const f32, u32, i32, *?*OpaqueStyle) callconv(.c) i32;
const CreatePatternFn = *const fn (*OpaqueSurface, [*]const u8, u32, u32, usize, i32, *?*OpaqueStyle) callconv(.c) i32;
const SetPatternTransformFn = *const fn (*OpaqueStyle, f64, f64, f64, f64, f64, f64) callconv(.c) i32;
const FreeStyleFn = *const fn (?*OpaqueSurface, ?*OpaqueStyle) callconv(.c) i32;
const EncodePngFn = *const fn (*OpaqueSurface, *?[*]u8, *usize) callconv(.c) i32;
const EncodeJpegFn = *const fn (*OpaqueSurface, i32, *?[*]u8, *usize) callconv(.c) i32;
const FreeEncodedFn = *const fn (?*anyopaque) callconv(.c) i32;
const FillTextFn = *const fn (*OpaqueSurface, [*]const u8, i32, f64, f64, f64, [*]const u8) callconv(.c) i32;
const MeasureTextFn = *const fn ([*]const u8, i32, f64, [*]const u8, ?[*]f32) callconv(.c) f64;

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
    read_pixels_fn: ReadPixelsFn,
    read_pixels_format_fn: ReadPixelsFormatFn,
    write_pixels_fn: WritePixelsFn,
    save_fn: SaveFn,
    restore_fn: RestoreFn,
    set_transform_fn: SetTransformFn,
    translate_fn: TranslateFn,
    scale_fn: ScaleFn,
    rotate_fn: RotateFn,
    begin_path_fn: BeginPathFn,
    move_to_fn: MoveToFn,
    line_to_fn: LineToFn,
    quad_to_fn: QuadToFn,
    bezier_to_fn: BezierToFn,
    arc_fn: ArcFn,
    arc_to_fn: ArcToFn,
    ellipse_fn: EllipseFn,
    rect_fn: RectFn,
    round_rect_fn: RoundRectFn,
    round_rect_radii_fn: RoundRectRadiiFn,
    close_path_fn: ClosePathFn,
    is_point_in_path_fn: IsPointInPathFn,
    is_point_in_stroke_fn: IsPointInStrokeFn,
    set_fill_style_fn: SetStyleFn,
    set_stroke_style_fn: SetStyleFn,
    set_fill_style_f_fn: SetStyleFFn,
    set_stroke_style_f_fn: SetStyleFFn,
    set_fill_style_color_space_f_fn: SetStyleColorSpaceFFn,
    set_stroke_style_color_space_f_fn: SetStyleColorSpaceFFn,
    set_line_width_fn: SetLineWidthFn,
    set_line_cap_fn: SetLineCapFn,
    set_line_join_fn: SetLineJoinFn,
    set_miter_limit_fn: SetMiterLimitFn,
    set_line_dash_fn: SetLineDashFn,
    set_global_alpha_fn: SetGlobalAlphaFn,
    set_composite_fn: SetCompositeFn,
    set_smoothing_quality_fn: SetSmoothingQualityFn,
    set_shadow_fn: SetShadowFn,
    set_shadow_f_fn: SetShadowFFn,
    set_filter_fn: SetFilterFn,
    clip_fn: ClipFn,
    clip_rect_fn: ClipRectFn,
    fill_fn: FillFn,
    stroke_fn: StrokeFn,
    fill_rect_fn: FillRectFn,
    stroke_rect_fn: StrokeRectFn,
    clear_rect_fn: ClearRectFn,
    draw_image_fn: DrawImageFn,
    create_gradient_fn: CreateGradientFn,
    create_gradient_f_fn: CreateGradientFFn,
    create_pattern_fn: CreatePatternFn,
    set_pattern_transform_fn: SetPatternTransformFn,
    free_style_fn: FreeStyleFn,
    encode_png_fn: EncodePngFn,
    encode_jpeg_fn: EncodeJpegFn,
    free_encoded_fn: FreeEncodedFn,
    fill_text_fn: FillTextFn,
    measure_text_fn: MeasureTextFn,
    version_fn: VersionFn,
    abi_version_fn: AbiVersionFn,

    pub fn open(path: []const u8) !Api {
        var library = try std.DynLib.open(path);
        errdefer library.close();

        const self: Api = .{
            .library = library,
            .create_fn = try lookup(&library, CreateFn, "cs_canvas_surface_create"),
            .free_fn = try lookup(&library, FreeFn, "cs_canvas_surface_free"),
            .get_info_fn = try lookup(&library, GetInfoFn, "cs_canvas_surface_get_info"),
            .resize_fn = try lookup(&library, ResizeFn, "cs_canvas_surface_resize"),
            .read_pixels_fn = try lookup(&library, ReadPixelsFn, "cs_canvas_surface_read_pixels"),
            .read_pixels_format_fn = try lookup(&library, ReadPixelsFormatFn, "cs_canvas_surface_read_pixels_format"),
            .write_pixels_fn = try lookup(&library, WritePixelsFn, "cs_canvas_surface_write_pixels"),
            .save_fn = try lookup(&library, SaveFn, "cs_canvas_save"),
            .restore_fn = try lookup(&library, RestoreFn, "cs_canvas_restore"),
            .set_transform_fn = try lookup(&library, SetTransformFn, "cs_canvas_set_transform"),
            .translate_fn = try lookup(&library, TranslateFn, "cs_canvas_translate"),
            .scale_fn = try lookup(&library, ScaleFn, "cs_canvas_scale"),
            .rotate_fn = try lookup(&library, RotateFn, "cs_canvas_rotate"),
            .begin_path_fn = try lookup(&library, BeginPathFn, "cs_canvas_begin_path"),
            .move_to_fn = try lookup(&library, MoveToFn, "cs_canvas_move_to"),
            .line_to_fn = try lookup(&library, LineToFn, "cs_canvas_line_to"),
            .quad_to_fn = try lookup(&library, QuadToFn, "cs_canvas_quad_to"),
            .bezier_to_fn = try lookup(&library, BezierToFn, "cs_canvas_bezier_to"),
            .arc_fn = try lookup(&library, ArcFn, "cs_canvas_arc"),
            .arc_to_fn = try lookup(&library, ArcToFn, "cs_canvas_arc_to"),
            .ellipse_fn = try lookup(&library, EllipseFn, "cs_canvas_ellipse"),
            .rect_fn = try lookup(&library, RectFn, "cs_canvas_rect"),
            .round_rect_fn = try lookup(&library, RoundRectFn, "cs_canvas_round_rect"),
            .round_rect_radii_fn = try lookup(&library, RoundRectRadiiFn, "cs_canvas_round_rect_radii"),
            .close_path_fn = try lookup(&library, ClosePathFn, "cs_canvas_close_path"),
            .is_point_in_path_fn = try lookup(&library, IsPointInPathFn, "cs_canvas_is_point_in_path"),
            .is_point_in_stroke_fn = try lookup(&library, IsPointInStrokeFn, "cs_canvas_is_point_in_stroke"),
            .set_fill_style_fn = try lookup(&library, SetStyleFn, "cs_canvas_set_fill_style"),
            .set_stroke_style_fn = try lookup(&library, SetStyleFn, "cs_canvas_set_stroke_style"),
            .set_fill_style_f_fn = try lookup(&library, SetStyleFFn, "cs_canvas_set_fill_style_f"),
            .set_stroke_style_f_fn = try lookup(&library, SetStyleFFn, "cs_canvas_set_stroke_style_f"),
            .set_fill_style_color_space_f_fn = try lookup(&library, SetStyleColorSpaceFFn, "cs_canvas_set_fill_style_color_space_f"),
            .set_stroke_style_color_space_f_fn = try lookup(&library, SetStyleColorSpaceFFn, "cs_canvas_set_stroke_style_color_space_f"),
            .set_line_width_fn = try lookup(&library, SetLineWidthFn, "cs_canvas_set_line_width"),
            .set_line_cap_fn = try lookup(&library, SetLineCapFn, "cs_canvas_set_line_cap"),
            .set_line_join_fn = try lookup(&library, SetLineJoinFn, "cs_canvas_set_line_join"),
            .set_miter_limit_fn = try lookup(&library, SetMiterLimitFn, "cs_canvas_set_miter_limit"),
            .set_line_dash_fn = try lookup(&library, SetLineDashFn, "cs_canvas_set_line_dash"),
            .set_global_alpha_fn = try lookup(&library, SetGlobalAlphaFn, "cs_canvas_set_global_alpha"),
            .set_composite_fn = try lookup(&library, SetCompositeFn, "cs_canvas_set_global_composite_operation"),
            .set_smoothing_quality_fn = try lookup(&library, SetSmoothingQualityFn, "cs_canvas_set_image_smoothing_quality"),
            .set_shadow_fn = try lookup(&library, SetShadowFn, "cs_canvas_set_shadow"),
            .set_shadow_f_fn = try lookup(&library, SetShadowFFn, "cs_canvas_set_shadow_f"),
            .set_filter_fn = try lookup(&library, SetFilterFn, "cs_canvas_set_filter"),
            .clip_fn = try lookup(&library, ClipFn, "cs_canvas_clip"),
            .clip_rect_fn = try lookup(&library, ClipRectFn, "cs_canvas_clip_rect"),
            .fill_fn = try lookup(&library, FillFn, "cs_canvas_fill"),
            .stroke_fn = try lookup(&library, StrokeFn, "cs_canvas_stroke"),
            .fill_rect_fn = try lookup(&library, FillRectFn, "cs_canvas_fill_rect"),
            .stroke_rect_fn = try lookup(&library, StrokeRectFn, "cs_canvas_stroke_rect"),
            .clear_rect_fn = try lookup(&library, ClearRectFn, "cs_canvas_clear_rect"),
            .draw_image_fn = try lookup(&library, DrawImageFn, "cs_canvas_draw_image"),
            .create_gradient_fn = try lookup(&library, CreateGradientFn, "cs_canvas_create_gradient"),
            .create_gradient_f_fn = try lookup(&library, CreateGradientFFn, "cs_canvas_create_gradient_f"),
            .create_pattern_fn = try lookup(&library, CreatePatternFn, "cs_canvas_create_pattern"),
            .set_pattern_transform_fn = try lookup(&library, SetPatternTransformFn, "cs_canvas_set_pattern_transform"),
            .free_style_fn = try lookup(&library, FreeStyleFn, "cs_canvas_free_style_object"),
            .encode_png_fn = try lookup(&library, EncodePngFn, "cs_canvas_encode_png"),
            .encode_jpeg_fn = try lookup(&library, EncodeJpegFn, "cs_canvas_encode_jpeg"),
            .free_encoded_fn = try lookup(&library, FreeEncodedFn, "cs_canvas_free_encoded_buffer"),
            .fill_text_fn = try lookup(&library, FillTextFn, "cs_canvas_fill_text"),
            .measure_text_fn = try lookup(&library, MeasureTextFn, "cs_canvas_measure_text"),
            .version_fn = try lookup(&library, VersionFn, "cs_canvas_backend_version"),
            .abi_version_fn = try lookup(&library, AbiVersionFn, "cs_canvas_backend_abi_version"),
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
            .api = self,
        };
    }

    pub fn setPatternTransform(self: *const Api, handle: *OpaqueStyle, matrix: [6]f64) Error!void {
        try expectOk(self.set_pattern_transform_fn(
            handle,
            matrix[0],
            matrix[1],
            matrix[2],
            matrix[3],
            matrix[4],
            matrix[5],
        ));
    }

    /// Style objects are independent of the surface used to create them. The
    /// backend accepts a null surface so callers can release a style after its
    /// originating surface has already been destroyed.
    pub fn freeStyleObject(self: *const Api, handle: *OpaqueStyle) Error!void {
        try expectOk(self.free_style_fn(null, handle));
    }
};

/// Owning surface handle; every method forwards to the matching ABI v5 symbol.
pub const OwnedSurface = struct {
    raw: *OpaqueSurface,
    api: *const Api,

    pub fn deinit(self: *OwnedSurface) Error!void {
        try expectOk(self.api.free_fn(self.raw));
        self.* = undefined;
    }

    pub fn info(self: *OwnedSurface) Error!SurfaceInfo {
        var result: SurfaceInfo = .{};
        try expectOk(self.api.get_info_fn(self.raw, &result));
        return result;
    }

    pub fn resize(self: *OwnedSurface, width: u32, height: u32) Error!void {
        try expectOk(self.api.resize_fn(self.raw, width, height));
    }

    pub fn readPixels(self: *OwnedSurface, x: u32, y: u32, width: u32, height: u32, destination: []u8, row_bytes: usize) Error!void {
        try expectOk(self.api.read_pixels_fn(self.raw, x, y, width, height, destination.ptr, destination.len, row_bytes));
    }

    pub fn readPixelsFormat(
        self: *OwnedSurface,
        x: u32,
        y: u32,
        width: u32,
        height: u32,
        destination: []u8,
        row_bytes: usize,
        format: ReadPixelFormat,
        color_space: ColorSpace,
    ) Error!void {
        try expectOk(self.api.read_pixels_format_fn(
            self.raw,
            x,
            y,
            width,
            height,
            destination.ptr,
            destination.len,
            row_bytes,
            format,
            color_space,
        ));
    }

    pub fn writePixels(self: *OwnedSurface, x: u32, y: u32, width: u32, height: u32, source: []const u8, row_bytes: usize) Error!void {
        try expectOk(self.api.write_pixels_fn(self.raw, x, y, width, height, source.ptr, source.len, row_bytes));
    }

    pub fn save(self: *OwnedSurface) Error!void {
        try expectOk(self.api.save_fn(self.raw));
    }
    pub fn restore(self: *OwnedSurface) Error!void {
        try expectOk(self.api.restore_fn(self.raw));
    }

    pub fn setTransform(self: *OwnedSurface, a: f64, b: f64, c: f64, d: f64, e: f64, f: f64) Error!void {
        try expectOk(self.api.set_transform_fn(self.raw, a, b, c, d, e, f));
    }
    pub fn translate(self: *OwnedSurface, dx: f64, dy: f64) Error!void {
        try expectOk(self.api.translate_fn(self.raw, dx, dy));
    }
    pub fn scale(self: *OwnedSurface, sx: f64, sy: f64) Error!void {
        try expectOk(self.api.scale_fn(self.raw, sx, sy));
    }
    pub fn rotate(self: *OwnedSurface, radians: f64) Error!void {
        try expectOk(self.api.rotate_fn(self.raw, radians));
    }

    pub fn beginPath(self: *OwnedSurface) Error!void {
        try expectOk(self.api.begin_path_fn(self.raw));
    }
    pub fn moveTo(self: *OwnedSurface, x: f64, y: f64) Error!void {
        try expectOk(self.api.move_to_fn(self.raw, x, y));
    }
    pub fn lineTo(self: *OwnedSurface, x: f64, y: f64) Error!void {
        try expectOk(self.api.line_to_fn(self.raw, x, y));
    }
    pub fn quadraticCurveTo(self: *OwnedSurface, cpx: f64, cpy: f64, x: f64, y: f64) Error!void {
        try expectOk(self.api.quad_to_fn(self.raw, cpx, cpy, x, y));
    }
    pub fn bezierCurveTo(self: *OwnedSurface, cp1x: f64, cp1y: f64, cp2x: f64, cp2y: f64, x: f64, y: f64) Error!void {
        try expectOk(self.api.bezier_to_fn(self.raw, cp1x, cp1y, cp2x, cp2y, x, y));
    }
    pub fn arc(self: *OwnedSurface, x: f64, y: f64, radius: f64, start: f64, end: f64, ccw: bool) Error!void {
        try expectOk(self.api.arc_fn(self.raw, x, y, radius, start, end, if (ccw) 1 else 0));
    }
    pub fn arcTo(self: *OwnedSurface, x1: f64, y1: f64, x2: f64, y2: f64, radius: f64) Error!void {
        try expectOk(self.api.arc_to_fn(self.raw, x1, y1, x2, y2, radius));
    }
    pub fn ellipse(self: *OwnedSurface, x: f64, y: f64, rx: f64, ry: f64, rotation: f64, start: f64, end: f64, ccw: bool) Error!void {
        try expectOk(self.api.ellipse_fn(self.raw, x, y, rx, ry, rotation, start, end, if (ccw) 1 else 0));
    }
    pub fn rect(self: *OwnedSurface, x: f64, y: f64, w: f64, h: f64) Error!void {
        try expectOk(self.api.rect_fn(self.raw, x, y, w, h));
    }
    pub fn roundRectRadii(self: *OwnedSurface, x: f64, y: f64, w: f64, h: f64, radii: *const [4]Radius) Error!void {
        try expectOk(self.api.round_rect_radii_fn(self.raw, x, y, w, h, radii));
    }
    pub fn closePath(self: *OwnedSurface) Error!void {
        try expectOk(self.api.close_path_fn(self.raw));
    }
    pub fn isPointInPath(self: *OwnedSurface, x: f64, y: f64, fill_rule: i32) Error!bool {
        var contains: i32 = 0;
        try expectOk(self.api.is_point_in_path_fn(self.raw, x, y, fill_rule, &contains));
        return contains != 0;
    }
    pub fn isPointInStroke(self: *OwnedSurface, x: f64, y: f64) Error!bool {
        var contains: i32 = 0;
        try expectOk(self.api.is_point_in_stroke_fn(self.raw, x, y, &contains));
        return contains != 0;
    }

    pub fn setFillStyleColor(self: *OwnedSurface, color: RGBA8) Error!void {
        try expectOk(self.api.set_fill_style_fn(self.raw, @intFromEnum(StyleKind.color), color, null));
    }
    pub fn setFillStyleColorSpaceF(self: *OwnedSurface, color4: *const [4]f32, color_space: ColorSpace) Error!void {
        try expectOk(self.api.set_fill_style_color_space_f_fn(
            self.raw,
            @intFromEnum(StyleKind.color),
            color4,
            color_space,
            null,
        ));
    }
    pub fn setFillStyleObject(self: *OwnedSurface, kind: StyleKind, handle: *OpaqueStyle) Error!void {
        try expectOk(self.api.set_fill_style_fn(self.raw, @intFromEnum(kind), .{ .r = 0, .g = 0, .b = 0, .a = 255 }, handle));
    }
    pub fn setStrokeStyleColorSpaceF(self: *OwnedSurface, color4: *const [4]f32, color_space: ColorSpace) Error!void {
        try expectOk(self.api.set_stroke_style_color_space_f_fn(
            self.raw,
            @intFromEnum(StyleKind.color),
            color4,
            color_space,
            null,
        ));
    }
    pub fn setStrokeStyleObject(self: *OwnedSurface, kind: StyleKind, handle: *OpaqueStyle) Error!void {
        try expectOk(self.api.set_stroke_style_fn(self.raw, @intFromEnum(kind), .{ .r = 0, .g = 0, .b = 0, .a = 255 }, handle));
    }

    pub fn setLineWidth(self: *OwnedSurface, w: f64) Error!void {
        try expectOk(self.api.set_line_width_fn(self.raw, w));
    }
    pub fn setLineCap(self: *OwnedSurface, cap: i32) Error!void {
        try expectOk(self.api.set_line_cap_fn(self.raw, cap));
    }
    pub fn setLineJoin(self: *OwnedSurface, join: i32) Error!void {
        try expectOk(self.api.set_line_join_fn(self.raw, join));
    }
    pub fn setMiterLimit(self: *OwnedSurface, m: f64) Error!void {
        try expectOk(self.api.set_miter_limit_fn(self.raw, m));
    }
    pub fn setLineDash(self: *OwnedSurface, intervals: []const f32, phase: f64) Error!void {
        try expectOk(self.api.set_line_dash_fn(self.raw, if (intervals.len == 0) null else intervals.ptr, @intCast(intervals.len), phase));
    }
    pub fn setGlobalAlpha(self: *OwnedSurface, alpha: f64) Error!void {
        try expectOk(self.api.set_global_alpha_fn(self.raw, alpha));
    }
    pub fn setGlobalCompositeOperation(self: *OwnedSurface, op: Blend) Error!void {
        try expectOk(self.api.set_composite_fn(self.raw, @intFromEnum(op)));
    }
    pub fn setImageSmoothingQuality(self: *OwnedSurface, quality: i32) Error!void {
        try expectOk(self.api.set_smoothing_quality_fn(self.raw, quality));
    }
    pub fn setShadowF(self: *OwnedSurface, blur: f64, dx: f64, dy: f64, color4: *const [4]f32) Error!void {
        try expectOk(self.api.set_shadow_f_fn(self.raw, blur, dx, dy, color4));
    }
    pub fn setFilter(self: *OwnedSurface, operations: []const FilterOperation) Error!void {
        try expectOk(self.api.set_filter_fn(
            self.raw,
            if (operations.len == 0) null else operations.ptr,
            @intCast(operations.len),
        ));
    }

    pub fn clip(self: *OwnedSurface, fill_rule: i32) Error!void {
        try expectOk(self.api.clip_fn(self.raw, fill_rule));
    }
    pub fn fill(self: *OwnedSurface, fill_rule: i32) Error!void {
        try expectOk(self.api.fill_fn(self.raw, fill_rule));
    }
    pub fn stroke(self: *OwnedSurface) Error!void {
        try expectOk(self.api.stroke_fn(self.raw));
    }
    pub fn fillRect(self: *OwnedSurface, x: f64, y: f64, w: f64, h: f64) Error!void {
        try expectOk(self.api.fill_rect_fn(self.raw, x, y, w, h));
    }
    pub fn strokeRect(self: *OwnedSurface, x: f64, y: f64, w: f64, h: f64) Error!void {
        try expectOk(self.api.stroke_rect_fn(self.raw, x, y, w, h));
    }
    pub fn clearRect(self: *OwnedSurface, x: f64, y: f64, w: f64, h: f64) Error!void {
        try expectOk(self.api.clear_rect_fn(self.raw, x, y, w, h));
    }

    pub fn drawImage(self: *OwnedSurface, pixels: []const u8, iw: u32, ih: u32, row_bytes: usize, sx: f64, sy: f64, sw: f64, sh: f64, dx: f64, dy: f64, dw: f64, dh: f64, smoothing: bool) Error!void {
        try expectOk(self.api.draw_image_fn(self.raw, pixels.ptr, iw, ih, row_bytes, sx, sy, sw, sh, dx, dy, dw, dh, if (smoothing) 1 else 0));
    }

    pub fn createGradientF(self: *OwnedSurface, kind: GradientKind, points: []const f32, stop_colors: []const f32, positions: ?[]const f32, tile_mode: i32) Error!*OpaqueStyle {
        var out: ?*OpaqueStyle = null;
        try expectOk(self.api.create_gradient_f_fn(self.raw, @intFromEnum(kind), points.ptr, stop_colors.ptr, if (positions) |p| p.ptr else null, @intCast(stop_colors.len / 4), tile_mode, &out));
        return out orelse error.BackendFailure;
    }
    pub fn createPattern(self: *OwnedSurface, pixels: []const u8, w: u32, h: u32, row_bytes: usize, repetition: PatternRepetition) Error!*OpaqueStyle {
        var out: ?*OpaqueStyle = null;
        try expectOk(self.api.create_pattern_fn(self.raw, pixels.ptr, w, h, row_bytes, @intFromEnum(repetition), &out));
        return out orelse error.BackendFailure;
    }
    pub fn setPatternTransform(self: *OwnedSurface, handle: *OpaqueStyle, matrix: [6]f64) Error!void {
        try self.api.setPatternTransform(handle, matrix);
    }
    pub fn freeStyleObject(self: *OwnedSurface, handle: *OpaqueStyle) Error!void {
        try expectOk(self.api.free_style_fn(self.raw, handle));
    }

    /// Encodes the surface; the returned slice is owned by the backend and must be
    /// released with freeEncodedBuffer.
    pub fn encodePng(self: *OwnedSurface) Error![]u8 {
        var ptr: ?[*]u8 = null;
        var len: usize = 0;
        try expectOk(self.api.encode_png_fn(self.raw, &ptr, &len));
        return (ptr orelse return error.BackendFailure)[0..len];
    }
    pub fn encodeJpeg(self: *OwnedSurface, quality: i32) Error![]u8 {
        var ptr: ?[*]u8 = null;
        var len: usize = 0;
        try expectOk(self.api.encode_jpeg_fn(self.raw, quality, &ptr, &len));
        return (ptr orelse return error.BackendFailure)[0..len];
    }
    pub fn freeEncodedBuffer(self: *OwnedSurface, buf: []u8) Error!void {
        try expectOk(self.api.free_encoded_fn(buf.ptr));
    }

    pub fn fillText(self: *OwnedSurface, utf8: []const u8, x: f64, y: f64, font_size: f64, family: [:0]const u8) Error!void {
        try expectOk(self.api.fill_text_fn(self.raw, utf8.ptr, @intCast(utf8.len), x, y, font_size, family.ptr));
    }

    pub fn measureText(self: *OwnedSurface, utf8: []const u8, font_size: f64, family: [:0]const u8, out_metrics: ?*[5]f32) f64 {
        return self.api.measure_text_fn(utf8.ptr, @intCast(utf8.len), font_size, family.ptr, if (out_metrics) |p| p else null);
    }
};

pub fn libraryName() []const u8 {
    return switch (builtin.os.tag) {
        .windows => "canvas.dll",
        .macos => "libcanvas.dylib",
        else => "libcanvas.so",
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
    if (@sizeOf(FilterOperation) != 48) @compileError("Canvas filter ABI layout changed");
    if (@sizeOf(SurfaceDescriptor) != 72) @compileError("Canvas descriptor ABI layout changed");
    if (@sizeOf(SurfaceInfo) != 40) @compileError("Canvas info ABI layout changed");
}
