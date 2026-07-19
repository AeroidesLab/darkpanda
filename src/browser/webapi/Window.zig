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
const builtin = @import("builtin");
const SysURL = @import("../../sys/url.zig");

const js = @import("../js/js.zig");
const TaggedOpaque = @import("../js/TaggedOpaque.zig");
const URL = @import("../URL.zig");
const Frame = @import("../Frame.zig");
const EventManager = @import("../EventManager.zig");
const SandboxFlags = @import("../SandboxFlags.zig");
const Console = @import("Console.zig");
const History = @import("History.zig");
const Navigation = @import("navigation/Navigation.zig");
const Crypto = @import("Crypto.zig");
const TrustedTypes = @import("TrustedTypes.zig");
const CSS = @import("CSS.zig");
const Navigator = @import("Navigator.zig");
const ModelContext = @import("ModelContext.zig");
const Screen = @import("Screen.zig");
const VisualViewport = @import("VisualViewport.zig");
const Performance = @import("Performance.zig");
const Document = @import("Document.zig");
const Location = @import("Location.zig");
const Fetch = @import("net/Fetch.zig");
const Event = @import("Event.zig");
const EventTarget = @import("EventTarget.zig");
const ErrorEvent = @import("event/ErrorEvent.zig");
const MessageEvent = @import("event/MessageEvent.zig");
const StorageEvent = @import("event/StorageEvent.zig");
const MessagePort = @import("MessagePort.zig");
const MediaQueryList = @import("css/MediaQueryList.zig");
const storage = @import("storage/storage.zig");
const idb = @import("storage/idb/idb.zig");
const CookieStore = @import("storage/CookieStore.zig");
const Element = @import("Element.zig");
const CSSStyleProperties = @import("css/CSSStyleProperties.zig");
const CustomElementRegistry = @import("CustomElementRegistry.zig");
const Selection = @import("Selection.zig");
const Timers = @import("Timers.zig");
const Notification = @import("../../Notification.zig");
const DOMException = @import("DOMException.zig");
const InputDeviceCapabilities = @import("InputDeviceCapabilities.zig");
const UserActivation = @import("UserActivation.zig");

const log = lp.log;
const IS_DEBUG = builtin.mode == .Debug;

const Allocator = std.mem.Allocator;
const Execution = js.Execution;

pub fn registerTypes() []const type {
    return &.{ Window, CrossOriginWindow, CrossOriginLocation };
}

const Window = @This();

_proto: *EventTarget,
_frame: *Frame,
_document: *Document,
_css: CSS = .init,
_crypto: Crypto = .init,
_trusted_types: TrustedTypes.TrustedTypePolicyFactory = .init,
_console: Console = .init,
_navigator: Navigator = .init,
_model_context: ModelContext = .init,
_screen: *Screen,
_visual_viewport: *VisualViewport,
_performance: Performance,
_input_capabilities_touch: ?*InputDeviceCapabilities = null,
_input_capabilities_no_touch: ?*InputDeviceCapabilities = null,
_local_storage: ?*storage.Lookup = null,
_session_storage: ?*storage.Lookup = null,
_cookie_store: ?*CookieStore = null,
_idb_factory: ?*idb.IDBFactory = null,
_on_load: ?js.Function.Global = null,
_on_pageshow: ?js.Function.Global = null,
_on_pagehide: ?js.Function.Global = null,
_on_unload: ?js.Function.Global = null,
_on_popstate: ?js.Function.Global = null,
_on_hashchange: ?js.Function.Global = null,
_on_error: ?js.Function.Global = null,
_on_error_order: ?u64 = null,
_on_message: ?js.Function.Global = null,
_on_storage: ?js.Function.Global = null,
_on_rejection_handled: ?js.Function.Global = null,
_on_unhandled_rejection: ?js.Function.Global = null,
_current_event: ?*Event = null,
_location: *Location,
_timers: Timers = .{},
_custom_elements: CustomElementRegistry = .{},
_scroll_pos: struct {
    x: u32,
    y: u32,
    state: enum {
        scroll,
        end,
        done,
    },
} = .{
    .x = 0,
    .y = 0,
    .state = .done,
},
// A cross origin wrapper for this window
_cross_origin_wrapper: CrossOriginWindow,

// The Window that called window.open to create this one. Null for the root
// window, for noopener popups, and cleared if the opener is torn down while
// we're still alive. Only valid if `!_opener.?._closed`.
_opener: ?*Window = null,

// True after window.close. The Frame itself stays alive (parked in
// page.closed_frames until Page.deinit) so cached references to this Window
// don't dangle, but the popup is neutered: dropped from page.popups, its
// transfers aborted, scheduler reset, and unreachable for events / name lookup.
_closed: bool = false,

// Browsing-context name (owned by the Page frame arena). For child frames
// this starts as the iframe's name content attribute, then follows writes to
// window.name; later iframe.name mutations do not rename the existing context.
_name: []const u8 = "",
_name_initialized: bool = false,

pub fn asEventTarget(self: *Window) *EventTarget {
    return self._proto;
}

pub fn getEvent(self: *const Window) ?*Event {
    return self._current_event;
}

pub fn setEvent(self: *Window, value: js.Value) void {
    self.replaceGlobalProperty(value, "event");
}

pub fn getSelf(self: *Window) *Window {
    return self;
}

pub fn getWindow(self: *Window) *Window {
    return self;
}

pub fn getIsSecureContext(self: *const Window) bool {
    return self._frame.isSecureContext();
}

pub fn getOpener(self: *Window, frame: *Frame) ?Access {
    const opener = self._opener orelse return null;
    if (opener._closed) return null;
    return Access.init(frame.window, opener);
}

// Per the HTML spec's opener setter: null disowns the opener (the accessor
// stays in place and the getter now returns null); any other value redefines
// the property as an own data property, like [Replaceable].
pub fn setOpener(self: *Window, value: js.Value) void {
    if (value.isNull()) {
        self._opener = null;
        return;
    }
    self.replaceGlobalProperty(value, "opener");
}

pub fn getClosed(self: *const Window) bool {
    return self._closed;
}

/// V8's WindowProxy access callback protects ordinary property lookup, but an
/// extracted native getter/setter/method can be invoked with a WindowProxy as
/// its explicit receiver. Blink repeats the receiver access check in that
/// binding path before argument conversion or return-value filtering.
pub fn checkReceiverAccess(self: *const Window, frame: *Frame) !void {
    if (Frame.sameEffectiveOrigin(frame, self._frame)) return;
    _ = try throwCrossOriginSecurityError(frame, "Window", null, .generic);
    return error.TryCatchRethrow;
}

// popup.close() exposes closed=true before its dismissal events, but Blink
// keeps the LocalDOMWindow/Document usable until those synchronous callbacks
// finish. iframe removal and navigation enter the same state with closed=false.
fn hasLifecycleBrowsingContext(self: *const Window) bool {
    return !self._frame.isRetired() and (!self._closed or self._frame.isRetiring());
}

pub fn getName(self: *const Window) []const u8 {
    return self._name;
}

pub fn setName(self: *Window, name: []const u8, frame: *Frame) !void {
    // Store in the Page's frame arena so the slice outlives any call_arena.
    self._name = try frame.arena.dupe(u8, name);
    self._name_initialized = true;
}

pub fn getTop(self: *Window, frame: *Frame) ?Access {
    if (!self.hasLifecycleBrowsingContext()) return null;
    var p = self._frame;
    while (p.parent) |parent| {
        p = parent;
    }
    return Access.init(frame.window, p.window);
}

pub fn getParent(self: *Window, frame: *Frame) ?Access {
    if (!self.hasLifecycleBrowsingContext()) return null;
    const parent = if (self._frame.parent) |p| p.window else self;
    // Even a top-level Window's `parent === self` result must pass through the
    // caller-relative WindowProxy access check. Returning the raw Window here
    // lets a cross-origin opener escape through popup.parent.document.
    return Access.init(frame.window, parent);
}

pub fn getDocument(self: *Window) *Document {
    return self._document;
}

pub fn getConsole(self: *Window) *Console {
    return &self._console;
}

pub fn setConsole(self: *Window, value: js.Value) void {
    self.replaceGlobalProperty(value, "console");
}

pub fn setSelf(self: *Window, value: js.Value) void {
    self.replaceGlobalProperty(value, "self");
}

pub fn setFrames(self: *Window, value: js.Value) void {
    self.replaceGlobalProperty(value, "frames");
}

pub fn setParent(self: *Window, value: js.Value) void {
    self.replaceGlobalProperty(value, "parent");
}

pub fn setLength(self: *Window, value: js.Value) void {
    self.replaceGlobalProperty(value, "length");
}

pub fn setInnerWidth(self: *Window, value: js.Value) void {
    self.replaceGlobalProperty(value, "innerWidth");
}

pub fn setInnerHeight(self: *Window, value: js.Value) void {
    self.replaceGlobalProperty(value, "innerHeight");
}

pub fn setScreenX(self: *Window, value: js.Value) void {
    self.replaceGlobalProperty(value, "screenX");
}

pub fn setScreenY(self: *Window, value: js.Value) void {
    self.replaceGlobalProperty(value, "screenY");
}

pub fn setScreenLeft(self: *Window, value: js.Value) void {
    self.replaceGlobalProperty(value, "screenLeft");
}

pub fn setScreenTop(self: *Window, value: js.Value) void {
    self.replaceGlobalProperty(value, "screenTop");
}

pub fn setOuterWidth(self: *Window, value: js.Value) void {
    self.replaceGlobalProperty(value, "outerWidth");
}

pub fn setOuterHeight(self: *Window, value: js.Value) void {
    self.replaceGlobalProperty(value, "outerHeight");
}

pub fn setScrollX(self: *Window, value: js.Value) void {
    self.replaceGlobalProperty(value, "scrollX");
}

pub fn setScrollY(self: *Window, value: js.Value) void {
    self.replaceGlobalProperty(value, "scrollY");
}

pub fn setPageXOffset(self: *Window, value: js.Value) void {
    self.replaceGlobalProperty(value, "pageXOffset");
}

pub fn setPageYOffset(self: *Window, value: js.Value) void {
    self.replaceGlobalProperty(value, "pageYOffset");
}

pub fn getNavigator(self: *Window) *Navigator {
    return &self._navigator;
}

pub fn getModelContext(self: *Window) *ModelContext {
    return &self._model_context;
}

pub fn getScreen(self: *Window) *Screen {
    return self._screen;
}

pub fn setScreen(self: *Window, value: js.Value) void {
    self.replaceGlobalProperty(value, "screen");
}

pub fn getVisualViewport(self: *const Window) *VisualViewport {
    return self._visual_viewport;
}

pub fn setVisualViewport(self: *Window, value: js.Value) void {
    self.replaceGlobalProperty(value, "visualViewport");
}

pub fn getCrypto(self: *Window) *Crypto {
    return &self._crypto;
}

pub fn getTrustedTypes(self: *Window) *TrustedTypes.TrustedTypePolicyFactory {
    return &self._trusted_types;
}

pub fn getCSS(self: *Window) *CSS {
    return &self._css;
}

pub fn getPerformance(self: *Window) *Performance {
    return &self._performance;
}

pub fn setPerformance(self: *Window, value: js.Value) void {
    self.replaceGlobalProperty(value, "performance");
}

/// Blink keeps two realm-local constants for trusted input: devices that do
/// and do not synthesize touch events. Reusing them is observable through
/// strict equality across events in the same Window.
pub fn inputDeviceCapabilities(self: *Window, fires_touch_events: bool) !*InputDeviceCapabilities {
    const slot = if (fires_touch_events)
        &self._input_capabilities_touch
    else
        &self._input_capabilities_no_touch;
    if (slot.*) |value| return value;

    const value = try self._frame._factory.create(InputDeviceCapabilities.fromBool(fires_touch_events));
    slot.* = value;
    return value;
}

fn topLevelContextIdentity(frame: *Frame) usize {
    var top = frame;
    while (top.parent) |parent| top = parent;
    return @intFromPtr(top._navigation_context);
}

fn storageOriginKey(frame: *const Frame) []const u8 {
    return frame.document._storage_origin_key;
}

fn areaForKind(self: *Window, kind: storage.Kind) *storage.Area {
    const frame = self._frame;
    const session = frame._session;
    const allocator = session.browser.app.allocator;
    return switch (kind) {
        .local => session.storage_shed.getLocal(allocator, storageOriginKey(frame)),
        .session => session.storage_shed.getSession(
            allocator,
            topLevelContextIdentity(frame),
            storageOriginKey(frame),
        ),
    } catch @panic("OOM");
}

fn materializeStorageInOwnerRealm(self: *Window, value: *storage.Lookup) !void {
    var ls: js.Local.Scope = undefined;
    self._frame.js.localScope(&ls);
    defer ls.deinit();
    _ = try ls.local.mapZigInstanceToJs(null, value);
}

fn storageForArea(
    self: *Window,
    cached: *?*storage.Lookup,
    area: *storage.Area,
    kind: storage.Kind,
) !?*storage.Lookup {
    if (!self.hasLifecycleBrowsingContext()) return null;
    if (cached.*) |value| return value;

    const value = try self._frame._factory.create(storage.Lookup.init(area, self._frame, kind));
    try self.materializeStorageInOwnerRealm(value);
    cached.* = value;
    return value;
}

