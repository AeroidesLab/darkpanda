// Copyright (C) 2026 DarkPanda contributors

//! Resolve paths relative to the native image containing DarkPanda code.
//!
//! Embedders such as Python and Node live in a different directory from
//! darkpanda.dll/libdarkpanda, so process-executable-relative lookup is not a
//! valid way to locate packaged runtime libraries.

const std = @import("std");
const builtin = @import("builtin");

const windows = std.os.windows;

const DlInfo = extern struct {
    file_name: ?[*:0]const u8,
    base_address: ?*anyopaque,
    symbol_name: ?[*:0]const u8,
    symbol_address: ?*anyopaque,
};

extern fn dladdr(address: ?*const anyopaque, info: *DlInfo) callconv(.c) c_int;

const get_module_handle_ex_flag_unchanged_refcount: windows.DWORD = 0x00000002;
const get_module_handle_ex_flag_from_address: windows.DWORD = 0x00000004;

extern "kernel32" fn GetModuleHandleExW(
    flags: windows.DWORD,
    address: ?*const anyopaque,
    out_module: *?windows.HMODULE,
) callconv(.winapi) windows.BOOL;

pub fn directoryPathAlloc(allocator: std.mem.Allocator) ![]u8 {
    if (comptime builtin.os.tag != .windows) {
        var info: DlInfo = .{
            .file_name = null,
            .base_address = null,
            .symbol_name = null,
            .symbol_address = null,
        };
        if (dladdr(@ptrCast(&moduleAddressAnchor), &info) == 0) {
            return error.ModulePathUnavailable;
        }
        const module_path = std.mem.span(info.file_name orelse return error.ModulePathUnavailable);
        const directory = std.fs.path.dirname(module_path) orelse
            return error.ModulePathUnavailable;
        return allocator.dupe(u8, directory);
    }

    var module: ?windows.HMODULE = null;
    const flags = get_module_handle_ex_flag_from_address |
        get_module_handle_ex_flag_unchanged_refcount;
    if (GetModuleHandleExW(flags, @ptrCast(&moduleAddressAnchor), &module) == 0) {
        return error.ModulePathUnavailable;
    }

    var module_path_w: [windows.PATH_MAX_WIDE:0]u16 = undefined;
    const path_w = try windows.GetModuleFileNameW(
        module orelse return error.ModulePathUnavailable,
        &module_path_w,
        @intCast(module_path_w.len),
    );
    const module_path = try std.unicode.wtf16LeToWtf8Alloc(allocator, path_w);
    defer allocator.free(module_path);

    const directory = std.fs.path.dirname(module_path) orelse
        return error.ModulePathUnavailable;
    return allocator.dupe(u8, directory);
}

pub fn adjacentPathAlloc(
    allocator: std.mem.Allocator,
    library_name: []const u8,
) ![]u8 {
    const directory = try directoryPathAlloc(allocator);
    defer allocator.free(directory);
    return std.fs.path.join(allocator, &.{ directory, library_name });
}

noinline fn moduleAddressAnchor() void {}
