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
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;

const BORDER = "=" ** 80;

// use in custom panic handler
var current_test: ?[]const u8 = null;
pub var v8_peak_memory: usize = 0;
pub var tracking_allocator: Allocator = undefined;

var RUNNER: *Runner = undefined;

pub fn main() !void {
    var mem: [8192]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&mem);

    var gpa: std.heap.DebugAllocator(.{}) = .init;
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();

    var ta = TrackingAllocator.init(gpa.allocator());
    tracking_allocator = ta.allocator();

    const allocator = fba.allocator();

    const env = Env.init(allocator);

    var runner = Runner.init(allocator, gpa.allocator(), arena.allocator(), &ta, env);
    RUNNER = &runner;
    try runner.run();
}

const Runner = struct {
    env: Env,
    allocator: Allocator,
    report_allocator: Allocator,
    ta: *TrackingAllocator,

    // per-test arena, used for collecting substests
    arena: Allocator,
    subtests: std.ArrayList([]const u8),

    fn init(
        allocator: Allocator,
        report_allocator: Allocator,
        arena: Allocator,
        ta: *TrackingAllocator,
        env: Env,
    ) Runner {
        return .{
            .ta = ta,
            .env = env,
            .arena = arena,
            .subtests = .empty,
            .allocator = allocator,
            .report_allocator = report_allocator,
        };
    }

    pub fn run(self: *Runner) !void {
        var slowest = SlowTracker.init(self.allocator, 5);
        defer slowest.deinit();

        var fail_list: std.ArrayList([]const u8) = .empty;
        var test_results: std.ArrayList(TestResult) = .empty;

        var pass: usize = 0;
        var fail: usize = 0;
        var skip: usize = 0;
        var leak: usize = 0;
        var selected: usize = 0;
        // track all tests duration, excluding setup and teardown.
        var ns_duration: u64 = 0;

        Printer.fmt("\r\x1b[0K", .{}); // beginning of line and clear to end of line

        for (builtin.test_functions) |t| {
            if (isSetup(t)) {
                t.func() catch |err| {
                    Printer.status(.fail, "\nsetup \"{s}\" failed: {}\n", .{ t.name, err });
                    return err;
                };
            }
        }

        // If we have a subfilter, Document#query_selector_all
        // Then we have a special check to make sure _some_ test was run. This
        const webapi_html_test_mode = self.env.filter == null and self.env.subfilter != null;

        for (builtin.test_functions) |t| {
            if (isSetup(t) or isTeardown(t)) {
                continue;
            }

            var status = Status.pass;
            slowest.startTiming();

            const is_unnamed_test = isUnnamed(t);
            if (!is_unnamed_test) {
                if (self.env.filter) |f| {
                    if (std.mem.indexOf(u8, t.name, f) == null) {
                        continue;
                    }
                } else if (webapi_html_test_mode) {
                    // allow filtering by subfilter only, assumes subfilters
                    // only exists for "WebApi: " tests (which is true for now).
                    if (std.mem.indexOf(u8, t.name, "WebApi: ") == null) {
                        continue;
                    }
                }
            }

            const friendly_name = blk: {
                const name = t.name;
                var it = std.mem.splitScalar(u8, name, '.');
                while (it.next()) |value| {
                    if (std.mem.eql(u8, value, "test")) {
                        const rest = it.rest();
                        break :blk if (rest.len > 0) rest else name;
                    }
                }
                break :blk name;
            };
            defer {
                self.subtests = .{};
                const arena: *std.heap.ArenaAllocator = @ptrCast(@alignCast(self.arena.ptr));
                _ = arena.reset(.{ .retain_with_limit = 2048 });
            }

            current_test = friendly_name;
            std.testing.allocator_instance = .{};
            const result = t.func();
            current_test = null;

            const leaked = std.testing.allocator_instance.deinit() == .leak;
            if (webapi_html_test_mode and self.subtests.items.len == 0) {
                if (leaked) {
                    leak += 1;
                    fail += 1;
                    Printer.status(.fail, "\n{s}\n\"{s}\" - Memory Leak\n{s}\n", .{ BORDER, friendly_name, BORDER });
                    try fail_list.append(self.report_allocator, friendly_name);
                    if (self.env.fail_first) break;
                }
                continue;
            }

            const ns_taken = slowest.endTiming(friendly_name, is_unnamed_test);
            ns_duration += ns_taken;

            if (leaked) {
                leak += 1;
                Printer.status(.fail, "\n{s}\n\"{s}\" - Memory Leak\n{s}\n", .{ BORDER, friendly_name, BORDER });
            }

            var error_name: ?[]const u8 = null;
            var was_skipped = false;
            if (result) |_| {} else |err| switch (err) {
                error.SkipZigTest => {
                    was_skipped = true;
                },
                else => {
                    error_name = @errorName(err);
                    Printer.status(.fail, "\n{s}\n\"{s}\" - {s}\n", .{ BORDER, friendly_name, @errorName(err) });
                    if (self.subtests.getLastOrNull()) |st| {
                        Printer.status(.fail, " {s}\n", .{st});
                    }
                    Printer.status(.fail, BORDER ++ "\n", .{});
                    if (@errorReturnTrace()) |trace| {
                        std.debug.dumpStackTrace(trace.*);
                    }
                },
            }

            const failed = leaked or error_name != null;
            if (failed) {
                status = .fail;
                fail += 1;
                try fail_list.append(self.report_allocator, friendly_name);
            } else if (was_skipped) {
                status = .skip;
                skip += 1;
            } else if (!is_unnamed_test) {
                pass += 1;
            }

            if (!is_unnamed_test) {
                selected += 1;
                try test_results.append(self.report_allocator, .{
                    .name = friendly_name,
                    .status = switch (status) {
                        .pass => .passed,
                        .fail => .failed,
                        .skip => .skipped,
                        .text => unreachable,
                    },
                    .duration_nanoseconds = ns_taken,
                    .error_name = error_name,
                    .memory_leak = leaked,
                });

                if (self.env.verbose) {
                    const ms = @as(f64, @floatFromInt(ns_taken)) / 1_000_000.0;
                    Printer.status(status, "{s} ({d:.2}ms)\n", .{ friendly_name, ms });
                    for (self.subtests.items) |st| {
                        Printer.status(status, "  - {s} \n", .{st});
                    }
                } else {
                    Printer.status(status, ".", .{});
                }
            }

            if (failed and self.env.fail_first) break;
        }

        for (builtin.test_functions) |t| {
            if (isTeardown(t)) {
                t.func() catch |err| {
                    Printer.status(.fail, "\nteardown \"{s}\" failed: {}\n", .{ t.name, err });
                    return err;
                };
            }
        }

        const zero_matches = selected == 0;
        if (zero_matches) {
            Printer.status(.fail, "\nNo tests matched the requested filter.\n", .{});
        }

        const total_tests = pass + fail;
        const succeeded = !zero_matches and fail == 0 and leak == 0;
        const status = if (succeeded) Status.pass else Status.fail;
        Printer.status(status, "\n{d} of {d} test{s} passed\n", .{ pass, total_tests, if (total_tests != 1) "s" else "" });
        if (skip > 0) {
            Printer.status(.skip, "{d} test{s} skipped\n", .{ skip, if (skip != 1) "s" else "" });
        }
        if (leak > 0) {
            Printer.status(.fail, "{d} test{s} leaked\n", .{ leak, if (leak != 1) "s" else "" });
        }
        Printer.fmt("\n", .{});

        try slowest.display();
        Printer.fmt("\n", .{});
        // stats
        if (self.env.metrics) {
            var stdout = std.fs.File.stdout();
            var writer = stdout.writer(&.{});
            const stats = self.ta.stats();
            try std.json.Stringify.value(&.{
                .{ .name = "browser", .bench = .{
                    .duration = ns_duration,
                    .alloc_nb = stats.allocation_count,
                    .realloc_nb = stats.reallocation_count,
                    .alloc_size = stats.allocated_bytes,
                } },
                .{ .name = "v8", .bench = .{
                    .duration = ns_duration,
                    .alloc_nb = 0,
                    .realloc_nb = 0,
                    .alloc_size = v8_peak_memory,
                } },
            }, .{ .whitespace = .indent_2 }, &writer.interface);
            Printer.fmt("\n", .{});
        }

        if (fail_list.items.len > 0) {
            Printer.status(.fail, "Failed Test Summary: \n", .{});
            for (fail_list.items) |name| {
                Printer.status(.fail, "- {s}\n", .{name});
            }
            Printer.fmt("\n", .{});
        }

        const summary: RunSummary = .{
            .selected = selected,
            .passed = pass,
            .failed = fail,
            .skipped = skip,
            .leaked = leak,
            .duration_nanoseconds = ns_duration,
            .fail_first = self.env.fail_first,
            .zero_matches = zero_matches,
            .success = succeeded,
        };
        try writeReports(self.report_allocator, self.env, summary, test_results.items);

        std.posix.exit(summary.exitCode());
    }
};

