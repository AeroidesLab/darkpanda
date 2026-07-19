// Copyright (C) 2023-2024  Lightpanda (Selecy SAS)
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
const builtin = @import("builtin");

const darkpanda_version = std.SemanticVersion.parse(@import("build.zig.zon").version) catch unreachable;
const min_zig_version = std.SemanticVersion.parse(@import("build.zig.zon").minimum_zig_version) catch unreachable;

const Build = blk: {
    if (builtin.zig_version.order(min_zig_version) == .lt) {
        const message = std.fmt.comptimePrint(
            \\Zig version is too old:
            \\  current Zig version: {f}
            \\  minimum Zig version: {f}
        , .{ builtin.zig_version, min_zig_version });
        @compileError(message);
    } else {
        break :blk std.Build;
    }
};

pub fn build(b: *Build) !void {
    // A native Windows target without an explicit ABI resolves to `.none` in
    // Zig's target query.  DarkPanda's V8, BoringSSL and Rust DLL boundary is
    // deliberately MSVC `/MT`, so make that ABI the native Windows default
    // while preserving `-Dtarget=...` overrides and all non-Windows defaults.
    const default_target: std.Target.Query = if (builtin.target.os.tag == .windows)
        .{
            .cpu_arch = builtin.target.cpu.arch,
            .os_tag = .windows,
            .abi = .msvc,
        }
    else
        .{};
    const target = b.standardTargetOptions(.{ .default_target = default_target });
    const optimize = b.standardOptimizeOption(.{});
    const strip_release = optimize != .Debug;
    const cargo_path = b.option(
        []const u8,
        "cargo_path",
        "Exact Cargo executable used for all Rust dependencies",
    ) orelse "cargo";
    const canvas_backend_target_dir = b.option(
        []const u8,
        "canvas_backend_target_dir",
        "Explicit Cargo target directory for the Canvas backend",
    );

    // Canvas is an optional runtime-loaded component. These explicit steps do
    // not make the large Skia dependency part of the default browser build.
    try addCanvasBackendSteps(b, target, optimize, cargo_path, canvas_backend_target_dir);
    const canvas_only = b.option(
        bool,
        "canvas_only",
        "Construct only Canvas build/smoke steps (do not inspect V8, wreq, or browser caches)",
    ) orelse false;
    if (canvas_only) return;

    const prebuilt_v8_path = b.option(
        []const u8,
        "prebuilt_v8_path",
        "Path to prebuilt libc_v8.a or complete Windows c_v8_standalone.lib",
    );
    const prebuilt_wreq_library = b.option(
        []const u8,
        "prebuilt_wreq_library",
        "Path to a prebuilt DarkPanda wreq shared library",
    );
    const wreq_transport_target_dir = b.option(
        []const u8,
        "wreq_transport_target_dir",
        "Explicit Cargo target directory for source-built wreq_transport",
    );
    const prebuilt_boringssl_dir = b.option(
        []const u8,
        "prebuilt_boringssl_dir",
        "Windows directory containing MSVC /MT crypto.lib for WebCrypto (TLS uses wreq)",
    );
    const snapshot_path = b.option([]const u8, "snapshot_path", "Path to v8 snapshot");
    const wpt_extensions = b.option(bool, "wpt_extensions", "Extend WebAPI with WPT driver behavior") orelse false;
    const test_cdp_port = b.option(
        u16,
        "test_cdp_port",
        "CDP listen port used only by the unit-test harness",
    ) orelse 9583;

    const version = resolveVersion(b);
    var stderr = std.fs.File.stderr().writer(&.{});
    try stderr.interface.print("DarkPanda {f}\n", .{version});

    const version_string = b.fmt("{f}", .{version});
    const version_encoded = std.mem.replaceOwned(u8, b.allocator, version_string, "+", "%2B") catch @panic("OOM");

    var opts = b.addOptions();
    opts.addOption([]const u8, "version", version_string);
    opts.addOption([]const u8, "version_encoded", version_encoded);
    opts.addOption(?[]const u8, "snapshot_path", snapshot_path);
    opts.addOption(bool, "wpt_extensions", wpt_extensions);
    opts.addOption(u16, "test_cdp_port", test_cdp_port);

    const enable_tsan = b.option(bool, "tsan", "Enable Thread Sanitizer") orelse false;
    const enable_asan = b.option(bool, "asan", "Enable Address Sanitizer") orelse false;
    const enable_csan = b.option(std.zig.SanitizeC, "csan", "Enable C Sanitizers");

    const wreq_transport_artifact = try buildWreqTransport(
        b,
        target.result,
        optimize,
        prebuilt_wreq_library,
        wreq_transport_target_dir,
        cargo_path,
    );

    var html5ever_artifact: ?Html5EverArtifact = null;
    const darkpanda_module = blk: {
        const mod = b.addModule("darkpanda", .{
            .root_source_file = b.path("src/darkpanda.zig"),
            .target = target,
            .optimize = optimize,
            .strip = strip_release,
            .link_libc = true,
            // The Windows c_v8.lib is built against MSVC's static STL (/MT).
            // Linking Zig's libc++/libc++abi into that MSVC ABI boundary would
            // mix two C++ runtimes and conflict with vcruntime_typeinfo.h.
            .link_libcpp = target.result.os.tag != .windows,
            .sanitize_c = enable_csan,
            .sanitize_thread = enable_tsan,
        });
        if (target.result.os.tag == .linux) {
            mod.linkSystemLibrary("dl", .{});
        }
        mod.addImport("darkpanda", mod); // allow circular "darkpanda" import
        mod.addImport("build_config", opts.createModule());

        // Format check
        const fmt_step = b.step("fmt", "Check code formatting");
        const fmt = b.addFmt(.{
            .paths = &.{ "src", "build.zig", "build.zig.zon" },
            .check = true,
        });
        fmt_step.dependOn(&fmt.step);

        // Formatting is an explicit CI/developer gate, not an install input.
        // The same source checkout may be mounted into WSL with Windows CRLF;
        // that must not make a native Linux artifact graph differ from the
        // Windows graph. Run `zig build fmt` in a normalized checkout.

        try linkV8(b, mod, enable_asan, enable_tsan, prebuilt_v8_path);
        try linkWebCrypto(b, mod, prebuilt_boringssl_dir);
        html5ever_artifact = try linkHtml5Ever(b, mod, cargo_path);

        if (target.result.os.tag == .windows) {
            const f128_shims = b.addObject(.{
                .name = "windows_f128_shims",
                .root_module = b.createModule(.{
                    .root_source_file = b.path("src/windows_f128_shims.zig"),
                    .target = target,
                    .optimize = optimize,
                    .link_libc = true,
                }),
            });
            f128_shims.bundle_compiler_rt = false;
            mod.addObject(f128_shims);
        }

        break :blk mod;
    };

    linkSqlite(b, darkpanda_module, enable_csan, enable_tsan);

    // Check compilation
    const check = b.step("check", "Check if DarkPanda compiles");

    const check_lib = b.addLibrary(.{
        .name = "darkpanda_check",
        .root_module = darkpanda_module,
    });
    check.dependOn(&check_lib.step);

    // Extras (snapshot_creator) are off the default install to
    // avoid paying for three exe compiles on every edit. Build explicitly
    // with `zig build extras`.
    const extras_step = b.step("extras", "Build snapshot_creator");

    {
        // browser
        const exe = b.addExecutable(.{
            .name = "darkpanda",
            .use_llvm = true,
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = target,
                .optimize = optimize,
                .strip = strip_release,
                .sanitize_c = enable_csan,
                .sanitize_thread = enable_tsan,
                .imports = &.{
                    .{ .name = "darkpanda", .module = darkpanda_module },
                },
            }),
        });
        switch (target.result.os.tag) {
            .linux => {
                // The html parser is installed beside the executable. Make
                // the installed artifact self-contained without
                // LD_LIBRARY_PATH.
                exe.root_module.addRPathSpecial("$ORIGIN");
            },
            .macos => {
                // Portable archives keep every dylib next to the executable.
                // Resolve the Rust html5ever boundary from that directory
                // instead of retaining the CI runner's temporary path.
                exe.root_module.addRPathSpecial("@loader_path");
            },
            else => {},
        }
        // html5ever is isolated in a shared library so its Cargo Rust runtime
        // never collides with Chromium's. Keep Zig compiler-rt enabled: the
        // Chromium clang_rt archive intentionally lacks Zig's binary128 ABI
        // helpers (__netf2, __multf3, and related symbols).
        b.installArtifact(exe);
        b.getInstallStep().dependOn(&wreq_transport_artifact.install.step);
        if (html5ever_artifact) |artifact| {
            b.getInstallStep().dependOn(&artifact.install.step);
        }

        const exe_check = b.addLibrary(.{
            .name = "darkpanda_exe_check",
            .root_module = exe.root_module,
        });
        check.dependOn(&exe_check.step);

        const run_cmd = b.addRunArtifact(exe);
        run_cmd.step.dependOn(&wreq_transport_artifact.install.step);
        run_cmd.setEnvironmentVariable(
            "DARKPANDA_WREQ_LIBRARY",
            b.getInstallPath(.bin, wreqLibraryName(target.result.os.tag)),
        );
        if (html5ever_artifact) |artifact| {
            run_cmd.step.dependOn(&artifact.install.step);
            run_cmd.setEnvironmentVariable("PATH", b.getInstallPath(.bin, ""));
        }
        if (b.args) |args| {
            run_cmd.addArgs(args);
        }
        const run_step = b.step("run", "Run the app");
        run_step.dependOn(&run_cmd.step);

        const version_info_step = b.step("version", "Print the resolved version information");
        const version_info_run = b.addRunArtifact(exe);
        version_info_run.addArg("version");
        version_info_step.dependOn(&version_info_run.step);
    }

    {
        // Stable native C ABI. The root module exports only direct embedding
        // calls; no CDP server, localhost socket or subprocess is involved.
        const ffi_module = b.createModule(.{
            .root_source_file = b.path("src/ffi.zig"),
            .target = target,
            .optimize = optimize,
            .strip = strip_release,
            .sanitize_c = enable_csan,
            .sanitize_thread = enable_tsan,
            .imports = &.{
                .{ .name = "darkpanda", .module = darkpanda_module },
            },
        });
        switch (target.result.os.tag) {
            .linux => {
                // Python loads libdarkpanda.so by absolute path. Its implicit
                // html5ever dependency must resolve from that same directory.
                ffi_module.addRPathSpecial("$ORIGIN");
            },
            .macos => {
                // Python loads libdarkpanda.dylib by absolute path. Resolve
                // its sibling html5ever dylib from the portable bundle.
                ffi_module.addRPathSpecial("@loader_path");
            },
            else => {},
        }
        const ffi_lib = b.addLibrary(.{
            .name = "darkpanda",
            .linkage = .dynamic,
            .use_llvm = true,
            .root_module = ffi_module,
        });
        // Keep the browser, embedding ABI, wreq and Canvas runtime libraries
        // in one module-adjacent directory on every platform. Unix's default
        // would put a dynamic library in lib/, breaking deterministic dlopen
        // lookup from both the executable and Python embedding boundary.
        const ffi_install = b.addInstallArtifact(ffi_lib, .{
            .dest_dir = .{ .override = .bin },
        });
        b.getInstallStep().dependOn(&ffi_install.step);
        const header_install = b.addInstallHeaderFile(b.path("include/darkpanda.h"), "darkpanda.h");
        b.getInstallStep().dependOn(&header_install.step);

        const ffi_step = b.step("ffi", "Build and install the native C ABI library");
        ffi_step.dependOn(&ffi_install.step);
        ffi_step.dependOn(&header_install.step);
        ffi_step.dependOn(&wreq_transport_artifact.install.step);
        if (html5ever_artifact) |artifact| ffi_step.dependOn(&artifact.install.step);

        // Compile-only coverage for the C ABI root is part of `zig build check`.
        // A static library avoids requiring a runnable/new V8 DLL at this step.
        const ffi_check = b.addLibrary(.{
            .name = "darkpanda_ffi_check",
            .root_module = ffi_module,
        });
        check.dependOn(&ffi_check.step);
    }

    {
        // snapshot creator
        const exe = b.addExecutable(.{
            .name = "darkpanda-snapshot-creator",
            .use_llvm = true,
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main_snapshot_creator.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "darkpanda", .module = darkpanda_module },
                },
            }),
        });
        extras_step.dependOn(&b.addInstallArtifact(exe, .{}).step);

        const exe_check = b.addLibrary(.{
            .name = "snapshot_creator_check",
            .root_module = exe.root_module,
        });
        check.dependOn(&exe_check.step);

        const run_cmd = b.addRunArtifact(exe);
        if (b.args) |args| {
            run_cmd.addArgs(args);
        }
        const run_step = b.step("snapshot_creator", "Generate a v8 snapshot");
        run_step.dependOn(&run_cmd.step);
    }

    {
        // test
        const tests = b.addTest(.{
            .root_module = darkpanda_module,
            .use_llvm = true,
            .test_runner = .{ .path = b.path("src/test_runner.zig"), .mode = .simple },
        });
        const run_tests = b.addRunArtifact(tests);
        run_tests.step.dependOn(&wreq_transport_artifact.install.step);
        run_tests.setEnvironmentVariable(
            "DARKPANDA_WREQ_LIBRARY",
            b.getInstallPath(.bin, wreqLibraryName(target.result.os.tag)),
        );
        if (html5ever_artifact) |artifact| {
            run_tests.step.dependOn(&artifact.install.step);
            run_tests.setEnvironmentVariable("PATH", b.getInstallPath(.bin, ""));
        }
        const test_compile_step = b.step("test-compile", "Compile unit tests without running them");
        test_compile_step.dependOn(&tests.step);
        const test_step = b.step("test", "Run unit tests");
        test_step.dependOn(&run_tests.step);
    }
}

