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
const builtin = @import("builtin");

const js = @import("js/js.zig");

const Frame = @import("Frame.zig");
const Session = @import("Session.zig");
const Factory = @import("Factory.zig");
const Viewport = @import("Viewport.zig");
const Blob = @import("webapi/Blob.zig");
const Window = @import("webapi/Window.zig");
const CanvasBackendProvider = @import("canvas_backend/Provider.zig");

const Allocator = std.mem.Allocator;
const IS_DEBUG = builtin.mode == .Debug;

// A Page is the container for a root Frame and all of its descendants
// (nested iframes). It owns the resources that share the lifetime of the root
// document: the DOM factory, the per-page arena, the JS identity map, shared
// origins, v8 global handles, and queued navigation buffers.
//
// In the future, a Session may hold multiple Pages at once (e.g. during a
// navigation, while the old Page is retiring and the new one is provisional).
// For now, Session still holds a single Page.
const Page = @This();

session: *Session,

// DOM version used to invalidate cached state of "live" collections. Ideally
// this would be on the Frame (and that's where it used to be). But getting the
// frame from a DOM mutation call is [relatively] expensive. You can't use
// the bridge-injected *Frame, because that's the frame where the JS is being
// executed, which might not be the *Frame that owns the node. We don't store
// *Frame in node (think of the memory!), so we have to iterate through its
// parents, find the Document, which has the frame.
// So the choice is between making every DOM mutation (which has to increase
// the dom_version) + every read (which has to check the version) slow, or
// putting this on the Page, and having an DOM mutation in Frame 1 invalidate
// a cached lookup on Frame 2. We picked the latter.
dom_version: usize = 0,

// Monotonic creation counter for BroadcastChannels in this Page. A postMessage
// captures the current value so delivery targets only channels that existed
// when it was called
broadcast_sequence: std.atomic.Value(u64) = .init(0),

// DOM object factory scoped to this Page's documents.
factory: Factory,

// The arena for this Page's lifetime. Document / Frame / Factory / DOM
// objects allocate out of this.
frame_arena: Allocator,

// Owns every native Canvas surface for this Page. Keeping the dynamic library
// handle above individual canvas elements guarantees that Rust function
// pointers remain valid until all thread-affine surfaces have been freed.
canvas_backend: CanvasBackendProvider,

// Origin map for same-origin context sharing. Entries live for the Page's
// lifetime.
origins: std.StringHashMapUnmanaged(*js.Origin) = .empty,

// Chromium gives every WindowAgent one event loop and therefore one V8
// MicrotaskQueue. The AgentClusterKey is origin-keyed by default in the
// release profile we mirror, so same-origin Window contexts in this Page
// share the queue stored here. Workers intentionally do not use this map.
//
// The Page owns these queues. Context teardown must never delete a queue from
// this map because another same-agent Context (or a retained, detached realm)
// can still refer to it.
window_agent_microtask_queues: std.StringHashMapUnmanaged(*js.v8.MicrotaskQueue) = .empty,

// Single ownership list for every queue ever associated with a Context in
// this Page, including worker/opaque queues and queues retired by navigation.
// They are destroyed only after every Page-owned v8::Global has been reset.
microtask_queues: std.ArrayList(*js.v8.MicrotaskQueue) = .empty,

// Identity tracking for the main world. All main-world contexts in this Page
// share this, ensuring object identity works across same-origin frames.
identity: js.Identity = .{},

// Page/agent-cluster-wide lookup for blob: URLs. Individual globals retain
// ownership maps so their entries can still be revoked at global teardown.
blob_url_registry: Blob.URLRegistry,

// Finalizer callbacks for Zig instances exposed to v8 in this Page. Keyed by
// Zig instance ptr. The backing FinalizerCallback.Identity structs come from
// Browser.fc_identity_pool so they outlive the Page (and the Session) for v8
// weak-callback safety.
finalizer_callbacks: std.AutoHashMapUnmanaged(usize, *js.FinalizerCallback) = .empty,

// Persisted v8 handles owned by this Page. Handles that outlive the Page are
// reset on teardown; handles that can be released early are dropped
// individually. See js.GlobalTracker.
globals: js.GlobalTracker,

