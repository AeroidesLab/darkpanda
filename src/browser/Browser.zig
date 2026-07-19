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

const App = @import("../App.zig");
const CDP = @import("../cdp/CDP.zig");
const Notification = @import("../Notification.zig");

const js = @import("js/js.zig");
const Page = @import("Page.zig");
const Watchdog = @import("../Watchdog.zig");
const Session = @import("Session.zig");
const Selector = @import("webapi/selector/Selector.zig");
const Viewport = @import("Viewport.zig");
const HttpClient = @import("HttpClient.zig");
const OwnerMailbox = @import("OwnerMailbox.zig");
const PermissionState = @import("webapi/Permissions.zig").State;
const FingerprintProfile = @import("../FingerprintProfile.zig");

const ArenaPool = App.ArenaPool;
const Allocator = std.mem.Allocator;

// Browser is an instance of the browser.
// You can create multiple browser instances.
// A browser contains only one session.
const Browser = @This();

env: js.Env,
app: *App,
session: ?Session,
allocator: Allocator,
arena_pool: *ArenaPool,
http_client: HttpClient,
// Cross-thread native envelopes targeting Window-owned Execution/V8 state.
// Producers only enqueue and wake the HTTP poll; Browser.runMacrotasks is the
// sole owner-thread drain point.
owner_mailbox: OwnerMailbox.Mailbox,
fingerprint_profile: ?*const FingerprintProfile.ResolvedFingerprintProfile,

// Shared across pages, survives navigation. See Selector.Cache.
selector_cache: Selector.Cache,

// Permission state set via CDP Browser.grantPermissions / setPermission /
// resetPermissions, keyed by permission name (e.g. "geolocation"). Read back
// by navigator.permissions.query(). Scoped to the Browser so it persists
// across page navigations, mirroring how Chrome scopes permissions to the
// browser context. Keys are owned by `allocator`; values are enum tags.
permissions: std.StringHashMapUnmanaged(PermissionState) = .empty,

// Runtime viewport override set via Emulation.setDeviceMetricsOverride and
// cleared via clearDeviceMetricsOverride. Null means use the compile-time
// Viewport.default. Scoped to the Browser so it persists across page
// navigations (matching how Chrome scopes the override to the connection).
// Every viewport consumer reads it through Page.getViewport so they all
// observe the same (possibly overridden) value.
viewport_override: ?Viewport = null,

// used by sessions to allocate pages.
page_pool: std.heap.MemoryPool(Page),

// Registered with App.watchdog for the lifetime of the env. The watchdog
// checker thread reads it until Browser.deinit unregisters.
watchdog_entry: Watchdog.Entry,

// Pool for FinalizerCallback.Identity structs — the records V8 weak-callback
// parameters point at. Scoped to the Browser (i.e. the V8 Isolate's lifetime)
// rather than the Session: V8 can run a weak finalizer arbitrarily late, any
// time up until the Isolate is torn down, so these must outlive every Session.
// Freed in deinit *after* env.deinit() tears down the Isolate — the point past
// which no finalizer can fire.
fc_identity_pool: std.heap.MemoryPool(js.FinalizerCallback.Identity),

// Monotonic frame-ID generator scoped to this Browser (one per CDP
// connection). Lives here, not on Session, because CDP target IDs
// (encoded as `FID-{d:0>10}`) must be unique for the lifetime of the
// connection -- a Session-scoped counter would re-issue the same
// `FID-0000000001` for every fresh BrowserContext on the connection,
// which Playwright rejects with `Duplicate target FID-...` (issue
// #2472).
frame_id_gen: u32 = 0,

const InitOpts = struct {
    env: js.Env.InitOpts = .{},
};

// Allocate the next frame ID. Wrapping `+%` keeps this safe past 2^32
// allocations on a single connection (which would take days of
// continuous navigation; in practice we wrap the connection long
// before that). Callers must format with `FID-{d:0>10}` to match the
// existing CDP target-ID encoding (`src/cdp/id.zig`).
pub fn nextFrameId(self: *Browser) u32 {
    const id = self.frame_id_gen +% 1;
    self.frame_id_gen = id;
    return id;
}

pub fn init(self: *Browser, app: *App, opts: InitOpts, cdp: ?*CDP) !void {
    const allocator = app.allocator;

    var env = try js.Env.init(app, opts.env);
    errdefer env.deinit();

    self.* = .{
        .app = app,
        .env = env,
        .session = null,
        .allocator = allocator,
        .arena_pool = &app.arena_pool,
        .http_client = undefined,
        .owner_mailbox = undefined,
        .fingerprint_profile = app.resolvedFingerprint(),
        .page_pool = std.heap.MemoryPool(Page).init(allocator),
        .fc_identity_pool = .init(allocator),
        .selector_cache = .init(allocator),
        .watchdog_entry = undefined,
    };
    self.env.protectHeapLimit();
    try self.http_client.init(allocator, &app.network, cdp);
    errdefer self.http_client.deinit();
    self.owner_mailbox = try OwnerMailbox.Mailbox.init(std.heap.page_allocator, .{
        .context = self,
        .notify = wakeOwnerMailbox,
    });
    errdefer self.owner_mailbox.deinit();

    self.watchdog_entry = .{
        .env = &self.env,
        .heartbeat = &self.http_client.heartbeat,
    };
    app.watchdog.register(&self.watchdog_entry);
}

