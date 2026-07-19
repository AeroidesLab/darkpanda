// Privacy-minimized network lifecycle observations for the embedding ABI.
//
// The browser runtime owner is the sole writer of the retained ring. Dedicated
// Worker HTTP callbacks run on their own owner threads, so they publish into a
// separate bounded ingress ring. The FFI runtime owner drains that ingress at
// the next query. No request/response bodies, headers, cookies, query strings,
// fragments, or opaque URL payloads are retained.

const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;

pub const Phase = enum {
    start,
    headers,
    done,
    fail,
};

/// Privacy-safe transport failure categories exposed to embedders. Backend
/// error names and diagnostic strings never enter retained observations.
pub const FailureKind = enum {
    timeout,
    dns,
    connect,
    tls,
    http2,
    cancelled,
    transport,
};

pub fn classifyFailure(err: anyerror) FailureKind {
    return switch (err) {
        error.OperationTimedout,
        error.Timeout,
        => .timeout,
        error.CouldntResolveHost,
        error.CouldntResolveProxy,
        => .dns,
        error.CouldntConnect => .connect,
        error.SslConnectError => .tls,
        error.Http2,
        error.Http2Stream,
        => .http2,
        error.AbortedByCallback,
        error.Cancelled,
        error.Shutdown,
        => .cancelled,
        else => .transport,
    };
}

pub const ResourceType = enum {
    document,
    xhr,
    image,
    script,
    fetch,
    stylesheet,

    fn jsonName(self: ResourceType) []const u8 {
        return switch (self) {
            .document => "Document",
            .xhr => "XHR",
            .image => "Image",
            .script => "Script",
            .fetch => "Fetch",
            .stylesheet => "Stylesheet",
        };
    }
};

pub const InitiatorContext = enum {
    page,
    worker,
};

pub const Input = struct {
    request_id: u32,
    phase: Phase,
    frame_id: u32,
    root_frame_id: u32,
    resource_type: ResourceType,
    status: ?u16 = null,
    failure_kind: ?FailureKind = null,
    url: []const u8,
    initiator_context: InitiatorContext,
};

const max_host_bytes = 128;
const max_path_category_bytes = 160;

const FixedText = struct {
    bytes: [max_path_category_bytes]u8 = [_]u8{0} ** max_path_category_bytes,
    len: u8 = 0,

    fn init(value: []const u8) FixedText {
        var result: FixedText = .{};
        const n = @min(value.len, result.bytes.len);
        @memcpy(result.bytes[0..n], value[0..n]);
        result.len = @intCast(n);
        return result;
    }

    fn slice(self: *const FixedText) []const u8 {
        return self.bytes[0..self.len];
    }
};

const Observation = struct {
    sequence: u64,
    request_id: u32,
    phase: Phase,
    frame_id: u32,
    root_frame_id: u32,
    resource_type: ResourceType,
    status: ?u16,
    failure_kind: ?FailureKind,
    monotonic_time_us: u64,
    host: FixedText,
    path_category: FixedText,
    initiator_context: InitiatorContext,
};

const SanitizedUrl = struct {
    host: FixedText,
    path_category: FixedText,
};

/// Production capacity keeps the retained Page history bounded while allowing
/// a few hundred ordinary requests (three or four lifecycle phases each).
/// Worker ingress is separate and smaller because main-thread traffic bypasses
/// it and writes directly to the retained owner ring.
pub const Store = StoreType(512, 1024);

