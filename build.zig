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
    const prebuilt_v8_path = b.option(
        []const u8,
        "prebuilt_v8_path",
        "Path to prebuilt libc_v8.a or complete Windows c_v8_standalone.lib",
    );
    const canvas_dist = componentDistOption(
        b,
        "canvas_dist",
        "Absolute path to the Canvas component dist/<target> directory",
    );
    const html5ever_dist = componentDistOption(
        b,
        "html5ever_dist",
        "Absolute path to the HTML5ever component dist/<target> directory",
    );
    const wreq_dist = componentDistOption(
        b,
        "wreq_dist",
        "Absolute path to the wreq component dist/<target> directory",
    );
    const boringssl_dist = componentDistOption(
        b,
        "boringssl_dist",
        "Absolute path to the BoringSSL component dist/<target> directory",
    );
    // Keep formatting and option discovery usable without materialized native
    // components. Every compile/install/run/test entry below depends on this
    // gate, so a real build can never silently omit one of the four dist sets.
    const component_dist_gate: ?*Build.Step = if (canvas_dist != null and
        html5ever_dist != null and
        wreq_dist != null and
        boringssl_dist != null)
        null
    else
        &b.addFail(
            "DarkPanda native builds require absolute -Dcanvas_dist, -Dhtml5ever_dist, -Dwreq_dist, and -Dboringssl_dist paths",
        ).step;

    const canvas_artifact = if (canvas_dist) |dist|
        installCanvasDist(b, target.result.os.tag, dist)
    else
        null;
    const wreq_artifact = if (wreq_dist) |dist|
        installRuntimeDist(b, dist, wreqLibraryName(target.result.os.tag))
    else
        null;
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

        // Do not start an expensive V8 dependency build when the component
        // contract is incomplete. Compile/install/run/test steps all depend on
        // the fail gate above and therefore stop before doing native work.
        if (component_dist_gate == null) {
            try linkV8(b, mod, enable_asan, enable_tsan, prebuilt_v8_path);
            linkWebCryptoDist(b, mod, boringssl_dist.?);
            html5ever_artifact = linkHtml5EverDist(b, mod, html5ever_dist.?);
        }

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
    if (component_dist_gate) |gate| check_lib.step.dependOn(gate);

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
        if (component_dist_gate) |gate| b.getInstallStep().dependOn(gate);
        if (canvas_artifact) |artifact| {
            b.getInstallStep().dependOn(&artifact.runtime.install.step);
            b.getInstallStep().dependOn(&artifact.header_install.step);
        }
        if (wreq_artifact) |artifact| {
            b.getInstallStep().dependOn(&artifact.install.step);
        }
        if (html5ever_artifact) |artifact| {
            b.getInstallStep().dependOn(&artifact.install.step);
        }

        const exe_check = b.addLibrary(.{
            .name = "darkpanda_exe_check",
            .root_module = exe.root_module,
        });
        check.dependOn(&exe_check.step);
        if (component_dist_gate) |gate| exe_check.step.dependOn(gate);

        const run_cmd = b.addRunArtifact(exe);
        configureRuntimeRun(
            b,
            run_cmd,
            target.result.os.tag,
            component_dist_gate,
            canvas_artifact,
            wreq_artifact,
            html5ever_artifact,
        );
        if (b.args) |args| {
            run_cmd.addArgs(args);
        }
        const run_step = b.step("run", "Run the app");
        run_step.dependOn(&run_cmd.step);

        const version_info_step = b.step("version", "Print the resolved version information");
        const version_info_run = b.addRunArtifact(exe);
        configureRuntimeRun(
            b,
            version_info_run,
            target.result.os.tag,
            component_dist_gate,
            canvas_artifact,
            wreq_artifact,
            html5ever_artifact,
        );
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
        if (component_dist_gate) |gate| {
            ffi_install.step.dependOn(gate);
            ffi_step.dependOn(gate);
        }
        if (canvas_artifact) |artifact| {
            ffi_step.dependOn(&artifact.runtime.install.step);
            ffi_step.dependOn(&artifact.header_install.step);
        }
        if (wreq_artifact) |artifact| ffi_step.dependOn(&artifact.install.step);
        if (html5ever_artifact) |artifact| ffi_step.dependOn(&artifact.install.step);

        // Compile-only coverage for the C ABI root is part of `zig build check`.
        // A static library avoids requiring a runnable/new V8 DLL at this step.
        const ffi_check = b.addLibrary(.{
            .name = "darkpanda_ffi_check",
            .root_module = ffi_module,
        });
        check.dependOn(&ffi_check.step);
        if (component_dist_gate) |gate| ffi_check.step.dependOn(gate);
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
        const extras_install = b.addInstallArtifact(exe, .{});
        extras_step.dependOn(&extras_install.step);
        if (component_dist_gate) |gate| extras_install.step.dependOn(gate);
        if (canvas_artifact) |artifact| {
            extras_step.dependOn(&artifact.runtime.install.step);
            extras_step.dependOn(&artifact.header_install.step);
        }
        if (wreq_artifact) |artifact| extras_step.dependOn(&artifact.install.step);
        if (html5ever_artifact) |artifact| extras_step.dependOn(&artifact.install.step);

        const exe_check = b.addLibrary(.{
            .name = "snapshot_creator_check",
            .root_module = exe.root_module,
        });
        check.dependOn(&exe_check.step);
        if (component_dist_gate) |gate| exe_check.step.dependOn(gate);

        const run_cmd = b.addRunArtifact(exe);
        configureRuntimeRun(
            b,
            run_cmd,
            target.result.os.tag,
            component_dist_gate,
            canvas_artifact,
            wreq_artifact,
            html5ever_artifact,
        );
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
        configureRuntimeRun(
            b,
            run_tests,
            target.result.os.tag,
            component_dist_gate,
            canvas_artifact,
            wreq_artifact,
            html5ever_artifact,
        );
        const test_compile_step = b.step("test-compile", "Compile unit tests without running them");
        test_compile_step.dependOn(&tests.step);
        if (component_dist_gate) |gate| tests.step.dependOn(gate);
        const test_step = b.step("test", "Run unit tests");
        test_step.dependOn(&run_tests.step);
    }
}