fn denySandboxedStorage(self: *Window, property: []const u8, exec: *Execution) !void {
    if (exec.origin() != null) return;
    if (!SandboxFlags.contains(self._frame.activeSandboxFlags(), SandboxFlags.origin)) {
        return error.SecurityError;
    }

    const local = exec.js.local orelse return error.SecurityError;
    const message = try std.fmt.allocPrint(
        exec.call_arena,
        "Failed to read the '{s}' property from 'Window': The document is sandboxed and lacks the 'allow-same-origin' flag.",
        .{property},
    );
    const exception = try local.zigValueToJs(DOMException.init(message, "SecurityError"), .{});
    _ = js.v8.v8__Exception__CaptureStackTrace(local.handle, @ptrCast(exception.handle));
    _ = local.isolate.throwException(exception.handle);
    return error.TryCatchRethrow;
}

pub fn getLocalStorage(self: *Window, exec: *Execution) !?*storage.Lookup {
    try self.denySandboxedStorage("localStorage", exec);
    if (!self.hasLifecycleBrowsingContext()) return null;
    return self.storageForArea(&self._local_storage, self.areaForKind(.local), .local);
}

pub fn getSessionStorage(self: *Window, exec: *Execution) !?*storage.Lookup {
    try self.denySandboxedStorage("sessionStorage", exec);
    if (!self.hasLifecycleBrowsingContext()) return null;
    return self.storageForArea(&self._session_storage, self.areaForKind(.session), .session);
}

/// Materialize the destination Window's realm-local Storage wrapper for a
/// trusted StorageEvent. The shared Area is checked again when the task runs so
/// a target which navigated before delivery cannot receive a stale event.
pub fn storageWrapperForEvent(
    self: *Window,
    kind: storage.Kind,
    expected_area: *storage.Area,
) !?*storage.Lookup {
    if (self._closed or self._frame.isRetired()) return null;
    const area = self.areaForKind(kind);
    if (area != expected_area) return null;
    return switch (kind) {
        .local => self.storageForArea(&self._local_storage, area, kind),
        .session => self.storageForArea(&self._session_storage, area, kind),
    };
}

/// Broadcast one successful Storage mutation. All event data, including the
/// source Document URL, is snapshotted before returning to script. Delivery is
/// a zero-delay normal Scheduler task, the project's DOM-manipulation task
/// source, and never runs in the source Window.
pub fn broadcastStorageMutation(
    self: *Window,
    source: *storage.Lookup,
    key: ?[]const u8,
    old_value: ?[]const u8,
    new_value: ?[]const u8,
) !void {
    const source_frame = self._frame;
    const source_url = self._document.getURL(source_frame);
    for (source_frame._session.pages.items) |page| {
        // A pending replacement is not yet an active Window. The old Page has
        // `replacement != null` but remains live until commit and is included.
        if (page.replaces != null) continue;
        try queueStorageEventInSubtree(
            source_frame,
            &page.frame,
            source,
            key,
            old_value,
            new_value,
            source_url,
        );
        for (page.popups.items) |popup| {
            try queueStorageEventInSubtree(
                source_frame,
                popup,
                source,
                key,
                old_value,
                new_value,
                source_url,
            );
        }
    }
}

fn queueStorageEventInSubtree(
    source_frame: *Frame,
    target: *Frame,
    source: *storage.Lookup,
    key: ?[]const u8,
    old_value: ?[]const u8,
    new_value: ?[]const u8,
    source_url: []const u8,
) !void {
    if (target.window._closed or target.isRetired()) return;

    if (target != source_frame) {
        const shed = &target._session.storage_shed;
        const target_area = switch (source._kind) {
            .local => shed.peekLocal(storageOriginKey(target)),
            .session => shed.peekSession(
                topLevelContextIdentity(target),
                storageOriginKey(target),
            ),
        };
        if (target_area != null and target_area.? == source._area) {
            try StorageEventTask.queue(
                target,
                source._kind,
                source._area,
                key,
                old_value,
                new_value,
                source_url,
            );
        }
    }

    for (target.child_frames.items) |child| {
        try queueStorageEventInSubtree(
            source_frame,
            child,
            source,
            key,
            old_value,
            new_value,
            source_url,
        );
    }
}

const StorageEventTask = struct {
    frame: *Frame,
    kind: storage.Kind,
    area: *storage.Area,
    key: ?[]const u8,
    old_value: ?[]const u8,
    new_value: ?[]const u8,
    source_url: []const u8,

    fn queue(
        frame: *Frame,
        kind: storage.Kind,
        area: *storage.Area,
        key: ?[]const u8,
        old_value: ?[]const u8,
        new_value: ?[]const u8,
        source_url: []const u8,
    ) !void {
        const task = try frame.arena.create(StorageEventTask);
        task.* = .{
            .frame = frame,
            .kind = kind,
            .area = area,
            .key = try dupeOptional(frame.arena, key),
            .old_value = try dupeOptional(frame.arena, old_value),
            .new_value = try dupeOptional(frame.arena, new_value),
            .source_url = try frame.arena.dupe(u8, source_url),
        };
        try frame.js.scheduler.add(task, StorageEventTask.run, 0, .{
            .name = "DOM manipulation: storage event",
        });
    }

    fn dupeOptional(allocator: Allocator, value: ?[]const u8) !?[]const u8 {
        const string = value orelse return null;
        return if (string.len == 0) "" else try allocator.dupe(u8, string);
    }

    fn run(ctx: *anyopaque) anyerror!?u32 {
        const self: *StorageEventTask = @ptrCast(@alignCast(ctx));
        const frame = self.frame;
        if (frame.window._closed or frame.isRetired()) return null;

        const storage_area = try frame.window.storageWrapperForEvent(self.kind, self.area) orelse
            return null;
        const event = try StorageEvent.initTrusted(comptime .wrap("storage"), .{
            .key = self.key,
            .oldValue = self.old_value,
            .newValue = self.new_value,
            .url = self.source_url,
            .storageArea = storage_area,
        }, frame);
        try frame._event_manager.dispatchDirect(
            frame.window.asEventTarget(),
            event.asEvent(),
            frame.window._on_storage,
            .{ .context = "Window storage event" },
        );
        return null;
    }
};

pub fn getCookieStore(self: *Window, exec: *Execution) !?*CookieStore {
    if (self._cookie_store) |cs| return cs;
    if (!self.hasLifecycleBrowsingContext()) return null;
    const cs = try exec._factory.eventTarget(CookieStore{ ._proto = undefined });
    try cs.attach(exec);
    self._cookie_store = cs;
    return cs;
}

pub fn getIndexedDB(self: *Window, exec: *Execution) !?*idb.IDBFactory {
    if (self._idb_factory) |f| {
        return f;
    }
    if (!self.hasLifecycleBrowsingContext()) return null;
    // Storage identity belongs to the receiver Window's committed Document,
    // not to the incumbent/caller realm injected by the binding bridge.
    // Keep the Execution pointer for realm and lifecycle ownership, while
    // snapshotting the Document's immutable storage origin exactly once.
    const storage_origin_key: ?[]const u8 = switch (self._frame.requestOrigin()) {
        .tuple => self._document._storage_origin_key,
        else => null,
    };
    const f = try exec._factory.create(try idb.IDBFactory.init(exec, storage_origin_key));
    self._idb_factory = f;
    return f;
}

pub fn getOrigin(self: *const Window) []const u8 {
    // Window.origin serializes the active SecurityOrigin. Location.origin is
    // URL-derived and intentionally differs for a sandboxed document whose
    // URL remains HTTP(S) while its SecurityOrigin is opaque.
    return switch (self._frame.requestOrigin()) {
        .tuple => |tuple| tuple,
        .legacy_derive_from_initiator_url, .none, .@"opaque" => "null",
    };
}

pub fn setOrigin(self: *Window, value: js.Value) void {
    self.replaceGlobalProperty(value, "origin");
}

pub fn getSelection(self: *const Window) *Selection {
    return &self._document._selection;
}

pub fn getFrameElement(self: *const Window, frame: *Frame) ?*Element.Html.IFrame {
    if (!self.hasLifecycleBrowsingContext() or self._document._frame == null) return null;
    const iframe = self._frame.iframe orelse return null;
    const owner_frame = iframe.asNode().ownerFrame(self._frame.parent orelse frame);
    // Window.frameElement is also [CheckSecurity=ReturnValue]: Blink checks
    // whether the current caller can access the returned owner Element. A
    // cross-origin child therefore sees null instead of receiving an object
    // that could escape through ownerDocument.defaultView.
    if (!Frame.sameEffectiveOrigin(frame, owner_frame)) return null;
    return iframe;
}

pub fn getLocation(self: *const Window) *Location {
    return self._location;
}

pub fn setLocation(self: *Window, url: [:0]const u8, frame: *Frame) !void {
    // The Web IDL conversion of `url` has already happened, but a discarded
    // browsing context no longer has a navigable to target.
    if (self._closed or self._frame.isRetired()) return;
    return frame.scheduleNavigation(url, .{ .reason = .script, .kind = .{ .push = null } }, .{ .script = self._frame });
}

pub fn getHistory(self: *Window) *History {
    return self._frame.history();
}

pub fn getNavigation(self: *Window) *Navigation {
    return self._frame.navigation();
}

pub fn setNavigation(self: *Window, value: js.Value) void {
    self.replaceGlobalProperty(value, "navigation");
}

pub fn getCustomElements(self: *Window) *CustomElementRegistry {
    return &self._custom_elements;
}

pub fn getOnLoad(self: *const Window) ?js.Function.Global {
    return self._on_load;
}

pub fn setOnLoad(self: *Window, setter: ?FunctionSetter) void {
    self._on_load = getFunctionFromSetter(setter);
}

pub fn getOnPageShow(self: *const Window) ?js.Function.Global {
    return self._on_pageshow;
}

pub fn setOnPageShow(self: *Window, setter: ?FunctionSetter) void {
    self._on_pageshow = getFunctionFromSetter(setter);
}

pub fn getOnPageHide(self: *const Window) ?js.Function.Global {
    return self._on_pagehide;
}

pub fn setOnPageHide(self: *Window, setter: ?FunctionSetter) void {
    self._on_pagehide = getFunctionFromSetter(setter);
}

pub fn getOnUnload(self: *const Window) ?js.Function.Global {
    return self._on_unload;
}

pub fn setOnUnload(self: *Window, setter: ?FunctionSetter) void {
    self._on_unload = getFunctionFromSetter(setter);
}

pub fn getOnPopState(self: *const Window) ?js.Function.Global {
    return self._on_popstate;
}

pub fn setOnPopState(self: *Window, setter: ?FunctionSetter) void {
    self._on_popstate = getFunctionFromSetter(setter);
}

pub fn getOnHashChange(self: *const Window) ?js.Function.Global {
    return self._on_hashchange;
}

pub fn setOnHashChange(self: *Window, setter: ?FunctionSetter) void {
    self._on_hashchange = getFunctionFromSetter(setter);
}

pub fn getOnError(self: *const Window) ?js.Function.Global {
    return self._on_error;
}

pub fn setOnError(self: *Window, setter: ?FunctionSetter) void {
    const function = getFunctionFromSetter(setter);
    if (function == null) {
        self._on_error = null;
        self._on_error_order = null;
        return;
    }

    // Replacing a live event-handler value updates its callback without
    // moving the handler in the event listener list. Clearing it and later
    // assigning again creates a fresh registration at the end.
    if (self._on_error_order == null) {
        self._on_error_order = self._frame._event_manager.base.reserveRegistrationOrder();
    }
    self._on_error = function;
}

pub fn getOnMessage(self: *const Window) ?js.Function.Global {
    return self._on_message;
}

pub fn setOnMessage(self: *Window, setter: ?FunctionSetter) void {
    self._on_message = getFunctionFromSetter(setter);
}

pub fn getOnStorage(self: *const Window) ?js.Function.Global {
    return self._on_storage;
}

pub fn setOnStorage(self: *Window, setter: ?FunctionSetter) void {
    self._on_storage = getFunctionFromSetter(setter);
}

pub fn getOnRejectionHandled(self: *const Window) ?js.Function.Global {
    return self._on_rejection_handled;
}

pub fn setOnRejectionHandled(self: *Window, setter: ?FunctionSetter) void {
    self._on_rejection_handled = getFunctionFromSetter(setter);
}

pub fn getOnUnhandledRejection(self: *const Window) ?js.Function.Global {
    return self._on_unhandled_rejection;
}

pub fn setOnUnhandledRejection(self: *Window, setter: ?FunctionSetter) void {
    self._on_unhandled_rejection = getFunctionFromSetter(setter);
}

pub fn fetch(_: *const Window, input: Fetch.Input, options: ?Fetch.InitOpts, exec: *const js.Execution) !js.Promise {
    return Fetch.init(input, options, exec);
}

pub fn setTimeout(self: *Window, raw_handler: ?js.Value, raw_delay: ?js.Value, params: []js.Value.Global, exec: *js.Execution) !u32 {
    var params_owned = true;
    errdefer if (params_owned) for (params) |param| param.release();
    const operation: js.WebIDL.Operation = .{ .interface = "Window", .name = "setTimeout" };
    var handler = try Timers.convertHandler(raw_handler, exec, operation);
    var handler_owned = true;
    errdefer if (handler_owned) handler.release();
    const delay_ms = try Timers.convertDelay(raw_delay, exec, operation);
    try handler.applyTrustedTypes(
        self._frame.js,
        self.getTrustedTypes(),
        exec,
        operation,
    );
    const schedule_params: []js.Value.Global = switch (handler) {
        .function => params,
        .string => blk: {
            for (params) |param| param.release();
            params_owned = false;
            if (!try handler.shouldSchedule(self._frame.js)) {
                handler_owned = false;
                return 0;
            }
            break :blk &.{};
        },
    };
    const cb = try handler.resolve(exec);
    handler_owned = false;
    var cb_owned = true;
    errdefer if (cb_owned) cb.release();
    // From here schedule owns cb and params, including on its error paths.
    cb_owned = false;
    params_owned = false;
    return self._timers.schedule(exec, cb, delay_ms, .{
        .repeat = false,
        .params = schedule_params,
        .name = "window.setTimeout",
    });
}