pub fn shouldRun(name: []const u8) bool {
    const sf = RUNNER.env.subfilter orelse return true;
    return std.mem.indexOf(u8, name, sf) != null;
}

pub fn subtest(name: []const u8) !void {
    try RUNNER.subtests.append(RUNNER.arena, try RUNNER.arena.dupe(u8, name));
}

const Printer = struct {
    fn fmt(comptime format: []const u8, args: anytype) void {
        std.debug.print(format, args);
    }

    fn status(s: Status, comptime format: []const u8, args: anytype) void {
        switch (s) {
            .pass => std.debug.print("\x1b[32m", .{}),
            .fail => std.debug.print("\x1b[31m", .{}),
            .skip => std.debug.print("\x1b[33m", .{}),
            else => {},
        }
        std.debug.print(format ++ "\x1b[0m", args);
    }
};

const Status = enum {
    pass,
    fail,
    skip,
    text,
};

const TestStatus = enum {
    passed,
    failed,
    skipped,
};

const TestResult = struct {
    name: []const u8,
    status: TestStatus,
    duration_nanoseconds: u64,
    error_name: ?[]const u8,
    memory_leak: bool,
};

const RunSummary = struct {
    selected: usize,
    passed: usize,
    failed: usize,
    skipped: usize,
    leaked: usize,
    duration_nanoseconds: u64,
    fail_first: bool,
    zero_matches: bool,
    success: bool,

    fn exitCode(self: RunSummary) u8 {
        return if (self.success) 0 else 1;
    }
};