const RuntimeDistArtifact = struct {
    source: Build.LazyPath,
    install: *Build.Step.InstallFile,
};

const CanvasDistArtifact = struct {
    runtime: RuntimeDistArtifact,
    header_install: *Build.Step.InstallFile,
};

fn componentDistOption(
    b: *Build,
    name: []const u8,
    description: []const u8,
) ?[]const u8 {
    const path = b.option([]const u8, name, description) orelse return null;
    if (!std.fs.path.isAbsolute(path)) {
        @panic(b.fmt("-D{s} must be an absolute dist/<target> path", .{name}));
    }
    return path;
}

fn distFile(b: *Build, dist: []const u8, directory: []const u8, name: []const u8) Build.LazyPath {
    return .{ .cwd_relative = b.pathJoin(&.{ dist, directory, name }) };
}

fn installRuntimeDist(b: *Build, dist: []const u8, name: []const u8) RuntimeDistArtifact {
    const source = distFile(b, dist, "bin", name);
    return .{
        .source = source,
        .install = b.addInstallBinFile(source, name),
    };
}

fn installCanvasDist(b: *Build, os: std.Target.Os.Tag, dist: []const u8) CanvasDistArtifact {
    return .{
        .runtime = installRuntimeDist(b, dist, canvasLibraryName(os)),
        .header_install = b.addInstallHeaderFile(
            distFile(b, dist, "include", "canvas.h"),
            "canvas.h",
        ),
    };
}

