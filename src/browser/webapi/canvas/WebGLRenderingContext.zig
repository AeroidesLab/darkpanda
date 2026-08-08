// Copyright (C) 2023-2025  Lightpanda (Selecy SAS)
//
// Francis Bouvier <francis@lightpanda.io>
// Pierre Tachoire <pierre@lightpanda.io>
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as
// published by the Free Software Foundation, either version 3 of the
// License, or (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

const std = @import("std");

const js = @import("../../js/js.zig");

pub fn registerTypes() []const type {
    return &.{
        WebGLRenderingContext,
        // Extension types should be runtime generated. We might want
        // to revisit this.
        Extension.Type.WEBGL_debug_renderer_info,
        Extension.Type.WEBGL_lose_context,
        Extension.Type.EXT_texture_filter_anisotropic,
        Extension.Type.WEBGL_draw_buffers,
    };
}

const WebGLRenderingContext = @This();

pub const CanvasHooks = struct {
    ptr: *anyopaque,
    toJs: *const fn (*anyopaque, *const js.Local) anyerror!js.Value,
    width: *const fn (*anyopaque) u32,
    height: *const fn (*anyopaque) u32,
};

_canvas: CanvasHooks,
_webgl2: bool,

pub fn init(canvas: CanvasHooks, webgl2: bool) WebGLRenderingContext {
    return .{ ._canvas = canvas, ._webgl2 = webgl2 };
}