pub fn StoreType(comptime ingress_capacity: usize, comptime owner_capacity: usize) type {
    if (ingress_capacity == 0 or owner_capacity == 0) {
        @compileError("network observation capacities must be non-zero");
    }

    return struct {
        const Self = @This();

        owner_thread_id: ?std.Thread.Id = null,
        next_sequence: std.atomic.Value(u64) = .init(1),
        dropped_count: std.atomic.Value(u64) = .init(0),

        // Only owner_thread_id may read or mutate these fields.
        owner_entries: [owner_capacity]Observation = undefined,
        owner_count: usize = 0,

        // Cross-owner publication boundary. Worker threads touch only this
        // fixed storage while holding ingress_mutex.
        ingress_mutex: std.Thread.Mutex = .{},
        ingress_entries: [ingress_capacity]Observation = undefined,
        ingress_head: usize = 0,
        ingress_count: usize = 0,

        pub fn bindOwnerThread(self: *Self) void {
            std.debug.assert(self.owner_thread_id == null);
            self.owner_thread_id = std.Thread.getCurrentId();
        }

        pub fn record(self: *Self, input: Input) void {
            // A zero root cannot be attributed to an FFI Page and must not
            // become a cross-Page side channel.
            if (input.root_frame_id == 0) return;

            const sequence = self.next_sequence.fetchAdd(1, .monotonic);
            const sanitized = sanitizeUrl(input.url);
            const observation: Observation = .{
                .sequence = sequence,
                .request_id = input.request_id,
                .phase = input.phase,
                .frame_id = input.frame_id,
                .root_frame_id = input.root_frame_id,
                .resource_type = input.resource_type,
                .status = input.status,
                .failure_kind = if (input.phase == .fail)
                    input.failure_kind orelse .transport
                else
                    null,
                .monotonic_time_us = monotonicTimeUs(),
                .host = sanitized.host,
                .path_category = sanitized.path_category,
                .initiator_context = input.initiator_context,
            };

            if (self.owner_thread_id == std.Thread.getCurrentId()) {
                self.appendOwner(observation);
                return;
            }
            self.enqueueIngress(observation);
        }

        /// `since_sequence` is an acknowledgement cursor. Retained entries at
        /// or below it are discarded without counting as drops, then all newer
        /// entries are returned in sequence order. `droppedCount` in the JSON
        /// is the cumulative number of entries evicted by capacity pressure
        /// since Page creation (not the number of entries in this response).
        pub fn snapshotJson(self: *Self, allocator: Allocator, since_sequence: u64) ![]u8 {
            self.assertOwner();
            self.pruneAcknowledged(since_sequence);
            self.drainIngress(since_sequence);

            var json_entries: std.ArrayList(JsonObservation) = .empty;
            defer json_entries.deinit(allocator);
            try json_entries.ensureTotalCapacity(allocator, self.owner_count);
            for (self.owner_entries[0..self.owner_count]) |*entry| {
                if (entry.sequence <= since_sequence) continue;
                json_entries.appendAssumeCapacity(.{
                    .sequence = entry.sequence,
                    .requestId = entry.request_id,
                    .phase = @tagName(entry.phase),
                    .frameId = entry.frame_id,
                    .rootFrameId = entry.root_frame_id,
                    .resourceType = entry.resource_type.jsonName(),
                    .status = entry.status,
                    .failureKind = if (entry.failure_kind) |kind| @tagName(kind) else null,
                    .monotonicTimeUs = entry.monotonic_time_us,
                    .host = hostSlice(&entry.host),
                    .pathCategory = entry.path_category.slice(),
                    .initiatorContext = @tagName(entry.initiator_context),
                });
            }
            std.sort.pdq(JsonObservation, json_entries.items, {}, struct {
                fn lessThan(_: void, a: JsonObservation, b: JsonObservation) bool {
                    return a.sequence < b.sequence;
                }
            }.lessThan);

            const next = self.next_sequence.load(.acquire);
            return std.json.Stringify.valueAlloc(allocator, .{
                .droppedCount = self.dropped_count.load(.acquire),
                .latestSequence = next -% 1,
                .observations = json_entries.items,
            }, .{});
        }

        fn assertOwner(self: *const Self) void {
            std.debug.assert(self.owner_thread_id == std.Thread.getCurrentId());
        }

        fn enqueueIngress(self: *Self, observation: Observation) void {
            self.ingress_mutex.lock();
            defer self.ingress_mutex.unlock();

            if (self.ingress_count == ingress_capacity) {
                // Keep the newest bounded window. The overwritten entry is an
                // actual capacity loss and contributes to droppedCount.
                self.ingress_entries[self.ingress_head] = observation;
                self.ingress_head = (self.ingress_head + 1) % ingress_capacity;
                _ = self.dropped_count.fetchAdd(1, .monotonic);
                return;
            }
            const tail = (self.ingress_head + self.ingress_count) % ingress_capacity;
            self.ingress_entries[tail] = observation;
            self.ingress_count += 1;
        }

        fn drainIngress(self: *Self, since_sequence: u64) void {
            self.ingress_mutex.lock();
            defer self.ingress_mutex.unlock();

            var index: usize = 0;
            while (index < self.ingress_count) : (index += 1) {
                const slot = (self.ingress_head + index) % ingress_capacity;
                const entry = self.ingress_entries[slot];
                if (entry.sequence > since_sequence) self.appendOwner(entry);
            }
            self.ingress_head = 0;
            self.ingress_count = 0;
        }

        fn pruneAcknowledged(self: *Self, since_sequence: u64) void {
            var write: usize = 0;
            for (self.owner_entries[0..self.owner_count]) |entry| {
                if (entry.sequence <= since_sequence) continue;
                self.owner_entries[write] = entry;
                write += 1;
            }
            self.owner_count = write;
        }

        fn appendOwner(self: *Self, observation: Observation) void {
            self.assertOwner();
            if (self.owner_count < owner_capacity) {
                self.owner_entries[self.owner_count] = observation;
                self.owner_count += 1;
                return;
            }

            // Ingress may contain an older sequence than a directly-recorded
            // owner event. Retain the newest N globally instead of blindly
            // overwriting by drain order.
            var minimum_index: usize = 0;
            for (self.owner_entries[1..], 1..) |entry, index| {
                if (entry.sequence < self.owner_entries[minimum_index].sequence) {
                    minimum_index = index;
                }
            }
            if (observation.sequence > self.owner_entries[minimum_index].sequence) {
                self.owner_entries[minimum_index] = observation;
            }
            _ = self.dropped_count.fetchAdd(1, .monotonic);
        }
    };
}

