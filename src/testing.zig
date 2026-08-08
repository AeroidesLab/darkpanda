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
const lp = @import("darkpanda");

const log = lp.log;
const Allocator = std.mem.Allocator;

pub const allocator = std.testing.allocator;
pub const expectError = std.testing.expectError;
pub const expect = std.testing.expect;
pub const expectString = std.testing.expectEqualStrings;
pub const expectEqualSlices = std.testing.expectEqualSlices;

// sometimes it's super useful to have an arena you don't really care about
// in a test. Like, you need a mutable string, so you just want to dupe a
// string literal. It has nothing to do with the code under test, it's just
// infrastructure for the test itself.
pub var arena_instance = std.heap.ArenaAllocator.init(std.heap.c_allocator);
pub const arena_allocator = arena_instance.allocator();

pub fn reset() void {
    _ = arena_instance.reset(.retain_capacity);
}

const App = @import("App.zig");
const js = @import("browser/js/js.zig");
const Config = @import("Config.zig");
const Frame = @import("browser/Frame.zig");
const Browser = @import("browser/Browser.zig");
const Session = @import("browser/Session.zig");
const Notification = @import("Notification.zig");

// Merged std.testing.expectEqual and std.testing.expectString
// can be useful when testing fields of an anytype an you don't know
// exactly how to assert equality
pub fn expectEqual(expected: anytype, actual: anytype) !void {
    switch (@typeInfo(@TypeOf(actual))) {
        .array => |arr| if (arr.child == u8) {
            return std.testing.expectEqualStrings(expected, &actual);
        },
        .pointer => |ptr| {
            if (ptr.child == u8) {
                return std.testing.expectEqualStrings(expected, actual);
            } else if (comptime isStringArray(ptr.child)) {
                return std.testing.expectEqualStrings(expected, actual);
            } else if (ptr.child == []u8 or ptr.child == []const u8) {
                return expectString(expected, actual);
            }
        },
        .@"struct" => |structType| {
            inline for (structType.fields) |field| {
                try expectEqual(@field(expected, field.name), @field(actual, field.name));
            }
            return;
        },
        .optional => {
            if (@typeInfo(@TypeOf(expected)) == .null) {
                return std.testing.expectEqual(null, actual);
            }
            if (actual) |_actual| {
                return expectEqual(expected, _actual);
            }
            return std.testing.expectEqual(expected, null);
        },
        .@"union" => |union_info| {
            if (union_info.tag_type == null) {
                @compileError("Unable to compare untagged union values");
            }
            const Tag = std.meta.Tag(@TypeOf(expected));

            const expectedTag = @as(Tag, expected);
            const actualTag = @as(Tag, actual);
            try expectEqual(expectedTag, actualTag);

            inline for (std.meta.fields(@TypeOf(actual))) |fld| {
                if (std.mem.eql(u8, fld.name, @tagName(actualTag))) {
                    try expectEqual(@field(expected, fld.name), @field(actual, fld.name));
                    return;
                }
            }
            unreachable;
        },
        else => {},
    }
    return std.testing.expectEqual(expected, actual);
}

pub fn expectDelta(expected: anytype, actual: anytype, delta: anytype) !void {
    if (@typeInfo(@TypeOf(expected)) == .null) {
        return std.testing.expectEqual(null, actual);
    }

    switch (@typeInfo(@TypeOf(actual))) {
        .optional => {
            if (actual) |value| {
                return expectDelta(expected, value, delta);
            }
            return std.testing.expectEqual(null, expected);
        },
        else => {},
    }

    switch (@typeInfo(@TypeOf(expected))) {
        .optional => {
            if (expected) |value| {
                return expectDelta(value, actual, delta);
            }
            return std.testing.expectEqual(null, actual);
        },
        else => {},
    }

    var diff = expected - actual;
    if (diff < 0) {
        diff = -diff;
    }
    if (diff <= delta) {
        return;
    }

    print("Expected {} to be within {} of {}. Actual diff: {}", .{ expected, delta, actual, diff });
    return error.NotWithinDelta;
}

fn isStringArray(comptime T: type) bool {
    if (!is(.array)(T) and !isPtrTo(.array)(T)) {
        return false;
    }
    return std.meta.Elem(T) == u8;
}

pub const TraitFn = fn (type) bool;
pub fn is(comptime id: std.builtin.TypeId) TraitFn {
    const Closure = struct {
        pub fn trait(comptime T: type) bool {
            return id == @typeInfo(T);
        }
    };
    return Closure.trait;
}

pub fn isPtrTo(comptime id: std.builtin.TypeId) TraitFn {
    const Closure = struct {
        pub fn trait(comptime T: type) bool {
            if (!comptime isSingleItemPtr(T)) return false;
            return id == @typeInfo(std.meta.Child(T));
        }
    };
    return Closure.trait;
}

pub fn isSingleItemPtr(comptime T: type) bool {
    if (comptime is(.pointer)(T)) {
        return @typeInfo(T).pointer.size == .one;
    }
    return false;
}

pub fn print(comptime fmt: []const u8, args: anytype) void {
    if (@inComptime()) {
        @compileError(std.fmt.comptimePrint(fmt, args));
    } else {
        std.debug.print(fmt, args);
    }
}