pub fn setInterval(self: *Window, raw_handler: ?js.Value, raw_delay: ?js.Value, params: []js.Value.Global, exec: *js.Execution) !u32 {
    var params_owned = true;
    errdefer if (params_owned) for (params) |param| param.release();
    const operation: js.WebIDL.Operation = .{ .interface = "Window", .name = "setInterval" };
    var handler = try Timers.convertHandler(raw_handler, exec, operation);
    var handler_owned = true;
    errdefer if (handler_owned) handler.release();
    const delay_ms = try Timers.convertDelay(raw_delay, exec, operation);
    try handler.applyTrustedTypes(
        self._frame.js,
        self.getTrustedTypes(),
        exec,
        operation,
    );
    const schedule_params: []js.Value.Global = switch (handler) {
        .function => params,
        .string => blk: {
            for (params) |param| param.release();
            params_owned = false;
            if (!try handler.shouldSchedule(self._frame.js)) {
                handler_owned = false;
                return 0;
            }
            break :blk &.{};
        },
    };
    const cb = try handler.resolve(exec);
    handler_owned = false;
    var cb_owned = true;
    errdefer if (cb_owned) cb.release();
    cb_owned = false;
    params_owned = false;
    return self._timers.schedule(exec, cb, delay_ms, .{
        .repeat = true,
        .params = schedule_params,
        .name = "window.setInterval",
    });
}

pub fn requestAnimationFrame(self: *Window, cb: js.Function.Global, exec: *js.Execution) !u32 {
    return self._timers.schedule(exec, cb, 5, .{
        .repeat = false,
        .params = &.{},
        .mode = .animation_frame,
        .name = "window.requestAnimationFrame",
    });
}

pub fn queueMicrotask(_: *Window, cb: js.Function, frame: *Frame) void {
    frame.js.queueMicrotaskFunc(cb);
}

pub fn clearTimeout(self: *Window, id: u32) void {
    self._timers.clear(id);
}

pub fn clearInterval(self: *Window, id: u32) void {
    self._timers.clear(id);
}

pub fn cancelAnimationFrame(self: *Window, id: u32) void {
    self._timers.clear(id);
}

const RequestIdleCallbackOpts = struct {
    timeout: ?u32 = null,
};
pub fn requestIdleCallback(self: *Window, cb: js.Function.Global, opts_: ?RequestIdleCallbackOpts, exec: *js.Execution) !u32 {
    const opts = opts_ orelse RequestIdleCallbackOpts{};
    // timeout=0 does not mean that the idle callback timed out. Blink only
    // arms a timeout task for a strictly positive explicit timeout.
    const timeout: ?u32 = if (opts.timeout) |ms| if (ms > 0) ms else null else null;
    return self._timers.scheduleIdle(exec, cb, timeout);
}

pub fn cancelIdleCallback(self: *Window, id: u32) void {
    self._timers.clear(id);
}

pub fn reportError(self: *Window, err: js.Value, frame: *Frame) !void {
    var report: js.TryCatch.ErrorReport = .{
        .message = err.toStringSlice() catch "Unknown error",
        .filename = "",
        .exception = try err.persist(),
    };
    return self.dispatchErrorReport(&report, false, frame, "window.reportError");
}

/// Report one ordinary uncaught classic/module script exception to Window.
/// A no-CORS cross-origin classic script uses HTML's muted-errors projection;
/// otherwise the exact V8 exception is transferred into ErrorEvent.
pub fn dispatchUncaughtScriptError(
    self: *Window,
    report: *js.TryCatch.ErrorReport,
    muted_errors: bool,
    frame: *Frame,
) !void {
    return self.dispatchErrorReport(report, muted_errors, frame, "window.uncaughtScriptError");
}

fn dispatchErrorReport(
    self: *Window,
    report: *js.TryCatch.ErrorReport,
    muted_errors: bool,
    frame: *Frame,
    comptime context: []const u8,
) !void {
    defer report.releaseError();

    if (muted_errors) report.releaseError();
    const error_event = try ErrorEvent.initTrusted(comptime .wrap("error"), .{
        .@"error" = if (muted_errors) null else report.exception,
        .message = if (muted_errors) "Script error." else report.message,
        .filename = if (muted_errors) "" else report.filename,
        .lineno = if (muted_errors) 0 else report.lineno,
        .colno = if (muted_errors) 0 else report.colno,
        .bubbles = false,
        .cancelable = true,
        .composed = false,
    }, frame._page);
    // ErrorEvent now owns the tracked exception handle.
    report.exception = null;

    const event = error_event.asEvent();
    try frame._event_manager.dispatchDirect(
        self.asEventTarget(),
        event,
        EventManager.OrderedHandler{
            .function_slot = &self._on_error,
            .registration_order_slot = &self._on_error_order,
            .kind = .window_error,
        },
        .{ .context = context },
    );

    if (comptime builtin.is_test == false) {
        if (!event._prevent_default) {
            log.warn(.js, context, .{
                .message = error_event._message,
                .filename = error_event._filename,
                .line_number = error_event._line_number,
                .column_number = error_event._column_number,
            });
        }
    }
}

pub fn matchMedia(_: *const Window, query: []const u8, frame: *Frame) !*MediaQueryList {
    return frame._factory.eventTarget(MediaQueryList{
        ._proto = undefined,
        ._media = try frame.dupeString(query),
    });
}

pub fn getComputedStyle(_: *const Window, element: *Element, pseudo_element: ?js.DOMString, frame: *Frame) !*CSSStyleProperties {
    if (pseudo_element) |pe| {
        if (pe.value.len != 0) {
            log.warn(.not_implemented, "window.GetComputedStyle", .{ .pseudo_element = pe.value });
            return CSSStyleProperties.init(element, true, frame);
        }
    }
    // CSSOM marks getComputedStyle() [NewObject]: every invocation returns a
    // fresh CSSStyleDeclaration wrapper. The declaration remains a live view.
    return CSSStyleProperties.init(element, true, frame);
}

// window.open(url?, target?, features?) — v1 scope:
//   * Always creates a new popup Frame on the Page (sibling to the root).
//   * Honors `noopener` / `noreferrer` tokens in `features` (opener=null,
//     return value=null). Geometry (width, height, ...) ignored.
//   * `target` values `_self` / `_parent` / `_top` navigate the current frame.
//     Any other value is treated as a popup name; reusing a live name
//     navigates the existing popup instead of spawning a new one.
//   * `url` empty or missing opens about:blank.
pub fn open(self: *Window, url_: ?[]const u8, target_: ?[]const u8, features_: ?[]const u8, frame: *Frame) !?Access {
    if (self._closed or frame.isRetired()) return null;

    const raw_url = url_ orelse "";
    const target = target_ orelse "";
    const features = features_ orelse "";

    const no_opener = hasFeatureToken(features, "noopener") or hasFeatureToken(features, "noreferrer");

    if (raw_url.len > 0) {
        // Per spec, we should validate the url
        _ = URL.resolve(frame.call_arena, frame.base(), raw_url, .{}) catch |err| switch (err) {
            error.OutOfMemory => |e| return e,
            else => return error.SyntaxError,
        };
    }

    // _self / _parent / _top navigate the current browsing context.
    if (std.ascii.eqlIgnoreCase(target, "_self") or
        std.ascii.eqlIgnoreCase(target, "_parent") or
        std.ascii.eqlIgnoreCase(target, "_top"))
    {
        const nav_target = frame.resolveTargetFrame(target) orelse frame;
        const nav_url = if (raw_url.len == 0) "about:blank" else raw_url;
        frame.scheduleNavigation(nav_url, .{
            .reason = .script,
            .kind = .{ .push = null },
        }, .{ .script = nav_target }) catch |err| switch (err) {
            // Blink's window.open navigation path reports a blocked target by
            // returning null (and emitting its console diagnostic) rather than
            // surfacing the SecurityError thrown by direct Location writes.
            error.SecurityError => return null,
            else => return err,
        };

        if (no_opener) {
            return null;
        }

        return Access.init(frame.window, nav_target.window);
    }

    const page = frame._page;

    // Name-based reuse: if a popup with this name already exists, reuse it.
    // `_blank` is reserved and never reuses.
    const is_named = target.len > 0 and !std.ascii.eqlIgnoreCase(target, "_blank");
    if (is_named) {
        if (page.findPopupByName(target)) |existing| {
            if (raw_url.len > 0) {
                frame.scheduleNavigation(raw_url, .{
                    .reason = .script,
                    .kind = .{ .push = null },
                }, .{ .script = existing }) catch |err| switch (err) {
                    error.SecurityError => return null,
                    else => return err,
                };
            }
            if (no_opener) {
                return null;
            }
            return Access.init(frame.window, existing.window);
        }
    }

    // Creating a new auxiliary browsing context is independently sandboxed.
    // `allow-popups-to-escape-sandbox` controls propagation only; without
    // `allow-popups`, creation is still denied and window.open returns null.
    if (SandboxFlags.contains(frame.activeSandboxFlags(), SandboxFlags.popups)) {
        return null;
    }

    // Spawn a new popup Frame as a sibling of the root.
    const popup = try frame.openPopup(.{
        .url = raw_url,
        .name = target,
        .opener = if (no_opener) null else self,
    });

    if (no_opener) {
        return null;
    }
    return Access.init(frame.window, popup.window);
}

pub fn close(self: *Window) void {
    if (self._closed) {
        return;
    }

    // Per spec, close() is only honored on script-opened windows. That
    // maps exactly to membership in page.popups.
    const frame = self._frame;
    const page = frame._page;

    var popup_index: usize = 0;
    while (popup_index < page.popups.items.len) : (popup_index += 1) {
        if (page.popups.items[popup_index] == frame) {
            break;
        }
    } else return;

    self._closed = true;

    // Any live Window holding us as its opener must drop the reference —
    // our Frame is about to go away, and a stale _frame deref on their
    // side would crash.
    for (page.popups.items) |popup| {
        if (popup.window._opener == self) {
            popup.window._opener = null;
        }
    }
    if (page.frame.window._opener == self) {
        page.frame.window._opener = null;
    }

    _ = page.popups.swapRemove(popup_index);

    // Drop any pending queued navigation for this frame.
    if (frame._queued_navigation != null) {
        for (page.queued_navigation.items, 0..) |f, i| {
            if (f == frame) {
                _ = page.queued_navigation.swapRemove(i);
                break;
            }
        }
    }

    // `closed_frames` is the sole Page owner after removal from `popups`.
    // Calling Page.retireFrameForDiscard here would also add this Frame to
    // `retired_frames` and make Page.deinit release it twice.
    page.closed_frames.append(page.frame_arena, frame) catch @panic("OOM");
    frame.retireForDiscard();
    frame._session.storage_shed.removeSessionNamespace(
        frame._session.browser.app.allocator,
        @intFromPtr(frame._navigation_context),
    );
}

// Window focus/blur are exposed even in a headless browsing context.  There
// is no native window manager to notify, but the operations themselves remain
// callable and are part of HTML's cross-origin WindowProxy whitelist.
pub fn blur(_: *Window) void {}

pub fn focus(_: *Window) void {}