const JsonObservation = struct {
    sequence: u64,
    requestId: u32,
    phase: []const u8,
    frameId: u32,
    rootFrameId: u32,
    resourceType: []const u8,
    status: ?u16,
    failureKind: ?[]const u8,
    monotonicTimeUs: u64,
    host: []const u8,
    pathCategory: []const u8,
    initiatorContext: []const u8,
};

fn hostSlice(value: *const FixedText) []const u8 {
    // Host has a lower public cap than pathCategory even though both use the
    // same compact backing type.
    return value.bytes[0..@min(value.len, max_host_bytes)];
}

fn monotonicTimeUs() u64 {
    const instant = std.time.Instant.now() catch return 0;
    return switch (builtin.os.tag) {
        .windows => blk: {
            const frequency = std.os.windows.QueryPerformanceFrequency();
            const seconds = instant.timestamp / frequency;
            const remainder: u128 = instant.timestamp % frequency;
            break :blk seconds * std.time.us_per_s +
                @as(u64, @intCast((remainder * std.time.us_per_s) / frequency));
        },
        .uefi, .wasi => instant.timestamp / std.time.ns_per_us,
        else => @as(u64, @intCast(instant.timestamp.sec)) * std.time.us_per_s +
            @as(u64, @intCast(@divTrunc(instant.timestamp.nsec, std.time.ns_per_us))),
    };
}

fn sanitizeUrl(url: []const u8) SanitizedUrl {
    const scheme_len: usize = if (std.ascii.startsWithIgnoreCase(url, "https://"))
        8
    else if (std.ascii.startsWithIgnoreCase(url, "http://"))
        7
    else
        return .{
            .host = FixedText.init(""),
            .path_category = FixedText.init(":non-http"),
        };

    const authority_end = indexOfAny(url, scheme_len, "/?#") orelse url.len;
    if (authority_end == scheme_len) {
        return .{
            .host = FixedText.init(""),
            .path_category = FixedText.init(":invalid-http-url"),
        };
    }
    const authority = url[scheme_len..authority_end];
    const host = if (std.mem.lastIndexOfScalar(u8, authority, '@')) |at|
        authority[at + 1 ..]
    else
        authority;
    const safe_host = if (host.len <= max_host_bytes)
        host
    else
        ":oversize-host";

    const path_end = indexOfAny(url, authority_end, "?#") orelse url.len;
    const path = if (authority_end < path_end and url[authority_end] == '/')
        url[authority_end..path_end]
    else
        "/";

    return .{
        .host = FixedText.init(safe_host),
        .path_category = categorizePath(path),
    };
}