pub const Random = struct {
    var instance: ?std.Random.DefaultPrng = null;

    pub fn fill(buf: []u8) void {
        var r = random();
        r.bytes(buf);
    }

    pub fn fillAtLeast(buf: []u8, min: usize) []u8 {
        var r = random();
        const l = r.intRangeAtMost(usize, min, buf.len);
        r.bytes(buf[0..l]);
        return buf;
    }

    pub fn intRange(comptime T: type, min: T, max: T) T {
        var r = random();
        return r.intRangeAtMost(T, min, max);
    }

    pub fn random() std.Random {
        if (instance == null) {
            var seed: u64 = undefined;
            std.posix.getrandom(std.mem.asBytes(&seed)) catch unreachable;
            instance = std.Random.DefaultPrng.init(seed);
            // instance = std.Random.DefaultPrng.init(0);
        }
        return instance.?.random();
    }
};

pub fn expectJson(a: anytype, b: anytype) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const aa = arena.allocator();

    const a_value = try convertToJson(aa, a);
    const b_value = try convertToJson(aa, b);

    errdefer {
        const a_json = std.json.Stringify.valueAlloc(aa, a_value, .{ .whitespace = .indent_2 }) catch unreachable;
        const b_json = std.json.Stringify.valueAlloc(aa, b_value, .{ .whitespace = .indent_2 }) catch unreachable;
        std.debug.print("== Expected ==\n{s}\n\n== Actual ==\n{s}", .{ a_json, b_json });
    }

    try expectJsonValue(a_value, b_value);
}

pub fn isEqualJson(a: anytype, b: anytype) !bool {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const aa = arena.allocator();
    const a_value = try convertToJson(aa, a);
    const b_value = try convertToJson(aa, b);
    return isJsonValue(a_value, b_value);
}

fn convertToJson(arena: Allocator, value: anytype) !std.json.Value {
    const T = @TypeOf(value);
    if (T == std.json.Value) {
        return value;
    }

    var str: []const u8 = undefined;
    if (T == []u8 or T == []const u8 or comptime isStringArray(T)) {
        str = value;
    } else {
        str = try std.json.Stringify.valueAlloc(arena, value, .{});
    }
    return std.json.parseFromSliceLeaky(std.json.Value, arena, str, .{});
}

fn expectJsonValue(a: std.json.Value, b: std.json.Value) !void {
    try expectEqual(@tagName(a), @tagName(b));

    // at this point, we know that if a is an int, b must also be an int
    switch (a) {
        .null => return,
        .bool => try expectEqual(a.bool, b.bool),
        .integer => try expectEqual(a.integer, b.integer),
        .float => try expectEqual(a.float, b.float),
        .number_string => try expectEqual(a.number_string, b.number_string),
        .string => try expectEqual(a.string, b.string),
        .array => {
            const a_len = a.array.items.len;
            const b_len = b.array.items.len;
            try expectEqual(a_len, b_len);
            for (a.array.items, b.array.items) |a_item, b_item| {
                try expectJsonValue(a_item, b_item);
            }
        },
        .object => {
            var it = a.object.iterator();
            while (it.next()) |entry| {
                const key = entry.key_ptr.*;
                if (b.object.get(key)) |b_item| {
                    try expectJsonValue(entry.value_ptr.*, b_item);
                } else {
                    return error.MissingKey;
                }
            }
        },
    }
}

fn isJsonValue(a: std.json.Value, b: std.json.Value) bool {
    if (std.mem.eql(u8, @tagName(a), @tagName(b)) == false) {
        return false;
    }

    // at this point, we know that if a is an int, b must also be an int
    switch (a) {
        .null => return true,
        .bool => return a.bool == b.bool,
        .integer => return a.integer == b.integer,
        .float => return a.float == b.float,
        .number_string => return std.mem.eql(u8, a.number_string, b.number_string),
        .string => return std.mem.eql(u8, a.string, b.string),
        .array => {
            const a_len = a.array.items.len;
            const b_len = b.array.items.len;
            if (a_len != b_len) {
                return false;
            }
            for (a.array.items, b.array.items) |a_item, b_item| {
                if (isJsonValue(a_item, b_item) == false) {
                    return false;
                }
            }
            return true;
        },
        .object => {
            var it = a.object.iterator();
            while (it.next()) |entry| {
                const key = entry.key_ptr.*;
                if (b.object.get(key)) |b_item| {
                    if (isJsonValue(entry.value_ptr.*, b_item) == false) {
                        return false;
                    }
                } else {
                    return false;
                }
            }
            return true;
        },
    }
}

pub var test_app: *App = undefined;
pub var test_browser: Browser = undefined;
pub var test_notification: *Notification = undefined;
pub var test_session: *Session = undefined;

const WEB_API_TEST_ROOT = "src/browser/tests/";
const HtmlRunnerOpts = struct {
    timeout_ms: u32 = 2000,
    inject_script: ?[]const u8 = null,
    load_external_stylesheets: bool = false,
};

// Create a fresh page on `test_session` and return its root frame — for tests
// that just need a frame to build a DOM in. The page lives on the session;
// release it with `defer testing.test_session.closeAllPages()`.
pub fn createFrame() !*Frame {
    return (try test_session.createPage()).frame().?;
}

pub fn waitForFrame() !void {
    var runner = test_session.runner(.{});
    const frame_id = test_session.pages.items[0].frame._frame_id;
    return runner.waitForFrame(frame_id, 2000, .{ .until = .done });
}

