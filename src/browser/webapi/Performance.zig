// Copyright (C) 2023-2026  Lightpanda (Selecy SAS)
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

const js = @import("../js/js.zig");
const datetime = @import("../../datetime.zig");

const EventCounts = @import("EventCounts.zig");
const Event = @import("Event.zig");
const EventTarget = @import("EventTarget.zig");
const PerformanceObserver = @import("PerformanceObserver.zig");
const HttpClient = @import("../HttpClient.zig");

const Execution = js.Execution;
const Allocator = std.mem.Allocator;

pub fn registerTypes() []const type {
    return &.{ Performance, Entry, ResourceTiming, Mark, Measure, PerformanceTiming, PerformanceNavigation, MemoryInfo };
}

const Performance = @This();

const default_resource_timing_buffer_size: u32 = 250;

// Port of Blink's TimeClamper at the pinned Chrome 149 Chromium revision.
// It deliberately operates on integer microseconds: using the full timestamp
// as a double distorts the jitter distribution for Unix epoch-sized values.
const TimeClamper = struct {
    const coarse_resolution_us: i64 = 100;
    const fine_resolution_us: i64 = 5;
    const ten_lower_digits_mod: i64 = 10_000_000_000;

    secret: u64,

    fn clampMicroseconds(
        self: TimeClamper,
        raw_time_microseconds: i64,
        cross_origin_isolated: bool,
    ) i64 {
        var time_microseconds = raw_time_microseconds;
        const was_negative = time_microseconds < 0;
        if (was_negative) {
            // Match Chromium's saturation of the i64 minimum before negation.
            time_microseconds = if (time_microseconds == std.math.minInt(i64))
                std.math.maxInt(i64)
            else
                -time_microseconds;
        }

        const lower = @mod(time_microseconds, ten_lower_digits_mod);
        var upper = time_microseconds - lower;
        const resolution = if (cross_origin_isolated)
            fine_resolution_us
        else
            coarse_resolution_us;

        var clamped = lower - @mod(lower, resolution);
        const threshold = self.thresholdFor(clamped, resolution);
        if (@as(f64, @floatFromInt(lower)) >= threshold) clamped += resolution;

        upper = @min(upper, std.math.maxInt(i64) - clamped);
        clamped += upper;
        return if (was_negative) -clamped else clamped;
    }

    fn thresholdFor(self: TimeClamper, clamped_time: i64, resolution: i64) f64 {
        const clamped_bits: u64 = @bitCast(clamped_time);
        const time_hash = murmurHash3(clamped_bits ^ self.secret);
        return @as(f64, @floatFromInt(clamped_time)) +
            @as(f64, @floatFromInt(resolution)) * toDouble(time_hash);
    }

    fn toDouble(value: u64) f64 {
        const exponent_bits: u64 = 0x3ff0_0000_0000_0000;
        const mantissa_mask: u64 = 0x000f_ffff_ffff_ffff;
        const random_bits = (value & mantissa_mask) | exponent_bits;
        return @as(f64, @bitCast(random_bits)) - 1.0;
    }

    fn murmurHash3(initial: u64) u64 {
        var value = initial;
        value ^= value >> 33;
        value *%= 0xff51_afd7_ed55_8ccd;
        value ^= value >> 33;
        value *%= 0xc4ce_b9fe_1a85_ec53;
        value ^= value >> 33;
        return value;
    }
};

// Chromium's Performance::ClampTimeResolution owns one process-wide static
// TimeClamper. Use an atomic lazy seed so Window and Worker timelines observe
// the same stable jitter thresholds even if initialization becomes threaded.
var time_clamper_secret: std.atomic.Value(u64) = .init(0);

fn sharedTimeClamperSecret() u64 {
    const existing = time_clamper_secret.load(.acquire);
    if (existing != 0) return existing;

    // Reserve zero as the uninitialized sentinel.
    const generated = std.crypto.random.int(u64) | 1;
    return time_clamper_secret.cmpxchgStrong(
        0,
        generated,
        .acq_rel,
        .acquire,
    ) orelse generated;
}

// Blink keeps the Unix epoch exposed by timeOrigin separate from the
// monotonic clock used by performance.now() and resource timing. Mixing these
// epochs is observable on Windows, where datetime.timespec() is backed by QPC.
_proto: *EventTarget = undefined,
_wall_time_origin_us: i64,
_monotonic_time_origin_us: u64,
_cross_origin_isolated: bool,
_time_clamper: TimeClamper,
_entries: std.ArrayList(*Entry) = .{},
_next_entry_index: u64 = 0,
// Blink keeps resource timing in a bounded primary timeline buffer and a
// temporary secondary buffer while its single buffer-full task is pending.
// `_entries` is DarkPanda's shared primary timeline, so retain an explicit
// resource count rather than treating marks/navigation as capacity users.
_resource_timing_buffer_size: u32 = 0,
_resource_timing_buffer_size_limit: u32 = default_resource_timing_buffer_size,
_resource_timing_secondary_buffer: std.ArrayList(*Entry) = .{},
_resource_timing_buffer_full_event_pending: bool = false,
_resource_timing_execution: ?*Execution = null,
_on_resource_timing_buffer_full: ?js.Function.Global = null,
// Navigation Timing is Window-only and is registered separately in the Page
// snapshot.  The entry exists from document commit, while its lifecycle
// fields remain live through loadEventEnd, just like Blink's single
// PerformanceNavigationTiming instance.
_navigation_timing: ?*NavigationTiming = null,
_navigation_type: NavigationTiming.Kind = .navigate,
_navigation_secondary_sink: ?HttpClient.ResourceTimingSink = null,
_navigation_observers_notified: bool = false,
_timing: PerformanceTiming = .{},
_navigation: PerformanceNavigation = .{},
_event_counts: EventCounts = .{},

// PerformanceObserver infrastructure. Lives here (rather than on the owning
// Frame/WorkerGlobalScope) so that both contexts get observers for free.
_observers: std.ArrayList(*PerformanceObserver) = .{},
_delivery_scheduled: bool = false,

/// Absolute monotonic platform time used by Event and Performance alike.
/// Keeping the timestamp absolute until a Web API getter runs mirrors Blink's
/// base::TimeTicks plumbing and lets the receiving realm apply its own time
/// origin and precision reduction.
pub fn monotonicMicroseconds() u64 {
    const ts = datetime.timespec();
    return @as(u64, @intCast(ts.sec)) * std.time.us_per_s +
        @as(u64, @intCast(@divTrunc(ts.nsec, std.time.ns_per_us)));
}

pub fn init() Performance {
    // crossOriginIsolated is deliberately false throughout the current
    // runtime (see js/Env.zig). Keep the parameterized constructor ready for
    // the point where COOP+COEP isolation is enabled.
    return initWithCrossOriginIsolation(false);
}

pub fn initWithCrossOriginIsolation(cross_origin_isolated: bool) Performance {
    // Bracket the wall-clock read with monotonic samples and use their
    // midpoint. This gives the two origins one coherent observation point.
    const monotonic_before = monotonicMicroseconds();
    const wall_time_origin_us = std.time.microTimestamp();
    const monotonic_after = monotonicMicroseconds();
    const monotonic_time_origin_us = monotonic_before +
        (monotonic_after - monotonic_before) / 2;

    return .{
        ._wall_time_origin_us = wall_time_origin_us,
        ._monotonic_time_origin_us = monotonic_time_origin_us,
        ._cross_origin_isolated = cross_origin_isolated,
        ._time_clamper = .{ .secret = sharedTimeClamperSecret() },
    };
}

pub fn getTiming(self: *Performance) *PerformanceTiming {
    return &self._timing;
}

pub fn now(self: *const Performance) f64 {
    return self.relativeMonotonicMilliseconds(monotonicMicroseconds());
}

pub fn getTimeOrigin(self: *const Performance) f64 {
    const clamped = self._time_clamper.clampMicroseconds(
        self._wall_time_origin_us,
        self._cross_origin_isolated,
    );
    return @as(f64, @floatFromInt(clamped)) / std.time.us_per_ms;
}

pub fn getNavigation(self: *Performance) *PerformanceNavigation {
    return &self._navigation;
}

pub fn getEventCounts(self: *Performance) *EventCounts {
    return &self._event_counts;
}