const CargoBuildProfile = struct {
    name: []const u8,
    output_dir: []const u8,
};

fn addCanvasBackendSteps(
    b: *Build,
    target: Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    cargo_path: []const u8,
    target_dir: ?[]const u8,
) !void {
    const rust_target = canvasBackendRustTarget(target.result);
    const profile = cargoBuildProfile(optimize == .Debug);
    const library_name = canvasBackendLibraryName(target.result.os.tag);

    const exec_cargo = b.addSystemCommand(&.{
        cargo_path,                      "build",
        "--locked",                      "--profile",
        profile.name,                    "--manifest-path",
        "src/canvas_backend/Cargo.toml", "--target",
        rust_target,
    });
    for ([_][]const u8{
        "src/canvas_backend/Cargo.toml",
        "src/canvas_backend/Cargo.lock",
        "src/canvas_backend/src/lib.rs",
        "src/canvas_backend/include/darkpanda_canvas_backend.h",
    }) |path| {
        exec_cargo.addFileInput(b.path(path));
    }
    const library: Build.LazyPath = if (target_dir) |path| blk: {
        exec_cargo.addArgs(&.{ "--target-dir", path });
        break :blk .{ .cwd_relative = b.pathJoin(&.{
            path,
            rust_target,
            profile.output_dir,
            library_name,
        }) };
    } else blk: {
        var out_dir = exec_cargo.addPrefixedOutputDirectoryArg("--target-dir=", "canvas_backend");
        out_dir = out_dir.path(b, rust_target);
        out_dir = out_dir.path(b, profile.output_dir);
        break :blk out_dir.path(b, library_name);
    };

    const install_library = b.addInstallBinFile(library, library_name);
    install_library.step.dependOn(&exec_cargo.step);
    const install_header = b.addInstallHeaderFile(
        b.path("src/canvas_backend/include/darkpanda_canvas_backend.h"),
        "darkpanda_canvas_backend.h",
    );
    const backend_step = b.step(
        "canvas-backend",
        "Build and install the optional rust-skia/fake Canvas backend",
    );
    backend_step.dependOn(&install_library.step);
    backend_step.dependOn(&install_header.step);

    const smoke = b.addExecutable(.{
        .name = "canvas_backend_abi_smoke",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/canvas_backend_smoke.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    if (target.result.os.tag != .windows) {
        smoke.linkLibC();
        if (target.result.os.tag == .linux) {
            smoke.linkSystemLibrary("dl");
        }
    }
    const run_smoke = b.addRunArtifact(smoke);
    run_smoke.step.dependOn(&install_library.step);
    run_smoke.setEnvironmentVariable(
        "DARKPANDA_CANVAS_BACKEND_LIBRARY",
        b.getInstallPath(.bin, library_name),
    );
    const smoke_step = b.step(
        "canvas-backend-smoke",
        "Build Canvas backend and run its Zig ABI smoke test",
    );
    smoke_step.dependOn(&run_smoke.step);
}

fn canvasBackendRustTarget(target: std.Target) []const u8 {
    return switch (target.os.tag) {
        .windows => switch (target.cpu.arch) {
            .x86_64 => if (target.abi == .msvc)
                "x86_64-pc-windows-msvc"
            else
                @panic("Canvas backend supports native Windows through the MSVC ABI"),
            .aarch64 => if (target.abi == .msvc)
                "aarch64-pc-windows-msvc"
            else
                @panic("Canvas backend supports native Windows through the MSVC ABI"),
            else => @panic("unsupported Windows architecture for Canvas backend"),
        },
        .linux => switch (target.cpu.arch) {
            .x86_64 => if (target.abi == .musl)
                "x86_64-unknown-linux-musl"
            else
                "x86_64-unknown-linux-gnu",
            .aarch64 => if (target.abi == .musl)
                "aarch64-unknown-linux-musl"
            else
                "aarch64-unknown-linux-gnu",
            else => @panic("unsupported Linux architecture for Canvas backend"),
        },
        .macos => switch (target.cpu.arch) {
            .x86_64 => "x86_64-apple-darwin",
            .aarch64 => "aarch64-apple-darwin",
            else => @panic("unsupported macOS architecture for Canvas backend"),
        },
        else => @panic("Canvas backend supports Windows, Linux, and macOS"),
    };
}

fn canvasBackendLibraryName(os: std.Target.Os.Tag) []const u8 {
    return switch (os) {
        .windows => "darkpanda_canvas_backend.dll",
        .macos => "libdarkpanda_canvas_backend.dylib",
        else => "libdarkpanda_canvas_backend.so",
    };
}

fn cargoBuildProfile(is_debug: bool) CargoBuildProfile {
    return if (is_debug)
        .{ .name = "dev", .output_dir = "debug" }
    else
        .{ .name = "release", .output_dir = "release" };
}

test "Cargo built-in profile output directories" {
    const debug = cargoBuildProfile(true);
    try std.testing.expectEqualStrings("dev", debug.name);
    try std.testing.expectEqualStrings("debug", debug.output_dir);

    const release = cargoBuildProfile(false);
    try std.testing.expectEqualStrings("release", release.name);
    try std.testing.expectEqualStrings("release", release.output_dir);
}

const WreqTransportArtifact = struct {
    dll: Build.LazyPath,
    install: *Build.Step.InstallFile,
};

fn buildWreqTransport(
    b: *Build,
    target: std.Target,
    optimize: std.builtin.OptimizeMode,
    prebuilt_dll: ?[]const u8,
    target_dir: ?[]const u8,
    cargo_path: []const u8,
) !WreqTransportArtifact {
    var cargo_step: ?*Build.Step = null;
    const installed_library_name = wreqLibraryName(target.os.tag);
    const cargo_library_name = wreqCargoLibraryName(target.os.tag);
    const dll: Build.LazyPath = if (prebuilt_dll) |path|
        .{ .cwd_relative = path }
    else blk: {
        const rust_target = wreqRustTarget(target);
        const profile = cargoBuildProfile(optimize == .Debug);
        const exec_cargo = b.addSystemCommand(&.{
            cargo_path,                      "build",
            "--locked",                      "--profile",
            profile.name,                    "--manifest-path",
            "src/wreq_transport/Cargo.toml", "--target",
            rust_target,
        });
        for ([_][]const u8{
            "src/wreq_transport/Cargo.toml",
            "src/wreq_transport/Cargo.lock",
            "src/wreq_transport/src/lib.rs",
            "src/wreq_transport/include/wreq_transport.h",
        }) |path| {
            exec_cargo.addFileInput(b.path(path));
        }
        if (target_dir) |path| {
            exec_cargo.addArgs(&.{ "--target-dir", path });
            cargo_step = &exec_cargo.step;
            break :blk .{ .cwd_relative = b.pathJoin(&.{
                path,
                rust_target,
                profile.output_dir,
                cargo_library_name,
            }) };
        }
        var out_dir = exec_cargo.addPrefixedOutputDirectoryArg("--target-dir=", "wreq_transport");
        out_dir = out_dir.path(b, rust_target);
        out_dir = out_dir.path(b, profile.output_dir);
        break :blk out_dir.path(b, cargo_library_name);
    };

    const install = b.addInstallBinFile(dll, installed_library_name);
    if (cargo_step) |step| install.step.dependOn(step);
    return .{ .dll = dll, .install = install };
}

fn wreqLibraryName(os_tag: std.Target.Os.Tag) []const u8 {
    return switch (os_tag) {
        .windows => "wreq.dll",
        .macos => "libwreq.dylib",
        else => "libwreq.so",
    };
}

// Keep Cargo's crate/output name distinct from the public runtime filename.
// Naming this Rust crate `wreq` would shadow the upstream `wreq` dependency
// throughout lib.rs. The install step above performs the public rename.
fn wreqCargoLibraryName(os_tag: std.Target.Os.Tag) []const u8 {
    return switch (os_tag) {
        .windows => "wreq_transport.dll",
        .macos => "libwreq_transport.dylib",
        else => "libwreq_transport.so",
    };
}

fn wreqRustTarget(target: std.Target) []const u8 {
    return switch (target.os.tag) {
        .windows => switch (target.cpu.arch) {
            .x86_64 => if (target.abi == .msvc) "x86_64-pc-windows-msvc" else @panic("wreq Windows requires MSVC"),
            .aarch64 => if (target.abi == .msvc) "aarch64-pc-windows-msvc" else @panic("wreq Windows requires MSVC"),
            else => @panic("unsupported Windows architecture for wreq"),
        },
        .linux => switch (target.cpu.arch) {
            .x86_64 => if (target.abi == .musl) "x86_64-unknown-linux-musl" else "x86_64-unknown-linux-gnu",
            .aarch64 => if (target.abi == .musl) "aarch64-unknown-linux-musl" else "aarch64-unknown-linux-gnu",
            else => @panic("unsupported Linux architecture for wreq"),
        },
        .macos => switch (target.cpu.arch) {
            .x86_64 => "x86_64-apple-darwin",
            .aarch64 => "aarch64-apple-darwin",
            else => @panic("unsupported macOS architecture for wreq"),
        },
        else => @panic("wreq transport supports Windows, Linux, and macOS"),
    };
}

fn linkV8(
    b: *Build,
    mod: *Build.Module,
    is_asan: bool,
    is_tsan: bool,
    prebuilt_v8_path: ?[]const u8,
) !void {
    const target = mod.resolved_target.?;

    const dep = b.dependency("v8", .{
        .target = target,
        .optimize = mod.optimize.?,
        .is_asan = is_asan,
        .is_tsan = is_tsan,
        .inspector_subtype = false,
        .v8_enable_sandbox = is_tsan or
            (target.result.os.tag == .windows and target.result.cpu.arch == .x86_64),
        .cache_root = b.pathFromRoot(".lp-cache"),
        .prebuilt_v8_path = prebuilt_v8_path,
    });
    const v8_module = dep.module("v8");
    if (target.result.os.tag == .windows) {
        // Keep the CRT libraries after c_v8.lib in link order. Chromium's
        // allocator shim defines malloc/calloc/free itself; placing ucrt.lib
        // before c_v8 would select duplicate heap import thunks.
        addWindowsRuntimeLibrariesAfterV8(b, v8_module, target.result);
    }
    mod.addImport("v8", v8_module);
}

fn addWindowsRuntimeLibrariesAfterV8(b: *Build, mod: *Build.Module, target: std.Target) void {
    mod.linkSystemLibrary("libvcruntime", .{});
    const windows_sdk = std.zig.WindowsSdk.find(b.allocator, target.cpu.arch) catch @panic(
        "Windows SDK with UCRT libraries was not found",
    );
    defer windows_sdk.free(b.allocator);
    const sdk = windows_sdk.windows10sdk orelse @panic("Windows 10/11 SDK was not found");
    const sdk_arch = switch (target.cpu.arch) {
        .x86_64 => "x64",
        .x86 => "x86",
        .aarch64 => "arm64",
        else => @panic("unsupported Windows architecture for UCRT"),
    };
    const ucrt_lib_dir = b.pathJoin(&.{ sdk.path, "Lib", sdk.version, "ucrt", sdk_arch });
    mod.addLibraryPath(.{ .cwd_relative = ucrt_lib_dir });
    // c_v8.lib precedes this archive, so allocator_shim satisfies heap symbols
    // before libucrt is searched; the remaining UCRT startup stays static.
    mod.linkSystemLibrary("libucrt", .{});
}

const Html5EverArtifact = struct {
    dll: Build.LazyPath,
    install: *Build.Step.InstallFile,
};

fn linkHtml5Ever(b: *Build, mod: *Build.Module, cargo_path: []const u8) !?Html5EverArtifact {
    const is_debug = if (mod.optimize.? == .Debug) true else false;
    const profile = cargoBuildProfile(is_debug);
    const target = mod.resolved_target.?.result;
    const rust_target: ?[]const u8 = if (target.os.tag == .windows)
        switch (target.cpu.arch) {
            .x86_64 => if (target.abi == .msvc)
                "x86_64-pc-windows-msvc"
            else
                "x86_64-pc-windows-gnu",
            .aarch64 => if (target.abi == .msvc)
                "aarch64-pc-windows-msvc"
            else
                @panic("native Windows aarch64 requires the MSVC ABI"),
            else => @panic("unsupported native Windows architecture for html5ever"),
        }
    else
        null;

    const exec_cargo = b.addSystemCommand(&.{
        cargo_path,                 "build",
        "--locked",                 "--profile",
        profile.name,               "--manifest-path",
        "src/html5ever/Cargo.toml",
    });
    if (rust_target) |triple| {
        exec_cargo.addArgs(&.{ "--target", triple });
    }

    // Track Rust sources so edits invalidate the cargo step's cache.
    // Without this, Zig keys the step on argv only and won't re-run cargo
    // when lib.rs/Cargo.toml change.
    for ([_][]const u8{
        "src/html5ever/Cargo.toml",
        "src/html5ever/Cargo.lock",
        "src/html5ever/lib.rs",
        "src/html5ever/sink.rs",
        "src/html5ever/types.rs",
        "src/html5ever/url.rs",
    }) |path| {
        exec_cargo.addFileInput(b.path(path));
    }

    // TODO: We can prefer `--artifact-dir` once it become stable.
    const out_dir = exec_cargo.addPrefixedOutputDirectoryArg("--target-dir=", "html5ever");

    const html5ever_step = b.step("html5ever", "Install html5ever dependency (requires cargo)");
    html5ever_step.dependOn(&exec_cargo.step);

    var obj_dir = out_dir;
    if (rust_target) |triple| {
        obj_dir = obj_dir.path(b, triple);
    }
    obj_dir = obj_dir.path(b, profile.output_dir);
    // Cargo emits both a staticlib and a cdylib. Keep the cdylib boundary on
    // every desktop platform: Chromium Temporal is compiled by Chromium's
    // pinned Rust toolchain, while html5ever uses the host Cargo toolchain.
    // Statically combining them duplicates rust_eh_personality, std, panic and
    // allocator state.
    if (target.os.tag == .windows and target.abi == .msvc) {
        const import_lib = obj_dir.path(b, "darkpanda_html5ever.dll.lib");
        const dll = obj_dir.path(b, "darkpanda_html5ever.dll");
        mod.addObjectFile(import_lib);
        const install = b.addInstallBinFile(dll, "darkpanda_html5ever.dll");
        return .{ .dll = dll, .install = install };
    }

    const library_name = switch (target.os.tag) {
        .linux => "libdarkpanda_html5ever.so",
        .macos => "libdarkpanda_html5ever.dylib",
        else => @panic("html5ever shared-library boundary supports Windows, Linux, and macOS"),
    };
    const library = obj_dir.path(b, library_name);
    mod.addLibraryPath(obj_dir);
    mod.linkSystemLibrary("darkpanda_html5ever", .{
        .preferred_link_mode = .dynamic,
        .search_strategy = .no_fallback,
    });
    const install = b.addInstallBinFile(library, library_name);
    return .{ .dll = library, .install = install };
}

fn linkSqlite(b: *Build, mod: *Build.Module, enable_csan: ?std.zig.SanitizeC, is_tsan: bool) void {
    const dep = b.dependency("sqlite3", .{
        .target = mod.resolved_target.?,
        .optimize = mod.optimize.?,
    });

    const lib = dep.artifact("sqlite3");
    lib.root_module.sanitize_c = enable_csan;
    lib.root_module.sanitize_thread = is_tsan;

    const macros = [_]struct { []const u8, []const u8 }{
        .{ "SQLITE_DEFAULT_FILE_PERMISSIONS", "0600" },
        .{ "SQLITE_DEFAULT_MEMSTATUS", "0" },
        .{ "SQLITE_DEFAULT_WAL_SYNCHRONOUS", "1" },
        .{ "SQLITE_DQS", "0" },
        .{ "SQLITE_ENABLE_API_ARMOR", "1" },
        .{ "SQLITE_ENABLE_UNLOCK_NOTIFY", "1" },
        .{ "SQLITE_TEMP_STORE", "3" },
        .{ "SQLITE_THREADSAFE", "1" },
        .{ "SQLITE_UNTESTABLE", "1" },
        .{ "SQLITE_USE_ALLOCA", "1" },
        .{ "SQLITE_OMIT_AUTHORIZATION", "1" },
        .{ "SQLITE_OMIT_AUTOMATIC_INDEX", "1" },
        .{ "SQLITE_OMIT_AUTORESET", "1" },
        .{ "SQLITE_OMIT_AUTOVACUUM", "1" },
        .{ "SQLITE_OMIT_BETWEEN_OPTIMIZATION", "1" },
        .{ "SQLITE_OMIT_CASE_SENSITIVE_LIKE_PRAGMA", "1" },
        .{ "SQLITE_OMIT_COMPLETE", "1" },
        .{ "SQLITE_OMIT_DECLTYPE", "1" },
        .{ "SQLITE_OMIT_DEPRECATED", "1" },
        .{ "SQLITE_OMIT_DESERIALIZE", "1" },
        .{ "SQLITE_OMIT_GET_TABLE", "1" },
        .{ "SQLITE_OMIT_INCRBLOB", "1" },
        .{ "SQLITE_OMIT_JSON", "1" },
        .{ "SQLITE_OMIT_LIKE_OPTIMIZATION", "1" },
        .{ "SQLITE_OMIT_LOAD_EXTENSION", "1" },
        .{ "SQLITE_OMIT_PROGRESS_CALLBACK", "1" },
        .{ "SQLITE_OMIT_SHARED_CACHE", "1" },
        .{ "SQLITE_OMIT_TCL_VARIABLE", "1" },
        .{ "SQLITE_OMIT_TEMPDB", "1" },
        .{ "SQLITE_OMIT_TRACE", "1" },
        .{ "SQLITE_OMIT_UTF16", "1" },
        .{ "SQLITE_OMIT_XFER_OPT", "1" },
    };
    for (macros) |m| {
        lib.root_module.addCMacro(m[0], m[1]);
    }

    mod.linkLibrary(lib);
}

fn linkWebCrypto(
    b: *Build,
    mod: *Build.Module,
    prebuilt_boringssl_dir: ?[]const u8,
) !void {
    if (mod.resolved_target.?.result.os.tag != .windows) {
        const boringssl = buildBoringSsl(b, mod.resolved_target.?, mod.optimize.?);
        mod.linkLibrary(boringssl.crypto);
        return;
    }

    // BoringSSL crypto remains only as the WebCrypto implementation. TLS is
    // isolated inside wreq_transport and no SSL archive is linked here.
    const dir = prebuilt_boringssl_dir orelse @panic(
        "Windows WebCrypto requires -Dprebuilt_boringssl_dir=<MSVC /MT BoringSSL directory containing crypto.lib and fipsmodule.lib>",
    );
    const crypto_path = b.pathJoin(&.{ dir, "crypto.lib" });
    const fipsmodule_path = b.pathJoin(&.{ dir, "fipsmodule.lib" });
    std.fs.cwd().access(crypto_path, .{}) catch @panic("prebuilt BoringSSL crypto.lib was not found");
    std.fs.cwd().access(fipsmodule_path, .{}) catch @panic("prebuilt BoringSSL fipsmodule.lib was not found");
    mod.addObjectFile(.{ .cwd_relative = crypto_path });
    mod.addObjectFile(.{ .cwd_relative = fipsmodule_path });

    mod.linkSystemLibrary("ws2_32", .{});
    mod.linkSystemLibrary("iphlpapi", .{});
    mod.linkSystemLibrary("bcrypt", .{});
    mod.linkSystemLibrary("crypt32", .{});
    mod.linkSystemLibrary("dbghelp", .{});
    mod.linkSystemLibrary("winmm", .{});
}

const BoringSslLibraries = struct {
    crypto: *Build.Step.Compile,
};

fn buildBoringSsl(b: *Build, target: Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) BoringSslLibraries {
    const dep = b.dependency("boringssl-zig", .{
        .target = target,
        .optimize = optimize,
        .force_pic = true,
    });

    const crypto = dep.artifact("crypto");
    crypto.bundle_ubsan_rt = false;

    if (target.result.os.tag == .windows) {
        // Keep <windows.h> from pulling in wincrypt.h. Its X509_NAME macro
        // collides with BoringSSL's X509_NAME type.
        crypto.root_module.addCMacro("WIN32_LEAN_AND_MEAN", "1");
        crypto.root_module.addCMacro("NOMINMAX", "1");
    }

    return .{
        .crypto = crypto,
    };
}

/// Resolves the semantic version of the build.
///
/// The base version is read from `build.zig.zon`. This can be overridden
/// using the `-Dversion` command-line flag:
/// - If the flag contains a full semantic version (e.g., `1.2.3`), it replaces
///   the base version entirely.
/// - If the flag contains a simple string (e.g., `nightly`), it replaces only
///   the pre-release tag of the base version (e.g., `1.0.0-dev` -> `1.0.0-nightly`).
///
/// For versions that have a pre-release tag and no explicit build metadata,
/// this function automatically enriches the version with the git commit count
/// and short hash (e.g., `1.0.0-dev.5243+dbe45229`).
fn resolveVersion(b: *std.Build) std.SemanticVersion {
    const opt_version = b.option([]const u8, "version", "Override the version of this build");

    const version = if (opt_version) |v|
        std.SemanticVersion.parse(v) catch blk: {
            var fallback = darkpanda_version;
            fallback.pre = v;
            break :blk fallback;
        }
    else
        darkpanda_version;

    // Only enrich versions that have a pre-release field and no explicit build metadata.
    if (version.pre == null or version.build != null) return version;

    // For dev/nightly versions, calculate the commit count and hash
    const git_hash_raw = runGit(b, &.{ "rev-parse", "--short", "HEAD" }) catch return version;
    const commit_hash = std.mem.trim(u8, git_hash_raw, " \n\r");

    const git_count_raw = runGit(b, &.{ "rev-list", "--count", "HEAD" }) catch return version;
    const commit_count = std.mem.trim(u8, git_count_raw, " \n\r");

    return .{
        .major = version.major,
        .minor = version.minor,
        .patch = version.patch,
        .pre = b.fmt("{s}.{s}", .{ version.pre.?, commit_count }),
        .build = commit_hash,
    };
}

/// Helper function to run git commands and return stdout
fn runGit(b: *std.Build, args: []const []const u8) ![]const u8 {
    var code: u8 = undefined;
    const dir = b.pathFromRoot(".");
    var command: std.ArrayList([]const u8) = .empty;
    defer command.deinit(b.allocator);
    try command.appendSlice(b.allocator, &.{ "git", "-C", dir });
    try command.appendSlice(b.allocator, args);
    return b.runAllowFail(command.items, &code, .Ignore);
}