pub fn htmlRunner(comptime path: []const u8, opts: HtmlRunnerOpts) !void {
    defer reset();

    var inject_scripts: [1][]const u8 = undefined;
    if (opts.inject_script) |script| {
        inject_scripts[0] = script;
        test_session.inject_scripts = inject_scripts[0..1];
    }
    defer test_session.inject_scripts = &.{};

    test_session.load_external_stylesheets = opts.load_external_stylesheets;
    defer test_session.load_external_stylesheets = false;

    const root = try std.fs.path.joinZ(arena_allocator, &.{ WEB_API_TEST_ROOT, path });
    const stat = std.fs.cwd().statFile(root) catch |err| {
        // On Windows, statFile intentionally reports IsDir instead of
        // returning a Stat whose kind is .directory.  Treat that one error as
        // the same directory path handled below; all other errors retain the
        // existing diagnostic and propagation behaviour.
        if (err == error.IsDir) {
            return runHtmlTestDirectory(root, opts.timeout_ms);
        }
        std.debug.print("Failed to stat file: '{s}'", .{root});
        return err;
    };

    switch (stat.kind) {
        .file => {
            if (@import("root").shouldRun(std.fs.path.basename(root)) == false) {
                return;
            }
            try @import("root").subtest(root);
            try runWebApiTest(root, opts.timeout_ms);
        },
        .directory => {
            try runHtmlTestDirectory(root, opts.timeout_ms);
        },
        else => |kind| {
            std.debug.print("Unknown file type: {s} for {s}\n", .{ @tagName(kind), root });
            return error.InvalidTestPath;
        },
    }
}

fn runHtmlTestDirectory(root: [:0]const u8, timeout_ms: u32) !void {
    var dir = try std.fs.cwd().openDir(root, .{
        .iterate = true,
        .no_follow = true,
        .access_sub_paths = false,
    });
    defer dir.close();

    var it = dir.iterateAssumeFirstIteration();
    while (try it.next()) |entry| {
        if (entry.kind != .file) {
            continue;
        }

        if (!std.mem.endsWith(u8, entry.name, ".html")) {
            continue;
        }

        // Files named `*_fixture.html` are navigation targets used by an
        // authored test or differential probe, not standalone assertions.
        // Running them through the directory test runner can either execute
        // without testing.js (and fail with `testing is not defined`) or
        // recursively start their helper Worker. Keep the convention generic
        // so support fixtures remain addressable at their existing URLs.
        if (std.mem.endsWith(u8, entry.name, "_fixture.html")) {
            continue;
        }

        if (@import("root").shouldRun(entry.name) == false) {
            continue;
        }

        const full_path = try std.fs.path.joinZ(arena_allocator, &.{ root, entry.name });
        try @import("root").subtest(entry.name);
        try runWebApiTest(full_path, timeout_ms);
    }
}

const RelativeDeadline = struct {
    timeout_ns: u64,

    fn init(timeout_ms: u32) RelativeDeadline {
        return .{ .timeout_ns = @as(u64, timeout_ms) * std.time.ns_per_ms };
    }

    fn expired(self: RelativeDeadline, elapsed_ns: u64) bool {
        return elapsed_ns >= self.timeout_ns;
    }
};

fn runWebApiTest(test_file: [:0]const u8, timeout_ms: u32) !void {
    const page = try test_session.createPage();
    defer page.close();

    // `test_file` is a native filesystem path.  A Windows join uses `\`, but
    // the value below is an HTTP URL path: serialize it with URL separators.
    // Chrome's URL parser also canonicalizes `\` to `/` for special schemes;
    // doing it at this boundary keeps Frame.url canonical from the first load.
    const url_path = try arena_allocator.dupe(u8, test_file);
    std.mem.replaceScalar(u8, url_path, '\\', '/');
    const url = try std.fmt.allocPrintSentinel(
        arena_allocator,
        "http://127.0.0.1:9582/{s}?__darkpanda_test_runner=1",
        .{url_path},
        0,
    );

    // The first navigation starts from the initial about:blank Frame. Root
    // navigation can later replace the Page/Frame while preserving frame_id,
    // so this pointer must not escape the navigation setup below.
    const initial_frame = page.frame().?;

    {
        var ls: js.Local.Scope = undefined;
        initial_frame.js.localScope(&ls);
        defer ls.deinit();

        var try_catch: js.TryCatch = undefined;
        try_catch.init(&ls.local);
        defer try_catch.deinit();

        try initial_frame.navigate(url, .{});
    }

    var runner = test_session.runner(.{});
    try runner.waitForFrame(page.frame_id, 2000, .{ .until = .load });

    const deadline = RelativeDeadline.init(timeout_ms);
    var timer = try std.time.Timer.start();
    while (true) {
        // The runner below is an event-loop boundary. Keep the Context entered
        // only for the assertion itself so navigation commits are free to
        // install their WindowAgent MicrotaskQueue.
        const assertions_done = blk: {
            const frame = page.frame() orelse return error.FrameNotFound;
            var ls: js.Local.Scope = undefined;
            frame.js.localScope(&ls);
            defer ls.deinit();

            var try_catch: js.TryCatch = undefined;
            try_catch.init(&ls.local);
            defer try_catch.deinit();

            // Match CDP Runtime.evaluate's test-only CSP bypass.  Authored page
            // eval/Function calls still enter the embedder callback; only the
            // native harness expression used to collect observations is
            // compiled while the V8 Context gate is temporarily open.
            const bypass_codegen = !frame.js.csp_code_generation.allow_eval or
                frame.js.csp_trusted_types.requiresScriptCheck();
            if (bypass_codegen) {
                js.v8.v8__Context__AllowCodeGenerationFromStrings(ls.local.handle, true);
            }
            defer if (bypass_codegen) {
                js.v8.v8__Context__AllowCodeGenerationFromStrings(ls.local.handle, false);
            };

            const js_val = ls.local.exec("testing.assertOk()", "testing.assertOk()") catch |err| {
                const caught = try_catch.caughtOrError(arena_allocator, err);
                std.debug.print("{s}: test failure\nError: {f}\n", .{ test_file, caught });
                return err;
            };
            break :blk js_val.isTrue();
        };
        if (assertions_done) {
            return;
        }
        const sleep_ms: usize = switch (try runner.tickForFrame(page.frame_id, 20, .{ .until = .done })) {
            .done => 20,
            .ok => |next_ms| @min(next_ms, 20),
        };

        if (deadline.expired(timer.read())) {
            const frame = page.frame() orelse return error.FrameNotFound;
            var ls: js.Local.Scope = undefined;
            frame.js.localScope(&ls);
            defer ls.deinit();
            ls.local.eval("testing.printTimeoutState()", "testing.printTimeoutState()") catch {};
            return error.TestTimedOut;
        }
        std.Thread.sleep(std.time.ns_per_ms * sleep_ms);
    }
}