// Double buffered so that, as we process one list of queued navigations, new
// entries are added to the separate buffer. Prevents endless navigation loops
// and invalidation of the list during iteration.
queued_navigation_1: std.ArrayList(*Frame) = .empty,
queued_navigation_2: std.ArrayList(*Frame) = .empty,
// pointer to either queued_navigation_1 or queued_navigation_2
queued_navigation: *std.ArrayList(*Frame) = undefined,

// Temporary buffer for about:blank navigations during processing.
// We process async navigations first (safe from re-entrance), then sync
// about:blank navigations (which may add to queued_navigation).
queued_queued_navigation: std.ArrayList(*Frame) = .empty,

// The root Frame of this Page. Non-optional — a Page always has a root frame.
frame: Frame,

// Popup Frames opened by window.open. They are top-level browsing contexts
// (parent == null, no iframe element) but share this Page's factory, arena,
// and identity map.
// Their lifetime is bound to the Page: on Page.deinit they
// are torn down. TODO: this is far from correct. An new window shouldn't be tied
// to the original page like this.
popups: std.ArrayList(*Frame) = .empty,

// Popup Frames that have been closed. The window can still be referenced / used
// from JS, so we defer shutting them down until page tear down (which isn't
// ideal from a memory point of view).
closed_frames: std.ArrayList(*Frame) = .empty,

// Navigated-away iframe/popup inner realms. They are no longer discoverable
// through the active frame tree, but their native Frame/Window/Context storage
// must remain valid for old closures and detached DOM wrappers. The Page arena
// owns them until the same teardown boundary as the shared identity map and
// persistent V8 handles.
retired_frames: std.ArrayList(*Frame) = .empty,

// In-flight navigation for a root page. When not null, this page will "replace"
// the referenced page once the response header arrives. This is necessary
// because, during navigation, both the "old" and "new" pages remain addressable
// in CDP
replaces: ?*Page = null,

// Inverse of `replaces`. While we don't strictly need both, it does streamline
// code. The two are kept in sync.
replacement: ?*Page = null,

// The viewport every consumer should read. The runtime override (set via
// Emulation.setDeviceMetricsOverride) is stored on the Browser so it persists
// across page navigations; delegate to it here, keeping a single read path for
// every viewport consumer.
pub fn getViewport(self: *const Page) Viewport {
    return self.session.browser.getViewport();
}

/// Explicit injection point for the resolved fingerprint/config owner. It
/// must be called before any canvas creates its backing surface.
pub fn configureCanvasBackend(self: *Page, options: CanvasBackendProvider.Options) !void {
    if (self.session.browser.resolvedFingerprint()) |profile| {
        const identity = canvasIdentity(profile.graphics);
        if (options.kind != identity.kind or
            options.profile_seed != identity.profile_seed or
            options.canvas_seed != identity.canvas_seed)
        {
            return error.CanvasIdentityOwnedByFingerprintProfile;
        }
    }
    try self.canvas_backend.configure(options);
}

// Initialize a Page and its root Frame.
pub fn init(
    self: *Page,
    session: *Session,
    frame_id: u32,
    navigation_context: ?*Frame.NavigationContext,
) !void {
    const frame_arena = try session.arena_pool.acquire(.large, "Page.frame_arena");
    errdefer session.arena_pool.release(frame_arena);
    var canvas_backend = if (session.browser.app.canvas_backend_options) |options|
        try CanvasBackendProvider.init(session.browser.app.allocator, options)
    else
        try CanvasBackendProvider.initFromEnvironment(session.browser.app.allocator);
    errdefer canvas_backend.deinit();
    if (session.browser.resolvedFingerprint()) |profile| {
        // Runtime environment selected the driver/library/fallback above;
        // only the immutable resolved profile may select observable kind and
        // seeds. This precedes Frame.init, hence precedes the first surface.
        try canvas_backend.configureIdentity(canvasIdentity(profile.graphics));
    }

    self.* = .{
        .session = session,
        .frame = undefined,
        .frame_arena = frame_arena,
        .canvas_backend = canvas_backend,
        .factory = Factory.init(frame_arena),
        .globals = .init(session.browser.app.allocator),
        .blob_url_registry = .init(session.browser.app.allocator),
    };
    self.queued_navigation = &self.queued_navigation_1;

    try Frame.init(&self.frame, frame_id, self, .{
        .navigation_context = navigation_context,
    });
}