pub fn deinit(self: *Browser) void {
    self.closeSession();
    // After this returns, the watchdog thread holds no reference to our env
    // or http_client — required before either is torn down.
    self.app.watchdog.unregister(&self.watchdog_entry);
    self.owner_mailbox.deinit();
    self.env.deinit();
    // After env.deinit() the Isolate is gone, so no further weak finalizer can
    // fire — only now is it safe to free the pool backing their parameters.
    self.fc_identity_pool.deinit();
    self.page_pool.deinit();
    self.http_client.deinit();
    self.clearPermissions();
    self.permissions.deinit(self.allocator);
    self.selector_cache.deinit();
}

// Set (or overwrite) the stored state for a permission. The name is duped into
// `allocator`; the state is a plain enum tag. Used by CDP
// Browser.grantPermissions / setPermission.
pub fn setPermission(self: *Browser, name: []const u8, state: PermissionState) !void {
    const gop = try self.permissions.getOrPut(self.allocator, name);
    if (!gop.found_existing) {
        gop.key_ptr.* = self.allocator.dupe(u8, name) catch |err| {
            _ = self.permissions.remove(name);
            return err;
        };
    }
    gop.value_ptr.* = state;
}

// Clear all stored permissions, freeing the keys. Used by CDP
// Browser.resetPermissions and on teardown.
pub fn clearPermissions(self: *Browser) void {
    var it = self.permissions.keyIterator();
    while (it.next()) |key| {
        self.allocator.free(key.*);
    }
    self.permissions.clearRetainingCapacity();
}

pub const Display = struct {
    screen_width: u32,
    screen_height: u32,
    avail_width: u32,
    avail_height: u32,
    screen_x: i32,
    screen_y: i32,
    outer_width: u32,
    outer_height: u32,
    inner_width: u32,
    inner_height: u32,
    device_pixel_ratio: f64,
    color_depth: u8,
    pixel_depth: u8,
};

pub fn resolvedFingerprint(self: *const Browser) ?*const FingerprintProfile.ResolvedFingerprintProfile {
    return self.fingerprint_profile;
}

/// One display view shared by Window, Screen, VisualViewport and layout.
/// Runtime emulation overrides only the layout viewport; it does not mutate
/// the immutable catalog profile.
pub fn getDisplay(self: *const Browser) Display {
    if (self.fingerprint_profile) |profile| {
        const display = profile.display;
        return .{
            .screen_width = display.screen_width,
            .screen_height = display.screen_height,
            .avail_width = display.avail_width,
            .avail_height = display.avail_height,
            .screen_x = display.screen_x,
            .screen_y = display.screen_y,
            .outer_width = display.outer_width,
            .outer_height = display.outer_height,
            .inner_width = display.inner_width,
            .inner_height = display.inner_height,
            .device_pixel_ratio = display.device_pixel_ratio,
            .color_depth = display.color_depth,
            .pixel_depth = display.pixel_depth,
        };
    }

    return .{
        .screen_width = Viewport.default.width,
        .screen_height = Viewport.default.height,
        .avail_width = Viewport.default.width,
        .avail_height = 1040,
        .screen_x = 0,
        .screen_y = 0,
        .outer_width = Viewport.default.width,
        .outer_height = Viewport.default.height,
        .inner_width = Viewport.default.width,
        .inner_height = Viewport.default.height,
        .device_pixel_ratio = 1,
        .color_depth = 24,
        .pixel_depth = 24,
    };
}

// The viewport every consumer should read: the runtime override if set,
// otherwise the resolved fingerprint's inner viewport.
pub fn getViewport(self: *const Browser) Viewport {
    if (self.viewport_override) |viewport| return viewport;
    const display = self.getDisplay();
    return .{ .width = display.inner_width, .height = display.inner_height };
}

pub fn newSession(self: *Browser, notification: *Notification) !*Session {
    self.closeSession();
    self.session = @as(Session, undefined);
    errdefer self.session = null;
    const session = &self.session.?;
    try Session.init(session, self, notification);
    return session;
}

pub fn closeSession(self: *Browser) void {
    if (self.session) |*session| {
        session.deinit();
        self.session = null;
    }
}

pub fn runMicrotasks(self: *Browser) void {
    self.env.runMicrotasks();
}

pub fn runMacrotasks(self: *Browser) !void {
    const env = &self.env;

    _ = try self.owner_mailbox.drain();

    if (self.session) |*session| {
        for (session.pages.items) |page| try page.frame.drainWorkerMessages();
    }

    try self.env.runMacrotasks();
    env.pumpMessageLoop();

    // either of the above could have queued more microtasks
    env.runMicrotasks();
}

pub fn hasBackgroundTasks(self: *Browser) bool {
    return self.owner_mailbox.hasPending() or self.env.hasBackgroundTasks();
}

pub fn waitForBackgroundTasks(self: *Browser) void {
    self.env.waitForBackgroundTasks();
}

pub fn msToNextMacrotask(self: *Browser) ?u64 {
    if (self.owner_mailbox.hasPending()) {
        return 0;
    }
    if (self.session) |*session| {
        for (session.pages.items) |page| {
            if (page.frame.hasWorkerActivity()) {
                return 0;
            }
        }
    }
    return self.env.msToNextMacrotask();
}

fn wakeOwnerMailbox(raw: *anyopaque) void {
    const self: *Browser = @ptrCast(@alignCast(raw));
    self.http_client.handles.wakeup() catch {};
}

pub fn msTo(self: *Browser) bool {
    return self.env.hasBackgroundTasks();
}

pub fn runIdleTasks(self: *const Browser) void {
    self.env.runIdleTasks();
}