test "WebApi test deadline preserves cumulative sub-millisecond progress" {
    const deadline = RelativeDeadline.init(2_000);
    var elapsed_ns: u64 = 0;

    for (0..2_001) |_| elapsed_ns += 999_999;

    try std.testing.expect(deadline.expired(elapsed_ns));
}

const PageTestOpts = struct {
    wait_until_done: bool = true,
};
pub fn pageTest(comptime test_file: []const u8, opts: PageTestOpts) !Session.PageHandle {
    const page = try test_session.createPage();
    errdefer page.close();

    const url = try std.fmt.allocPrintSentinel(
        arena_allocator,
        "http://127.0.0.1:9582/{s}{s}",
        .{ WEB_API_TEST_ROOT, test_file },
        0,
    );

    try page.navigate(url, .{});
    if (opts.wait_until_done) {
        var runner = test_session.runner(.{});
        try runner.waitForFrame(page.frame_id, 2000, .{ .until = .done });
    }
    return page;
}

const TestHTTPServer = @import("TestHTTPServer.zig");
const TestWSServer = @import("TestWSServer.zig");

const Server = @import("Server.zig");
var test_cdp_server: ?*Server = null;
var test_cdp_server_thread: ?std.Thread = null;
var test_cdp_start_error: ?anyerror = null;
var test_http_server: ?TestHTTPServer = null;
var test_http_server_thread: ?std.Thread = null;
var test_ws_server: ?TestWSServer = null;
var test_ws_server_thread: ?std.Thread = null;

// Valid, fully-formed 3x2 RGBA PNG used by HTMLImageElement tests. Keeping
// the bytes inline makes the fixture deterministic on every platform and
// avoids coupling resource-loading tests to an image codec or the filesystem.
const test_png_3x2 = [_]u8{
    0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d,
    0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00, 0x02,
    0x08, 0x06, 0x00, 0x00, 0x00, 0x9d, 0x74, 0x66, 0x1a, 0x00, 0x00, 0x00,
    0x0b, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9c, 0x63, 0x60, 0xc0, 0x05, 0x00,
    0x00, 0x1a, 0x00, 0x01, 0xbc, 0x3c, 0xe0, 0x41, 0x00, 0x00, 0x00, 0x00,
    0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82,
};
var test_image_request_count: std.atomic.Value(u32) = .init(0);

var test_config: Config = undefined;

test "tests:beforeAll" {
    log.opts.level = .warn;
    log.opts.format = .pretty;

    const test_allocator = @import("root").tracking_allocator;

    test_config = try Config.initCore(test_allocator, "test", .{ .serve = .{} }, .{
        .tls_verify_host = false,
        // Follow the platform's transport-compatible identity. Native
        // Windows is wreq/Chrome149-only, while other targets retain the
        // historical Lightpanda harness profile.
        .client_profile = @import("ClientProfile.zig").target_default,
        .user_agent_suffix = "internal-tester",
        .ws_max_concurrent = 50,
        .webrtc_tun_bind_address = "127.0.0.1",
    });

    test_app = try App.init(test_allocator, &test_config);
    errdefer test_app.deinit();

    try test_browser.init(test_app, .{}, null);
    errdefer test_browser.deinit();

    // Create notification for testing
    test_notification = try Notification.init(test_app.allocator);
    errdefer test_notification.deinit();

    test_session = try test_browser.newSession(test_notification);

    var wg: std.Thread.WaitGroup = .{};
    wg.startMany(3);

    test_cdp_start_error = null;
    test_cdp_server_thread = try std.Thread.spawn(.{}, serveCDP, .{&wg});

    test_http_server = TestHTTPServer.init(testHTTPHandler);
    test_http_server_thread = try std.Thread.spawn(.{}, TestHTTPServer.run, .{ &test_http_server.?, &wg });

    test_ws_server = TestWSServer.init();
    test_ws_server_thread = try std.Thread.spawn(.{}, TestWSServer.run, .{ &test_ws_server.?, &wg });

    // need to wait for the servers to be listening, else tests will fail because
    // they aren't able to connect.
    wg.wait();
    if (test_cdp_start_error) |err| return err;
}