fn canvasIdentity(graphics: anytype) CanvasBackendProvider.Identity {
    return .{
        .kind = switch (graphics.canvas_backend) {
            .skia => .skia,
            .fake => .fake,
        },
        .profile_seed = graphics.profile_seed,
        .canvas_seed = graphics.canvas_seed,
    };
}

// Tear down the Page and its root Frame. Equivalent to the old
// Session.removePage + Session.resetFrameResources.
pub fn deinit(self: *Page) void {
    // Re-entrant navigation/discard can temporarily register a Frame while an
    // active root, popup, closed Frame, or another retired Frame still owns it
    // through child_frames. Build one deduplicated ownership forest spanning
    // every Page registry and deinitialize structural roots only. A descendant
    // detached before teardown naturally becomes its own root.
    var registered_frames: std.ArrayList(*Frame) = .empty;
    appendRegisteredFrame(&registered_frames, self.frame_arena, &self.frame);
    for (self.popups.items) |frame| appendRegisteredFrame(&registered_frames, self.frame_arena, frame);
    for (self.closed_frames.items) |frame| appendRegisteredFrame(&registered_frames, self.frame_arena, frame);
    for (self.retired_frames.items) |frame| appendRegisteredFrame(&registered_frames, self.frame_arena, frame);

    for (registered_frames.items) |frame| {
        var has_owner = false;
        for (registered_frames.items) |candidate| {
            if (candidate == frame) continue;
            if (frameStructurallyOwns(candidate, frame)) {
                has_owner = true;
                break;
            }
        }
        if (!has_owner) frame.deinit();
    }

    self.popups = .empty;
    self.closed_frames = .empty;
    self.retired_frames = .empty;
    if (comptime IS_DEBUG) {
        std.debug.assert(self.blob_url_registry.count() == 0);
    }
    // Defensive cleanup for leaked owner entries. URLRegistry owns both its
    // key storage and one strong Blob reference per live entry.
    self.blob_url_registry.deinit(self);

    const session = self.session;
    defer session.browser.env.memoryPressureNotification(.moderate);

    self.identity.deinit();
    self.identity = .{};

    // Force cleanup all remaining finalized objects.
    {
        var it = self.finalizer_callbacks.valueIterator();
        while (it.next()) |fc| {
            fc.*.deinit(self);
        }
        self.finalizer_callbacks = .empty;
    }

    // CanvasGradient and CanvasPattern finalizers release opaque style handles
    // through the dynamically loaded canvas API. Keep both the surfaces and
    // the library alive until every remaining JS-backed object has finalized;
    // unloading the backend first leaves their cached API function pointers
    // dangling and turns normal Page teardown into an access violation.
    self.canvas_backend.deinit();

    self.globals.deinit();

    if (comptime IS_DEBUG) {
        std.debug.assert(self.origins.count() == 0);
    }
    // Defensive cleanup in case origins leaked.
    {
        const app = session.browser.app;
        var it = self.origins.valueIterator();
        while (it.next()) |value| {
            value.*.deinit(app);
        }
        self.origins = .empty;
    }

    // V8 requires a MicrotaskQueue to outlive every associated Context. At
    // this point frame contexts are detached and all Page-owned Globals and
    // security tokens have been reset, so each queue can be deleted once.
    self.window_agent_microtask_queues.deinit(self.frame_arena);
    self.window_agent_microtask_queues = .empty;
    for (self.microtask_queues.items) |queue| {
        js.v8.v8__MicrotaskQueue__DELETE(queue);
    }
    self.microtask_queues.deinit(self.frame_arena);
    self.microtask_queues = .empty;

    session.arena_pool.release(self.frame_arena);
}