/// On Chrome and Safari, a call to `getSupportedExtensions` returns total of 39.
/// The reference for it lists lesser number of extensions:
/// https://developer.mozilla.org/en-US/docs/Web/API/WebGL_API/Using_Extensions#extension_list
pub const Extension = union(enum) {
    ANGLE_instanced_arrays: void,
    EXT_blend_minmax: void,
    EXT_clip_control: void,
    EXT_color_buffer_half_float: void,
    EXT_depth_clamp: void,
    EXT_disjoint_timer_query: void,
    EXT_float_blend: void,
    EXT_frag_depth: void,
    EXT_polygon_offset_clamp: void,
    EXT_shader_texture_lod: void,
    EXT_texture_compression_bptc: void,
    EXT_texture_compression_rgtc: void,
    EXT_texture_filter_anisotropic: *Type.EXT_texture_filter_anisotropic,
    EXT_texture_mirror_clamp_to_edge: void,
    EXT_sRGB: void,
    KHR_parallel_shader_compile: void,
    OES_element_index_uint: void,
    OES_fbo_render_mipmap: void,
    OES_standard_derivatives: void,
    OES_texture_float: void,
    OES_texture_float_linear: void,
    OES_texture_half_float: void,
    OES_texture_half_float_linear: void,
    OES_vertex_array_object: void,
    WEBGL_blend_func_extended: void,
    WEBGL_color_buffer_float: void,
    WEBGL_compressed_texture_astc: void,
    WEBGL_compressed_texture_etc: void,
    WEBGL_compressed_texture_etc1: void,
    WEBGL_compressed_texture_pvrtc: void,
    WEBGL_compressed_texture_s3tc: void,
    WEBGL_compressed_texture_s3tc_srgb: void,
    WEBGL_debug_renderer_info: *Type.WEBGL_debug_renderer_info,
    WEBGL_debug_shaders: void,
    WEBGL_depth_texture: void,
    WEBGL_draw_buffers: *Type.WEBGL_draw_buffers,
    WEBGL_lose_context: *Type.WEBGL_lose_context,
    WEBGL_multi_draw: void,
    WEBGL_polygon_mode: void,

    /// Reified enum type from the fields of this union.
    const Kind = blk: {
        const info = @typeInfo(Extension).@"union";
        const fields = info.fields;
        var items: [fields.len]std.builtin.Type.EnumField = undefined;
        for (fields, 0..) |field, i| {
            items[i] = .{ .name = field.name, .value = i };
        }

        break :blk @Type(.{
            .@"enum" = .{
                .tag_type = std.math.IntFittingRange(0, if (fields.len == 0) 0 else fields.len - 1),
                .fields = &items,
                .decls = &.{},
                .is_exhaustive = true,
            },
        });
    };

    /// Returns the `Extension.Kind` by its name.
    fn find(name: []const u8) ?Kind {
        // Just to make you really sad, this function has to be case-insensitive.
        // So here we copy what's being done in `std.meta.stringToEnum` but replace
        // the comparison function.
        const kvs = comptime build_kvs: {
            const T = Extension.Kind;
            const EnumKV = struct { []const u8, T };
            var kvs_array: [@typeInfo(T).@"enum".fields.len]EnumKV = undefined;
            for (@typeInfo(T).@"enum".fields, 0..) |enumField, i| {
                kvs_array[i] = .{ enumField.name, @field(T, enumField.name) };
            }
            break :build_kvs kvs_array[0..];
        };
        const Map = std.StaticStringMapWithEql(Extension.Kind, std.static_string_map.eqlAsciiIgnoreCase);
        const map = Map.initComptime(kvs);
        return map.get(name);
    }

    /// Extension types.
    pub const Type = struct {
        pub const WEBGL_debug_renderer_info = struct {
            _: u8 = 0,
            pub const UNMASKED_VENDOR_WEBGL: u64 = 0x9245;
            pub const UNMASKED_RENDERER_WEBGL: u64 = 0x9246;

            pub const JsApi = struct {
                pub const bridge = js.Bridge(WEBGL_debug_renderer_info);

                pub const Meta = struct {
                    pub const name = "WEBGL_debug_renderer_info";
                    pub const global_export = false;

                    pub const prototype_chain = bridge.prototypeChain();
                    pub var class_id: bridge.ClassId = undefined;
                };

                pub const UNMASKED_VENDOR_WEBGL = bridge.property(WEBGL_debug_renderer_info.UNMASKED_VENDOR_WEBGL, .{ .template = false, .readonly = true });
                pub const UNMASKED_RENDERER_WEBGL = bridge.property(WEBGL_debug_renderer_info.UNMASKED_RENDERER_WEBGL, .{ .template = false, .readonly = true });
            };
        };

        pub const WEBGL_lose_context = struct {
            _: u8 = 0,
            pub fn loseContext(_: *const WEBGL_lose_context) void {}
            pub fn restoreContext(_: *const WEBGL_lose_context) void {}

            pub const JsApi = struct {
                pub const bridge = js.Bridge(WEBGL_lose_context);

                pub const Meta = struct {
                    pub const name = "WEBGL_lose_context";
                    pub const global_export = false;

                    pub const prototype_chain = bridge.prototypeChain();
                    pub var class_id: bridge.ClassId = undefined;
                };

                pub const loseContext = bridge.function(WEBGL_lose_context.loseContext, .{ .noop = true });
                pub const restoreContext = bridge.function(WEBGL_lose_context.restoreContext, .{ .noop = true });
            };
        };

        pub const EXT_texture_filter_anisotropic = struct {
            _: u8 = 0,
            pub const MAX_TEXTURE_MAX_ANISOTROPY_EXT: u64 = 0x84FF;

            pub const JsApi = struct {
                pub const bridge = js.Bridge(EXT_texture_filter_anisotropic);

                pub const Meta = struct {
                    pub const name = "EXT_texture_filter_anisotropic";
                    pub const global_export = false;
                    pub const prototype_chain = bridge.prototypeChain();
                    pub var class_id: bridge.ClassId = undefined;
                };

                pub const MAX_TEXTURE_MAX_ANISOTROPY_EXT = bridge.property(EXT_texture_filter_anisotropic.MAX_TEXTURE_MAX_ANISOTROPY_EXT, .{ .template = false, .readonly = true });
            };
        };

        pub const WEBGL_draw_buffers = struct {
            _: u8 = 0,
            pub const MAX_DRAW_BUFFERS_WEBGL: u64 = 0x8824;

            pub const JsApi = struct {
                pub const bridge = js.Bridge(WEBGL_draw_buffers);

                pub const Meta = struct {
                    pub const name = "WEBGL_draw_buffers";
                    pub const global_export = false;
                    pub const prototype_chain = bridge.prototypeChain();
                    pub var class_id: bridge.ClassId = undefined;
                };

                pub const MAX_DRAW_BUFFERS_WEBGL = bridge.property(WEBGL_draw_buffers.MAX_DRAW_BUFFERS_WEBGL, .{ .template = false, .readonly = true });
            };
        };
    };
};