fn appendEntry(self: *Performance, entry: *Entry, exec: *const Execution) !void {
    entry._index = self._next_entry_index;
    self._next_entry_index +%= 1;
    try self._entries.append(exec.arena, entry);
    try self.notifyObservers(entry, exec);
}

/// Set by Frame before either a network or synthetic document commit.  A
/// Performance object belongs to one inner Window, so there is exactly one
/// navigation kind during its lifetime.
pub fn prepareNavigation(self: *Performance, kind: NavigationTiming.Kind) void {
    self._navigation_type = kind;
}

/// Main-document requests use the same transport timing source as resource
/// entries.  For child documents, `secondary` preserves the parent's iframe
/// resource entry while this sink creates the child's navigation entry.
pub fn navigationTimingSink(
    self: *Performance,
    exec: *const Execution,
    secondary: ?HttpClient.ResourceTimingSink,
) HttpClient.ResourceTimingSink {
    self._navigation_secondary_sink = secondary;
    return .{
        .context = self,
        .execution_context = @constCast(exec),
        .initiator = .other,
        .record = recordNavigationTiming,
    };
}

fn recordNavigationTiming(
    raw_performance: *anyopaque,
    raw_execution: *anyopaque,
    _: HttpClient.ResourceTimingInitiator,
    info: HttpClient.ResourceTimingInfo,
) !void {
    const self: *Performance = @ptrCast(@alignCast(raw_performance));
    const exec: *const Execution = @ptrCast(@alignCast(raw_execution));
    try self.createNavigationTiming(info, exec);

    // A child document's request is simultaneously a navigation entry in the
    // child and an iframe resource entry in the parent.
    if (self._navigation_secondary_sink) |secondary| {
        self._navigation_secondary_sink = null;
        secondary.record(
            secondary.context,
            secondary.execution_context,
            secondary.initiator,
            info,
        ) catch |err| {
            lp.log.warn(.frame, "Performance.navigation parent resource", .{ .err = err });
        };
    }
}

fn createNavigationTiming(
    self: *Performance,
    info: HttpClient.ResourceTimingInfo,
    exec: *const Execution,
) !void {
    if (self._navigation_timing != null) return;

    const resource = try ResourceTiming.init(self, info, "navigation", exec);
    const navigation = try exec._factory.create(NavigationTiming{
        ._proto = resource,
        ._type = self._navigation_type,
    });
    const entry = resource._proto;
    entry._type = .{ .navigation = navigation };
    // Navigation Timing defines startTime as navigationStart (zero) and
    // duration as the live loadEventEnd value, rather than resource duration.
    entry._start_time = 0;
    entry._duration = 0;
    entry._index = self._next_entry_index;
    self._next_entry_index +%= 1;
    self._navigation_timing = navigation;
    try self._entries.append(exec.arena, entry);
    // Blink does not notify observers here: it publishes the already-visible
    // object only after loadEventEnd.  A {type, buffered:true} observer can
    // still request this entry before then.
}

/// Synthetic documents have no transport lifecycle, but still expose one
/// Navigation Timing entry before parser-inserted script executes.
pub fn ensureNavigationTiming(
    self: *Performance,
    url: []const u8,
    exec: *const Execution,
) !void {
    if (self._navigation_timing != null) return;
    try self.createNavigationTiming(.{
        .name = url,
        .start_time_us = 0,
        .request_start_us = 0,
        .response_start_us = 0,
        .response_end_us = 0,
        .next_hop_protocol = "",
        .transfer_size = 0,
        .encoded_body_size = 0,
        .decoded_body_size = 0,
        .response_status = 200,
        .content_type = "text/html",
        .content_encoding = "",
    }, exec);
}

fn navigationLifecycleNow(self: *const Performance) f64 {
    const now_ms = self.now();
    const navigation = self._navigation_timing orelse return now_ms;
    return @max(now_ms, navigation._proto._response_end);
}

pub fn markNavigationDomInteractive(self: *Performance) void {
    const navigation = self._navigation_timing orelse return;
    navigation._dom_interactive = self.navigationLifecycleNow();
}

pub fn markNavigationDomContentLoadedStart(self: *Performance) void {
    const navigation = self._navigation_timing orelse return;
    navigation._dom_content_loaded_event_start = @max(
        navigation._dom_interactive,
        self.navigationLifecycleNow(),
    );
}

pub fn markNavigationDomContentLoadedEnd(self: *Performance) void {
    const navigation = self._navigation_timing orelse return;
    navigation._dom_content_loaded_event_end = @max(
        navigation._dom_content_loaded_event_start,
        self.navigationLifecycleNow(),
    );
}

pub fn markNavigationDomComplete(self: *Performance) void {
    const navigation = self._navigation_timing orelse return;
    navigation._dom_complete = @max(
        navigation._dom_content_loaded_event_end,
        self.navigationLifecycleNow(),
    );
}

pub fn markNavigationLoadEventStart(self: *Performance) void {
    const navigation = self._navigation_timing orelse return;
    navigation._load_event_start = @max(
        navigation._dom_complete,
        self.navigationLifecycleNow(),
    );
}

pub fn finishNavigation(
    self: *Performance,
    exec: *const Execution,
    outermost_main_frame: bool,
) !void {
    const navigation = self._navigation_timing orelse return;
    navigation._load_event_end = @max(
        navigation._load_event_start,
        self.navigationLifecycleNow(),
    );
    navigation._proto._proto._duration = navigation._load_event_end;
    if (outermost_main_frame and navigation._confidence == null) {
        navigation._confidence = TimingConfidence.generate();
    }
    if (self._navigation_observers_notified) return;
    self._navigation_observers_notified = true;
    try self.notifyObservers(navigation._proto._proto, exec);
}

/// Produce a transport sink tied to this Window/Worker performance timeline.
/// HttpClient invokes it synchronously before releasing its Transfer arena.
pub fn resourceTimingSink(
    self: *Performance,
    exec: *const Execution,
    initiator: HttpClient.ResourceTimingInitiator,
) HttpClient.ResourceTimingSink {
    return .{
        .context = self,
        .execution_context = @constCast(exec),
        .initiator = initiator,
        .record = recordResourceTiming,
    };
}

fn recordResourceTiming(
    raw_performance: *anyopaque,
    raw_execution: *anyopaque,
    initiator: HttpClient.ResourceTimingInitiator,
    info: HttpClient.ResourceTimingInfo,
) !void {
    const self: *Performance = @ptrCast(@alignCast(raw_performance));
    const exec: *const Execution = @ptrCast(@alignCast(raw_execution));
    const resource = try ResourceTiming.init(self, info, initiator.string(), exec);
    try self.addResourceTiming(resource._proto, exec);
}

/// Resource Timing's observer path deliberately precedes admission to the
/// bounded timeline buffer. An unbuffered observer therefore still sees an
/// entry when the primary limit is zero, matching Blink and the specification.
fn addResourceTiming(self: *Performance, entry: *Entry, exec: *const Execution) !void {
    entry._index = self._next_entry_index;
    self._next_entry_index +%= 1;
    self._resource_timing_execution = @constCast(exec);

    try self.notifyObservers(entry, exec);

    if (self.canAddResourceTimingEntry() and
        !self._resource_timing_buffer_full_event_pending)
    {
        try self._entries.append(exec.arena, entry);
        self._resource_timing_buffer_size += 1;
        return;
    }

    try self._resource_timing_secondary_buffer.append(exec.arena, entry);
    if (!self._resource_timing_buffer_full_event_pending) {
        self._resource_timing_buffer_full_event_pending = true;
        errdefer {
            self._resource_timing_buffer_full_event_pending = false;
            self._resource_timing_secondary_buffer.clearRetainingCapacity();
        }
        try exec._scheduler.add(
            self,
            fireResourceTimingBufferFullTask,
            0,
            .{
                .name = "Performance.resourceTimingBufferFull",
                .finalizer = cancelResourceTimingBufferFullTask,
            },
        );
    }
}

fn canAddResourceTimingEntry(self: *const Performance) bool {
    return self._resource_timing_buffer_size < self._resource_timing_buffer_size_limit;
}