const JsonReport = struct {
    schema: []const u8 = "darkpanda-test-results/v1",
    summary: RunSummary,
    tests: []const TestResult,
};

fn writeReports(
    allocator: Allocator,
    env: Env,
    summary: RunSummary,
    test_results: []const TestResult,
) !void {
    if (env.json_output) |path| {
        try writeJsonReport(allocator, path, summary, test_results);
    }
    if (env.junit_output) |path| {
        try writeJUnitReport(allocator, path, summary, test_results);
    }
}

fn writeJsonReport(
    allocator: Allocator,
    path: []const u8,
    summary: RunSummary,
    test_results: []const TestResult,
) !void {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();

    try std.json.Stringify.value(
        JsonReport{
            .summary = summary,
            .tests = test_results,
        },
        .{ .whitespace = .indent_2 },
        &output.writer,
    );
    try output.writer.writeByte('\n');
    try writeOutputFile(path, output.written());
}

fn writeJUnitReport(
    allocator: Allocator,
    path: []const u8,
    summary: RunSummary,
    test_results: []const TestResult,
) !void {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    const writer = &output.writer;

    var reported_failures: usize = 0;
    var reported_skips: usize = 0;
    for (test_results) |result| {
        switch (result.status) {
            .passed => {},
            .failed => reported_failures += 1,
            .skipped => reported_skips += 1,
        }
    }

    const discovery_failure: usize = @intFromBool(summary.zero_matches);
    const suite_tests = test_results.len + discovery_failure;
    const suite_failures = reported_failures + discovery_failure;
    const seconds = @as(f64, @floatFromInt(summary.duration_nanoseconds)) /
        @as(f64, @floatFromInt(std.time.ns_per_s));

    try writer.writeAll("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n");
    try writer.print(
        "<testsuites tests=\"{d}\" failures=\"{d}\" errors=\"0\" skipped=\"{d}\" time=\"{d:.9}\">\n",
        .{ suite_tests, suite_failures, reported_skips, seconds },
    );
    try writer.print(
        "  <testsuite name=\"darkpanda\" tests=\"{d}\" failures=\"{d}\" errors=\"0\" skipped=\"{d}\" time=\"{d:.9}\">\n",
        .{ suite_tests, suite_failures, reported_skips, seconds },
    );

    for (test_results) |result| {
        const test_seconds = @as(f64, @floatFromInt(result.duration_nanoseconds)) /
            @as(f64, @floatFromInt(std.time.ns_per_s));
        try writer.writeAll("    <testcase name=\"");
        try writeXmlEscaped(writer, result.name);
        try writer.print("\" classname=\"darkpanda\" time=\"{d:.9}\"", .{test_seconds});
        switch (result.status) {
            .passed => try writer.writeAll("/>\n"),
            .skipped => try writer.writeAll("><skipped/></testcase>\n"),
            .failed => {
                try writer.writeAll(">\n      <failure message=\"");
                try writeFailureDescription(writer, result);
                try writer.writeAll("\">");
                try writeFailureDescription(writer, result);
                try writer.writeAll("</failure>\n    </testcase>\n");
            },
        }
    }

    if (summary.zero_matches) {
        try writer.writeAll(
            "    <testcase name=\"test discovery\" classname=\"darkpanda.test-runner\" time=\"0.000000000\">\n" ++
                "      <failure message=\"No tests matched\">No tests matched the requested filter.</failure>\n" ++
                "    </testcase>\n",
        );
    }

    try writer.writeAll("  </testsuite>\n</testsuites>\n");
    try writeOutputFile(path, output.written());
}