const PostMessageArguments = struct {
    target_origin: []const u8,
    transfer: []const js.Value,
    include_user_activation: bool,

    fn convert(second: ?js.Value, third: ?js.Value, local: *const js.Local) !PostMessageArguments {
        // The three-argument form always selects the legacy overload, even if
        // argument 2 is an object that would select WindowPostMessageOptions in
        // the two-argument form.
        if (third) |transfer| {
            const target = second orelse js.Value{
                .local = local,
                .handle = local.isolate.initUndefined(),
            };
            // Web IDL converts arguments from left to right.
            const target_origin = try toTargetOrigin(target);
            return .{
                .target_origin = target_origin,
                .transfer = try toTransferSequence(transfer, local),
                .include_user_activation = false,
            };
        }

        const value = second orelse return .{
            .target_origin = "/",
            .transfer = &.{},
            .include_user_activation = false,
        };
        // For overload resolution, null/undefined and every object (including
        // functions, arrays, and boxed strings) select the dictionary overload.
        if (value.isNullOrUndefined() or value.isObject()) {
            return fromOptions(value, local);
        }

        // Primitive values select the legacy USVString overload. In particular,
        // Symbol conversion throws before structured serialization.
        return .{
            .target_origin = try toTargetOrigin(value),
            .transfer = &.{},
            .include_user_activation = false,
        };
    }

    fn fromOptions(value: js.Value, local: *const js.Local) !PostMessageArguments {
        if (value.isNullOrUndefined()) {
            return .{
                .target_origin = "/",
                .transfer = &.{},
                .include_user_activation = false,
            };
        }

        const options = value.toObject();
        // Blink walks inherited dictionaries from their base. Chrome 149
        // therefore observes StructuredSerializeOptions.transfer first,
        // PostMessageOptions.includeUserActivation second, and the derived
        // WindowPostMessageOptions targetOrigin member last.
        const raw_transfer = options.get("transfer") catch return error.TryCatchRethrow;
        const transfer = try toTransferSequence(raw_transfer, local);
        const raw_include_user_activation = options.get("includeUserActivation") catch
            return error.TryCatchRethrow;
        const include_user_activation = if (raw_include_user_activation.isUndefined())
            false
        else
            raw_include_user_activation.toBool();
        const raw_target = options.get("targetOrigin") catch return error.TryCatchRethrow;
        const target_origin = if (raw_target.isUndefined()) "/" else try toTargetOrigin(raw_target);
        return .{
            .target_origin = target_origin,
            .transfer = transfer,
            .include_user_activation = include_user_activation,
        };
    }

    fn toTargetOrigin(value: js.Value) ![]const u8 {
        if (value.isSymbol()) return error.TypeError;
        const str = value.toString() catch return error.TryCatchRethrow;
        // String.toSlice writes UTF-8 with invalid UTF-16 replaced, giving the
        // USVString scalar-value conversion required by the IDL.
        return str.toSlice();
    }

    fn toTransferSequence(value: js.Value, local: *const js.Local) ![]const js.Value {
        if (value.isUndefined()) return &.{};
        if (!value.isObject()) return error.TypeError;

        const iterable = value.toObject();
        const iterator_symbol = js.v8.v8__Symbol__GetIterator(local.isolate.handle);
        const method_handle = js.v8.v8__Object__Get(
            iterable.handle,
            local.handle,
            @ptrCast(iterator_symbol),
        ) orelse return error.TryCatchRethrow;
        const method = js.Value{ .local = local, .handle = method_handle };
        if (!method.isFunction()) return error.TypeError;

        const iterator_fn = js.Function{ .local = local, .handle = @ptrCast(method.handle) };
        const bound_iterator_fn = try iterator_fn.withThis(iterable);
        const iterator_value = try bound_iterator_fn.callRethrow(js.Value, .{});
        if (!iterator_value.isObject()) return error.TypeError;
        const iterator = iterator_value.toObject();

        const next_value = iterator.get("next") catch return error.TryCatchRethrow;
        if (!next_value.isFunction()) return error.TypeError;
        const next = js.Function{ .local = local, .handle = @ptrCast(next_value.handle) };
        const bound_next = try next.withThis(iterator);

        var items: std.ArrayListUnmanaged(js.Value) = .{};
        while (true) {
            const result_value = try bound_next.callRethrow(js.Value, .{});
            if (!result_value.isObject()) return error.TypeError;
            const result = result_value.toObject();
            const done = result.get("done") catch return error.TryCatchRethrow;
            if (done.toBool()) break;
            const item = result.get("value") catch return error.TryCatchRethrow;
            // sequence<object> performs this conversion before entering the
            // postMessage algorithm.
            if (!item.isObject()) return error.TypeError;
            try items.append(local.call_arena, item);
        }
        return items.items;
    }
};

fn validatePostMessageTransferList(values: []const js.Value, arena: Allocator) ![]const *MessagePort {
    if (values.len == 0) return &.{};
    const ports = try arena.alloc(*MessagePort, values.len);
    var count: usize = 0;
    for (values) |value| {
        // The serializer currently has no transfer delegate. Only the existing
        // MessagePort event.ports plumbing is supported; ArrayBuffer detachment,
        // port neutering, and other transferable types remain an explicit gate.
        const port = value.toZig(*MessagePort) catch return error.DataClone;
        for (ports[0..count]) |seen| {
            if (seen == port) return error.DataClone;
        }
        ports[count] = port;
        count += 1;
    }
    return ports[0..count];
}

pub fn postMessage(self: *Window, message: js.Value, second: ?js.Value, third: ?js.Value, frame: *Frame) !void {
    // `frame` is an injected WebIDL execution parameter. The incumbent
    // SecurityOrigin below is intentionally taken from the target Context,
    // matching Blink's DOMWindow::DoPostMessage path.
    _ = frame;
    const args = try PostMessageArguments.convert(second, third, message.local);
    const target_frame = self._frame;
    const source_window = target_frame.js.getIncumbent().window;

    const arena = try target_frame.getArena(.medium, "Window.postMessage");
    errdefer target_frame.releaseArena(arena);

    // StructuredSerializeWithTransfer validates the transfer list before it
    // serializes the message or parses targetOrigin.
    const ports = try validatePostMessageTransferList(args.transfer, arena);

    // StructuredSerialize runs synchronously (per spec): clone the message into
    // the target window's realm now. The receiver gets a fresh, independent copy
    // minted in its own realm (not the source realm's object), an unserializable
    // value throws a DataCloneError to the caller, and the source-realm temp
    // doesn't leak into the destination context. Mirrors Worker.postMessage.
    const cloned = blk: {
        var ls: js.Local.Scope = undefined;
        target_frame.js.localScope(&ls);
        defer ls.deinit();

        // Contain any V8 exception from a failed serialization so it surfaces as
        // a clean DataCloneError; deinit() (no rethrow) clears it.
        var try_catch: js.TryCatch = undefined;
        try_catch.init(&ls.local);
        defer try_catch.deinit();

        const c = message.structuredCloneTo(&ls.local) catch {
            return error.DataClone;
        };
        break :blk try c.persist();
    };
    errdefer cloned.release();

    // Blink serializes first, then DOMWindow::DoPostMessage checks whether the
    // target is still displayed in a Frame. A discarded target silently drops
    // the message before parsing targetOrigin or disentangling ports.
    if (target_frame.isRetired()) {
        cloned.release();
        target_frame.releaseArena(arena);
        return;
    }

    // Blink serializes the message before parsing targetOrigin. This ordering is
    // observable when both operations would fail: an unserializable value with
    // an invalid targetOrigin must throw DataCloneError, not SyntaxError. The
    // origin comparison itself still happens when the queued task runs because
    // the target may navigate between postMessage() and delivery.
    const intended_target_origin = try IntendedTargetOrigin.parse(args.target_origin, source_window, arena);

    // MessageEvent.origin serializes the source Window's committed
    // SecurityOrigin, not the URL exposed by Location.origin.  Those differ
    // for an iframe sandboxed without allow-same-origin: its HTTP Location
    // keeps the URL tuple while its SecurityOrigin is opaque and therefore
    // serializes as "null".
    const origin = switch (source_window._frame.requestOrigin()) {
        .tuple => |tuple| tuple,
        .legacy_derive_from_initiator_url, .none, .@"opaque" => "null",
    };
    const callback = try arena.create(PostMessageCallback);
    callback.* = .{
        .arena = arena,
        .message = cloned,
        .frame = target_frame,
        .source = source_window,
        .origin = try arena.dupe(u8, origin),
        .target_origin = intended_target_origin,
        .ports = ports,
        .user_activation = if (args.include_user_activation) .{
            .has_been_active = source_window._frame.hasStickyUserActivation(),
            .is_active = source_window._frame.hasTransientUserActivation(),
        } else null,
    };

    try target_frame.js.scheduler.add(callback, PostMessageCallback.run, 0, .{
        .name = "postMessage",
        .low_priority = false,
        .finalizer = PostMessageCallback.cancelled,
    });
}

const IntendedTargetOrigin = union(enum) {
    wildcard,
    serialized: []const u8,
    // The default "/" target uses the incumbent environment's effective
    // origin, including an opaque origin's unguessable identity. Context
    // origin keys preserve that identity across inherited about:blank/srcdoc
    // realms without coupling delivery to one Frame/loader instance.
    same_origin_key: []const u8,

    fn parse(raw: ?[]const u8, source: *Window, arena: Allocator) !IntendedTargetOrigin {
        const value = raw orelse "/";
        if (std.mem.eql(u8, value, "*")) return .wildcard;

        if (std.mem.eql(u8, value, "/")) {
            return .{ .same_origin_key = try arena.dupe(u8, source._frame.js.origin.key) };
        }

        var parse_error: i32 = 0;
        const parsed = SysURL.url_parse(value.ptr, value.len, &parse_error) orelse
            return error.SyntaxError;
        defer SysURL.url_free(parsed);

        const origin = SysURL.url_get_origin(parsed);
        defer origin.deinit();
        if (!std.mem.eql(u8, origin.slice(), "null")) {
            return .{ .serialized = try arena.dupe(u8, origin.slice()) };
        }

        // Chromium represents file URLs with the non-opaque file:// security
        // origin. Other URL-parser opaque origins cannot be named by a string
        // targetOrigin and therefore synchronously throw SyntaxError.
        var scheme_ptr: [*]const u8 = undefined;
        var scheme_len: usize = 0;
        SysURL.url_get_scheme(parsed, &scheme_ptr, &scheme_len);
        if (std.mem.eql(u8, scheme_ptr[0..scheme_len], "file")) {
            return .{ .serialized = try arena.dupe(u8, "file://") };
        }
        return error.SyntaxError;
    }

    fn matches(self: IntendedTargetOrigin, target: *const Frame) bool {
        return switch (self) {
            .wildcard => true,
            // A serialized targetOrigin is matched against the recipient's
            // SecurityOrigin.  Never let the URL tuple name a sandboxed opaque
            // recipient; such a target is reachable only through "*" or an
            // exact inherited opaque identity represented by the default "/".
            .serialized => |expected| switch (target.requestOrigin()) {
                .tuple => |actual| std.mem.eql(u8, expected, actual),
                .legacy_derive_from_initiator_url, .none, .@"opaque" => false,
            },
            .same_origin_key => |expected| std.mem.eql(
                u8,
                expected,
                target.js.origin.key,
            ),
        };
    }
};

const base64 = @import("encoding/base64.zig");
pub fn btoa(_: *const Window, input: base64.BinInput, frame: *Frame) ![]const u8 {
    return base64.encode(frame.local_arena, input);
}

pub fn atob(_: *const Window, input: base64.BinInput, frame: *Frame) !js.String.OneByte {
    const decoded = try base64.decode(frame.local_arena, input);
    return .{ .bytes = decoded };
}

pub fn structuredClone(
    _: *const Window,
    value: js.Value,
    options: ?js.Value,
    exec: *js.Execution,
) !js.Value {
    // the serializer already threw (e.g. a DataCloneError); keep it
    return value.structuredCloneWithOptions(options, exec) catch error.TryCatchRethrow;
}

pub fn getFrame(self: *Window, idx: usize) !?*Window {
    if (self._closed) return null;
    const child = self._frame.scopedChild(idx) orelse return null;
    return child.window;
}

/// Blink WindowProperties::AnonymousNamedGetter / FrameTree::ScopedChild(name)
/// equivalent. The browsing-context name is not the iframe id, and lookup
/// follows FrameTree creation order rather than current DOM order.
pub fn getNamedFrame(self: *Window, name: []const u8) ?*Window {
    if (self._closed or name.len == 0) return null;

    for (self._frame.child_frames.items) |child| {
        if (!child.scoped_for_window) continue;
        const owner = child.iframe orelse continue;

        // Until Frame publishes the owner's initial name into Window._name,
        // use the creation owner's attribute as a compatibility fallback. The
        // initialized bit is required because an explicit `window.name = ''`
        // must not fall back to that attribute.
        const child_name = if (child.window._name_initialized)
            child.window._name
        else
            owner.getName();
        if (!std.mem.eql(u8, child_name, name)) continue;

        // WindowProperties applies this guard before its ordinary cross-origin
        // access check. A cross-origin child remains exposed under the iframe's
        // actual name attribute, but not under a name changed by child script.
        if (self._frame.js.origin == child.js.origin or
            std.mem.eql(u8, owner.getName(), name))
        {
            return child.window;
        }
        return null;
    }
    return null;
}

pub fn getFramesLength(self: *const Window) u32 {
    if (self._closed) return 0;
    return @intCast(self._frame.scopedChildCount());
}

pub fn getScrollX(self: *const Window) u32 {
    return self._scroll_pos.x;
}

pub fn getScrollY(self: *const Window) u32 {
    return self._scroll_pos.y;
}

pub fn getInnerWidth(_: *const Window, frame: *Frame) u32 {
    return frame._page.getViewport().width;
}

pub fn getScreenX(_: *const Window, frame: *Frame) i32 {
    return frame._session.browser.getDisplay().screen_x;
}

pub fn getScreenY(_: *const Window, frame: *Frame) i32 {
    return frame._session.browser.getDisplay().screen_y;
}

pub fn getOuterWidth(_: *const Window, frame: *Frame) u32 {
    return frame._session.browser.getDisplay().outer_width;
}

pub fn getOuterHeight(_: *const Window, frame: *Frame) u32 {
    return frame._session.browser.getDisplay().outer_height;
}

pub fn getDevicePixelRatio(_: *const Window, frame: *Frame) f64 {
    return frame._session.browser.getDisplay().device_pixel_ratio;
}

pub fn setDevicePixelRatio(self: *Window, value: js.Value) void {
    self.replaceGlobalProperty(value, "devicePixelRatio");
}

// Faux-layout viewport height, used to decide whether an element is already
// within view (e.g. scrollIntoViewIfNeeded).
pub fn getInnerHeight(_: *const Window, frame: *Frame) u32 {
    return frame._page.getViewport().height;
}