pub fn registerBlobURL(
    self: *Page,
    owner: *Blob.OwnedURLSet,
    owner_arena: Allocator,
    url: []const u8,
    blob: *Blob,
) !void {
    try owner.putNoClobber(owner_arena, url, {});
    errdefer _ = owner.remove(url);

    // The central registry owns a separately allocated key. Never allocate it
    // from frame_arena: DedicatedWorkers call this method on their owner thread
    // while the creator thread can simultaneously allocate DOM objects there.
    try self.blob_url_registry.register(url, blob);
}

pub fn revokeBlobURL(self: *Page, url: []const u8) void {
    self.blob_url_registry.revoke(url, self);
}

pub fn releaseOwnedBlobURLs(self: *Page, owner: *Blob.OwnedURLSet) void {
    var it = owner.keyIterator();
    while (it.next()) |url| {
        self.blob_url_registry.revoke(url.*, self);
    }
    owner.* = .{};
}

/// Transfers an old inner Frame from the active browsing-context tree into
/// Page-lifetime ownership. Append first so an allocation failure leaves the
/// still-active realm untouched; retireForNavigation itself is infallible.
pub fn retireFrameForNavigation(self: *Page, frame: *Frame) !void {
    try self.registerRetiredFrame(frame);
    frame.retireForNavigation();
}

/// Transfers a browsing context which has been discarded rather than
/// navigated. Its old V8 global stays attached, matching Blink's
/// WindowProxy::ClearForClose behavior for removed iframe subtrees.
pub fn retireFrameForDiscard(self: *Page, frame: *Frame) !void {
    try self.registerRetiredFrame(frame);
    frame.retireForDiscard();
}

fn registerRetiredFrame(self: *Page, frame: *Frame) !void {
    if (std.mem.indexOfScalar(*Frame, self.retired_frames.items, frame) != null) return;
    try self.retired_frames.append(self.frame_arena, frame);
}

fn frameStructurallyOwns(ancestor: *Frame, descendant: *Frame) bool {
    var current = descendant;
    while (current.parent) |parent| {
        if (std.mem.indexOfScalar(*Frame, parent.child_frames.items, current) == null) return false;
        if (parent == ancestor) return true;
        current = parent;
    }
    return false;
}

fn appendRegisteredFrame(frames: *std.ArrayList(*Frame), allocator: Allocator, frame: *Frame) void {
    if (std.mem.indexOfScalar(*Frame, frames.items, frame) != null) return;
    frames.append(allocator, frame) catch @panic("OOM while normalizing Page Frame ownership");
}

test "Page retired ownership forest follows current structural edges" {
    const allocator = std.testing.allocator;
    var root: Frame = undefined;
    var child: Frame = undefined;
    var grandchild: Frame = undefined;

    root.parent = null;
    root.child_frames = .empty;
    defer root.child_frames.deinit(allocator);
    child.parent = &root;
    child.child_frames = .empty;
    defer child.child_frames.deinit(allocator);
    grandchild.parent = &child;
    grandchild.child_frames = .empty;

    try root.child_frames.append(allocator, &child);
    try child.child_frames.append(allocator, &grandchild);
    try std.testing.expect(frameStructurallyOwns(&root, &child));
    try std.testing.expect(frameStructurallyOwns(&root, &grandchild));
    try std.testing.expect(frameStructurallyOwns(&child, &grandchild));

    _ = root.child_frames.orderedRemove(0);
    try std.testing.expect(!frameStructurallyOwns(&root, &child));
    try std.testing.expect(!frameStructurallyOwns(&root, &grandchild));
    try std.testing.expect(frameStructurallyOwns(&child, &grandchild));
}

/// Native opener links target the current inner Window even though JavaScript
/// observes the stable outer WindowProxy. Patch every live or retained realm
/// when a popup commits a fresh inner Window so origin checks never consult a
/// navigated-away opener Frame.
pub fn replaceOpenerReferences(self: *Page, old: *Window, replacement: ?*Window) void {
    replaceFrameOpenerReferences(&self.frame, old, replacement);
    for (self.popups.items) |popup| {
        replaceFrameOpenerReferences(popup, old, replacement);
    }
    for (self.closed_frames.items) |frame| {
        replaceFrameOpenerReferences(frame, old, replacement);
    }
    for (self.retired_frames.items) |frame| {
        replaceFrameOpenerReferences(frame, old, replacement);
    }
}