fn writeFailureDescription(writer: *std.Io.Writer, result: TestResult) !void {
    if (result.error_name) |name| {
        try writeXmlEscaped(writer, name);
        if (result.memory_leak) try writer.writeAll("; ");
    }
    if (result.memory_leak) {
        try writer.writeAll("Memory leak detected");
    } else if (result.error_name == null) {
        try writer.writeAll("Test failed");
    }
}

fn writeXmlEscaped(writer: *std.Io.Writer, value: []const u8) !void {
    var start: usize = 0;
    for (value, 0..) |byte, index| {
        const replacement: ?[]const u8 = switch (byte) {
            '&' => "&amp;",
            '<' => "&lt;",
            '>' => "&gt;",
            '"' => "&quot;",
            '\'' => "&apos;",
            else => null,
        };
        if (replacement) |escaped| {
            try writer.writeAll(value[start..index]);
            try writer.writeAll(escaped);
            start = index + 1;
        }
    }
    try writer.writeAll(value[start..]);
}

fn writeOutputFile(path: []const u8, data: []const u8) !void {
    if (std.fs.path.dirname(path)) |directory| {
        if (directory.len > 0) try std.fs.cwd().makePath(directory);
    }
    var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(data);
    try file.sync();
}

const SlowTracker = struct {
    const SlowestQueue = std.PriorityDequeue(TestInfo, void, compareTiming);
    max: usize,
    slowest: SlowestQueue,
    timer: std.time.Timer,

    fn init(allocator: Allocator, count: u32) SlowTracker {
        const timer = std.time.Timer.start() catch @panic("failed to start timer");
        var slowest = SlowestQueue.init(allocator, {});
        slowest.ensureTotalCapacity(count) catch @panic("OOM");
        return .{
            .max = count,
            .timer = timer,
            .slowest = slowest,
        };
    }

    const TestInfo = struct {
        ns: u64,
        name: []const u8,
    };

    fn deinit(self: SlowTracker) void {
        self.slowest.deinit();
    }

    fn startTiming(self: *SlowTracker) void {
        self.timer.reset();
    }

    fn endTiming(self: *SlowTracker, test_name: []const u8, is_unnamed_test: bool) u64 {
        var timer = self.timer;
        const ns = timer.lap();
        if (is_unnamed_test) {
            return ns;
        }

        var slowest = &self.slowest;

        if (slowest.count() < self.max) {
            // Capacity is fixed to the # of slow tests we want to track
            // If we've tracked fewer tests than this capacity, than always add
            slowest.add(TestInfo{ .ns = ns, .name = test_name }) catch @panic("failed to track test timing");
            return ns;
        }

        {
            // Optimization to avoid shifting the dequeue for the common case
            // where the test isn't one of our slowest.
            const fastest_of_the_slow = slowest.peekMin() orelse unreachable;
            if (fastest_of_the_slow.ns > ns) {
                // the test was faster than our fastest slow test, don't add
                return ns;
            }
        }

        // the previous fastest of our slow tests, has been pushed off.
        _ = slowest.removeMin();
        slowest.add(TestInfo{ .ns = ns, .name = test_name }) catch @panic("failed to track test timing");
        return ns;
    }

    fn display(self: *SlowTracker) !void {
        var slowest = self.slowest;
        const count = slowest.count();
        Printer.fmt("Slowest {d} test{s}: \n", .{ count, if (count != 1) "s" else "" });
        while (slowest.removeMinOrNull()) |info| {
            const ms = @as(f64, @floatFromInt(info.ns)) / 1_000_000.0;
            Printer.fmt("  {d:.2}ms\t{s}\n", .{ ms, info.name });
        }
    }

    fn compareTiming(context: void, a: TestInfo, b: TestInfo) std.math.Order {
        _ = context;
        return std.math.order(a.ns, b.ns);
    }
};