const ScrollToOpts = union(enum) {
    x: i32,
    opts: Opts,

    const Opts = struct {
        top: i32,
        left: i32,
        behavior: []const u8 = "",
    };
};
pub fn scrollTo(self: *Window, opts: ScrollToOpts, y: ?i32, frame: *Frame) !void {
    const new_x: u32, const new_y: u32 = switch (opts) {
        .x => |x| .{ @intCast(@max(x, 0)), @intCast(@max(0, y orelse 0)) },
        .opts => |o| .{ @intCast(@max(0, o.left)), @intCast(@max(0, o.top)) },
    };

    if (new_x == self._scroll_pos.x and new_y == self._scroll_pos.y) {
        return;
    }

    self._scroll_pos.x = new_x;
    self._scroll_pos.y = new_y;
    self._scroll_pos.state = .scroll;

    // We dispatch scroll event asynchronously after 10ms. So we can throttle
    // them.
    try frame.js.scheduler.add(
        frame,
        struct {
            fn dispatch(_frame: *anyopaque) anyerror!?u32 {
                const f: *Frame = @ptrCast(@alignCast(_frame));
                const pos = &f.window._scroll_pos;
                // If the state isn't scroll, we can ignore safely to throttle
                // the events.
                if (pos.state != .scroll) {
                    return null;
                }

                const event = try Event.initTrusted(comptime .wrap("scroll"), .{ .bubbles = true }, f._page);
                try f._event_manager.dispatch(f.document.asEventTarget(), event);
                pos.state = .end;

                return null;
            }
        }.dispatch,
        10,
        // Scroll steps are an ordinary rendering task source, not idle work.
        // Keeping them in Scheduler's normal queue also preserves FIFO against
        // a same-deadline setTimeout, instead of letting that timer mutate the
        // shared scroll state before the earlier scroll task is delivered.
        .{ .name = "window.scroll event" },
    );
    // We dispatch scrollend event asynchronously after 20ms.
    try frame.js.scheduler.add(
        frame,
        struct {
            fn dispatch(_frame: *anyopaque) anyerror!?u32 {
                const f: *Frame = @ptrCast(@alignCast(_frame));
                const pos = &f.window._scroll_pos;
                // Dispatch only if the state is .end.
                // If a scroll is pending, retry in 10ms.
                // If the state is .end, the event has been dispatched, so
                // ignore safely.
                switch (pos.state) {
                    .scroll => return 10,
                    .end => {},
                    .done => return null,
                }
                const event = try Event.initTrusted(comptime .wrap("scrollend"), .{ .bubbles = true }, f._page);
                try f._event_manager.dispatch(f.document.asEventTarget(), event);
                pos.state = .done;

                return null;
            }
        }.dispatch,
        20,
        .{ .name = "window.scrollend event" },
    );
}

pub fn scrollBy(self: *Window, opts: ScrollToOpts, y: ?i32, frame: *Frame) !void {
    // The scroll is relative to the current position. So compute to new
    // absolute position.
    var absx: i32 = undefined;
    var absy: i32 = undefined;
    switch (opts) {
        .x => |x| {
            absx = @as(i32, @intCast(self._scroll_pos.x)) + x;
            absy = @as(i32, @intCast(self._scroll_pos.y)) + (y orelse 0);
        },
        .opts => |o| {
            absx = @as(i32, @intCast(self._scroll_pos.x)) + o.left;
            absy = @as(i32, @intCast(self._scroll_pos.y)) + o.top;
        },
    }
    return self.scrollTo(.{ .x = absx }, absy, frame);
}

// only exposed when the binary is built with the -Dwpt_extensions flag
pub fn getWebDriver(_: *const Window) @import("WebDriver.zig") {
    return .{};
}

pub fn unhandledPromiseRejection(self: *Window, no_handler: bool, rejection: js.PromiseRejection, frame: *Frame) !void {
    if (comptime IS_DEBUG) {
        log.debug(.js, "unhandled rejection", .{
            .target = "window",
            .value = rejection.reason(),
            .stack = rejection.local.stackTrace() catch |err| @errorName(err) orelse "???",
        });
    }

    const event_name, const attribute_callback = blk: {
        if (no_handler) {
            break :blk .{ "unhandledrejection", self._on_unhandled_rejection };
        }
        break :blk .{ "rejectionhandled", self._on_rejection_handled };
    };

    const target = self.asEventTarget();
    if (frame._event_manager.hasDirectListeners(target, event_name, attribute_callback)) {
        const event = (try @import("event/PromiseRejectionEvent.zig").init(event_name, .{
            .cancelable = no_handler,
            .reason = if (rejection.reason()) |r| try r.persist() else null,
            .promise = try rejection.promise().persist(),
        }, frame._page)).asEvent();
        event.setTrusted();
        try frame._event_manager.dispatchDirect(target, event, attribute_callback, .{ .context = "window.unhandledrejection" });
    }
}

// Some properties are readonly but [Replaceable]. They get assigned as own
// data properties on the underlying v8::object that represents the global (the
// Window)
fn replaceGlobalProperty(self: *Window, value: js.Value, comptime name: []const u8) void {
    const global = self._frame.js.globalObject(value.local);
    _ = global.defineOwnProperty(name, value, 0);
}

pub const Access = union(enum) {
    window: *Window,
    cross_origin: *CrossOriginWindow,

    pub fn init(callee: *Window, accessing: *Window) Access {
        // A WindowProxy has one stable identity for the lifetime of its
        // browsing context.  Whether the caller gets same-origin or
        // cross-origin behavior is decided by V8's access-check callback at
        // each operation, using the target's *current* Context/security
        // origin.  Selecting a different Zig wrapper here made A -> B -> A
        // navigation permanently change JavaScript identity.
        _ = callee;
        return .{ .window = accessing };
    }
};

const PostMessageCallback = struct {
    frame: *Frame,
    source: *Window,
    arena: Allocator,
    origin: []const u8,
    target_origin: IntendedTargetOrigin,
    message: js.Value.Global,
    ports: []const *MessagePort,
    user_activation: ?UserActivation.Snapshot,

    fn deinit(self: *PostMessageCallback) void {
        self.frame.releaseArena(self.arena);
    }

    // Called by the scheduler if the task is dropped before it runs. `run` and
    // `cancelled` are mutually exclusive, so the temp is released exactly once.
    fn cancelled(ctx: *anyopaque) void {
        const self: *PostMessageCallback = @ptrCast(@alignCast(ctx));
        self.message.release();
        self.deinit();
    }

    fn run(ctx: *anyopaque) !?u32 {
        const self: *PostMessageCallback = @ptrCast(@alignCast(ctx));
        defer self.deinit();

        const frame = self.frame;
        const window = frame.window;

        if (!self.target_origin.matches(frame)) {
            self.message.release();
            return null;
        }

        const event_target = window.asEventTarget();

        // The MessageEvent takes ownership of the cloned temp and releases it on
        // teardown; if there are no listeners, release it here so it doesn't leak.
        if (!frame._event_manager.hasDirectListeners(event_target, "message", window._on_message)) {
            self.message.release();
            return null;
        }

        const message_event = try MessageEvent.initTrusted(comptime .wrap("message"), .{
            .data = .{ .value = self.message },
            .origin = self.origin,
            .source = .{ .window = self.source },
            .ports = self.ports,
            .bubbles = false,
            .cancelable = false,
        }, frame._page);
        if (self.user_activation) |snapshot| {
            try message_event.setUserActivationSnapshot(
                snapshot.has_been_active,
                snapshot.is_active,
            );
        }
        const event = message_event.asEvent();
        try frame._event_manager.dispatchDirect(event_target, event, window._on_message, .{ .context = "window.postMessage" });

        return null;
    }
};

const FunctionSetter = union(enum) {
    func: js.Function.Global,
    anything: js.Value,
};

// window.onload = {}; doesn't fail, but it doesn't do anything.
// seems like setting to null is ok (though, at least on Firefix, it preserves
// the original value, which we could do, but why?)
fn getFunctionFromSetter(setter_: ?FunctionSetter) ?js.Function.Global {
    const setter = setter_ orelse return null;
    return switch (setter) {
        .func => |func| func, // Already a Global from bridge auto-conversion
        .anything => null,
    };
}

// Checks whether a window.open features string contains a token, matched
// case-insensitively on whole-token boundaries (comma or whitespace separated).
// The features syntax is legacy and loose; the only tokens we interpret are
// noopener and noreferrer.
fn hasFeatureToken(features: []const u8, token: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, features, " \t\r\n,");
    while (it.next()) |raw| {
        // Trim a trailing =value if present — we only need the key.
        const key = if (std.mem.indexOfScalarPos(u8, raw, 0, '=')) |eq| raw[0..eq] else raw;
        if (std.ascii.eqlIgnoreCase(key, token)) return true;
    }
    return false;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Window);

    pub const Meta = struct {
        pub const name = "Window";
        pub const global_scope = true;
        pub const access_check = CrossOriginAccessHandlers;
        pub const immutable_proto = js.bridge.ImmutableProto.both;
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    // Legacy File System API constants. Blink installs constants declared on a
    // [Global] interface on both the interface object and its prototype, but
    // not on the global object itself.
    pub const TEMPORARY = bridge.property(0, .{ .template = true });
    pub const PERSISTENT = bridge.property(1, .{ .template = true });

    pub const document = bridge.accessor(Window.getDocument, null, .{ .cache = .{ .internal = 1 }, .deletable = false });
    pub const console = bridge.accessor(Window.getConsole, Window.setConsole, .{});

    pub const top = bridge.accessor(Window.getTop, null, .{ .deletable = false, .cross_origin_getter_allowed = true });
    pub const self = bridge.accessor(Window.getWindow, Window.setSelf, .{ .cross_origin_getter_allowed = true });
    pub const window = bridge.accessor(Window.getWindow, null, .{ .deletable = false, .cross_origin_getter_allowed = true });
    pub const parent = bridge.accessor(Window.getParent, Window.setParent, .{ .cross_origin_getter_allowed = true });
    pub const navigator = bridge.accessor(Window.getNavigator, null, .{});
    pub const screen = bridge.accessor(Window.getScreen, Window.setScreen, .{});
    pub const visualViewport = bridge.accessor(Window.getVisualViewport, Window.setVisualViewport, .{});
    pub const performance = bridge.accessor(Window.getPerformance, Window.setPerformance, .{});
    pub const localStorage = bridge.accessor(Window.getLocalStorage, null, .{});
    pub const sessionStorage = bridge.accessor(Window.getSessionStorage, null, .{});
    pub const cookieStore = bridge.accessor(Window.getCookieStore, null, .{});
    pub const indexedDB = bridge.accessor(Window.getIndexedDB, null, .{});
    pub const origin = bridge.accessor(Window.getOrigin, Window.setOrigin, .{});
    pub const location = bridge.accessor(Window.getLocation, Window.setLocation, .{ .deletable = false, .cross_origin_allowed = true });
    pub const history = bridge.accessor(Window.getHistory, null, .{});
    pub const navigation = bridge.accessor(Window.getNavigation, Window.setNavigation, .{});
    pub const crypto = bridge.accessor(Window.getCrypto, null, .{});
    pub const trustedTypes = bridge.accessor(Window.getTrustedTypes, null, .{});
    pub const CSS = bridge.accessor(Window.getCSS, null, .{});
    pub const customElements = bridge.accessor(Window.getCustomElements, null, .{});
    pub const onload = bridge.accessor(Window.getOnLoad, Window.setOnLoad, .{});
    pub const onpageshow = bridge.accessor(Window.getOnPageShow, Window.setOnPageShow, .{});
    pub const onpagehide = bridge.accessor(Window.getOnPageHide, Window.setOnPageHide, .{});
    pub const onunload = bridge.accessor(Window.getOnUnload, Window.setOnUnload, .{});
    pub const onpopstate = bridge.accessor(Window.getOnPopState, Window.setOnPopState, .{});
    pub const onhashchange = bridge.accessor(Window.getOnHashChange, Window.setOnHashChange, .{});
    pub const onerror = bridge.accessor(Window.getOnError, Window.setOnError, .{});
    pub const onmessage = bridge.accessor(Window.getOnMessage, Window.setOnMessage, .{});
    pub const onstorage = bridge.accessor(Window.getOnStorage, Window.setOnStorage, .{});
    pub const onrejectionhandled = bridge.accessor(Window.getOnRejectionHandled, Window.setOnRejectionHandled, .{});
    pub const onunhandledrejection = bridge.accessor(Window.getOnUnhandledRejection, Window.setOnUnhandledRejection, .{});
    pub const event = bridge.accessor(Window.getEvent, Window.setEvent, .{ .null_as_undefined = true });
    pub const fetch = bridge.function(Window.fetch, .{});
    pub const queueMicrotask = bridge.function(Window.queueMicrotask, .{});
    pub const setTimeout = bridge.function(Window.setTimeout, .{ .arity = 1, .required_args = 1, .variadic = true });
    pub const clearTimeout = bridge.function(Window.clearTimeout, .{});
    pub const setInterval = bridge.function(Window.setInterval, .{ .arity = 1, .required_args = 1, .variadic = true });
    pub const clearInterval = bridge.function(Window.clearInterval, .{});
    pub const requestAnimationFrame = bridge.function(Window.requestAnimationFrame, .{});
    pub const cancelAnimationFrame = bridge.function(Window.cancelAnimationFrame, .{});
    pub const requestIdleCallback = bridge.function(Window.requestIdleCallback, .{});
    pub const cancelIdleCallback = bridge.function(Window.cancelIdleCallback, .{});
    pub const matchMedia = bridge.function(Window.matchMedia, .{});
    pub const postMessage = bridge.function(Window.postMessage, .{ .cross_origin_allowed = true });
    pub const btoa = bridge.function(Window.btoa, .{});
    pub const atob = bridge.function(Window.atob, .{});
    pub const reportError = bridge.function(Window.reportError, .{});
    pub const structuredClone = bridge.function(Window.structuredClone, .{});
    pub const getComputedStyle = bridge.function(Window.getComputedStyle, .{});
    pub const getSelection = bridge.function(Window.getSelection, .{});
    pub const frameElement = bridge.accessor(Window.getFrameElement, null, .{});

    pub const frames = bridge.accessor(Window.getWindow, Window.setFrames, .{ .cross_origin_getter_allowed = true });
    pub const index = bridge.indexed(Window.getFrame, null, .{ .null_as_undefined = true });
    pub const length = bridge.accessor(Window.getFramesLength, Window.setLength, .{ .cross_origin_getter_allowed = true });
    pub const scrollX = bridge.accessor(Window.getScrollX, Window.setScrollX, .{});
    pub const scrollY = bridge.accessor(Window.getScrollY, Window.setScrollY, .{});
    pub const pageXOffset = bridge.accessor(Window.getScrollX, Window.setPageXOffset, .{});
    pub const pageYOffset = bridge.accessor(Window.getScrollY, Window.setPageYOffset, .{});
    pub const scrollTo = bridge.function(Window.scrollTo, .{});
    pub const scroll = bridge.function(Window.scrollTo, .{});
    pub const scrollBy = bridge.function(Window.scrollBy, .{});

    pub const isSecureContext = bridge.accessor(Window.getIsSecureContext, null, .{});

    // [Replaceable] (CSSOM-View): the getter reads the page's runtime viewport
    // (overridable via Emulation.setDeviceMetricsOverride); the setter overwrites
    // the attribute rather than throwing.
    pub const innerWidth = bridge.accessor(Window.getInnerWidth, Window.setInnerWidth, .{});
    pub const innerHeight = bridge.accessor(Window.getInnerHeight, Window.setInnerHeight, .{});
    pub const screenX = bridge.accessor(Window.getScreenX, Window.setScreenX, .{});
    pub const screenY = bridge.accessor(Window.getScreenY, Window.setScreenY, .{});
    pub const outerWidth = bridge.accessor(Window.getOuterWidth, Window.setOuterWidth, .{});
    pub const outerHeight = bridge.accessor(Window.getOuterHeight, Window.setOuterHeight, .{});
    pub const devicePixelRatio = bridge.accessor(Window.getDevicePixelRatio, Window.setDevicePixelRatio, .{});
    pub const screenLeft = bridge.accessor(Window.getScreenX, Window.setScreenLeft, .{});
    pub const screenTop = bridge.accessor(Window.getScreenY, Window.setScreenTop, .{});

    pub const opener = bridge.accessor(Window.getOpener, Window.setOpener, .{ .cross_origin_allowed = true });
    pub const closed = bridge.accessor(Window.getClosed, null, .{ .cross_origin_getter_allowed = true });
    pub const name = bridge.accessor(Window.getName, Window.setName, .{});
    pub const open = bridge.function(Window.open, .{});
    pub const close = bridge.function(Window.close, .{ .cross_origin_allowed = true });
    pub const blur = bridge.function(Window.blur, .{ .cross_origin_allowed = true });
    pub const focus = bridge.function(Window.focus, .{ .cross_origin_allowed = true });

    pub const alert = bridge.function(struct {
        fn alert(receiver: *const Window, message: ?[]const u8, _: *Frame) void {
            if (receiver._closed or receiver._frame.isRetired()) return;

            const owner = receiver._frame;
            var response: Notification.DialogResponse = .{};
            owner._session.notification.dispatch(.javascript_dialog_opening, &.{
                .url = owner.url,
                .message = message orelse "",
                .dialog_type = "alert",
                .response = &response,
            });
            // Return value is void; we still pop a pre-armed response so the
            // CDP client's pre-arm doesn't leak across to the next dialog.
        }
    }.alert, .{});
    pub const confirm = bridge.function(struct {
        fn confirm(receiver: *const Window, message: ?[]const u8, _: *Frame) bool {
            if (receiver._closed or receiver._frame.isRetired()) return false;

            const owner = receiver._frame;
            var response: Notification.DialogResponse = .{};
            owner._session.notification.dispatch(.javascript_dialog_opening, &.{
                .url = owner.url,
                .message = message orelse "",
                .dialog_type = "confirm",
                .response = &response,
            });
            return response.accept;
        }
    }.confirm, .{});
    pub const prompt = bridge.function(struct {
        fn prompt(receiver: *const Window, message: ?[]const u8, default_text: ?[]const u8, _: *Frame) ?[]const u8 {
            if (receiver._closed or receiver._frame.isRetired()) return null;

            const owner = receiver._frame;
            var response: Notification.DialogResponse = .{};
            owner._session.notification.dispatch(.javascript_dialog_opening, &.{
                .url = owner.url,
                .message = message orelse "",
                .dialog_type = "prompt",
                .response = &response,
            });
            if (!response.accept) return null;
            // Pre-armed promptText wins when present. Otherwise fall back to
            // the dialog's defaultText (second arg to window.prompt) — Chrome's
            // accept-without-typing behavior. If both are absent, return ""
            // per CDP spec
            // (https://chromedevtools.github.io/devtools-protocol/tot/Page/#method-handleJavaScriptDialog).
            return response.prompt_text orelse default_text orelse "";
        }
    }.prompt, .{});

    pub const webdriver = bridge.accessor(Window.getWebDriver, null, .{ .wpt_only = true });
};