fn jsValue(value: anytype, exec: *js.Execution) !js.Value {
    return exec.js.local.?.zigValueToJs(value, .{});
}

/// Deterministic Chrome-compatible capability surface. Rendering is intentionally
/// CPU-only; callers get stable values instead of leaking the host GPU.
pub fn getParameter(self: *const WebGLRenderingContext, pname: u32, exec: *js.Execution) !js.Value {
    return switch (pname) {
        0x846D => jsValue([2]f64{ 1, 1024 }, exec), // ALIASED_POINT_SIZE_RANGE
        0x846E => jsValue([2]f64{ 1, 1 }, exec), // ALIASED_LINE_WIDTH_RANGE
        0x0B93, 0x0B98, 0x8CA4, 0x8CA5 => jsValue(@as(u64, std.math.maxInt(u32)), exec),
        0x0D33, 0x851C, 0x84E8 => jsValue(@as(u32, 16384), exec),
        0x0D3A => jsValue([2]u32{ 32767, 32767 }, exec),
        0x0D50 => jsValue(@as(u32, 4), exec),
        0x8869 => jsValue(@as(u32, 16), exec),
        0x8DFB => jsValue(@as(u32, 4096), exec),
        0x8DFC => jsValue(@as(u32, 30), exec),
        0x8B4D => jsValue(@as(u32, 32), exec),
        0x8B4C, 0x8872 => jsValue(@as(u32, 16), exec),
        0x8DFD => jsValue(@as(u32, 1024), exec),
        0x8B8C => jsValue(if (self._webgl2) "WebGL GLSL ES 3.00 (OpenGL ES GLSL ES 3.0 Chromium)" else "WebGL GLSL ES 1.0 (OpenGL ES GLSL ES 1.0 Chromium)", exec),
        0x1F00 => jsValue("WebKit", exec),
        0x1F01 => jsValue("WebKit WebGL", exec),
        0x1F02 => jsValue(if (self._webgl2) "WebGL 2.0 (OpenGL ES 3.0 Chromium)" else "WebGL 1.0 (OpenGL ES 2.0 Chromium)", exec),
        0x8069 => jsValue(@as(u32, 2048), exec),
        0x80E8, 0x80E9 => jsValue(@as(u32, std.math.maxInt(i32)), exec),
        0x84FD => jsValue(@as(f64, 2), exec),
        0x8824, 0x8CDF => jsValue(@as(u32, 8), exec),
        0x8B49 => jsValue(@as(u32, 4096), exec),
        0x8B4A => jsValue(@as(u32, 16384), exec),
        0x88FF => jsValue(@as(u32, 2048), exec),
        0x8905 => jsValue(@as(i32, 7), exec),
        0x8B4B => jsValue(@as(u32, 120), exec),
        0x8C80 => jsValue(@as(u32, 4), exec),
        0x8C8A => jsValue(@as(u32, 120), exec),
        0x8C8B => jsValue(@as(u32, 4), exec),
        0x8D57 => jsValue(@as(u32, 16), exec),
        0x8A2B, 0x8A2D => jsValue(@as(u32, 12), exec),
        0x8A2E, 0x8A2F => jsValue(@as(u32, 24), exec),
        0x8A30 => jsValue(@as(u32, 65_536), exec),
        0x8A31 => jsValue(@as(u32, 212_992), exec),
        0x8A33 => jsValue(@as(u32, 200_704), exec),
        0x9122 => jsValue(@as(u32, 120), exec),
        0x9125 => jsValue(@as(u32, 120), exec),
        0x9111, 0x9247 => jsValue(@as(u64, 0), exec),
        0x8D6B => jsValue(@as(u64, std.math.maxInt(u32) - 1), exec),
        0x9245 => jsValue("Google Inc. (Microsoft)", exec),
        0x9246 => jsValue("ANGLE (Microsoft, Microsoft Basic Render Driver (0x0000008C) Direct3D11 vs_5_0 ps_5_0, D3D11)", exec),
        0x84FF => jsValue(@as(u32, 16), exec),
        else => jsValue(null, exec),
    };
}