fn copyResourceTimingSecondaryBuffer(self: *Performance, exec: *const Execution) !void {
    while (self._resource_timing_secondary_buffer.items.len != 0 and
        self.canAddResourceTimingEntry())
    {
        const entry = self._resource_timing_secondary_buffer.items[0];
        try self._entries.append(exec.arena, entry);
        _ = self._resource_timing_secondary_buffer.orderedRemove(0);
        self._resource_timing_buffer_size += 1;
    }
}

fn fireResourceTimingBufferFullTask(raw_performance: *anyopaque) anyerror!?u32 {
    const self: *Performance = @ptrCast(@alignCast(raw_performance));
    defer self._resource_timing_buffer_full_event_pending = false;

    const exec = self._resource_timing_execution orelse {
        self._resource_timing_secondary_buffer.clearRetainingCapacity();
        return null;
    };

    // Port of Performance::FireResourceTimingBufferFull at Chromium 48860e5.
    // A handler can clear or grow the primary buffer. Copy after dispatch, and
    // discard the secondary buffer if the handler made no forward progress.
    while (self._resource_timing_secondary_buffer.items.len != 0) {
        const excess_entries_before = self._resource_timing_secondary_buffer.items.len;
        if (!self.canAddResourceTimingEntry()) {
            const event = try Event.initTrusted(
                lp.String.wrap("resourcetimingbufferfull"),
                .{},
                exec.page,
            );
            try exec.dispatch(
                self.asEventTarget(),
                event,
                self._on_resource_timing_buffer_full,
                .{ .context = "Performance.resourcetimingbufferfull" },
            );
        }

        try self.copyResourceTimingSecondaryBuffer(exec);
        const excess_entries_after = self._resource_timing_secondary_buffer.items.len;
        if (excess_entries_after >= excess_entries_before) {
            self._resource_timing_secondary_buffer.clearRetainingCapacity();
            break;
        }
    }
    return null;
}

fn cancelResourceTimingBufferFullTask(raw_performance: *anyopaque) void {
    const self: *Performance = @ptrCast(@alignCast(raw_performance));
    self._resource_timing_buffer_full_event_pending = false;
    self._resource_timing_secondary_buffer.clearRetainingCapacity();
}

fn relativeMilliseconds(self: *const Performance, absolute_us: u64) f64 {
    return self.relativeMonotonicMilliseconds(absolute_us);
}

fn relativeMonotonicMilliseconds(self: *const Performance, absolute_us: u64) f64 {
    if (absolute_us == 0 or absolute_us <= self._monotonic_time_origin_us) return 0;

    const absolute = std.math.cast(i64, absolute_us) orelse return 0;
    const origin = std.math.cast(i64, self._monotonic_time_origin_us) orelse return 0;
    const clamped_absolute = self._time_clamper.clampMicroseconds(
        absolute,
        self._cross_origin_isolated,
    );
    const clamped_origin = self._time_clamper.clampMicroseconds(
        origin,
        self._cross_origin_isolated,
    );
    if (clamped_absolute <= clamped_origin) return 0;
    return @as(f64, @floatFromInt(clamped_absolute - clamped_origin)) /
        std.time.us_per_ms;
}

/// Convert an absolute monotonic platform timestamp to this realm's
/// DOMHighResTimeStamp. Event.timeStamp uses the ScriptState of the accessor,
/// so the conversion deliberately lives on Performance rather than Event.
pub fn monotonicTimeToDOMHighResTimeStamp(self: *const Performance, absolute_us: u64) f64 {
    return self.relativeMonotonicMilliseconds(absolute_us);
}

pub fn mark(
    self: *Performance,
    name: []const u8,
    _options: ?Mark.Options,
    exec: *const Execution,
) !*Mark {
    const opts = _options orelse Mark.Options{};
    const start_time = opts.startTime orelse self.now();
    const m = try Mark.init(name, opts.detail, start_time, exec);
    try self.appendEntry(m._proto, exec);
    return m;
}

const MeasureOptionsOrStartMark = union(enum) {
    measure_options: Measure.Options,
    start_mark: []const u8,
};

pub fn measure(
    self: *Performance,
    name: []const u8,
    maybe_options_or_start: ?MeasureOptionsOrStartMark,
    maybe_end_mark: ?[]const u8,
    exec: *const Execution,
) !*Measure {
    if (maybe_options_or_start) |options_or_start| switch (options_or_start) {
        .measure_options => |options| {
            // Get start timestamp.
            const start_timestamp = blk: {
                if (options.start) |timestamp_or_mark| {
                    break :blk switch (timestamp_or_mark) {
                        .timestamp => |timestamp| timestamp,
                        .mark => |mark_name| try self.getMarkTime(mark_name),
                    };
                }

                break :blk 0.0;
            };

            // Get end timestamp.
            const end_timestamp = blk: {
                if (options.end) |timestamp_or_mark| {
                    break :blk switch (timestamp_or_mark) {
                        .timestamp => |timestamp| timestamp,
                        .mark => |mark_name| try self.getMarkTime(mark_name),
                    };
                }

                break :blk self.now();
            };

            const m = try Measure.init(
                name,
                options.detail,
                start_timestamp,
                end_timestamp,
                options.duration,
                exec,
            );
            try self.appendEntry(m._proto, exec);
            return m;
        },
        .start_mark => |start_mark| {
            // Get start timestamp.
            const start_timestamp = try self.getMarkTime(start_mark);
            // Get end timestamp.
            const end_timestamp = blk: {
                if (maybe_end_mark) |mark_name| {
                    break :blk try self.getMarkTime(mark_name);
                }

                break :blk self.now();
            };

            const m = try Measure.init(
                name,
                null,
                start_timestamp,
                end_timestamp,
                null,
                exec,
            );
            try self.appendEntry(m._proto, exec);
            return m;
        },
    };

    const m = try Measure.init(name, null, 0.0, self.now(), null, exec);
    try self.appendEntry(m._proto, exec);
    return m;
}

pub fn clearMarks(self: *Performance, mark_name: ?[]const u8) void {
    var i: usize = 0;
    while (i < self._entries.items.len) {
        const entry = self._entries.items[i];
        if (entry._type == .mark and (mark_name == null or std.mem.eql(u8, entry._name, mark_name.?))) {
            _ = self._entries.orderedRemove(i);
        } else {
            i += 1;
        }
    }
}

pub fn clearMeasures(self: *Performance, measure_name: ?[]const u8) void {
    var i: usize = 0;
    while (i < self._entries.items.len) {
        const entry = self._entries.items[i];
        if (entry._type == .measure and (measure_name == null or std.mem.eql(u8, entry._name, measure_name.?))) {
            _ = self._entries.orderedRemove(i);
        } else {
            i += 1;
        }
    }
}

pub fn setResourceTimingBufferSize(self: *Performance, max_size: u32) void {
    // Per Resource Timing, changing the limit alone neither copies queued
    // secondary entries nor dispatches an event. The already-queued task, if
    // any, observes the new limit when it eventually runs.
    self._resource_timing_buffer_size_limit = max_size;
}

pub fn clearResourceTimings(self: *Performance) void {
    var i: usize = 0;
    while (i < self._entries.items.len) {
        if (self._entries.items[i]._type == .resource) {
            _ = self._entries.orderedRemove(i);
        } else {
            i += 1;
        }
    }
    // The secondary buffer intentionally survives. A pending buffer-full task
    // can copy it into the newly-cleared primary buffer after author handlers
    // have run, exactly as Blink's separate vectors do.
    self._resource_timing_buffer_size = 0;
}

pub fn asEventTarget(self: *Performance) *EventTarget {
    return self._proto;
}

pub fn getOnResourceTimingBufferFull(self: *const Performance) ?js.Function.Global {
    return self._on_resource_timing_buffer_full;
}

pub fn setOnResourceTimingBufferFull(self: *Performance, setter: ?FunctionSetter) void {
    const value = setter orelse {
        self._on_resource_timing_buffer_full = null;
        return;
    };
    self._on_resource_timing_buffer_full = switch (value) {
        .func => |func| func,
        .anything => null,
    };
}

const FunctionSetter = union(enum) {
    func: js.Function.Global,
    anything: js.Value,
};

pub fn toJSON(self: *const Performance) struct { timeOrigin: f64 } {
    return .{ .timeOrigin = self.getTimeOrigin() };
}