const CrossOriginErrorOperation = enum {
    read,
    write,
    generic,
};

fn throwCrossOriginSecurityError(
    frame: *Frame,
    comptime interface_name: []const u8,
    property: ?[]const u8,
    operation: CrossOriginErrorOperation,
) !js.Value {
    const local = frame.js.local orelse return error.SecurityError;
    const caller_origin = switch (frame.requestOrigin()) {
        .tuple => |tuple| tuple,
        .legacy_derive_from_initiator_url, .none, .@"opaque" => "null",
    };
    const message = switch (operation) {
        .read => std.fmt.allocPrint(
            frame.js.arena,
            "Failed to read a named property '{s}' from '{s}': Blocked a frame with origin \"{s}\" from accessing a cross-origin frame.",
            .{ property.?, interface_name, caller_origin },
        ) catch return error.OutOfMemory,
        .write => std.fmt.allocPrint(
            frame.js.arena,
            "Failed to set a named property '{s}' on '{s}': Blocked a frame with origin \"{s}\" from accessing a cross-origin frame.",
            .{ property.?, interface_name, caller_origin },
        ) catch return error.OutOfMemory,
        .generic => std.fmt.allocPrint(
            frame.js.arena,
            "Blocked a frame with origin \"{s}\" from accessing a cross-origin frame.",
            .{caller_origin},
        ) catch return error.OutOfMemory,
    };

    const value = local.zigValueToJs(DOMException.init(message, "SecurityError"), .{}) catch
        return error.OutOfMemory;
    _ = js.v8.v8__Exception__CaptureStackTrace(local.handle, @ptrCast(value.handle));
    return .{
        .local = local,
        .handle = local.isolate.throwException(value.handle),
    };
}

fn crossOriginValue(frame: *Frame, value: anytype) !js.Value {
    const local = frame.js.local orelse return error.InvalidStateError;
    return local.zigValueToJs(value, .{});
}

// Cross-origin named interceptors mask the real own properties so reads can
// perform Blink's access check while reflection still falls through to the
// exact own descriptor. Operations return the member function stored on the
// hidden FunctionTemplate prototype; V8 caches one Function per template and
// context, preserving stable function identity.
fn crossOriginBackingPrototype(comptime T: type, frame: *Frame) !js.Object {
    const local = frame.js.local orelse return error.InvalidStateError;
    const template = frame.js.templates[T.JsApi.Meta.class_id];
    const constructor = js.v8.v8__FunctionTemplate__GetFunction(template, local.handle) orelse
        return error.CrossOriginConstructorMissing;
    const prototype_key = local.isolate.initStringHandle("prototype");
    const prototype_value = js.v8.v8__Object__Get(
        @ptrCast(constructor),
        local.handle,
        prototype_key,
    ) orelse return error.TryCatchRethrow;
    if (!js.v8.v8__Value__IsObject(prototype_value)) {
        return error.CrossOriginPrototypeMissing;
    }
    return .{ .local = local, .handle = @ptrCast(prototype_value) };
}

fn crossOriginBackingMember(comptime T: type, frame: *Frame, name: []const u8) !js.Value {
    const local = frame.js.local orelse return error.InvalidStateError;
    const prototype = try crossOriginBackingPrototype(T, frame);
    const member_key = local.isolate.initStringHandle(name);
    const member = js.v8.v8__Object__Get(
        prototype.handle,
        local.handle,
        member_key,
    ) orelse return error.TryCatchRethrow;
    return .{ .local = local, .handle = member };
}

fn crossOriginDataDescriptor(frame: *Frame, value: js.Value) !js.Value {
    const local = frame.js.local orelse return error.InvalidStateError;
    return local.zigValueToJs(.{
        .value = value,
        .writable = false,
        .enumerable = false,
        .configurable = true,
    }, .{});
}

fn crossOriginAccessorDescriptor(
    comptime T: type,
    frame: *Frame,
    comptime getter_name: ?[]const u8,
    comptime setter_name: ?[]const u8,
) !js.Value {
    const local = frame.js.local orelse return error.InvalidStateError;
    const getter = if (getter_name) |name|
        try crossOriginBackingMember(T, frame, js.bridge.crossOriginGetterBackingName(name))
    else
        try local.zigValueToJs(js.Undefined{}, .{});
    const setter = if (setter_name) |name|
        try crossOriginBackingMember(T, frame, js.bridge.crossOriginSetterBackingName(name))
    else
        try local.zigValueToJs(js.Undefined{}, .{});
    return local.zigValueToJs(.{
        .get = getter,
        .set = setter,
        .enumerable = false,
        .configurable = true,
    }, .{});
}

fn crossOriginNavigationString(value: js.Value) ![:0]const u8 {
    return value.toStringSliceZ() catch |err| switch (err) {
        error.JsException => error.TryCatchRethrow,
        else => err,
    };
}

fn throwCrossOriginIndexedSecurityError(
    frame: *Frame,
    index: usize,
    operation: CrossOriginErrorOperation,
) !js.Value {
    const local = frame.js.local orelse return error.SecurityError;
    const caller_origin = switch (frame.requestOrigin()) {
        .tuple => |tuple| tuple,
        .legacy_derive_from_initiator_url, .none, .@"opaque" => "null",
    };
    const blocked = try std.fmt.allocPrint(
        frame.js.arena,
        "Blocked a frame with origin \"{s}\" from accessing a cross-origin frame.",
        .{caller_origin},
    );
    const message = switch (operation) {
        .read => try std.fmt.allocPrint(
            frame.js.arena,
            "Failed to read an indexed property [{d}] from 'Window': {s}",
            .{ index, blocked },
        ),
        .write => try std.fmt.allocPrint(
            frame.js.arena,
            "Failed to set an indexed property [{d}] on 'Window': {s}",
            .{ index, blocked },
        ),
        .generic => blocked,
    };
    const value = try local.zigValueToJs(DOMException.init(message, "SecurityError"), .{});
    _ = js.v8.v8__Exception__CaptureStackTrace(local.handle, @ptrCast(value.handle));
    return .{
        .local = local,
        .handle = local.isolate.throwException(value.handle),
    };
}

fn crossOriginCallbackFunction(
    frame: *Frame,
    comptime callback: *const fn (?*const js.v8.FunctionCallbackInfo) callconv(.c) void,
    comptime name: []const u8,
    length: i32,
) !js.Value {
    // The cache belongs to the accessing (caller) Context, not this target
    // Window. The Window FunctionTemplate supplies V8's receiver Signature.
    return frame.js.crossOriginFunction(
        Window.JsApi.Meta.class_id,
        callback,
        name,
        length,
    );
}

fn crossOriginCallbackAccessorDescriptor(
    frame: *Frame,
    getter: ?js.Value,
    setter: ?js.Value,
) !js.Value {
    const local = frame.js.local orelse return error.InvalidStateError;
    const undefined_value = try local.zigValueToJs(js.Undefined{}, .{});
    return local.zigValueToJs(.{
        .get = getter orelse undefined_value,
        .set = setter orelse undefined_value,
        .enumerable = false,
        .configurable = true,
    }, .{});
}

// V8's receiver Signature runs before this callback. Thus `{}` receivers get
// "Illegal invocation" even when the required message argument is also
// missing, while undefined/null receivers which normalize to the caller's
// Window reach Web IDL's argument-count diagnostic.
fn crossOriginPostMessageCallback(
    raw_info: ?*const js.v8.FunctionCallbackInfo,
) callconv(.c) void {
    const info = raw_info orelse return;
    if (js.v8.v8__FunctionCallbackInfo__Length(info) >= 1) {
        return Window.JsApi.postMessage.func(raw_info);
    }

    const isolate_handle = js.v8.v8__FunctionCallbackInfo__GetIsolate(info) orelse return;
    const isolate: js.Isolate = .{ .handle = isolate_handle };
    const message = "Failed to execute 'postMessage' on 'Window': 1 argument required, but only 0 present.";
    _ = isolate.throwException(isolate.createTypeError(message));
}