const Env = struct {
    verbose: bool,
    fail_first: bool,
    filter: ?[]const u8,
    subfilter: ?[]const u8,
    metrics: bool,
    json_output: ?[]const u8,
    junit_output: ?[]const u8,

    fn init(allocator: Allocator) Env {
        const full_filter = readEnv(allocator, "TEST_FILTER");
        const filter, const subfilter = parseFilter(full_filter);
        return .{
            .verbose = readEnvBool(allocator, "TEST_VERBOSE", true),
            .fail_first = readEnvBool(allocator, "TEST_FAIL_FIRST", false),
            .filter = filter,
            .subfilter = subfilter,
            .metrics = readEnvBool(allocator, "METRICS", false),
            .json_output = readEnvPath(allocator, "TEST_JSON_OUTPUT"),
            .junit_output = readEnvPath(allocator, "TEST_JUNIT_OUTPUT"),
        };
    }

    fn deinit(self: Env, allocator: Allocator) void {
        if (self.filter) |f| {
            allocator.free(f);
        }
    }

    fn readEnv(allocator: Allocator, key: []const u8) ?[]const u8 {
        const v = std.process.getEnvVarOwned(allocator, key) catch |err| {
            if (err == error.EnvironmentVariableNotFound) {
                return null;
            }
            std.log.warn("failed to get env var {s} due to err {}", .{ key, err });
            return null;
        };
        return v;
    }

    fn readEnvBool(allocator: Allocator, key: []const u8, deflt: bool) bool {
        const value = readEnv(allocator, key) orelse return deflt;
        defer allocator.free(value);
        return std.ascii.eqlIgnoreCase(value, "true");
    }

    fn readEnvPath(allocator: Allocator, key: []const u8) ?[]const u8 {
        const value = readEnv(allocator, key) orelse return null;
        if (value.len > 0) return value;
        allocator.free(value);
        return null;
    }

    fn parseFilter(full_filter: ?[]const u8) struct { ?[]const u8, ?[]const u8 } {
        const ff = full_filter orelse return .{ null, null };
        if (ff.len == 0) return .{ null, null };

        const split = std.mem.indexOfScalarPos(u8, ff, 0, '#') orelse {
            return .{ ff, null };
        };

        const filter = std.mem.trim(u8, ff[0..split], " ");

        return .{
            if (filter.len == 0) null else filter,
            std.mem.trim(u8, ff[split + 1 ..], " "),
        };
    }
};