pub fn getMemory(_: *const Performance, exec: *const Execution) !*MemoryInfo {
    const stats = exec.js.isolate.getHeapStatistics();
    return exec._factory.create(MemoryInfo{
        .total_js_heap_size = @floatFromInt(stats.total_heap_size),
        .used_js_heap_size = @floatFromInt(stats.used_heap_size),
        .js_heap_size_limit = @floatFromInt(stats.heap_size_limit),
    });
}

pub fn getInteractionCount(_: *const Performance) f64 {
    // Event Timing interaction accounting is not implemented yet. The runtime-
    // enabled Chrome 149 attribute is still an observable Window-only zero.
    return 0;
}

pub fn getEntries(self: *const Performance, exec: *const Execution) ![]const *Entry {
    const entries = try exec.local_arena.dupe(*Entry, self._entries.items);
    sortEntries(entries);
    return entries;
}

pub fn getEntriesByType(self: *const Performance, entry_type: []const u8, exec: *const Execution) ![]const *Entry {
    return filterEntriesByType(exec.local_arena, self._entries.items, entry_type);
}

pub fn getEntriesByName(self: *const Performance, name: []const u8, entry_type: ?[]const u8, exec: *const Execution) ![]const *Entry {
    return filterEntriesByName(exec.local_arena, self._entries.items, name, entry_type);
}

// Also used by PerformanceObserver
pub fn filterEntriesByType(arena: Allocator, list: []*Entry, entry_type: []const u8) ![]const *Entry {
    var result: std.ArrayList(*Entry) = .empty;
    for (list) |entry| {
        if (std.mem.eql(u8, entry.getEntryType(), entry_type)) {
            try result.append(arena, entry);
        }
    }
    sortEntries(result.items);
    return result.items;
}

// Also used by PerformanceObserver
pub fn filterEntriesByName(arena: Allocator, list: []*Entry, name: []const u8, entry_type: ?[]const u8) ![]const *Entry {
    var result: std.ArrayList(*Entry) = .empty;

    for (list) |entry| {
        if (!std.mem.eql(u8, entry._name, name)) {
            continue;
        }
        if (entry_type == null or std.mem.eql(u8, entry.getEntryType(), entry_type.?)) {
            try result.append(arena, entry);
        }
    }

    sortEntries(result.items);
    return result.items;
}

/// Performance Timeline ordering is ascending startTime, preserving creation
/// order for ties. A small stable insertion sort is ideal for these typically
/// short per-document buffers and avoids manufacturing order from completion
/// time when concurrent resources finish out of order.
pub fn sortEntries(entries: []*Entry) void {
    var i: usize = 1;
    while (i < entries.len) : (i += 1) {
        const current = entries[i];
        var j = i;
        while (j > 0 and entryLessThan(current, entries[j - 1])) : (j -= 1) {
            entries[j] = entries[j - 1];
        }
        entries[j] = current;
    }
}

fn entryLessThan(a: *const Entry, b: *const Entry) bool {
    if (a._start_time < b._start_time) return true;
    if (a._start_time > b._start_time) return false;
    return a._index < b._index;
}

fn getMarkTime(self: *const Performance, mark_name: []const u8) !f64 {
    for (self._entries.items) |entry| {
        if (entry._type == .mark and std.mem.eql(u8, entry._name, mark_name)) {
            return entry._start_time;
        }
    }

    // PerformanceTiming attribute names are valid start/end marks per the
    // W3C User Timing Level 2 spec. All are relative to navigationStart (= 0).
    // https://www.w3.org/TR/user-timing/#dom-performance-measure
    //
    // `navigationStart` is an equivalent to 0.
    // Others are dependant to request arrival, end of request etc, but we
    // return a dummy 0 value for now.
    const navigation_timing_marks = std.StaticStringMap(void).initComptime(.{
        .{ "navigationStart", {} },
        .{ "unloadEventStart", {} },
        .{ "unloadEventEnd", {} },
        .{ "redirectStart", {} },
        .{ "redirectEnd", {} },
        .{ "fetchStart", {} },
        .{ "domainLookupStart", {} },
        .{ "domainLookupEnd", {} },
        .{ "connectStart", {} },
        .{ "connectEnd", {} },
        .{ "secureConnectionStart", {} },
        .{ "requestStart", {} },
        .{ "responseStart", {} },
        .{ "responseEnd", {} },
        .{ "domLoading", {} },
        .{ "domInteractive", {} },
        .{ "domContentLoadedEventStart", {} },
        .{ "domContentLoadedEventEnd", {} },
        .{ "domComplete", {} },
        .{ "loadEventStart", {} },
        .{ "loadEventEnd", {} },
    });
    if (navigation_timing_marks.has(mark_name)) {
        return 0;
    }

    return error.SyntaxError; // Mark not found
}

pub fn registerObserver(self: *Performance, observer: *PerformanceObserver, exec: *const Execution) !void {
    return self._observers.append(exec.arena, observer);
}

pub fn unregisterObserver(self: *Performance, observer: *PerformanceObserver) void {
    for (self._observers.items, 0..) |o, i| {
        if (o == observer) {
            _ = self._observers.swapRemove(i);
            return;
        }
    }
}

/// Append the entry to every interested observer's queue and schedule async
/// delivery. Does NOT fire the callbacks synchronously — that happens later
/// via the scheduled task.
pub fn notifyObservers(self: *Performance, entry: *Entry, exec: *const Execution) !void {
    for (self._observers.items) |observer| {
        if (observer.interested(entry)) {
            observer._entries.append(exec.arena, entry) catch |err| {
                lp.log.err(.frame, "Performance.notifyObservers", .{ .err = err });
            };
        }
    }

    try self.scheduleDelivery(exec);
}

pub fn scheduleDelivery(self: *Performance, exec: *const Execution) !void {
    if (self._delivery_scheduled) {
        return;
    }
    self._delivery_scheduled = true;

    return exec._scheduler.add(
        self,
        struct {
            fn run(_self: *anyopaque) anyerror!?u32 {
                const perf: *Performance = @ptrCast(@alignCast(_self));
                perf._delivery_scheduled = false;
                for (perf._observers.items) |observer| {
                    if (observer.hasRecords()) {
                        try observer.dispatch();
                    }
                }
                return null;
            }
        }.run,
        0,
        .{
            .name = "Performance.deliverObservers",
            .finalizer = struct {
                fn run(_self: *anyopaque) void {
                    const perf: *Performance = @ptrCast(@alignCast(_self));
                    perf._delivery_scheduled = false;
                    for (perf._observers.items) |observer| {
                        observer._entries.clearRetainingCapacity();
                    }
                }
            }.run,
        },
    );
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Performance);

    pub const Meta = struct {
        pub const name = "Performance";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const Prototype = EventTarget;

    // Declaration order mirrors Chrome 149's generated Performance prototype.
    // Window-only supplements are reinserted after the implicit constructor by
    // Snapshot once V8 materializes the per-realm prototype object.
    pub const timeOrigin = bridge.accessor(Performance.getTimeOrigin, null, .{});
    pub const onresourcetimingbufferfull = bridge.accessor(Performance.getOnResourceTimingBufferFull, Performance.setOnResourceTimingBufferFull, .{});
    pub const clearMarks = bridge.function(Performance.clearMarks, .{});
    pub const clearMeasures = bridge.function(Performance.clearMeasures, .{});
    pub const clearResourceTimings = bridge.function(Performance.clearResourceTimings, .{});
    pub const getEntries = bridge.function(Performance.getEntries, .{});
    pub const getEntriesByName = bridge.function(Performance.getEntriesByName, .{});
    pub const getEntriesByType = bridge.function(Performance.getEntriesByType, .{});
    pub const mark = bridge.function(Performance.mark, .{});
    pub const measure = bridge.function(Performance.measure, .{});
    pub const setResourceTimingBufferSize = bridge.function(Performance.setResourceTimingBufferSize, .{});
    pub const toJSON = bridge.function(Performance.toJSON, .{});
    pub const now = bridge.function(Performance.now, .{});
    pub const timing = bridge.accessor(Performance.getTiming, null, .{ .exposed = .window });
    pub const navigation = bridge.accessor(Performance.getNavigation, null, .{ .exposed = .window });
    pub const memory = bridge.accessor(Performance.getMemory, null, .{ .exposed = .window });
    pub const eventCounts = bridge.accessor(Performance.getEventCounts, null, .{ .exposed = .window });
    pub const interactionCount = bridge.accessor(Performance.getInteractionCount, null, .{ .exposed = .window });
};