fn crossOriginWindowMethod(frame: *Frame, name: []const u8) !js.Value {
    if (std.mem.eql(u8, name, "postMessage")) {
        return crossOriginCallbackFunction(frame, crossOriginPostMessageCallback, "postMessage", 1);
    }
    if (std.mem.eql(u8, name, "close")) {
        return crossOriginCallbackFunction(frame, Window.JsApi.close.func, "close", 0);
    }
    if (std.mem.eql(u8, name, "blur")) {
        return crossOriginCallbackFunction(frame, Window.JsApi.blur.func, "blur", 0);
    }
    if (std.mem.eql(u8, name, "focus")) {
        return crossOriginCallbackFunction(frame, Window.JsApi.focus.func, "focus", 0);
    }
    return error.NotHandled;
}

fn crossOriginIndexedDescriptor(frame: *Frame, value: js.Value) !js.Value {
    const local = frame.js.local orelse return error.InvalidStateError;
    return local.zigValueToJs(.{
        .value = value,
        .writable = false,
        .enumerable = true,
        .configurable = true,
    }, .{});
}

fn isCrossOriginFallbackSymbolName(name: js.Caller.PropertyName) bool {
    return switch (name.kind) {
        .to_string_tag, .has_instance, .is_concat_spreadable => true,
        else => false,
    };
}

fn isCrossOriginWindowAllowedName(name: js.Caller.PropertyName) bool {
    if (name.kind != .string) return isCrossOriginFallbackSymbolName(name);
    const names = [_][]const u8{
        "window",      "self",   "location", "closed", "frames", "length",
        "top",         "opener", "parent",   "blur",   "close",  "focus",
        "postMessage", "then",
    };
    inline for (names) |allowed| {
        if (std.mem.eql(u8, name.text, allowed)) return true;
    }
    return false;
}

fn crossOriginWindowNamedGet(self: *Window, name: js.Caller.PropertyName, frame: *Frame) !js.Value {
    if (name.kind == .string and (std.mem.eql(u8, name.text, "window") or
        std.mem.eql(u8, name.text, "self") or
        std.mem.eql(u8, name.text, "frames")))
    {
        return crossOriginValue(frame, self);
    }
    if (name.kind == .string and std.mem.eql(u8, name.text, "location")) return crossOriginValue(frame, self._location);
    if (name.kind == .string and std.mem.eql(u8, name.text, "closed")) return crossOriginValue(frame, self.getClosed());
    if (name.kind == .string and std.mem.eql(u8, name.text, "length")) return crossOriginValue(frame, self.getFramesLength());
    if (name.kind == .string and std.mem.eql(u8, name.text, "top")) return crossOriginValue(frame, self.getTop(frame));
    if (name.kind == .string and std.mem.eql(u8, name.text, "opener")) return crossOriginValue(frame, self.getOpener(frame));
    if (name.kind == .string and std.mem.eql(u8, name.text, "parent")) return crossOriginValue(frame, self.getParent(frame));
    if (name.kind == .string and (std.mem.eql(u8, name.text, "blur") or
        std.mem.eql(u8, name.text, "close") or
        std.mem.eql(u8, name.text, "focus") or
        std.mem.eql(u8, name.text, "postMessage")))
    {
        return crossOriginWindowMethod(frame, name.text);
    }
    if (name.kind == .string) {
        if (self.getNamedFrame(name.text)) |child| {
            return crossOriginValue(frame, Access.init(frame.window, child));
        }
    }
    // `then` is an allowed undefined fallback only when no child browsing
    // context has that name. Chrome exposes a real child named "then".
    if ((name.kind == .string and std.mem.eql(u8, name.text, "then")) or isCrossOriginFallbackSymbolName(name)) {
        return crossOriginValue(frame, js.Undefined{});
    }
    return throwCrossOriginSecurityError(frame, "Window", name.text, .read);
}

fn crossOriginWindowNamedSet(self: *Window, name: js.Caller.PropertyName, value: js.Value, frame: *Frame) !void {
    if (name.kind == .string and std.mem.eql(u8, name.text, "location")) {
        return self.setLocation(try crossOriginNavigationString(value), frame);
    }
    _ = try throwCrossOriginSecurityError(frame, "Window", name.text, .write);
}

fn crossOriginWindowNamedReject(_: *Window, _: js.Caller.PropertyName, frame: *Frame) !void {
    _ = try throwCrossOriginSecurityError(frame, "Window", null, .generic);
}

fn crossOriginWindowNamedEnumerate(_: *Window, frame: *Frame) ![]js.Value {
    const local = frame.js.local orelse return error.InvalidStateError;
    const names = [_][]const u8{
        "window", "self",   "location", "closed", "frames", "length",      "top",
        "opener", "parent", "blur",     "close",  "focus",  "postMessage", "then",
    };
    const values = try frame.call_arena.alloc(js.Value, names.len + 3);
    for (names, 0..) |name, i| values[i] = try local.zigValueToJs(name, .{});
    values[names.len] = .{
        .local = local,
        .handle = @ptrCast(js.v8.v8__Symbol__GetToStringTag(local.isolate.handle)),
    };
    values[names.len + 1] = .{
        .local = local,
        .handle = @ptrCast(js.v8.v8__Symbol__GetHasInstance(local.isolate.handle)),
    };
    values[names.len + 2] = .{
        .local = local,
        .handle = @ptrCast(js.v8.v8__Symbol__GetIsConcatSpreadable(local.isolate.handle)),
    };
    return values;
}

fn crossOriginWindowNamedQuery(_: *Window, name: js.Caller.PropertyName, frame: *Frame) !?u32 {
    if (isCrossOriginWindowAllowedName(name)) {
        const readonly = name.kind != .string or
            std.mem.eql(u8, name.text, "blur") or
            std.mem.eql(u8, name.text, "close") or
            std.mem.eql(u8, name.text, "focus") or
            std.mem.eql(u8, name.text, "postMessage") or
            std.mem.eql(u8, name.text, "then") or
            isCrossOriginFallbackSymbolName(name);
        return @intCast(js.v8.DontEnum | if (readonly) js.v8.ReadOnly else 0);
    }
    _ = try throwCrossOriginSecurityError(frame, "Window", null, .generic);
    return null;
}

fn crossOriginWindowNamedDescriptor(self: *Window, name: js.Caller.PropertyName, frame: *Frame) !js.Value {
    if (name.kind == .string and std.mem.eql(u8, name.text, "location")) {
        const getter = try crossOriginCallbackFunction(frame, Window.JsApi.location.getter.?, "get location", 0);
        const setter = try crossOriginCallbackFunction(frame, Window.JsApi.location.setter.?, "set location", 1);
        return crossOriginCallbackAccessorDescriptor(frame, getter, setter);
    }
    inline for (&.{ "window", "self", "closed", "frames", "length", "top", "opener", "parent" }) |accessor_name| {
        if (name.kind == .string and std.mem.eql(u8, name.text, accessor_name)) {
            const accessor = @field(Window.JsApi, accessor_name);
            const getter = try crossOriginCallbackFunction(
                frame,
                accessor.getter.?,
                "get " ++ accessor_name,
                0,
            );
            return crossOriginCallbackAccessorDescriptor(frame, getter, null);
        }
    }
    inline for (&.{ "blur", "close", "focus", "postMessage" }) |method_name| {
        if (name.kind == .string and std.mem.eql(u8, name.text, method_name)) {
            return crossOriginDataDescriptor(frame, try crossOriginWindowMethod(frame, method_name));
        }
    }
    if (name.kind == .string) {
        if (self.getNamedFrame(name.text)) |child| {
            return crossOriginDataDescriptor(
                frame,
                try crossOriginValue(frame, Access.init(frame.window, child)),
            );
        }
    }
    if ((name.kind == .string and std.mem.eql(u8, name.text, "then")) or isCrossOriginFallbackSymbolName(name)) {
        return crossOriginDataDescriptor(frame, try crossOriginValue(frame, js.Undefined{}));
    }
    return throwCrossOriginSecurityError(frame, "Window", name.text, .read);
}

fn crossOriginWindowGetIndex(self: *Window, index: usize, frame: *Frame) !js.Value {
    const child = self.getFrame(index) catch |err| return err;
    if (child) |window| return crossOriginValue(frame, Access.init(frame.window, window));
    return throwCrossOriginIndexedSecurityError(frame, index, .read);
}

fn crossOriginWindowSetIndex(_: *Window, index: usize, _: js.Value, frame: *Frame) !void {
    _ = try throwCrossOriginIndexedSecurityError(frame, index, .write);
}

fn crossOriginWindowRejectIndex(_: *Window, _: usize, frame: *Frame) !void {
    _ = try throwCrossOriginSecurityError(frame, "Window", null, .generic);
}

fn crossOriginWindowQueryIndex(self: *Window, index: usize, frame: *Frame) !?u32 {
    if (index < self.getFramesLength()) return js.v8.ReadOnly;
    _ = try throwCrossOriginIndexedSecurityError(frame, index, .read);
    return null;
}

fn crossOriginWindowEnumerateIndexes(self: *Window, frame: *Frame) ![]u32 {
    const indices = try frame.call_arena.alloc(u32, self.getFramesLength());
    for (indices, 0..) |*index, i| index.* = @intCast(i);
    return indices;
}

fn crossOriginWindowDescribeIndex(self: *Window, index: usize, frame: *Frame) !js.Value {
    const child = self.getFrame(index) catch |err| return err;
    if (child) |window| {
        return crossOriginIndexedDescriptor(frame, try crossOriginValue(frame, Access.init(frame.window, window)));
    }
    return throwCrossOriginIndexedSecurityError(frame, index, .read);
}

fn windowAccessCheckCallback(
    accessing_context: ?*const js.v8.Context,
    accessed_object: ?*const js.v8.Object,
    _: ?*const js.v8.Value,
) callconv(.c) bool {
    const context = js.Context.fromC(accessing_context orelse return false) orelse return false;
    const caller = switch (context.global) {
        .frame => |frame| frame.window,
        .worker => return false,
    };
    const target = TaggedOpaque.fromJS(*Window, accessed_object orelse return false) catch return false;
    return caller == target or caller._frame.js.origin == target._frame.js.origin;
}

pub fn failedAccessCheckCallback(
    accessed_object: ?*const js.v8.Object,
    _: js.v8.AccessType,
    _: ?*const js.v8.Value,
) callconv(.c) void {
    const isolate = js.v8.v8__Isolate__GetCurrent() orelse return;
    var caller: js.Caller = undefined;
    if (!caller.init(isolate)) return;
    defer caller.deinit();

    const frame = switch (caller.local.ctx.global) {
        .frame => |value| value,
        .worker => return,
    };

    // V8 exposes one isolate-wide failed-access callback for every access-
    // checked template. Dispatch by the accessed wrapper's TaggedOpaque type
    // so Location can preserve Blink's detached-Document policy diagnostic.
    if (accessed_object) |object| {
        const location: ?*Location = TaggedOpaque.fromJS(*Location, object) catch null;
        if (location) |value| {
            value.throwFailedAccessCheckSecurityError(frame) catch {};
            return;
        }
    }

    _ = throwCrossOriginSecurityError(frame, "Window", null, .generic) catch {};
}

const CrossOriginAccessHandlers = struct {
    const bridge = js.Bridge(Window);

    pub const callback = windowAccessCheckCallback;
    pub const named = bridge.namedIndexedFull(
        crossOriginWindowNamedGet,
        crossOriginWindowNamedSet,
        crossOriginWindowNamedReject,
        crossOriginWindowNamedEnumerate,
        crossOriginWindowNamedQuery,
        crossOriginWindowNamedReject,
        crossOriginWindowNamedDescriptor,
        .{},
    );
    pub const indexed = bridge.indexedFull(
        crossOriginWindowGetIndex,
        crossOriginWindowSetIndex,
        crossOriginWindowRejectIndex,
        crossOriginWindowQueryIndex,
        crossOriginWindowEnumerateIndexes,
        crossOriginWindowRejectIndex,
        crossOriginWindowDescribeIndex,
        .{},
    );
};