fn categorizePath(path: []const u8) FixedText {
    if (path.len == 0 or std.mem.eql(u8, path, "/")) return FixedText.init("/");

    var buffer: [max_path_category_bytes]u8 = undefined;
    var length: usize = 0;
    var segment_count: usize = 0;
    var iterator = std.mem.splitScalar(u8, path, '/');
    while (iterator.next()) |segment| {
        if (segment.len == 0) continue;
        segment_count += 1;
        if (segment_count > 8) {
            if (!appendText(&buffer, &length, "/:more")) {
                return FixedText.init("/:oversize-path");
            }
            break;
        }
        if (!appendText(&buffer, &length, "/") or
            !appendText(&buffer, &length, categorizeSegment(segment)))
        {
            return FixedText.init("/:oversize-path");
        }
    }
    if (length == 0) return FixedText.init("/");
    return FixedText.init(buffer[0..length]);
}

fn categorizeSegment(segment: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, segment, '%') != null) return ":encoded";
    if (allAsciiDigits(segment)) return ":number";
    if (isUuid(segment)) return ":uuid";
    if (segment.len >= 8 and allAsciiHex(segment)) return ":hex";
    if (looksHighEntropy(segment)) return ":token";
    if (segment.len > 48) return ":long";
    for (segment) |byte| {
        if (!(std.ascii.isAlphanumeric(byte) or byte == '.' or byte == '_' or
            byte == '-' or byte == '~')) return ":segment";
    }
    return segment;
}

fn allAsciiDigits(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |byte| if (!std.ascii.isDigit(byte)) return false;
    return true;
}

fn allAsciiHex(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |byte| if (!std.ascii.isHex(byte)) return false;
    return true;
}

fn isUuid(value: []const u8) bool {
    if (value.len != 36) return false;
    for (value, 0..) |byte, index| {
        if (index == 8 or index == 13 or index == 18 or index == 23) {
            if (byte != '-') return false;
        } else if (!std.ascii.isHex(byte)) return false;
    }
    return true;
}