fn configureRuntimeRun(
    b: *Build,
    run: *Build.Step.Run,
    os: std.Target.Os.Tag,
    component_dist_gate: ?*Build.Step,
    canvas: ?CanvasDistArtifact,
    wreq: ?RuntimeDistArtifact,
    html5ever: ?Html5EverArtifact,
) void {
    if (component_dist_gate) |gate| run.step.dependOn(gate);
    if (canvas) |artifact| run.step.dependOn(&artifact.runtime.install.step);
    if (wreq) |artifact| run.step.dependOn(&artifact.install.step);
    if (html5ever) |artifact| run.step.dependOn(&artifact.install.step);

    run.setEnvironmentVariable(
        "DARKPANDA_WREQ_LIBRARY",
        b.getInstallPath(.bin, wreqLibraryName(os)),
    );
    run.setEnvironmentVariable(
        "DARKPANDA_CANVAS_BACKEND_LIBRARY",
        b.getInstallPath(.bin, canvasLibraryName(os)),
    );
    run.setEnvironmentVariable("DARKPANDA_CANVAS_DRIVER", "dynamic");
    run.setEnvironmentVariable("DARKPANDA_CANVAS_BACKEND_FALLBACK", "disabled");
    const runtime_bin = b.getInstallPath(.bin, "");
    switch (os) {
        .windows => run.setEnvironmentVariable("PATH", runtime_bin),
        .linux => run.setEnvironmentVariable("LD_LIBRARY_PATH", runtime_bin),
        .macos => run.setEnvironmentVariable("DYLD_LIBRARY_PATH", runtime_bin),
        else => {},
    }
}

fn canvasLibraryName(os: std.Target.Os.Tag) []const u8 {
    return switch (os) {
        .windows => "canvas.dll",
        .macos => "libcanvas.dylib",
        else => "libcanvas.so",
    };
}

fn wreqLibraryName(os_tag: std.Target.Os.Tag) []const u8 {
    return switch (os_tag) {
        .windows => "wreq.dll",
        .macos => "libwreq.dylib",
        else => "libwreq.so",
    };
}

fn html5everLibraryName(os: std.Target.Os.Tag) []const u8 {
    return switch (os) {
        .windows => "html5ever.dll",
        .macos => "libhtml5ever.dylib",
        else => "libhtml5ever.so",
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

const Html5EverArtifact = RuntimeDistArtifact;

fn linkHtml5EverDist(b: *Build, mod: *Build.Module, dist: []const u8) Html5EverArtifact {
    const target = mod.resolved_target.?.result;
    const library_name = html5everLibraryName(target.os.tag);
    const library = distFile(b, dist, "bin", library_name);

    if (target.os.tag == .windows) {
        if (target.abi != .msvc) {
            @panic("the standardized Windows HTML5ever dist requires the MSVC ABI");
        }
        mod.addObjectFile(distFile(b, dist, "lib", "html5ever.dll.lib"));
    } else {
        const library_dir: Build.LazyPath = .{ .cwd_relative = b.pathJoin(&.{ dist, "bin" }) };
        mod.addLibraryPath(library_dir);
        mod.linkSystemLibrary("html5ever", .{
            .preferred_link_mode = .dynamic,
            .search_strategy = .no_fallback,
        });
    }

    return .{
        .source = library,
        .install = b.addInstallBinFile(library, library_name),
    };
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

fn linkWebCryptoDist(b: *Build, mod: *Build.Module, dist: []const u8) void {
    const target = mod.resolved_target.?.result;
    // BoringSSL crypto remains only as the WebCrypto implementation. TLS is
    // isolated inside wreq_transport and no SSL archive is linked here. The
    // M149 crypto archive already contains the fipsmodule object library.
    const crypto_name = if (target.os.tag == .windows) "crypto.lib" else "libcrypto.a";
    mod.addObjectFile(distFile(b, dist, "lib", crypto_name));

    if (target.os.tag == .windows) {
        mod.linkSystemLibrary("ws2_32", .{});
        mod.linkSystemLibrary("iphlpapi", .{});
        mod.linkSystemLibrary("bcrypt", .{});
        mod.linkSystemLibrary("crypt32", .{});
        mod.linkSystemLibrary("dbghelp", .{});
        mod.linkSystemLibrary("winmm", .{});
    }
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