test "tests:afterAll" {
    test_app.network.stop();
    if (test_cdp_server_thread) |thread| {
        thread.join();
    }
    if (test_cdp_server) |server| {
        server.deinit();
    }

    if (test_http_server) |*server| {
        server.stop();
    }
    if (test_http_server_thread) |thread| {
        thread.join();
    }
    if (test_http_server) |*server| {
        server.deinit();
    }

    if (test_ws_server) |*server| {
        server.stop();
    }
    if (test_ws_server_thread) |thread| {
        thread.join();
    }

    @import("root").v8_peak_memory = test_browser.env.isolate.getHeapStatistics().total_physical_size;

    // Browser must be deinit'd before the notification — Session/Frame
    // teardown may unregister notification listeners (e.g. CookieStore
    // detach), which dereferences `notification.listeners`.
    test_browser.deinit();
    test_notification.deinit();
    test_app.deinit();
    test_config.deinit(@import("root").tracking_allocator);
}

pub fn testCDPPort() u16 {
    return lp.build_config.test_cdp_port;
}

fn serveCDP(wg: *std.Thread.WaitGroup) void {
    // `network.run()` owns this thread after a successful bind, so report
    // readiness before entering it. Every earlier return must also release the
    // setup WaitGroup; otherwise an occupied test port deadlocks before the
    // custom runner can report a setup failure.
    var readiness_reported = false;
    defer if (!readiness_reported) wg.finish();

    const port = testCDPPort();
    const address = std.net.Address.parseIp("127.0.0.1", port) catch |err| {
        test_cdp_start_error = err;
        std.debug.print("CDP test address error on 127.0.0.1:{d}: {}\n", .{ port, err });
        return;
    };

    test_cdp_server = Server.init(test_app, address) catch |err| {
        test_cdp_start_error = err;
        std.debug.print("CDP test server error on 127.0.0.1:{d}: {}\n", .{ port, err });
        return;
    };
    readiness_reported = true;
    wg.finish();

    test_app.network.run();
}