fn replaceFrameOpenerReferences(frame: *Frame, old: *Window, replacement: ?*Window) void {
    if (frame.window._opener == old) frame.window._opener = replacement;
    for (frame.child_frames.items) |child| {
        replaceFrameOpenerReferences(child, old, replacement);
    }
}

// Returns a strong reference which must be released by the caller.
pub fn acquireBlobURL(self: *Page, url: []const u8) ?*Blob {
    return self.blob_url_registry.acquire(url);
}

// Opaque callback used by HttpClient's resolved BlobURL token. Keeping this
// here avoids coupling HttpClient to Page while preserving Blob ref-counting
// through the Page's arena pool.
pub fn releaseHttpBlob(ctx: *anyopaque, raw_blob: *anyopaque) void {
    const self: *Page = @ptrCast(@alignCast(ctx));
    const blob: *Blob = @ptrCast(@alignCast(raw_blob));
    blob.releaseRef(self);
}

pub fn getArena(self: *Page, size_or_bucket: anytype, debug: []const u8) !Allocator {
    return self.session.getArena(size_or_bucket, debug);
}

pub fn releaseArena(self: *Page, allocator: Allocator) void {
    return self.session.releaseArena(allocator);
}

pub fn getOrCreateOrigin(self: *Page, key_: ?[]const u8) !*js.Origin {
    const session = self.session;
    var opaque_origin: [36]u8 = undefined;
    const key = key_ orelse blk: {
        @import("../id.zig").uuidv4(&opaque_origin);
        // Every null request still gets a fresh, unguessable opaque identity.
        // Register that generated key like a tuple origin so an inherited
        // about:/blob: realm in this Page can recover the exact same *Origin
        // and V8 security-token object from a captured key.
        break :blk opaque_origin[0..];
    };

    const gop = try self.origins.getOrPut(session.arena, key);
    if (gop.found_existing) {
        const origin = gop.value_ptr.*;
        origin.rc += 1;
        return origin;
    }

    errdefer _ = self.origins.remove(key);

    const origin = try js.Origin.init(session.browser.app, session.browser.env.isolate, key);
    gop.key_ptr.* = origin.key;
    gop.value_ptr.* = origin;
    return origin;
}

// Retain an exact Page-owned Origin when the creator Context is still alive.
// Callers must use getOrCreateOrigin(source.key) instead when crossing a Page
// replacement boundary; Page teardown owns every Origin registered above.
pub fn retainOrigin(self: *Page, origin: *js.Origin) *js.Origin {
    if (comptime IS_DEBUG) {
        std.debug.assert(self.origins.get(origin.key) == origin);
    }
    origin.rc += 1;
    return origin;
}

pub fn releaseOrigin(self: *Page, origin: *js.Origin) void {
    const rc = origin.rc;
    if (rc == 1) {
        _ = self.origins.remove(origin.key);
        origin.deinit(self.session.browser.app);
    } else {
        origin.rc = rc - 1;
    }
}

pub const WindowAgentMicrotaskQueue = struct {
    queue: *js.v8.MicrotaskQueue,
};

pub fn createMicrotaskQueue(self: *Page) !*js.v8.MicrotaskQueue {
    const queue = js.v8.v8__MicrotaskQueue__New(
        self.session.browser.env.isolate.handle,
        js.v8.kExplicit,
    ).?;
    errdefer js.v8.v8__MicrotaskQueue__DELETE(queue);
    try self.microtask_queues.append(self.frame_arena, queue);
    return queue;
}