/// Enables a WebGL extension.
pub fn getExtension(_: *const WebGLRenderingContext, name: []const u8, exec: *js.Execution) !?Extension {
    const tag = Extension.find(name) orelse return null;

    return switch (tag) {
        .WEBGL_debug_renderer_info => {
            const info = try exec._factory.create(Extension.Type.WEBGL_debug_renderer_info{});
            return .{ .WEBGL_debug_renderer_info = info };
        },
        .WEBGL_lose_context => {
            const ctx = try exec._factory.create(Extension.Type.WEBGL_lose_context{});
            return .{ .WEBGL_lose_context = ctx };
        },
        .EXT_texture_filter_anisotropic => {
            const ctx = try exec._factory.create(Extension.Type.EXT_texture_filter_anisotropic{});
            return .{ .EXT_texture_filter_anisotropic = ctx };
        },
        .WEBGL_draw_buffers => {
            const ctx = try exec._factory.create(Extension.Type.WEBGL_draw_buffers{});
            return .{ .WEBGL_draw_buffers = ctx };
        },
        inline else => |comptime_enum| @unionInit(Extension, @tagName(comptime_enum), {}),
    };
}

/// Returns a list of all the supported WebGL extensions.
pub fn getSupportedExtensions(_: *const WebGLRenderingContext) []const []const u8 {
    return std.meta.fieldNames(Extension.Kind);
}

pub fn getCanvas(self: *const WebGLRenderingContext, exec: *js.Execution) !js.Value {
    return self._canvas.toJs(self._canvas.ptr, exec.js.local.?);
}

pub fn getDrawingBufferWidth(self: *const WebGLRenderingContext) u32 {
    return self._canvas.width(self._canvas.ptr);
}

pub fn getDrawingBufferHeight(self: *const WebGLRenderingContext) u32 {
    return self._canvas.height(self._canvas.ptr);
}

pub const ContextAttributes = struct {
    alpha: bool = true,
    antialias: bool = true,
    depth: bool = true,
    desynchronized: bool = false,
    failIfMajorPerformanceCaveat: bool = false,
    powerPreference: []const u8 = "default",
    premultipliedAlpha: bool = true,
    preserveDrawingBuffer: bool = false,
    stencil: bool = false,
    xrCompatible: bool = false,
};

pub fn getContextAttributes(_: *const WebGLRenderingContext) ContextAttributes {
    return .{};
}

pub fn clear(_: *WebGLRenderingContext, _: u32) void {}

pub fn createObject(_: *WebGLRenderingContext, exec: *js.Execution) js.Object {
    return exec.js.local.?.newObject();
}