fn looksHighEntropy(value: []const u8) bool {
    if (value.len < 16) return false;
    var seen = [_]bool{false} ** 256;
    var unique: usize = 0;
    var has_digit = false;
    for (value) |byte| {
        if (!(std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.')) {
            return false;
        }
        has_digit = has_digit or std.ascii.isDigit(byte);
        if (!seen[byte]) {
            seen[byte] = true;
            unique += 1;
        }
    }
    return (has_digit and unique >= 8) or (value.len >= 24 and unique >= 10);
}

fn appendText(buffer: []u8, length: *usize, value: []const u8) bool {
    if (value.len > buffer.len - length.*) return false;
    @memcpy(buffer[length.*..][0..value.len], value);
    length.* += value.len;
    return true;
}

fn indexOfAny(value: []const u8, start: usize, needles: []const u8) ?usize {
    for (value[start..], start..) |byte, index| {
        if (std.mem.indexOfScalar(u8, needles, byte) != null) return index;
    }
    return null;
}

test "network observations remove query, fragment, credentials and opaque URL payloads" {
    const sanitized = sanitizeUrl(
        "https://user:secret@example.test/api/123/550e8400-e29b-41d4-a716-446655440000/" ++
            "aB9kLm2NpQ7rSt4UvW8x?token=never-retain#fragment",
    );
    try std.testing.expectEqualStrings("example.test", hostSlice(&sanitized.host));
    try std.testing.expectEqualStrings(
        "/api/:number/:uuid/:token",
        sanitized.path_category.slice(),
    );
    try std.testing.expect(std.mem.indexOf(u8, sanitized.path_category.slice(), "never-retain") == null);

    const image = sanitizeUrl(
        "http://127.0.0.1:9000/assets/aB9kLm2NpQ7rSt4UvW8xYz6.png?image=secret",
    );
    try std.testing.expectEqualStrings("127.0.0.1:9000", hostSlice(&image.host));
    try std.testing.expectEqualStrings("/assets/:token", image.path_category.slice());

    const opaque_url = sanitizeUrl("blob:https://example.test/opaque-identifier");
    try std.testing.expectEqualStrings("", hostSlice(&opaque_url.host));
    try std.testing.expectEqualStrings(":non-http", opaque_url.path_category.slice());
}

test "network failure classification is bounded and success phases stay null" {
    try std.testing.expectEqual(FailureKind.timeout, classifyFailure(error.OperationTimedout));
    try std.testing.expectEqual(FailureKind.timeout, classifyFailure(error.Timeout));
    try std.testing.expectEqual(FailureKind.dns, classifyFailure(error.CouldntResolveHost));
    try std.testing.expectEqual(FailureKind.connect, classifyFailure(error.CouldntConnect));
    try std.testing.expectEqual(FailureKind.tls, classifyFailure(error.SslConnectError));
    try std.testing.expectEqual(FailureKind.http2, classifyFailure(error.Http2));
    try std.testing.expectEqual(FailureKind.cancelled, classifyFailure(error.AbortedByCallback));
    try std.testing.expectEqual(FailureKind.transport, classifyFailure(error.WreqRequestFailed));

    const TinyStore = StoreType(1, 2);
    var store: TinyStore = .{};
    store.bindOwnerThread();
    store.record(.{
        .request_id = 1,
        .phase = .start,
        .frame_id = 10,
        .root_frame_id = 10,
        .resource_type = .fetch,
        // A caller cannot attach a failure category to a successful phase.
        .failure_kind = .tls,
        .url = "https://example.test/start",
        .initiator_context = .page,
    });
    store.record(.{
        .request_id = 1,
        .phase = .fail,
        .frame_id = 10,
        .root_frame_id = 10,
        .resource_type = .fetch,
        .failure_kind = .dns,
        .url = "https://example.test/fail",
        .initiator_context = .page,
    });

    const json = try store.snapshotJson(std.testing.allocator, 0);
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "CouldntResolveHost") == null);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    const observations = parsed.value.object.get("observations").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), observations.len);
    switch (observations[0].object.get("failureKind").?) {
        .null => {},
        else => return error.TestExpectedEqual,
    }
    try std.testing.expectEqualStrings(
        "dns",
        observations[1].object.get("failureKind").?.string,
    );
}

test "network observation worker ingress is bounded and owner ordered" {
    const TinyStore = StoreType(2, 3);
    var store: TinyStore = .{};
    store.bindOwnerThread();

    const Producer = struct {
        fn run(target: *TinyStore) void {
            for (0..3) |index| target.record(.{
                .request_id = @intCast(index + 1),
                .phase = .start,
                .frame_id = 20,
                .root_frame_id = 10,
                .resource_type = .fetch,
                .url = "https://example.test/worker?secret=discarded",
                .initiator_context = .worker,
            });
        }
    };
    var thread = try std.Thread.spawn(.{}, Producer.run, .{&store});
    thread.join();

    store.record(.{
        .request_id = 4,
        .phase = .done,
        .frame_id = 10,
        .root_frame_id = 10,
        .resource_type = .document,
        .status = 200,
        .url = "https://example.test/",
        .initiator_context = .page,
    });

    const json = try store.snapshotJson(std.testing.allocator, 0);
    defer std.testing.allocator.free(json);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqual(@as(i64, 1), root.get("droppedCount").?.integer);
    const observations = root.get("observations").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), observations.len);
    try std.testing.expect(observations[0].object.get("sequence").?.integer <
        observations[1].object.get("sequence").?.integer);
    try std.testing.expect(observations[1].object.get("sequence").?.integer <
        observations[2].object.get("sequence").?.integer);
}