pub const panic = std.debug.FullPanic(struct {
    pub fn panicFn(msg: []const u8, first_trace_addr: ?usize) noreturn {
        if (current_test) |ct| {
            std.debug.print("\x1b[31m{s}\npanic running \"{s}\"\n", .{ BORDER, ct });
            if (RUNNER.subtests.getLastOrNull()) |st| {
                std.debug.print(" {s}\n", .{st});
            }
            std.debug.print("\x1b[0m{s}\n", .{BORDER});
        }
        std.debug.defaultPanic(msg, first_trace_addr);
    }
}.panicFn);

fn isUnnamed(t: std.builtin.TestFn) bool {
    const marker = ".test_";
    const test_name = t.name;
    const index = std.mem.indexOf(u8, test_name, marker) orelse return false;
    _ = std.fmt.parseInt(u32, test_name[index + marker.len ..], 10) catch return false;
    return true;
}

fn isSetup(t: std.builtin.TestFn) bool {
    return std.mem.endsWith(u8, t.name, "tests:beforeAll");
}

fn isTeardown(t: std.builtin.TestFn) bool {
    return std.mem.endsWith(u8, t.name, "tests:afterAll");
}

pub const TrackingAllocator = struct {
    parent_allocator: Allocator,
    free_count: usize = 0,
    allocated_bytes: usize = 0,
    allocation_count: usize = 0,
    reallocation_count: usize = 0,
    mutex: std.Thread.Mutex = .{},

    const Stats = struct {
        allocated_bytes: usize,
        allocation_count: usize,
        reallocation_count: usize,
    };

    fn init(parent_allocator: Allocator) TrackingAllocator {
        return .{
            .parent_allocator = parent_allocator,
        };
    }

    pub fn stats(self: *const TrackingAllocator) Stats {
        return .{
            .allocated_bytes = self.allocated_bytes,
            .allocation_count = self.allocation_count,
            .reallocation_count = self.reallocation_count,
        };
    }

    pub fn allocator(self: *TrackingAllocator) Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .free = free,
            .remap = remap,
        } };
    }

    fn alloc(
        ctx: *anyopaque,
        len: usize,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) ?[*]u8 {
        const self: *TrackingAllocator = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();

        const result = self.parent_allocator.rawAlloc(len, alignment, return_address);
        self.allocation_count += 1;
        self.allocated_bytes += len;
        return result;
    }

    fn resize(
        ctx: *anyopaque,
        old_mem: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ra: usize,
    ) bool {
        const self: *TrackingAllocator = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();

        const result = self.parent_allocator.rawResize(old_mem, alignment, new_len, ra);
        if (result) self.reallocation_count += 1;
        return result;
    }

    fn free(
        ctx: *anyopaque,
        old_mem: []u8,
        alignment: std.mem.Alignment,
        ra: usize,
    ) void {
        const self: *TrackingAllocator = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();

        self.parent_allocator.rawFree(old_mem, alignment, ra);
        self.free_count += 1;
    }

    fn remap(
        ctx: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) ?[*]u8 {
        const self: *TrackingAllocator = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        defer self.mutex.unlock();

        const result = self.parent_allocator.rawRemap(memory, alignment, new_len, ret_addr);
        if (result != null) self.reallocation_count += 1;
        return result;
    }
};