pub fn bindBuffer(_: *WebGLRenderingContext, _: u32, _: ?js.Value) void {}
pub fn bufferData(_: *WebGLRenderingContext, _: u32, _: js.Value, _: u32) void {}
pub fn createShader(self: *WebGLRenderingContext, _: u32, exec: *js.Execution) js.Object {
    return self.createObject(exec);
}
pub fn shaderSource(_: *WebGLRenderingContext, _: js.Value, _: []const u8) void {}
pub fn compileShader(_: *WebGLRenderingContext, _: js.Value) void {}
pub fn attachShader(_: *WebGLRenderingContext, _: js.Value, _: js.Value) void {}
pub fn linkProgram(_: *WebGLRenderingContext, _: js.Value) void {}
pub fn useProgram(_: *WebGLRenderingContext, _: js.Value) void {}
pub fn getAttribLocation(_: *WebGLRenderingContext, _: js.Value, _: []const u8) i32 {
    return 0;
}
pub fn getUniformLocation(self: *WebGLRenderingContext, _: js.Value, _: []const u8, exec: *js.Execution) js.Object {
    return self.createObject(exec);
}
pub fn enableVertexAttribArray(_: *WebGLRenderingContext, _: ?u32) void {}
pub fn vertexAttribPointer(_: *WebGLRenderingContext, _: u32, _: i32, _: u32, _: bool, _: i32, _: i32) void {}
pub fn uniform2f(_: *WebGLRenderingContext, _: js.Value, _: f64, _: f64) void {}
pub fn drawArrays(_: *WebGLRenderingContext, _: u32, _: i32, _: i32) void {}

pub const ShaderPrecisionFormat = struct {
    precision: i32,
    rangeMax: i32,
    rangeMin: i32,
};

pub fn getShaderPrecisionFormat(_: *WebGLRenderingContext, shader: u32, precision: u32) ShaderPrecisionFormat {
    const integer = precision >= 0x8DF3 and precision <= 0x8DF5;
    const high = precision == 0x8DF2 or precision == 0x8DF5;
    _ = shader;
    return if (integer)
        .{ .precision = 0, .rangeMax = if (high) 30 else 15, .rangeMin = if (high) 31 else 15 }
    else
        .{ .precision = 23, .rangeMax = 127, .rangeMin = 127 };
}