const CrossOriginWindow = struct {
    window: *Window,
    location: CrossOriginLocation = undefined,

    fn getWindow(self: *CrossOriginWindow) *CrossOriginWindow {
        return self;
    }

    fn getLocation(self: *CrossOriginWindow) *CrossOriginLocation {
        // The wrapper is embedded at a stable address. Frame initializes the
        // existing CrossOriginWindow with only `.window`, so initialize this
        // leaf lazily without changing Frame's construction path.
        self.location.window = self.window;
        return &self.location;
    }

    fn setLocation(self: *CrossOriginWindow, value: js.Value, frame: *Frame) !void {
        const url = try crossOriginNavigationString(value);
        if (self.window._closed or self.window._frame.isRetired()) return;
        return frame.scheduleNavigation(
            url,
            .{ .reason = .script, .kind = .{ .push = null } },
            .{ .script = self.window._frame },
        );
    }

    fn getClosed(self: *const CrossOriginWindow) bool {
        return self.window.getClosed();
    }

    pub fn postMessage(self: *CrossOriginWindow, message: js.Value, second: ?js.Value, third: ?js.Value, frame: *Frame) !void {
        return self.window.postMessage(message, second, third, frame);
    }

    pub fn getTop(self: *CrossOriginWindow, frame: *Frame) ?Access {
        return self.window.getTop(frame);
    }

    pub fn getParent(self: *CrossOriginWindow, frame: *Frame) ?Access {
        return self.window.getParent(frame);
    }

    pub fn getFramesLength(self: *const CrossOriginWindow) u32 {
        return self.window.getFramesLength();
    }

    fn getOpener(self: *CrossOriginWindow, frame: *Frame) ?Access {
        return self.window.getOpener(frame);
    }

    fn blur(_: *CrossOriginWindow) void {}

    fn close(self: *CrossOriginWindow) void {
        self.window.close();
    }

    fn focus(_: *CrossOriginWindow) void {}

    fn getFrame(self: *CrossOriginWindow, idx: usize, frame: *Frame) !?Access {
        const child = try self.window.getFrame(idx) orelse return null;
        return Access.init(frame.window, child);
    }

    fn enumerateFrames(self: *CrossOriginWindow, frame: *Frame) ![]u32 {
        const len = self.window.getFramesLength();
        const indices = try frame.call_arena.alloc(u32, len);
        for (indices, 0..) |*index, i| index.* = @intCast(i);
        return indices;
    }

    fn setFrame(_: *CrossOriginWindow, _: usize, _: js.Value, frame: *Frame) !void {
        _ = try throwCrossOriginSecurityError(frame, "Window", null, .generic);
    }

    fn deleteFrame(_: *CrossOriginWindow, _: usize, frame: *Frame) !void {
        _ = try throwCrossOriginSecurityError(frame, "Window", null, .generic);
    }

    fn queryFrame(self: *CrossOriginWindow, idx: usize) bool {
        return idx < self.window.getFramesLength();
    }

    fn isAllowedName(name: []const u8) bool {
        const names = [_][]const u8{
            "window",      "self",   "location", "closed", "frames", "length",
            "top",         "opener", "parent",   "blur",   "close",  "focus",
            "postMessage", "then",
        };
        inline for (names) |allowed| {
            if (std.mem.eql(u8, name, allowed)) return true;
        }
        return false;
    }

    fn namedGet(self: *CrossOriginWindow, name: []const u8, frame: *Frame) !js.Value {
        if (std.mem.eql(u8, name, "window") or
            std.mem.eql(u8, name, "self") or
            std.mem.eql(u8, name, "frames"))
        {
            return crossOriginValue(frame, self);
        }
        if (std.mem.eql(u8, name, "location")) return crossOriginValue(frame, self.getLocation());
        if (std.mem.eql(u8, name, "closed")) return crossOriginValue(frame, self.getClosed());
        if (std.mem.eql(u8, name, "length")) return crossOriginValue(frame, self.getFramesLength());
        if (std.mem.eql(u8, name, "top")) return crossOriginValue(frame, self.getTop(frame));
        if (std.mem.eql(u8, name, "opener")) return crossOriginValue(frame, self.getOpener(frame));
        if (std.mem.eql(u8, name, "parent")) return crossOriginValue(frame, self.getParent(frame));
        if (std.mem.eql(u8, name, "blur") or
            std.mem.eql(u8, name, "close") or
            std.mem.eql(u8, name, "focus") or
            std.mem.eql(u8, name, "postMessage"))
        {
            return crossOriginBackingMember(CrossOriginWindow, frame, name);
        }
        if (std.mem.eql(u8, name, "then")) return crossOriginValue(frame, js.Undefined{});
        return throwCrossOriginSecurityError(frame, "Window", name, .read);
    }

    fn namedSet(self: *CrossOriginWindow, name: []const u8, value: js.Value, frame: *Frame) !void {
        if (std.mem.eql(u8, name, "location")) return self.setLocation(value, frame);
        _ = try throwCrossOriginSecurityError(frame, "Window", name, .write);
    }

    fn namedDelete(_: *CrossOriginWindow, _: []const u8, frame: *Frame) !void {
        _ = try throwCrossOriginSecurityError(frame, "Window", null, .generic);
    }

    fn namedEnumerate(_: *CrossOriginWindow) []const []const u8 {
        return &.{};
    }

    fn namedQuery(_: *CrossOriginWindow, name: []const u8, frame: *Frame) !?u32 {
        // Allowed names already exist as real own properties on the instance
        // template.  Declining the query lets V8 use those exact descriptors;
        // claiming them here while the descriptor callback declined caused a
        // query/descriptor fallback loop in Object.getOwnPropertyDescriptor.
        if (isAllowedName(name)) return null;
        _ = try throwCrossOriginSecurityError(frame, "Window", null, .generic);
        return 0;
    }

    fn namedDescriptor(_: *CrossOriginWindow, name: []const u8, frame: *Frame) !js.Value {
        if (std.mem.eql(u8, name, "location")) {
            return crossOriginAccessorDescriptor(CrossOriginWindow, frame, "location", "location");
        }
        inline for (&.{ "window", "self", "closed", "frames", "length", "top", "opener", "parent" }) |accessor_name| {
            if (std.mem.eql(u8, name, accessor_name)) {
                return crossOriginAccessorDescriptor(CrossOriginWindow, frame, accessor_name, null);
            }
        }
        inline for (&.{ "blur", "close", "focus", "postMessage" }) |method_name| {
            if (std.mem.eql(u8, name, method_name)) {
                return crossOriginDataDescriptor(frame, try crossOriginBackingMember(CrossOriginWindow, frame, method_name));
            }
        }
        if (std.mem.eql(u8, name, "then")) return error.NotHandled;
        return throwCrossOriginSecurityError(frame, "Window", null, .generic);
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(CrossOriginWindow);

        pub const Meta = struct {
            pub const name = "CrossOriginWindow";
            pub const global_export = false;
            pub const own_properties = true;
            pub const cross_origin_surface = true;
            pub const members_also_on_hidden_prototype = true;
            pub const members_non_enumerable = true;
            pub const methods_readonly = true;
            pub const masking_named_interceptor = true;
            pub const null_prototype = true;
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        // Chrome 149 CrossOriginOwnPropertyHelper order. These are own,
        // non-enumerable, configurable properties; methods are non-writable.
        pub const window = bridge.accessor(CrossOriginWindow.getWindow, null, .{});
        pub const self = bridge.accessor(CrossOriginWindow.getWindow, null, .{});
        pub const location = bridge.accessor(CrossOriginWindow.getLocation, CrossOriginWindow.setLocation, .{});
        pub const closed = bridge.accessor(CrossOriginWindow.getClosed, null, .{});
        pub const frames = bridge.accessor(CrossOriginWindow.getWindow, null, .{});
        pub const length = bridge.accessor(CrossOriginWindow.getFramesLength, null, .{});
        pub const top = bridge.accessor(CrossOriginWindow.getTop, null, .{});
        pub const opener = bridge.accessor(CrossOriginWindow.getOpener, null, .{});
        pub const parent = bridge.accessor(CrossOriginWindow.getParent, null, .{});
        pub const blur = bridge.function(CrossOriginWindow.blur, .{});
        pub const close = bridge.function(CrossOriginWindow.close, .{});
        pub const focus = bridge.function(CrossOriginWindow.focus, .{});
        pub const postMessage = bridge.function(CrossOriginWindow.postMessage, .{});

        pub const index = bridge.indexedReadWrite(
            CrossOriginWindow.getFrame,
            CrossOriginWindow.setFrame,
            CrossOriginWindow.deleteFrame,
            CrossOriginWindow.queryFrame,
            CrossOriginWindow.enumerateFrames,
            .{ .null_as_undefined = true },
        );
        pub const named = bridge.namedIndexedFull(
            CrossOriginWindow.namedGet,
            CrossOriginWindow.namedSet,
            CrossOriginWindow.namedDelete,
            CrossOriginWindow.namedEnumerate,
            CrossOriginWindow.namedQuery,
            CrossOriginWindow.namedDelete,
            CrossOriginWindow.namedDescriptor,
            .{},
        );
    };
};

const CrossOriginLocation = struct {
    window: *Window,

    fn setHref(self: *CrossOriginLocation, value: js.Value, frame: *Frame) !void {
        const url = try crossOriginNavigationString(value);
        if (self.window._closed or self.window._frame.isRetired()) return;
        return frame.scheduleNavigation(
            url,
            .{ .reason = .script, .kind = .{ .push = null } },
            .{ .script = self.window._frame },
        );
    }

    fn replace(self: *CrossOriginLocation, value: js.Value, frame: *Frame) !void {
        const url = try crossOriginNavigationString(value);
        if (self.window._closed or self.window._frame.isRetired()) return;
        return frame.scheduleNavigation(
            url,
            .{ .reason = .script, .kind = .{ .replace = null } },
            .{ .script = self.window._frame },
        );
    }

    fn isAllowedName(name: []const u8) bool {
        return std.mem.eql(u8, name, "href") or
            std.mem.eql(u8, name, "replace") or
            std.mem.eql(u8, name, "then");
    }

    fn namedGet(_: *CrossOriginLocation, name: []const u8, frame: *Frame) !js.Value {
        if (std.mem.eql(u8, name, "replace")) {
            return crossOriginBackingMember(CrossOriginLocation, frame, name);
        }
        if (std.mem.eql(u8, name, "then")) return crossOriginValue(frame, js.Undefined{});
        return throwCrossOriginSecurityError(frame, "Location", name, .read);
    }

    fn namedSet(self: *CrossOriginLocation, name: []const u8, value: js.Value, frame: *Frame) !void {
        if (std.mem.eql(u8, name, "href")) return self.setHref(value, frame);
        _ = try throwCrossOriginSecurityError(frame, "Location", name, .write);
    }

    fn namedDelete(_: *CrossOriginLocation, _: []const u8, frame: *Frame) !void {
        _ = try throwCrossOriginSecurityError(frame, "Location", null, .generic);
    }

    fn namedEnumerate(_: *CrossOriginLocation) []const []const u8 {
        return &.{};
    }

    fn namedQuery(_: *CrossOriginLocation, name: []const u8, frame: *Frame) !?u32 {
        if (isAllowedName(name)) return null;
        _ = try throwCrossOriginSecurityError(frame, "Location", null, .generic);
        return 0;
    }

    fn namedDescriptor(_: *CrossOriginLocation, name: []const u8, frame: *Frame) !js.Value {
        if (std.mem.eql(u8, name, "href")) {
            return crossOriginAccessorDescriptor(CrossOriginLocation, frame, null, "href");
        }
        if (std.mem.eql(u8, name, "replace")) {
            return crossOriginDataDescriptor(frame, try crossOriginBackingMember(CrossOriginLocation, frame, "replace"));
        }
        if (std.mem.eql(u8, name, "then")) return error.NotHandled;
        return throwCrossOriginSecurityError(frame, "Location", null, .generic);
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(CrossOriginLocation);

        pub const Meta = struct {
            pub const name = "CrossOriginLocation";
            pub const global_export = false;
            pub const own_properties = true;
            pub const cross_origin_surface = true;
            pub const members_also_on_hidden_prototype = true;
            pub const members_non_enumerable = true;
            pub const methods_readonly = true;
            pub const masking_named_interceptor = true;
            pub const null_prototype = true;
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        // Cross-origin Location intentionally has a setter-only href own
        // accessor. Reads are rejected by the masking named interceptor.
        pub const href = bridge.accessor(null, CrossOriginLocation.setHref, .{});
        pub const replace = bridge.function(CrossOriginLocation.replace, .{});
        pub const named = bridge.namedIndexedFull(
            CrossOriginLocation.namedGet,
            CrossOriginLocation.namedSet,
            CrossOriginLocation.namedDelete,
            CrossOriginLocation.namedEnumerate,
            CrossOriginLocation.namedQuery,
            CrossOriginLocation.namedDelete,
            CrossOriginLocation.namedDescriptor,
            .{},
        );
    };
};

const testing = @import("../../testing.zig");
test "WebApi: Window" {
    try testing.htmlRunner("window", .{});
}

test "WebApi: Window iframe discard lifecycle" {
    try testing.htmlRunner("window/iframe_discard_lifecycle.html", .{ .timeout_ms = 8000 });
}

test "WebApi: Window scroll" {
    try testing.htmlRunner("window_scroll.html", .{});
}

test "WebApi: Window.onerror" {
    try testing.htmlRunner("event/report_error.html", .{});
}

test "WebApi: Chrome 149 Window uncaught script ErrorEvent" {
    try testing.htmlRunner("window/uncaught_script_error_chrome149.html", .{ .timeout_ms = 8000 });
}

test "WebApi: Chrome 149 cross-origin WindowProxy security boundary" {
    try testing.htmlRunner("window/cross_origin_security.html", .{ .timeout_ms = 8000 });
}

test "WebApi: Secure Context Window and Worker inheritance" {
    try testing.htmlRunner("secure_context.html", .{ .timeout_ms = 8000 });
}

test "WebApi: Secure Context simulated origins and ancestor chain" {
    const parent = try testing.createFrame();
    defer testing.test_session.closeAllPages();

    parent.url = "https://secure.example/";
    parent.origin = "https://secure.example";
    try testing.expect(parent.window.getIsSecureContext());

    parent.url = "http://127.0.0.1:8080/";
    parent.origin = "http://127.0.0.1:8080";
    try testing.expect(parent.window.getIsSecureContext());

    const child = try parent.arena.create(Frame);
    try Frame.init(
        child,
        testing.test_session.nextFrameId(),
        parent._page,
        .{ .parent = parent },
    );
    defer child.deinit();
    child.url = "https://child.example/";
    child.origin = "https://child.example";
    try testing.expect(child.window.getIsSecureContext());

    // A trustworthy child is not contextually secure below an insecure
    // ancestor, matching LocalDOMWindow::HasInsecureContextInAncestors().
    parent.url = "http://insecure.example/";
    parent.origin = "http://insecure.example";
    try testing.expect(!child.window.getIsSecureContext());
}