/// LegacyNoInterfaceObject in Blink. The wrapper still has a tagged prototype,
/// but no global `MemoryInfo` binding is exported.
pub const MemoryInfo = struct {
    total_js_heap_size: f64,
    used_js_heap_size: f64,
    js_heap_size_limit: f64,

    pub fn getTotalJSHeapSize(self: *const MemoryInfo) f64 {
        return self.total_js_heap_size;
    }

    pub fn getUsedJSHeapSize(self: *const MemoryInfo) f64 {
        return self.used_js_heap_size;
    }

    pub fn getJSHeapSizeLimit(self: *const MemoryInfo) f64 {
        return self.js_heap_size_limit;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(MemoryInfo);

        pub const Meta = struct {
            pub const name = "MemoryInfo";
            pub const global_export = false;
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const totalJSHeapSize = bridge.accessor(MemoryInfo.getTotalJSHeapSize, null, .{});
        pub const usedJSHeapSize = bridge.accessor(MemoryInfo.getUsedJSHeapSize, null, .{});
        pub const jsHeapSizeLimit = bridge.accessor(MemoryInfo.getJSHeapSizeLimit, null, .{});
    };
};

pub const Entry = struct {
    _duration: f64 = 0.0,
    _type: Type,
    _name: []const u8,
    _start_time: f64 = 0.0,
    _index: u64 = 0,

    pub const Type = union(Enum) {
        element,
        event,
        first_input,
        @"largest-contentful-paint",
        @"layout-shift",
        @"long-animation-frame",
        longtask,
        measure: *Measure,
        navigation: *NavigationTiming,
        paint,
        resource: *ResourceTiming,
        taskattribution,
        @"visibility-state",
        mark: *Mark,

        pub const Enum = enum(u8) {
            element = 1, // Changing this affect PerformanceObserver's behavior.
            event = 2,
            first_input = 3,
            @"largest-contentful-paint" = 4,
            @"layout-shift" = 5,
            @"long-animation-frame" = 6,
            longtask = 7,
            measure = 8,
            navigation = 9,
            paint = 10,
            resource = 11,
            taskattribution = 12,
            @"visibility-state" = 13,
            mark = 14,
            // If we ever have types more than 16, we have to update entry
            // table of PerformanceObserver too.
        };
    };

    pub fn getDuration(self: *const Entry) f64 {
        return self._duration;
    }

    pub fn getEntryType(self: *const Entry) []const u8 {
        return switch (self._type) {
            else => |t| @tagName(t),
        };
    }

    pub fn getName(self: *const Entry) []const u8 {
        return self._name;
    }

    pub fn getStartTime(self: *const Entry) f64 {
        return self._start_time;
    }

    pub fn toJSON(self: *const Entry) struct {
        name: []const u8,
        entryType: []const u8,
        startTime: f64,
        duration: f64,
    } {
        return .{
            .name = self._name,
            .entryType = self.getEntryType(),
            .startTime = self._start_time,
            .duration = self._duration,
        };
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(Entry);

        pub const Meta = struct {
            pub const name = "PerformanceEntry";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };
        pub const name = bridge.accessor(Entry.getName, null, .{});
        pub const entryType = bridge.accessor(Entry.getEntryType, null, .{});
        pub const startTime = bridge.accessor(Entry.getStartTime, null, .{});
        pub const duration = bridge.accessor(Entry.getDuration, null, .{});
        pub const toJSON = bridge.function(Entry.toJSON, .{});
    };
};

/// Resource Timing Level 3 / Chrome 149 surface backed by HttpClient's real
/// request lifecycle. Transport fields not exposed by the current wreq ABI
/// stay at their specification-permitted zero/empty values.
pub const ResourceTiming = struct {
    _proto: *Entry,
    _initiator_type: []const u8,
    _next_hop_protocol: []const u8,
    _content_type: []const u8,
    _content_encoding: []const u8,
    _fetch_start: f64,
    _request_start: f64,
    _response_start: f64,
    _response_end: f64,
    _transfer_size: u64,
    _encoded_body_size: u64,
    _decoded_body_size: u64,
    _response_status: u16,

    pub fn init(
        performance: *const Performance,
        info: HttpClient.ResourceTimingInfo,
        initiator_type: []const u8,
        exec: *const Execution,
    ) !*ResourceTiming {
        const start_time = performance.relativeMilliseconds(info.start_time_us);
        const request_start = performance.relativeMilliseconds(info.request_start_us);
        const response_start = performance.relativeMilliseconds(info.response_start_us);
        const response_end = performance.relativeMilliseconds(info.response_end_us);

        const resource = try exec._factory.create(ResourceTiming{
            ._proto = undefined,
            ._initiator_type = try exec.dupeString(initiator_type),
            ._next_hop_protocol = try exec.dupeString(info.next_hop_protocol),
            ._content_type = try exec.dupeString(info.content_type),
            ._content_encoding = try exec.dupeString(info.content_encoding),
            ._fetch_start = start_time,
            ._request_start = request_start,
            ._response_start = response_start,
            ._response_end = response_end,
            ._transfer_size = info.transfer_size,
            ._encoded_body_size = info.encoded_body_size,
            ._decoded_body_size = info.decoded_body_size,
            ._response_status = info.response_status,
        });
        resource._proto = try exec._factory.create(Entry{
            ._name = try exec.dupeString(info.name),
            ._start_time = start_time,
            ._duration = @max(0, response_end - start_time),
            ._type = .{ .resource = resource },
        });
        return resource;
    }

    pub fn getInitiatorType(self: *const ResourceTiming) []const u8 {
        return self._initiator_type;
    }
    pub fn getNextHopProtocol(self: *const ResourceTiming) []const u8 {
        return self._next_hop_protocol;
    }
    pub fn getDeliveryType(_: *const ResourceTiming) []const u8 {
        return "";
    }
    pub fn getWorkerStart(_: *const ResourceTiming) f64 {
        return 0;
    }
    pub fn getWorkerRouterEvaluationStart(_: *const ResourceTiming) f64 {
        return 0;
    }
    pub fn getWorkerCacheLookupStart(_: *const ResourceTiming) f64 {
        return 0;
    }
    pub fn getWorkerMatchedSourceType(_: *const ResourceTiming) []const u8 {
        return "";
    }
    pub fn getWorkerFinalSourceType(_: *const ResourceTiming) []const u8 {
        return "";
    }
    pub fn getRedirectStart(_: *const ResourceTiming) f64 {
        return 0;
    }
    pub fn getRedirectEnd(_: *const ResourceTiming) f64 {
        return 0;
    }
    pub fn getFetchStart(self: *const ResourceTiming) f64 {
        return self._fetch_start;
    }
    pub fn getDomainLookupStart(self: *const ResourceTiming) f64 {
        // The transport currently exposes no DNS/connection phase boundaries.
        // A reused connection is represented by the Resource Timing mandated
        // collapsed interval at fetchStart, preserving monotonic ordering.
        return self._fetch_start;
    }
    pub fn getDomainLookupEnd(self: *const ResourceTiming) f64 {
        return self._fetch_start;
    }
    pub fn getConnectStart(self: *const ResourceTiming) f64 {
        return self._fetch_start;
    }
    pub fn getConnectEnd(self: *const ResourceTiming) f64 {
        return self._fetch_start;
    }
    pub fn getSecureConnectionStart(_: *const ResourceTiming) f64 {
        return 0;
    }
    pub fn getRequestStart(self: *const ResourceTiming) f64 {
        return self._request_start;
    }
    pub fn getResponseStart(self: *const ResourceTiming) f64 {
        return self._response_start;
    }
    pub fn getFirstInterimResponseStart(_: *const ResourceTiming) f64 {
        return 0;
    }
    pub fn getFinalResponseHeadersStart(self: *const ResourceTiming) f64 {
        return self._response_start;
    }
    pub fn getResponseEnd(self: *const ResourceTiming) f64 {
        return self._response_end;
    }
    pub fn getTransferSize(self: *const ResourceTiming) f64 {
        return @floatFromInt(self._transfer_size);
    }
    pub fn getEncodedBodySize(self: *const ResourceTiming) f64 {
        return @floatFromInt(self._encoded_body_size);
    }
    pub fn getDecodedBodySize(self: *const ResourceTiming) f64 {
        return @floatFromInt(self._decoded_body_size);
    }
    pub fn getServerTiming(_: *const ResourceTiming) []const []const u8 {
        return &.{};
    }
    pub fn getRenderBlockingStatus(_: *const ResourceTiming) []const u8 {
        return "non-blocking";
    }
    pub fn getResponseStatus(self: *const ResourceTiming) u16 {
        return self._response_status;
    }
    pub fn getContentType(self: *const ResourceTiming) []const u8 {
        return self._content_type;
    }
    pub fn getContentEncoding(self: *const ResourceTiming) []const u8 {
        return self._content_encoding;
    }

    pub fn toJSON(self: *const ResourceTiming) struct {
        name: []const u8,
        entryType: []const u8,
        startTime: f64,
        duration: f64,
        initiatorType: []const u8,
        deliveryType: []const u8,
        nextHopProtocol: []const u8,
        renderBlockingStatus: []const u8,
        contentType: []const u8,
        contentEncoding: []const u8,
        workerStart: f64,
        workerRouterEvaluationStart: f64,
        workerCacheLookupStart: f64,
        workerMatchedSourceType: []const u8,
        workerFinalSourceType: []const u8,
        redirectStart: f64,
        redirectEnd: f64,
        fetchStart: f64,
        domainLookupStart: f64,
        domainLookupEnd: f64,
        connectStart: f64,
        secureConnectionStart: f64,
        connectEnd: f64,
        requestStart: f64,
        responseStart: f64,
        firstInterimResponseStart: f64,
        finalResponseHeadersStart: f64,
        responseEnd: f64,
        transferSize: f64,
        encodedBodySize: f64,
        decodedBodySize: f64,
        responseStatus: u16,
        serverTiming: []const []const u8,
    } {
        return .{
            .name = self._proto._name,
            .entryType = "resource",
            .startTime = self._proto._start_time,
            .duration = self._proto._duration,
            .initiatorType = self._initiator_type,
            .deliveryType = "",
            .nextHopProtocol = self._next_hop_protocol,
            .renderBlockingStatus = "non-blocking",
            .contentType = self._content_type,
            .contentEncoding = self._content_encoding,
            .workerStart = 0,
            .workerRouterEvaluationStart = 0,
            .workerCacheLookupStart = 0,
            .workerMatchedSourceType = "",
            .workerFinalSourceType = "",
            .redirectStart = 0,
            .redirectEnd = 0,
            .fetchStart = self._fetch_start,
            .domainLookupStart = self._fetch_start,
            .domainLookupEnd = self._fetch_start,
            .connectStart = self._fetch_start,
            .secureConnectionStart = 0,
            .connectEnd = self._fetch_start,
            .requestStart = self._request_start,
            .responseStart = self._response_start,
            .firstInterimResponseStart = 0,
            .finalResponseHeadersStart = self._response_start,
            .responseEnd = self._response_end,
            .transferSize = @floatFromInt(self._transfer_size),
            .encodedBodySize = @floatFromInt(self._encoded_body_size),
            .decodedBodySize = @floatFromInt(self._decoded_body_size),
            .responseStatus = self._response_status,
            .serverTiming = &.{},
        };
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(ResourceTiming);

        pub const Meta = struct {
            pub const name = "PerformanceResourceTiming";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const initiatorType = bridge.accessor(ResourceTiming.getInitiatorType, null, .{});
        pub const nextHopProtocol = bridge.accessor(ResourceTiming.getNextHopProtocol, null, .{});
        pub const deliveryType = bridge.accessor(ResourceTiming.getDeliveryType, null, .{});
        pub const workerStart = bridge.accessor(ResourceTiming.getWorkerStart, null, .{});
        pub const redirectStart = bridge.accessor(ResourceTiming.getRedirectStart, null, .{});
        pub const redirectEnd = bridge.accessor(ResourceTiming.getRedirectEnd, null, .{});
        pub const fetchStart = bridge.accessor(ResourceTiming.getFetchStart, null, .{});
        pub const domainLookupStart = bridge.accessor(ResourceTiming.getDomainLookupStart, null, .{});
        pub const domainLookupEnd = bridge.accessor(ResourceTiming.getDomainLookupEnd, null, .{});
        pub const connectStart = bridge.accessor(ResourceTiming.getConnectStart, null, .{});
        pub const connectEnd = bridge.accessor(ResourceTiming.getConnectEnd, null, .{});
        pub const secureConnectionStart = bridge.accessor(ResourceTiming.getSecureConnectionStart, null, .{});
        pub const requestStart = bridge.accessor(ResourceTiming.getRequestStart, null, .{});
        pub const responseStart = bridge.accessor(ResourceTiming.getResponseStart, null, .{});
        pub const responseEnd = bridge.accessor(ResourceTiming.getResponseEnd, null, .{});
        pub const transferSize = bridge.accessor(ResourceTiming.getTransferSize, null, .{});
        pub const encodedBodySize = bridge.accessor(ResourceTiming.getEncodedBodySize, null, .{});
        pub const decodedBodySize = bridge.accessor(ResourceTiming.getDecodedBodySize, null, .{});
        pub const serverTiming = bridge.accessor(ResourceTiming.getServerTiming, null, .{});
        pub const responseStatus = bridge.accessor(ResourceTiming.getResponseStatus, null, .{});
        pub const finalResponseHeadersStart = bridge.accessor(ResourceTiming.getFinalResponseHeadersStart, null, .{});
        pub const firstInterimResponseStart = bridge.accessor(ResourceTiming.getFirstInterimResponseStart, null, .{});
        pub const toJSON = bridge.function(ResourceTiming.toJSON, .{});
        pub const workerRouterEvaluationStart = bridge.accessor(ResourceTiming.getWorkerRouterEvaluationStart, null, .{});
        pub const workerCacheLookupStart = bridge.accessor(ResourceTiming.getWorkerCacheLookupStart, null, .{});
        pub const workerMatchedSourceType = bridge.accessor(ResourceTiming.getWorkerMatchedSourceType, null, .{});
        pub const workerFinalSourceType = bridge.accessor(ResourceTiming.getWorkerFinalSourceType, null, .{});
        pub const renderBlockingStatus = bridge.accessor(ResourceTiming.getRenderBlockingStatus, null, .{});
        pub const contentType = bridge.accessor(ResourceTiming.getContentType, null, .{});
        pub const contentEncoding = bridge.accessor(ResourceTiming.getContentEncoding, null, .{});
    };
};

/// Navigation Timing Level 2. Chrome creates one live object at document
/// commit, exposes it immediately through the Performance timeline, and only
/// publishes it to unbuffered observers after loadEventEnd.
pub const NavigationTiming = struct {
    _proto: *ResourceTiming,
    _type: Kind = .navigate,
    _unload_event_start: f64 = 0,
    _unload_event_end: f64 = 0,
    _dom_interactive: f64 = 0,
    _dom_content_loaded_event_start: f64 = 0,
    _dom_content_loaded_event_end: f64 = 0,
    _dom_complete: f64 = 0,
    _load_event_start: f64 = 0,
    _load_event_end: f64 = 0,
    _redirect_count: u16 = 0,
    _confidence: ?TimingConfidence = null,

    pub const Kind = enum {
        navigate,
        reload,
        back_forward,
        prerender,

        fn string(self: Kind) []const u8 {
            return switch (self) {
                .navigate => "navigate",
                .reload => "reload",
                .back_forward => "back_forward",
                .prerender => "prerender",
            };
        }
    };

    pub fn getUnloadEventStart(self: *const NavigationTiming) f64 {
        return self._unload_event_start;
    }
    pub fn getUnloadEventEnd(self: *const NavigationTiming) f64 {
        return self._unload_event_end;
    }
    pub fn getDomInteractive(self: *const NavigationTiming) f64 {
        return self._dom_interactive;
    }
    pub fn getDomContentLoadedEventStart(self: *const NavigationTiming) f64 {
        return self._dom_content_loaded_event_start;
    }
    pub fn getDomContentLoadedEventEnd(self: *const NavigationTiming) f64 {
        return self._dom_content_loaded_event_end;
    }
    pub fn getDomComplete(self: *const NavigationTiming) f64 {
        return self._dom_complete;
    }
    pub fn getLoadEventStart(self: *const NavigationTiming) f64 {
        return self._load_event_start;
    }
    pub fn getLoadEventEnd(self: *const NavigationTiming) f64 {
        return self._load_event_end;
    }
    pub fn getType(self: *const NavigationTiming) []const u8 {
        return self._type.string();
    }
    pub fn getRedirectCount(self: *const NavigationTiming) u16 {
        return self._redirect_count;
    }
    pub fn getCriticalCHRestart(_: *const NavigationTiming) f64 {
        return 0;
    }
    pub fn getActivationStart(_: *const NavigationTiming) f64 {
        return 0;
    }
    pub fn getConfidence(self: *const NavigationTiming) ?TimingConfidence {
        // Blink constructs a fresh ScriptWrappable on every getter call.
        return self._confidence;
    }
    pub fn getNotRestoredReasons(_: *const NavigationTiming) ?[]const u8 {
        return null;
    }

    pub const JSON = struct {
        name: []const u8,
        entryType: []const u8,
        startTime: f64,
        duration: f64,
        initiatorType: []const u8,
        deliveryType: []const u8,
        nextHopProtocol: []const u8,
        renderBlockingStatus: []const u8,
        contentType: []const u8,
        contentEncoding: []const u8,
        workerStart: f64,
        workerRouterEvaluationStart: f64,
        workerCacheLookupStart: f64,
        workerMatchedSourceType: []const u8,
        workerFinalSourceType: []const u8,
        redirectStart: f64,
        redirectEnd: f64,
        fetchStart: f64,
        domainLookupStart: f64,
        domainLookupEnd: f64,
        connectStart: f64,
        secureConnectionStart: f64,
        connectEnd: f64,
        requestStart: f64,
        responseStart: f64,
        firstInterimResponseStart: f64,
        finalResponseHeadersStart: f64,
        responseEnd: f64,
        transferSize: f64,
        encodedBodySize: f64,
        decodedBodySize: f64,
        responseStatus: u16,
        serverTiming: []const []const u8,
        unloadEventStart: f64,
        unloadEventEnd: f64,
        domInteractive: f64,
        domContentLoadedEventStart: f64,
        domContentLoadedEventEnd: f64,
        domComplete: f64,
        loadEventStart: f64,
        loadEventEnd: f64,
        type: []const u8,
        redirectCount: u16,
        activationStart: f64,
        criticalCHRestart: f64,
        notRestoredReasons: ?[]const u8,
        confidence: ?TimingConfidence,
    };

    pub fn toJSON(self: *const NavigationTiming) JSON {
        const resource = self._proto;
        const entry = resource._proto;
        return .{
            .name = entry._name,
            .entryType = "navigation",
            .startTime = entry._start_time,
            .duration = entry._duration,
            .initiatorType = resource._initiator_type,
            .deliveryType = "",
            .nextHopProtocol = resource._next_hop_protocol,
            .renderBlockingStatus = "non-blocking",
            .contentType = resource._content_type,
            .contentEncoding = resource._content_encoding,
            .workerStart = 0,
            .workerRouterEvaluationStart = 0,
            .workerCacheLookupStart = 0,
            .workerMatchedSourceType = "",
            .workerFinalSourceType = "",
            .redirectStart = 0,
            .redirectEnd = 0,
            .fetchStart = resource._fetch_start,
            .domainLookupStart = resource.getDomainLookupStart(),
            .domainLookupEnd = resource.getDomainLookupEnd(),
            .connectStart = resource.getConnectStart(),
            .secureConnectionStart = resource.getSecureConnectionStart(),
            .connectEnd = resource.getConnectEnd(),
            .requestStart = resource._request_start,
            .responseStart = resource._response_start,
            .firstInterimResponseStart = 0,
            .finalResponseHeadersStart = resource._response_start,
            .responseEnd = resource._response_end,
            .transferSize = @floatFromInt(resource._transfer_size),
            .encodedBodySize = @floatFromInt(resource._encoded_body_size),
            .decodedBodySize = @floatFromInt(resource._decoded_body_size),
            .responseStatus = resource._response_status,
            .serverTiming = &.{},
            .unloadEventStart = self._unload_event_start,
            .unloadEventEnd = self._unload_event_end,
            .domInteractive = self._dom_interactive,
            .domContentLoadedEventStart = self._dom_content_loaded_event_start,
            .domContentLoadedEventEnd = self._dom_content_loaded_event_end,
            .domComplete = self._dom_complete,
            .loadEventStart = self._load_event_start,
            .loadEventEnd = self._load_event_end,
            .type = self._type.string(),
            .redirectCount = self._redirect_count,
            .activationStart = 0,
            .criticalCHRestart = 0,
            .notRestoredReasons = null,
            .confidence = self._confidence,
        };
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(NavigationTiming);

        pub const Meta = struct {
            pub const name = "PerformanceNavigationTiming";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        // Declaration order follows Chromium 149's generated prototype.
        pub const unloadEventStart = bridge.accessor(NavigationTiming.getUnloadEventStart, null, .{});
        pub const unloadEventEnd = bridge.accessor(NavigationTiming.getUnloadEventEnd, null, .{});
        pub const domInteractive = bridge.accessor(NavigationTiming.getDomInteractive, null, .{});
        pub const domContentLoadedEventStart = bridge.accessor(NavigationTiming.getDomContentLoadedEventStart, null, .{});
        pub const domContentLoadedEventEnd = bridge.accessor(NavigationTiming.getDomContentLoadedEventEnd, null, .{});
        pub const domComplete = bridge.accessor(NavigationTiming.getDomComplete, null, .{});
        pub const loadEventStart = bridge.accessor(NavigationTiming.getLoadEventStart, null, .{});
        pub const loadEventEnd = bridge.accessor(NavigationTiming.getLoadEventEnd, null, .{});
        pub const @"type" = bridge.accessor(NavigationTiming.getType, null, .{});
        pub const redirectCount = bridge.accessor(NavigationTiming.getRedirectCount, null, .{});
        pub const criticalCHRestart = bridge.accessor(NavigationTiming.getCriticalCHRestart, null, .{});
        pub const activationStart = bridge.accessor(NavigationTiming.getActivationStart, null, .{});
        pub const toJSON = bridge.function(NavigationTiming.toJSON, .{});
        pub const confidence = bridge.accessor(NavigationTiming.getConfidence, null, .{});
        pub const notRestoredReasons = bridge.accessor(NavigationTiming.getNotRestoredReasons, null, .{});
    };
};

/// Runtime-enabled in the pinned Chrome 149 build. The default epsilon (1.1)
/// yields a seven-decimal randomized trigger rate of 0.4994798.
pub const TimingConfidence = struct {
    randomized_trigger_rate: f64,
    confidence_value: Value,

    pub const randomized_trigger_rate_chrome149: f64 = 0.4994798;

    pub const Value = enum {
        high,
        low,

        fn string(self: Value) []const u8 {
            return @tagName(self);
        }
    };

    pub fn generate() TimingConfidence {
        var value: Value = .high;
        // Chromium applies randomized response to an underlying high default:
        // with probability 0.4994798 it replaces that result with a fair coin.
        if (std.crypto.random.int(u32) % 10_000_000 < 4_994_798) {
            value = if (std.crypto.random.int(u8) & 1 == 0) .low else .high;
        }
        return .{
            .randomized_trigger_rate = randomized_trigger_rate_chrome149,
            .confidence_value = value,
        };
    }

    pub fn getRandomizedTriggerRate(self: *const TimingConfidence) f64 {
        return self.randomized_trigger_rate;
    }

    pub fn getValue(self: *const TimingConfidence) []const u8 {
        return self.confidence_value.string();
    }

    pub fn toJSON(self: *const TimingConfidence) struct {
        randomizedTriggerRate: f64,
        value: []const u8,
    } {
        return .{
            .randomizedTriggerRate = self.randomized_trigger_rate,
            .value = self.confidence_value.string(),
        };
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(TimingConfidence);

        pub const Meta = struct {
            pub const name = "PerformanceTimingConfidence";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const randomizedTriggerRate = bridge.accessor(TimingConfidence.getRandomizedTriggerRate, null, .{});
        pub const value = bridge.accessor(TimingConfidence.getValue, null, .{});
        pub const toJSON = bridge.function(TimingConfidence.toJSON, .{});
    };
};

pub const Mark = struct {
    _proto: *Entry,
    _detail: ?js.Value.Global,

    const Options = struct {
        detail: ?js.Value = null,
        startTime: ?f64 = null,
    };

    pub fn init(name: []const u8, maybe_detail: ?js.Value, start_time: f64, exec: *const Execution) !*Mark {
        if (start_time < 0.0) {
            return error.TypeError;
        }

        const detail = if (maybe_detail) |d| try d.persist() else null;
        const m = try exec._factory.create(Mark{
            ._proto = undefined,
            ._detail = detail,
        });

        const entry = try exec._factory.create(Entry{
            ._start_time = start_time,
            ._name = try exec.dupeString(name),
            ._type = .{ .mark = m },
        });
        m._proto = entry;
        return m;
    }

    pub fn getDetail(self: *const Mark) ?js.Value.Global {
        return self._detail;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(Mark);

        pub const Meta = struct {
            pub const name = "PerformanceMark";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };
        pub const detail = bridge.accessor(Mark.getDetail, null, .{});
    };
};

pub const Measure = struct {
    _proto: *Entry,
    _detail: ?js.Value.Global,

    const Options = struct {
        detail: ?js.Value = null,
        start: ?TimestampOrMark,
        end: ?TimestampOrMark,
        duration: ?f64 = null,

        const TimestampOrMark = union(enum) {
            timestamp: f64,
            mark: []const u8,
        };
    };

    pub fn init(
        name: []const u8,
        maybe_detail: ?js.Value,
        start_timestamp: f64,
        end_timestamp: f64,
        maybe_duration: ?f64,
        exec: *const Execution,
    ) !*Measure {
        const duration = maybe_duration orelse (end_timestamp - start_timestamp);
        if (duration < 0.0) {
            return error.TypeError;
        }

        const detail = if (maybe_detail) |d| try d.persist() else null;
        const m = try exec._factory.create(Measure{
            ._proto = undefined,
            ._detail = detail,
        });

        const entry = try exec._factory.create(Entry{
            ._start_time = start_timestamp,
            ._duration = duration,
            ._name = try exec.dupeString(name),
            ._type = .{ .measure = m },
        });
        m._proto = entry;
        return m;
    }

    pub fn getDetail(self: *const Measure) ?js.Value.Global {
        return self._detail;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(Measure);

        pub const Meta = struct {
            pub const name = "PerformanceMeasure";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };
        pub const detail = bridge.accessor(Measure.getDetail, null, .{});
    };
};

/// PerformanceTiming — Navigation Timing Level 1 (legacy, but widely used).
/// https://developer.mozilla.org/en-US/docs/Web/API/PerformanceTiming
/// All properties return 0 as stub values; the object must not be undefined
/// so that scripts accessing performance.timing.navigationStart don't crash.
pub const PerformanceTiming = struct {
    // Padding to avoid zero-size struct, which causes identity_map pointer collisions.
    _pad: bool = false,

    pub const JsApi = struct {
        pub const bridge = js.Bridge(PerformanceTiming);

        pub const Meta = struct {
            pub const name = "PerformanceTiming";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
            pub const empty_with_no_proto = true;
        };

        pub const navigationStart = bridge.constantAccessor(0.0);
        pub const unloadEventStart = bridge.constantAccessor(0.0);
        pub const unloadEventEnd = bridge.constantAccessor(0.0);
        pub const redirectStart = bridge.constantAccessor(0.0);
        pub const redirectEnd = bridge.constantAccessor(0.0);
        pub const fetchStart = bridge.constantAccessor(0.0);
        pub const domainLookupStart = bridge.constantAccessor(0.0);
        pub const domainLookupEnd = bridge.constantAccessor(0.0);
        pub const connectStart = bridge.constantAccessor(0.0);
        pub const connectEnd = bridge.constantAccessor(0.0);
        pub const secureConnectionStart = bridge.constantAccessor(0.0);
        pub const requestStart = bridge.constantAccessor(0.0);
        pub const responseStart = bridge.constantAccessor(0.0);
        pub const responseEnd = bridge.constantAccessor(0.0);
        pub const domLoading = bridge.constantAccessor(0.0);
        pub const domInteractive = bridge.constantAccessor(0.0);
        pub const domContentLoadedEventStart = bridge.constantAccessor(0.0);
        pub const domContentLoadedEventEnd = bridge.constantAccessor(0.0);
        pub const domComplete = bridge.constantAccessor(0.0);
        pub const loadEventStart = bridge.constantAccessor(0.0);
        pub const loadEventEnd = bridge.constantAccessor(0.0);
    };
};

// PerformanceNavigation implements the Navigation Timing Level 1 API.
// https://www.w3.org/TR/navigation-timing/#sec-navigation-navigation-timing-interface
// Stub implementation — returns 0 for type (TYPE_NAVIGATE) and 0 for redirectCount.
pub const PerformanceNavigation = struct {
    // Padding to avoid zero-size struct, which causes identity_map pointer collisions.
    _pad: bool = false,

    pub const JsApi = struct {
        pub const bridge = js.Bridge(PerformanceNavigation);

        pub const Meta = struct {
            pub const name = "PerformanceNavigation";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
            pub const empty_with_no_proto = true;
        };

        pub const @"type" = bridge.constantAccessor(0.0);
        pub const redirectCount = bridge.constantAccessor(0.0);
    };
};

const testing = @import("../../testing.zig");

test "Chrome 149 time clamping is deterministic and resolution-aware" {
    const clamper = TimeClamper{ .secret = 0x0123_4567_89ab_cdef };
    const cases = [_]struct {
        cross_origin_isolated: bool,
        resolution_us: i64,
    }{
        .{ .cross_origin_isolated = false, .resolution_us = TimeClamper.coarse_resolution_us },
        .{ .cross_origin_isolated = true, .resolution_us = TimeClamper.fine_resolution_us },
    };

    for (cases) |case| {
        var previous = clamper.clampMicroseconds(0, case.cross_origin_isolated);
        var raw: i64 = 0;
        while (raw < case.resolution_us * 100) : (raw += 1) {
            const clamped = clamper.clampMicroseconds(raw, case.cross_origin_isolated);
            try std.testing.expectEqual(clamped, clamper.clampMicroseconds(raw, case.cross_origin_isolated));
            try std.testing.expectEqual(-clamped, clamper.clampMicroseconds(-raw, case.cross_origin_isolated));
            try std.testing.expect(clamped >= previous);
            if (clamped > previous) {
                try std.testing.expectEqual(case.resolution_us, clamped - previous);
                previous = clamped;
            }
        }

        const large_timestamp: i64 = 1_616_533_323_846_260;
        const large_clamped = clamper.clampMicroseconds(
            large_timestamp,
            case.cross_origin_isolated,
        );
        try std.testing.expectEqual(@as(i64, 0), @mod(large_clamped, case.resolution_us));
    }
}

test "Performance timeOrigin plus now reconstructs Unix wall time" {
    const performance = Performance.init();
    const reconstructed_wall_ms = performance.getTimeOrigin() + performance.now();
    const current_wall_ms = @as(f64, @floatFromInt(std.time.microTimestamp())) /
        std.time.us_per_ms;
    try std.testing.expectApproxEqAbs(current_wall_ms, reconstructed_wall_ms, 50.0);
}

test "WebApi: Performance" {
    try testing.htmlRunner("performance.html", .{});
}

test "WebApi: PerformanceResourceTiming" {
    try testing.htmlRunner("performance_resource_timing.html", .{ .timeout_ms = 5000 });
}

test "WebApi: Performance resource timing buffer Chrome 149" {
    try testing.htmlRunner("performance_resource_buffer_chrome149.html", .{ .timeout_ms = 30000 });
}

test "WebApi: PerformanceNavigationTiming" {
    try testing.htmlRunner("performance_navigation_timing.html", .{ .timeout_ms = 5000 });
}