pub fn readPixels(_: *WebGLRenderingContext, _: i32, _: i32, _: f64, _: f64, _: u32, _: u32, destination: js.TypedArray(u8)) void {
    // ponytail: deterministic CPU pixels; replace with ANGLE when general GPU rendering is required.
    const values = @constCast(destination.values);
    for (values, 0..) |*byte, index| byte.* = @intCast((index * 29 + 17) % 251);
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(WebGLRenderingContext);

    pub const Meta = struct {
        pub const name = "WebGLRenderingContext";

        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const getParameter = bridge.function(WebGLRenderingContext.getParameter, .{});
    pub const getExtension = bridge.function(WebGLRenderingContext.getExtension, .{});
    pub const getSupportedExtensions = bridge.function(WebGLRenderingContext.getSupportedExtensions, .{});
    pub const canvas = bridge.accessor(WebGLRenderingContext.getCanvas, null, .{});
    pub const drawingBufferWidth = bridge.accessor(WebGLRenderingContext.getDrawingBufferWidth, null, .{});
    pub const drawingBufferHeight = bridge.accessor(WebGLRenderingContext.getDrawingBufferHeight, null, .{});
    pub const getContextAttributes = bridge.function(WebGLRenderingContext.getContextAttributes, .{});
    pub const clear = bridge.function(WebGLRenderingContext.clear, .{});
    pub const createBuffer = bridge.function(WebGLRenderingContext.createObject, .{});
    pub const bindBuffer = bridge.function(WebGLRenderingContext.bindBuffer, .{});
    pub const bufferData = bridge.function(WebGLRenderingContext.bufferData, .{});
    pub const createProgram = bridge.function(WebGLRenderingContext.createObject, .{});
    pub const createShader = bridge.function(WebGLRenderingContext.createShader, .{});
    pub const shaderSource = bridge.function(WebGLRenderingContext.shaderSource, .{});
    pub const compileShader = bridge.function(WebGLRenderingContext.compileShader, .{});
    pub const attachShader = bridge.function(WebGLRenderingContext.attachShader, .{});
    pub const linkProgram = bridge.function(WebGLRenderingContext.linkProgram, .{});
    pub const useProgram = bridge.function(WebGLRenderingContext.useProgram, .{});
    pub const getAttribLocation = bridge.function(WebGLRenderingContext.getAttribLocation, .{});
    pub const getUniformLocation = bridge.function(WebGLRenderingContext.getUniformLocation, .{});
    pub const enableVertexAttribArray = bridge.function(WebGLRenderingContext.enableVertexAttribArray, .{});
    pub const vertexAttribPointer = bridge.function(WebGLRenderingContext.vertexAttribPointer, .{});
    pub const uniform2f = bridge.function(WebGLRenderingContext.uniform2f, .{});
    pub const drawArrays = bridge.function(WebGLRenderingContext.drawArrays, .{});
    pub const getShaderPrecisionFormat = bridge.function(WebGLRenderingContext.getShaderPrecisionFormat, .{});
    pub const readPixels = bridge.function(WebGLRenderingContext.readPixels, .{});

    pub const COLOR_BUFFER_BIT = bridge.property(0x4000, .{ .template = true });
    pub const ARRAY_BUFFER = bridge.property(0x8892, .{ .template = true });
    pub const STATIC_DRAW = bridge.property(0x88E4, .{ .template = true });
    pub const VERTEX_SHADER = bridge.property(0x8B31, .{ .template = true });
    pub const FRAGMENT_SHADER = bridge.property(0x8B30, .{ .template = true });
    pub const FLOAT = bridge.property(0x1406, .{ .template = true });
    pub const LINE_LOOP = bridge.property(0x0002, .{ .template = true });
    pub const RGBA = bridge.property(0x1908, .{ .template = true });
    pub const UNSIGNED_BYTE = bridge.property(0x1401, .{ .template = true });
    pub const LOW_FLOAT = bridge.property(0x8DF0, .{ .template = true });
    pub const MEDIUM_FLOAT = bridge.property(0x8DF1, .{ .template = true });
    pub const HIGH_FLOAT = bridge.property(0x8DF2, .{ .template = true });
    pub const HIGH_INT = bridge.property(0x8DF5, .{ .template = true });

    pub const ALIASED_POINT_SIZE_RANGE = bridge.property(0x846D, .{ .template = true });
    pub const ALIASED_LINE_WIDTH_RANGE = bridge.property(0x846E, .{ .template = true });
    pub const STENCIL_VALUE_MASK = bridge.property(0x0B93, .{ .template = true });
    pub const STENCIL_WRITEMASK = bridge.property(0x0B98, .{ .template = true });
    pub const STENCIL_BACK_VALUE_MASK = bridge.property(0x8CA4, .{ .template = true });
    pub const STENCIL_BACK_WRITEMASK = bridge.property(0x8CA5, .{ .template = true });
    pub const MAX_TEXTURE_SIZE = bridge.property(0x0D33, .{ .template = true });
    pub const MAX_VIEWPORT_DIMS = bridge.property(0x0D3A, .{ .template = true });
    pub const SUBPIXEL_BITS = bridge.property(0x0D50, .{ .template = true });
    pub const MAX_VERTEX_ATTRIBS = bridge.property(0x8869, .{ .template = true });
    pub const MAX_VERTEX_UNIFORM_VECTORS = bridge.property(0x8DFB, .{ .template = true });
    pub const MAX_VARYING_VECTORS = bridge.property(0x8DFC, .{ .template = true });
    pub const MAX_COMBINED_TEXTURE_IMAGE_UNITS = bridge.property(0x8B4D, .{ .template = true });
    pub const MAX_VERTEX_TEXTURE_IMAGE_UNITS = bridge.property(0x8B4C, .{ .template = true });
    pub const MAX_TEXTURE_IMAGE_UNITS = bridge.property(0x8872, .{ .template = true });
    pub const MAX_FRAGMENT_UNIFORM_VECTORS = bridge.property(0x8DFD, .{ .template = true });
    pub const SHADING_LANGUAGE_VERSION = bridge.property(0x8B8C, .{ .template = true });
    pub const VENDOR = bridge.property(0x1F00, .{ .template = true });
    pub const RENDERER = bridge.property(0x1F01, .{ .template = true });
    pub const VERSION = bridge.property(0x1F02, .{ .template = true });
    pub const MAX_CUBE_MAP_TEXTURE_SIZE = bridge.property(0x851C, .{ .template = true });
    pub const MAX_RENDERBUFFER_SIZE = bridge.property(0x84E8, .{ .template = true });
    pub const MAX_3D_TEXTURE_SIZE = bridge.property(0x8069, .{ .template = true });
    pub const MAX_ELEMENTS_VERTICES = bridge.property(0x80E8, .{ .template = true });
    pub const MAX_ELEMENTS_INDICES = bridge.property(0x80E9, .{ .template = true });
    pub const MAX_TEXTURE_LOD_BIAS = bridge.property(0x84FD, .{ .template = true });
    pub const MAX_DRAW_BUFFERS = bridge.property(0x8824, .{ .template = true });
    pub const MAX_FRAGMENT_UNIFORM_COMPONENTS = bridge.property(0x8B49, .{ .template = true });
    pub const MAX_VERTEX_UNIFORM_COMPONENTS = bridge.property(0x8B4A, .{ .template = true });
    pub const MAX_ARRAY_TEXTURE_LAYERS = bridge.property(0x88FF, .{ .template = true });
    pub const MAX_PROGRAM_TEXEL_OFFSET = bridge.property(0x8905, .{ .template = true });
    pub const MAX_VARYING_COMPONENTS = bridge.property(0x8B4B, .{ .template = true });
    pub const MAX_TRANSFORM_FEEDBACK_SEPARATE_COMPONENTS = bridge.property(0x8C80, .{ .template = true });
    pub const MAX_TRANSFORM_FEEDBACK_INTERLEAVED_COMPONENTS = bridge.property(0x8C8A, .{ .template = true });
    pub const MAX_TRANSFORM_FEEDBACK_SEPARATE_ATTRIBS = bridge.property(0x8C8B, .{ .template = true });
    pub const MAX_COLOR_ATTACHMENTS = bridge.property(0x8CDF, .{ .template = true });
    pub const MAX_SAMPLES = bridge.property(0x8D57, .{ .template = true });
    pub const MAX_VERTEX_UNIFORM_BLOCKS = bridge.property(0x8A2B, .{ .template = true });
    pub const MAX_FRAGMENT_UNIFORM_BLOCKS = bridge.property(0x8A2D, .{ .template = true });
    pub const MAX_COMBINED_UNIFORM_BLOCKS = bridge.property(0x8A2E, .{ .template = true });
    pub const MAX_UNIFORM_BUFFER_BINDINGS = bridge.property(0x8A2F, .{ .template = true });
    pub const MAX_UNIFORM_BLOCK_SIZE = bridge.property(0x8A30, .{ .template = true });
    pub const MAX_COMBINED_VERTEX_UNIFORM_COMPONENTS = bridge.property(0x8A31, .{ .template = true });
    pub const MAX_COMBINED_FRAGMENT_UNIFORM_COMPONENTS = bridge.property(0x8A33, .{ .template = true });
    pub const MAX_VERTEX_OUTPUT_COMPONENTS = bridge.property(0x9122, .{ .template = true });
    pub const MAX_FRAGMENT_INPUT_COMPONENTS = bridge.property(0x9125, .{ .template = true });
    pub const MAX_SERVER_WAIT_TIMEOUT = bridge.property(0x9111, .{ .template = true });
    pub const MAX_ELEMENT_INDEX = bridge.property(0x8D6B, .{ .template = true });
    pub const MAX_CLIENT_WAIT_TIMEOUT_WEBGL = bridge.property(0x9247, .{ .template = true });
};

const testing = @import("../../../testing.zig");
test "WebApi: WebGLRenderingContext" {
    try testing.htmlRunner("canvas/webgl_rendering_context.html", .{});
}