// Return the queue for an origin-keyed WindowAgent. When the caller still
// owns its freshly-created Context queue, adopt that queue for the first
// Context instead of allocating and immediately replacing it.
pub fn getOrCreateWindowAgentMicrotaskQueue(
    self: *Page,
    key: []const u8,
    candidate: ?*js.v8.MicrotaskQueue,
) !WindowAgentMicrotaskQueue {
    if (self.window_agent_microtask_queues.get(key)) |queue| {
        return .{ .queue = queue };
    }

    const queue = candidate orelse try self.createMicrotaskQueue();

    // Origin objects are ref-counted and can disappear before the Page. The
    // registry key must therefore have Page lifetime of its own.
    const owned_key = try self.frame_arena.dupe(u8, key);
    try self.window_agent_microtask_queues.putNoClobber(
        self.frame_arena,
        owned_key,
        queue,
    );
    return .{ .queue = queue };
}

pub fn scheduleNavigation(self: *Page, frame: *Frame) !void {
    const list = self.queued_navigation;

    // Check if frame is already queued
    for (list.items) |existing| {
        if (existing == frame) {
            // Already queued
            return;
        }
    }

    return list.append(self.session.arena, frame);
}

pub fn findFrameByFrameId(self: *Page, frame_id: u32) ?*Frame {
    if (findFrameBy(&self.frame, "_frame_id", frame_id)) |found| {
        return found;
    }
    return self.findPopupBy("_frame_id", frame_id);
}

// Returns the popup Frame registered under `name`, or null.
pub fn findPopupByName(self: *Page, name: []const u8) ?*Frame {
    for (self.popups.items) |popup| {
        if (std.mem.eql(u8, popup.window._name, name)) {
            return popup;
        }
    }
    return null;
}

pub fn findFrameByLoaderId(self: *Page, loader_id: u32) ?*Frame {
    if (findFrameBy(&self.frame, "_loader_id", loader_id)) |found| {
        return found;
    }
    return self.findPopupBy("_loader_id", loader_id);
}

fn findFrameBy(frame: *Frame, comptime field: []const u8, id: u32) ?*Frame {
    if (@field(frame, field) == id) {
        return frame;
    }
    for (frame.child_frames.items) |f| {
        if (findFrameBy(f, field, id)) |found| {
            return found;
        }
    }
    return null;
}

fn findPopupBy(self: *Page, comptime field: []const u8, id: u32) ?*Frame {
    for (self.popups.items) |frame| {
        if (findFrameBy(frame, field, id)) |found| {
            return found;
        }
    }
    return null;
}

// Snapshots the Execution of every same-origin global in this Page — the root
// frame, descendant iframes, popups (and their descendants), and each frame's
// worker scopes — into `arena`.
//
// The returned set is fixed, so a caller may run user JS (which can create or
// tear down frames/workers) while walking it without invalidating the slice.
pub fn executionsForOrigin(self: *Page, arena: Allocator, origin: []const u8) ![]*js.Execution {
    var list: std.ArrayList(*js.Execution) = .empty;
    try appendFrameExecutions(&self.frame, origin, arena, &list);
    for (self.popups.items) |popup| {
        try appendFrameExecutions(popup, origin, arena, &list);
    }
    return list.items;
}

// Creator-thread fan-out for BroadcastChannel. Worker V8 state is never
// borrowed here: each Worker retains the isolate-free envelope in its inbound
// mailbox and deserializes it later on the worker owner thread. `excluded` is
// the source Worker for worker -> creator -> worker forwarding.
pub fn routeBroadcastToWorkers(
    self: *Page,
    message: *js.Value.BroadcastMessage,
    excluded: ?*anyopaque,
) void {
    self.frame.routeBroadcastToWorkers(message, excluded);
    for (self.popups.items) |popup| {
        popup.routeBroadcastToWorkers(message, excluded);
    }
}

fn appendFrameExecutions(frame: *Frame, origin: []const u8, arena: Allocator, list: *std.ArrayList(*js.Execution)) !void {
    if (frame.origin) |fo| {
        if (std.mem.eql(u8, fo, origin)) {
            try list.append(arena, &frame.js.execution);
        }
    }
    // DedicatedWorker Executions are isolate/thread-affine and must never be
    // handed to a Window-thread caller. Cross-agent features route through the
    // worker mailbox instead of borrowing `js.Execution` directly.
    for (frame.child_frames.items) |child| {
        try appendFrameExecutions(child, origin, arena, list);
    }
}