fn testHTTPHandler(req: *std.http.Server.Request) !void {
    const path = req.head.target;

    if (std.mem.eql(u8, path, "/image/valid.png") or
        std.mem.startsWith(u8, path, "/image/valid.png?") or
        std.mem.eql(u8, path, "/image/counted.png") or
        std.mem.eql(u8, path, "/image/slow.png") or
        std.mem.eql(u8, path, "/image/teardown-slow.png"))
    {
        if (std.mem.eql(u8, path, "/image/slow.png")) {
            std.Thread.sleep(150 * std.time.ns_per_ms);
        }
        if (std.mem.eql(u8, path, "/image/teardown-slow.png")) {
            std.Thread.sleep(350 * std.time.ns_per_ms);
        }
        if (std.mem.eql(u8, path, "/image/counted.png")) {
            _ = test_image_request_count.fetchAdd(1, .seq_cst);
        }
        return req.respond(&test_png_3x2, .{ .extra_headers = &.{
            .{ .name = "Content-Type", .value = "image/png" },
            .{ .name = "Cache-Control", .value = "no-store" },
        } });
    }

    if (std.mem.eql(u8, path, "/image/invalid.png")) {
        return req.respond("not a png", .{ .extra_headers = &.{
            .{ .name = "Content-Type", .value = "image/png" },
            .{ .name = "Cache-Control", .value = "no-store" },
        } });
    }

    if (std.mem.eql(u8, path, "/image/404.png")) {
        return req.respond(&test_png_3x2, .{
            .status = .not_found,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "image/png" },
                .{ .name = "Cache-Control", .value = "no-store" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/image/count/reset")) {
        test_image_request_count.store(0, .seq_cst);
        return req.respond("ok", .{ .extra_headers = &.{
            .{ .name = "Content-Type", .value = "text/plain" },
            .{ .name = "Cache-Control", .value = "no-store" },
        } });
    }

    if (std.mem.eql(u8, path, "/image/count")) {
        var count_buffer: [32]u8 = undefined;
        const count = try std.fmt.bufPrint(&count_buffer, "{d}", .{test_image_request_count.load(.seq_cst)});
        return req.respond(count, .{ .extra_headers = &.{
            .{ .name = "Content-Type", .value = "text/plain" },
            .{ .name = "Cache-Control", .value = "no-store" },
        } });
    }

    if (std.mem.eql(u8, path, "/xhr")) {
        return req.respond("1234567890" ** 10, .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/html; charset=utf-8" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/xhr_empty")) {
        return req.respond("", .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/html; charset=utf-8" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/xhr/json")) {
        return req.respond("{\"over\":\"9000!!!\",\"updated_at\":1765867200000}", .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "application/json" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/xhr/redirect")) {
        return req.respond("", .{
            .status = .found,
            .extra_headers = &.{
                .{ .name = "Location", .value = "http://127.0.0.1:9582/xhr" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/redirect-no-fragment")) {
        return req.respond("", .{
            .status = .found,
            .extra_headers = &.{
                .{ .name = "Location", .value = "/redirect-target" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/redirect-target")) {
        return req.respond("<!DOCTYPE html><title>landed</title>", .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/html; charset=utf-8" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/303-no-location")) {
        // 3xx WITHOUT a Location header: not a redirect, a final response
        // whose body must be delivered (RFC 9110 §15.4).
        return req.respond("<!DOCTYPE html><title>landed</title><p>see other body</p>", .{
            .status = .see_other,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/html; charset=utf-8" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/300-with-location")) {
        // A non-redirect 3xx (fetch's redirect statuses are only 301, 302,
        // 303, 307 and 308) carrying a Location header: the header is a
        // preference hint, not a redirect — the body must be delivered.
        return req.respond("<!DOCTYPE html><title>choices</title><p>multiple choices body</p>", .{
            .status = .multiple_choice,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/html; charset=utf-8" },
                .{ .name = "Location", .value = "http://127.0.0.1:9582/hi.html" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/redirect-with-fragment")) {
        return req.respond("", .{
            .status = .found,
            .extra_headers = &.{
                .{ .name = "Location", .value = "/redirect-target#target_fragment" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/referrer/redirect-cross-origin")) {
        return req.respond("", .{
            .status = .found,
            .extra_headers = &.{
                .{ .name = "Location", .value = "http://localhost:9582/referrer/final-cross-origin" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/referrer/redirect-no-referrer")) {
        return req.respond("", .{
            .status = .found,
            .extra_headers = &.{
                .{ .name = "Referrer-Policy", .value = "future-policy, no-referrer" },
                .{ .name = "Location", .value = "/referrer/final-no-referrer" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/referrer/final-cross-origin") or
        std.mem.eql(u8, path, "/referrer/final-no-referrer"))
    {
        return req.respond(
            "<!doctype html><script>parent.postMessage({kind:location.pathname,referrer:document.referrer}, '*')</script>",
            .{ .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/html; charset=utf-8" },
            } },
        );
    }

    if (std.mem.eql(u8, path, "/xhr/404")) {
        return req.respond("Not Found", .{
            .status = .not_found,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/plain" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/src/browser/tests/401")) {
        return req.respond("No", .{
            .status = .unauthorized,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/plain" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/404.js")) {
        // Valid JS body served with a 404 status. Used to assert that
        // ScriptManager does NOT execute the body of a failed script
        // fetch — if it did, window.__404_body_executed would be set.
        return req.respond("window.__404_body_executed = true;", .{
            .status = .not_found,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "application/javascript" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/defer-marker.js")) {
        // A deferred script body. Used by the regression test for a
        // <script defer> whose completion is deferred by a later
        // <link rel=stylesheet>'s synchronous fetch — it must still execute.
        return req.respond("window.__deferRan = true;", .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "application/javascript" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/xhr/500")) {
        return req.respond("Internal Server Error", .{
            .status = .internal_server_error,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/plain" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/xhr/binary")) {
        return req.respond(&.{ 0, 0, 1, 2, 0, 0, 9 }, .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "application/octet-stream" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/styles/visibility.css")) {
        // Used by css/external_stylesheet.html — drives the visibility
        // cascade through StyleManager via Frame.loadExternalStylesheet
        // so a `.ext-hide` element is observable to checkVisibility().
        return req.respond(".ext-hide { display: none; }", .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/css" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/styles/visibility2.css")) {
        // Second visibility sheet used by the href-change regression test:
        // mutating link.href must replace the cached sheet's rules in place,
        // not append a new entry to document.styleSheets.
        return req.respond(".ext-hide-2 { display: none; }", .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/css" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/styles/404.css")) {
        return req.respond("/* unused */", .{
            .status = .not_found,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/css" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/styles/oversize.css")) {
        // Body that exceeds Frame.MAX_STYLESHEET_BYTES (2 MiB) — written as a
        // long sequence of valid declarations so the response itself parses
        // fine and the error path is exercised by the size cap, not by a
        // CSS parse failure.
        const chunk = ".pad { color: #abcdef; } "; // 25 bytes
        const repeats = (2 * 1024 * 1024 / chunk.len) + 1024;
        var body = try std.ArrayList(u8).initCapacity(arena_allocator, chunk.len * repeats);
        for (0..repeats) |_| body.appendSliceAssumeCapacity(chunk);
        return req.respond(body.items, .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/css" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/wasm/minimal.wasm")) {
        // A valid empty WebAssembly module, served through the real fetch path
        // with the MIME type required by compileStreaming.
        const module = [_]u8{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 };
        return req.respond(&module, .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "application/wasm" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/src/browser/tests/csp/code_generation_header.html") or
        std.mem.startsWith(u8, path, "/src/browser/tests/csp/code_generation_header.html?"))
    {
        // A real navigation response policy, kept separate from the meta
        // fixtures so both CSP delivery paths exercise the same V8 callbacks.
        return req.respond(@embedFile("browser/tests/csp/code_generation_header.html"), .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/html; charset=utf-8" },
                .{ .name = "Content-Security-Policy", .value = "script-src 'self' 'unsafe-inline'" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/src/browser/tests/csp/trusted_types_header.html") or
        std.mem.startsWith(u8, path, "/src/browser/tests/csp/trusted_types_header.html?"))
    {
        return req.respond(@embedFile("browser/tests/csp/trusted_types_header.html"), .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/html; charset=utf-8" },
                .{ .name = "Content-Security-Policy", .value = "require-trusted-types-for 'script'; trusted-types * 'allow-duplicates'; script-src 'self' 'unsafe-inline' 'unsafe-eval'" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/src/browser/tests/csp/trusted_types_document_write.html") or
        std.mem.startsWith(u8, path, "/src/browser/tests/csp/trusted_types_document_write.html?"))
    {
        return req.respond(@embedFile("browser/tests/csp/trusted_types_document_write.html"), .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/html; charset=utf-8" },
                .{ .name = "Content-Security-Policy", .value = "require-trusted-types-for 'script'; trusted-types * 'allow-duplicates'; script-src 'self' 'unsafe-inline'" },
            },
        });
    }

    inline for (.{
        "trusted_types_default_missing.html",
        "trusted_types_default_nullish.html",
        "trusted_types_default_throw.html",
    }) |fixture| {
        const fixture_path = "/src/browser/tests/csp/" ++ fixture;
        if (std.mem.eql(u8, path, fixture_path) or
            (std.mem.startsWith(u8, path, fixture_path) and path.len > fixture_path.len and path[fixture_path.len] == '?'))
        {
            return req.respond(@embedFile("browser/tests/csp/" ++ fixture), .{
                .extra_headers = &.{
                    .{ .name = "Content-Type", .value = "text/html; charset=utf-8" },
                    .{ .name = "Content-Security-Policy", .value = "require-trusted-types-for 'script'; trusted-types default; script-src 'self' 'unsafe-inline'" },
                },
            });
        }
    }

    inline for (.{
        "trusted_types_codegen_require.html",
        "trusted_types_codegen_default.html",
        "trusted_types_codegen_default_reject.html",
    }) |fixture| {
        const fixture_path = "/src/browser/tests/csp/" ++ fixture;
        if (std.mem.eql(u8, path, fixture_path) or
            (std.mem.startsWith(u8, path, fixture_path) and path.len > fixture_path.len and path[fixture_path.len] == '?'))
        {
            return req.respond(@embedFile("browser/tests/csp/" ++ fixture), .{
                .extra_headers = &.{
                    .{ .name = "Content-Type", .value = "text/html; charset=utf-8" },
                    .{ .name = "Content-Security-Policy", .value = "require-trusted-types-for 'script'; trusted-types * 'allow-duplicates'; script-src 'self' 'unsafe-inline' 'unsafe-eval'" },
                },
            });
        }
    }

    if (std.mem.eql(u8, path, "/src/browser/tests/csp/trusted_types_codegen_tteval.html") or
        std.mem.startsWith(u8, path, "/src/browser/tests/csp/trusted_types_codegen_tteval.html?"))
    {
        return req.respond(@embedFile("browser/tests/csp/trusted_types_codegen_tteval.html"), .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/html; charset=utf-8" },
                .{ .name = "Content-Security-Policy", .value = "require-trusted-types-for 'script'; trusted-types * 'allow-duplicates'; script-src 'self' 'unsafe-inline' 'trusted-types-eval'" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/src/browser/tests/csp/trusted_types_report_only.html") or
        std.mem.startsWith(u8, path, "/src/browser/tests/csp/trusted_types_report_only.html?"))
    {
        return req.respond(@embedFile("browser/tests/csp/trusted_types_report_only.html"), .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/html; charset=utf-8" },
                .{ .name = "Content-Security-Policy-Report-Only", .value = "require-trusted-types-for 'script'; trusted-types alpha" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/src/browser/tests/csp/trusted_types_codegen_report_only.html") or
        std.mem.startsWith(u8, path, "/src/browser/tests/csp/trusted_types_codegen_report_only.html?"))
    {
        return req.respond(@embedFile("browser/tests/csp/trusted_types_codegen_report_only.html"), .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/html; charset=utf-8" },
                .{ .name = "Content-Security-Policy-Report-Only", .value = "require-trusted-types-for 'script'" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/src/browser/tests/csp/trusted_types_report_only_worker.js") or
        std.mem.startsWith(u8, path, "/src/browser/tests/csp/trusted_types_report_only_worker.js?"))
    {
        return req.respond(@embedFile("browser/tests/csp/trusted_types_report_only_worker.js"), .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "application/javascript; charset=utf-8" },
                .{ .name = "Content-Security-Policy-Report-Only", .value = "require-trusted-types-for 'script'" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/src/browser/tests/csp/worker_trusted_script_url_constructor.html") or
        std.mem.startsWith(u8, path, "/src/browser/tests/csp/worker_trusted_script_url_constructor.html?"))
    {
        return req.respond(@embedFile("browser/tests/csp/worker_trusted_script_url_constructor.html"), .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/html; charset=utf-8" },
                .{ .name = "Content-Security-Policy", .value = "require-trusted-types-for 'script'; trusted-types worker-url default; script-src 'self' 'unsafe-inline' 'unsafe-eval' blob: data:; worker-src 'self' blob: data:" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/src/browser/tests/csp/worker_policy_probe.js") or
        std.mem.startsWith(u8, path, "/src/browser/tests/csp/worker_policy_probe.js?"))
    {
        if (std.mem.indexOf(u8, path, "delay_ms=")) |pos| {
            const digits_start = pos + "delay_ms=".len;
            var end = digits_start;
            while (end < path.len and std.ascii.isDigit(path[end])) : (end += 1) {}
            const delay_ms = std.fmt.parseInt(u64, path[digits_start..end], 10) catch 0;
            std.Thread.sleep(delay_ms * std.time.ns_per_ms);
        }

        const body = @embedFile("browser/tests/csp/worker_policy_probe.js");
        if (std.mem.indexOf(u8, path, "policy=report") != null) {
            return req.respond(body, .{
                .extra_headers = &.{
                    .{ .name = "Content-Type", .value = "application/javascript; charset=utf-8" },
                    .{ .name = "Content-Security-Policy-Report-Only", .value = "require-trusted-types-for 'script'; trusted-types default; script-src 'unsafe-eval'" },
                },
            });
        }
        if (std.mem.indexOf(u8, path, "policy=enforce") != null) {
            return req.respond(body, .{
                .extra_headers = &.{
                    .{ .name = "Content-Type", .value = "application/javascript; charset=utf-8" },
                    .{ .name = "Content-Security-Policy", .value = "require-trusted-types-for 'script'; trusted-types default; script-src 'unsafe-eval'" },
                },
            });
        }
        if (std.mem.indexOf(u8, path, "policy=tteval") != null) {
            return req.respond(body, .{
                .extra_headers = &.{
                    .{ .name = "Content-Type", .value = "application/javascript; charset=utf-8" },
                    .{ .name = "Content-Security-Policy", .value = "require-trusted-types-for 'script'; trusted-types * 'allow-duplicates'; script-src 'trusted-types-eval'" },
                },
            });
        }
        return req.respond(body, .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "application/javascript; charset=utf-8" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/echo_referer")) {
        // Echo the request's Referer header back as HTML so tests can assert
        // what Referer the navigation sent. Used by the cross-page Referer test.
        var it = req.iterateHeaders();
        var referer: []const u8 = "NONE";
        while (it.next()) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "Referer")) {
                referer = h.value;
                break;
            }
        }
        var html_buf: [512]u8 = undefined;
        const html = try std.fmt.bufPrint(&html_buf, "<html><body>referer={s}</body></html>", .{referer});
        return req.respond(html, .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/html; charset=utf-8" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/referer_link.html")) {
        // Page with an anchor link to /echo_referer. The test clicks the link
        // via JS and asserts the resulting page reports Referer = this page.
        return req.respond(
            "<html><body><a id=\"link\" href=\"/echo_referer\">go</a></body></html>",
            .{
                .extra_headers = &.{
                    .{ .name = "Content-Type", .value = "text/html; charset=utf-8" },
                },
            },
        );
    }

    if (std.mem.eql(u8, path, "/echo_method")) {
        // Echo the request method back as HTML so tests can assert on what
        // method the navigation used. Used by the Page.reload-replays-POST test.
        const method_name = @tagName(req.head.method);
        var html_buf: [128]u8 = undefined;
        const html = try std.fmt.bufPrint(&html_buf, "<html><body>method={s}</body></html>", .{method_name});
        return req.respond(html, .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/html; charset=utf-8" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/redirect_to_echo")) {
        // 302 to /echo_method. Used by the Page.reload-after-redirect test to
        // confirm a POST→302→GET chain doesn't replay POST on reload.
        return req.respond("", .{
            .status = .found,
            .extra_headers = &.{
                .{ .name = "Location", .value = "/echo_method" },
            },
        });
    }

    if (std.mem.eql(u8, path, "/download/report.csv")) {
        // A file download: Content-Disposition: attachment drives the
        // Browser.setDownloadBehavior path (issue #2701).
        return req.respond("col1,col2\nhello,world\n42,1337\n", .{
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = "text/csv" },
                .{ .name = "Content-Disposition", .value = "attachment; filename=\"report.csv\"" },
            },
        });
    }

    if (std.mem.startsWith(u8, path, "/src/browser/tests/")) {
        if (std.mem.indexOf(u8, path, "delay_ms=")) |pos| {
            const digits_start = pos + "delay_ms=".len;
            var end = digits_start;
            while (end < path.len and std.ascii.isDigit(path[end])) : (end += 1) {}
            const delay_ms = std.fmt.parseInt(u64, path[digits_start..end], 10) catch 0;
            std.Thread.sleep(delay_ms * std.time.ns_per_ms);
        }
        // strip off leading / so that it's relative to CWD
        return TestHTTPServer.sendFile(req, path[1..]);
    }

    // Image fixtures often intentionally reference a missing resource. Keep
    // those requests deterministic and non-fatal instead of crashing the
    // shared test server's connection thread at the final `unreachable`.
    const path_without_query = path[0 .. std.mem.indexOfScalar(u8, path, '?') orelse path.len];
    inline for (.{ ".png", ".jpg", ".jpeg", ".gif", ".webp", ".avif", ".svg" }) |extension| {
        if (std.mem.endsWith(u8, path_without_query, extension)) {
            return req.respond("image fixture not found", .{ .status = .not_found });
        }
    }

    std.debug.print("TestHTTPServer was asked to serve an unknown file: {s}\n", .{path});

    unreachable;
}

/// LogFilter provides a scoped way to suppress specific log categories during tests.
/// This is useful for tests that trigger expected errors or warnings.
pub const LogFilter = struct {
    old_filter: [log.num_scopes]bool,

    /// Sets the log filter to suppress the specified scope(s).
    /// Returns a LogFilter that should be deinitialized to restore previous filters.
    pub fn init(comptime scopes: []const log.Scope) LogFilter {
        comptime std.debug.assert(@TypeOf(scopes) == []const log.Scope);
        const old_filter = log.opts.scope_enabled;
        inline for (scopes) |scope| {
            log.opts.scope_enabled[@intFromEnum(scope)] = false;
        }
        return .{ .old_filter = old_filter };
    }

    /// Restores the log filters to their previous state.
    pub fn deinit(self: LogFilter) void {
        log.opts.scope_enabled = self.old_filter;
    }
};
