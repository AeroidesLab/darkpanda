const std = @import("std");
const canvas = @import("canvas_backend/adapter.zig");

pub fn main() !void {
    var allocator_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = allocator_state.deinit();
    const allocator = allocator_state.allocator();

    var api = try canvas.Api.openConfigured(allocator);
    defer api.close();

    try std.testing.expectEqual(@as(u32, 2), canvas.abi_version);
    try std.testing.expect(std.mem.indexOf(u8, api.version(), "rust-skia/0.99.0") != null);

    try exerciseBackend(&api, .skia);
    try exerciseBackend(&api, .fake);
    try exerciseStableFake(&api);
    try exerciseChrome149SkiaPixels(&api);

    std.debug.print("canvas backend ABI smoke: PASS ({s})\n", .{api.version()});
}

fn exerciseBackend(api: *const canvas.Api, kind: canvas.BackendKind) !void {
    const descriptor: canvas.SurfaceDescriptor = .{
        .backend_kind = kind,
        .width = 4,
        .height = 3,
        .profile_seed = 0x1020_3040_5060_7080,
        .canvas_seed = 0x8877_6655_4433_2211,
    };
    var surface = try api.create(&descriptor);
    defer surface.deinit() catch unreachable;

    const info = try surface.info();
    try std.testing.expectEqual(kind, info.backend_kind);
    try std.testing.expectEqual(@as(u32, 4), info.width);
    try std.testing.expectEqual(@as(u32, 3), info.height);
    try std.testing.expectEqual(@as(u32, 16), info.canonical_row_bytes);
    try std.testing.expectEqual(canvas.PixelFormat.rgba8_premul_srgb, info.pixel_format);

    try surface.clear(.{ .r = 255, .g = 0, .b = 0, .a = 128 });
    var strided: [56]u8 = @splat(0xa5);
    try surface.readPixels(0, 0, 4, 3, &strided, 20);
    for (0..3) |row| {
        for (0..4) |column| {
            const offset = row * 20 + column * 4;
            try std.testing.expectEqualSlices(u8, &.{ 128, 0, 0, 128 }, strided[offset .. offset + 4]);
        }
        if (row != 2) {
            try std.testing.expectEqualSlices(u8, &.{ 0xa5, 0xa5, 0xa5, 0xa5 }, strided[row * 20 + 16 .. row * 20 + 20]);
        }
    }

    try surface.fillRect(-1, 1, 3, 1, .{ .r = 0, .g = 255, .b = 0, .a = 255 }, 1);
    var row: [16]u8 = undefined;
    try surface.readPixels(0, 1, 4, 1, &row, 16);
    try std.testing.expectEqualSlices(u8, &.{ 0, 255, 0, 255, 0, 255, 0, 255 }, row[0..8]);
    try std.testing.expectEqualSlices(u8, &.{ 128, 0, 0, 128, 128, 0, 0, 128 }, row[8..16]);

    try surface.clearRect(0, 1, 1, 1);
    try surface.readPixels(0, 1, 4, 1, &row, 16);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, row[0..4]);

    const written = [_]u8{ 7, 6, 5, 8 };
    try surface.writePixels(3, 2, 1, 1, &written, 4);
    var round_trip: [4]u8 = undefined;
    try surface.readPixels(3, 2, 1, 1, &round_trip, 4);
    try std.testing.expectEqualSlices(u8, &written, &round_trip);

    try surface.resize(0, 0);
    const zero_info = try surface.info();
    try std.testing.expectEqual(@as(u32, 0), zero_info.width);
    try std.testing.expectEqual(@as(u32, 0), zero_info.canonical_row_bytes);
}

fn exerciseStableFake(api: *const canvas.Api) !void {
    const descriptor: canvas.SurfaceDescriptor = .{
        .backend_kind = .fake,
        .width = 4,
        .height = 3,
        .profile_seed = 12345,
        .canvas_seed = 67890,
    };
    var first = try api.create(&descriptor);
    defer first.deinit() catch unreachable;
    var second = try api.create(&descriptor);
    defer second.deinit() catch unreachable;

    var baseline: [48]u8 = undefined;
    var repeated: [48]u8 = undefined;
    var same_seed: [48]u8 = undefined;
    try first.readPixels(0, 0, 4, 3, &baseline, 16);
    try first.readPixels(0, 0, 4, 3, &repeated, 16);
    try second.readPixels(0, 0, 4, 3, &same_seed, 16);
    try std.testing.expectEqualSlices(u8, &baseline, &repeated);
    try std.testing.expectEqualSlices(u8, &baseline, &same_seed);

    try first.resize(2, 2);
    try first.resize(4, 3);
    try first.readPixels(0, 0, 4, 3, &repeated, 16);
    try std.testing.expectEqualSlices(u8, &baseline, &repeated);
}

fn exerciseChrome149SkiaPixels(api: *const canvas.Api) !void {
    const descriptor: canvas.SurfaceDescriptor = .{
        .backend_kind = .skia,
        .width = 2,
        .height = 1,
        .profile_seed = 1,
        .canvas_seed = 2,
    };
    var surface = try api.create(&descriptor);
    defer surface.deinit() catch unreachable;

    try surface.clear(.{ .r = 0, .g = 0, .b = 0, .a = 0 });
    try surface.fillRect(0, 0, 1, 1, .{ .r = 17, .g = 99, .b = 201, .a = 255 }, 0.5);
    var pixels: [8]u8 = undefined;
    try surface.readPixels(0, 0, 2, 1, &pixels, 8);
    // Direct rust-skia stores [9, 50, 101, 128] here. Chrome149's accelerated
    // Windows Canvas probe exposes a slightly darker [16, 98, 199, 128] after
    // unpremultiplication; keep this explicit so a future Skia/profile upgrade
    // can close the remaining raster-pipeline delta without changing the
    // ImageData boundary contract.
    try std.testing.expectEqualSlices(u8, &.{ 9, 50, 101, 128 }, pixels[0..4]);

    try surface.clear(.{ .r = 0, .g = 0, .b = 0, .a = 0 });
    try surface.fillRect(0, 0, 0.5, 1, .{ .r = 255, .g = 0, .b = 0, .a = 255 }, 1);
    try surface.readPixels(0, 0, 2, 1, &pixels, 8);
    // CPU rust-skia analytic AA is 127/255 here; the Chrome149 accelerated
    // Windows probe is 96/255. This smoke pins the selected CPU backend rather
    // than pretending the two raster pipelines are byte-identical.
    try std.testing.expectEqualSlices(u8, &.{ 127, 0, 0, 127 }, pixels[0..4]);

    try surface.clear(.{ .r = 17, .g = 99, .b = 201, .a = 255 });
    try surface.clearRect(0, 0, 0.25, 1);
    try surface.readPixels(0, 0, 1, 1, pixels[0..4], 4);
    try std.testing.expectEqualSlices(u8, &.{ 17, 99, 201, 255 }, pixels[0..4]);
    try surface.clearRect(0, 0, 0.5, 1);
    try surface.readPixels(0, 0, 1, 1, pixels[0..4], 4);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, pixels[0..4]);
}
