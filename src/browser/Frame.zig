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
const builtin = @import("builtin");

const JS = @import("js/js.zig");
const Mime = @import("Mime.zig");
const Page = @import("Page.zig");
const Factory = @import("Factory.zig");
const Session = @import("Session.zig");
const EventManager = @import("EventManager.zig");
const ScriptManager = @import("ScriptManager.zig");
const StyleManager = @import("StyleManager.zig");

const Parser = @import("parser/Parser.zig");
const h5e = @import("parser/html5ever.zig");

const CustomElementReactions = @import("CustomElementReactions.zig");

const URL = @import("URL.zig");
const SecureContext = @import("SecureContext.zig");
const SandboxFlags = @import("SandboxFlags.zig");
const Blob = @import("webapi/Blob.zig");
const FileList = @import("webapi/FileList.zig");
const Node = @import("webapi/Node.zig");
const Event = @import("webapi/Event.zig");
const EventTarget = @import("webapi/EventTarget.zig");
const Element = @import("webapi/Element.zig");
const HtmlElement = @import("webapi/element/Html.zig");
const AnimatedString = @import("webapi/svg/AnimatedString.zig");
const Window = @import("webapi/Window.zig");
const Location = @import("webapi/Location.zig");
const Document = @import("webapi/Document.zig");
const ShadowRoot = @import("webapi/ShadowRoot.zig");
const Performance = @import("webapi/Performance.zig");
const Screen = @import("webapi/Screen.zig");
const VisualViewport = @import("webapi/VisualViewport.zig");
const AbstractRange = @import("webapi/AbstractRange.zig");
const Worker = @import("webapi/Worker.zig");
const CSSStyleSheet = @import("webapi/css/CSSStyleSheet.zig");
const CustomElementDefinition = @import("webapi/CustomElementDefinition.zig");
const PageTransitionEvent = @import("webapi/event/PageTransitionEvent.zig");
const SubmitEvent = @import("webapi/event/SubmitEvent.zig");
const HashChangeEvent = @import("webapi/event/HashChangeEvent.zig");
const popover = @import("webapi/element/popover.zig");
const slotting = @import("webapi/element/slotting.zig");
const History = @import("webapi/History.zig");
const NavigationAPI = @import("webapi/navigation/Navigation.zig");
const NavigationKind = @import("webapi/navigation/root.zig").NavigationKind;

const HttpClient = @import("HttpClient.zig");
const sys_url = @import("../sys/url.zig");

const timestamp = @import("../datetime.zig").timestamp;
const milliTimestamp = @import("../datetime.zig").milliTimestamp;

const GlobalEventHandlersLookup = @import("webapi/global_event_handlers.zig").Lookup;

pub const observers = @import("frame/observers.zig");
pub const user_input = @import("frame/user_input.zig");
pub const node_factory = @import("frame/node_factory.zig");

const log = lp.log;
const String = lp.String;
const IFrame = Element.Html.IFrame;
const Allocator = std.mem.Allocator;
const IS_DEBUG = builtin.mode == .Debug;

pub const BUF_SIZE = 1024;

const Frame = @This();

/// Session owns cookies/storage and a browsing-context group, but session
/// history belongs to an individual browsing context. This object therefore
/// outlives Document/Frame replacements and is explicitly carried across a
/// navigation of the same iframe, popup, or top-level page.
pub const NavigationContext = struct {
    history: History = .{},
    navigation: NavigationAPI = .{ ._proto = undefined },

    // V8's global proxy belongs to the browsing context, not to any one
    // inner Window.  Keep a dedicated, non-zero-sized identity cell here so
    // its address survives every cross-document Frame/Window replacement and
    // cannot alias the address of `history` (the first struct field).
    window_proxy_identity: struct { marker: u8 = 0 } = .{},

    pub fn windowProxyIdentityKey(self: *NavigationContext) usize {
        return @intFromPtr(&self.window_proxy_identity);
    }
};

// This is the "id" of the frame. It can be re-used from frame-to-frame, e.g.
// when navigating.
_frame_id: u32,

// This is the "id" of this specific instance of the frame. It changes on every
// navigate.
_loader_id: u32,

_page: *Page,

_session: *Session,

_navigation_context: *NavigationContext,

_event_manager: EventManager,

_parse_mode: enum { document, fragment, document_write } = .document,

// While fragment-parsing (e.g. innerHTML), scripts are normally marked
// "already started" so they never run. The one exception is
// Range.createContextualFragment(), whose scripts DO run when the fragment is
// inserted into a document
_fragment_scripts_runnable: bool = false,

// See Attribute.List for what this is. TL;DR: proper DOM Attribute Nodes are
// fat yet rarely needed. We only create them on-demand, but still need proper
// identity (a given attribute should return the same *Attribute), so we do
// a look here, keyed by (list, name). We don't store this in the Element or
// Attribute.List.Entry because that would require additional space per
// element / Attribute.List.Entry even though we'll create very few (if any)
// actual *Attributes.
_attribute_lookup: Element.Attribute.List.Lookup = .empty,

// Canonical pool for attribute names that aren't in String.intern's.
// Every Attribute's entry's name is either a String intern or held here.
// This is both a memory optimization (deduping attribute names) and a performance
// optimization (since we can compare strings by just their pointer)
_attribute_names: std.StringHashMapUnmanaged(void) = .empty,

// Same as _atlribute_lookup, but instead of individual attributes, this is for
// the return of elements.attributes.
_attribute_named_node_map_lookup: std.AutoHashMapUnmanaged(usize, *Element.Attribute.NamedNodeMap) = .empty,

// Lazily-created style, classList, and dataset objects. Only stored for elements
// that actually access these features via JavaScript, saving 24 bytes per element.
_element_styles: Element.StyleLookup = .empty,
_element_datasets: Element.DatasetLookup = .empty,
_element_class_lists: Element.ClassListLookup = .empty,
_element_rel_lists: Element.RelListLookup = .empty,
_element_shadow_roots: Element.ShadowRootLookup = .empty,
// A sheet candidate belongs to the TreeScope that contained its owner when it
// was registered. Keeping the root explicitly lets disconnect steps remove it
// after the DOM node has already been unlinked, matching Blink's use of the
// insertion-point TreeScope in StyleEngine::RemoveStyleSheetCandidateNode.
_style_sheet_roots: std.AutoHashMapUnmanaged(*CSSStyleSheet, *Node) = .empty,
_node_owner_documents: Node.OwnerDocumentLookup = .empty,
_element_scroll_positions: Element.ScrollPositionLookup = .empty,
_element_namespace_uris: Element.NamespaceUriLookup = .empty,
_svg_animated_strings: AnimatedString.Lookup = .empty,

// Same as above, but for Nodes (slot assigments apply to both Element AND
// Text nodes)
_assigned_slots: Node.AssignedSlotLookup = .empty,
_manual_slot_assignments: Node.AssignedSlotLookup = .empty,

/// Lazily-created inline event listeners (or listeners provided as attributes).
/// Avoids bloating all elements with extra function fields for rare usage.
///
/// Use this when a listener provided like this:
///
/// ```js
/// img.onload = () => { ... };
/// ```
///
/// Its also used as cache for such cases after lazy evaluation:
///
/// ```html
/// <img onload="(() => { ... })()" />
/// ```
///
/// ```js
/// img.setAttribute("onload", "(() => { ... })()");
/// ```
_event_target_attr_listeners: GlobalEventHandlersLookup = .empty,

// Blob URL registry for URL.createObjectURL/revokeObjectURL
_blob_urls: Blob.OwnedURLSet = .{},

// FileLists owned by `<input type=file>` elements. Each holds refs on its
// File objects (reference counted via their Blob proto); released at teardown.
_file_lists: std.ArrayList(*FileList) = .{},

/// Element `load`/`error` events queued to fire on the next scheduler tick,
/// and flushed before window's `load` event.
/// A call to `documentIsComplete` (which calls `_documentIsComplete`) resets it.
/// Double-buffered so that dispatching events (which may trigger JS that
/// creates new elements) doesn't invalidate the list while iterating.
_queued_events_1: std.ArrayList(QueuedEvent) = .{},
_queued_events_2: std.ArrayList(QueuedEvent) = .{},
_queued_events: *std.ArrayList(QueuedEvent) = undefined,

_style_manager: StyleManager,
_script_manager: ScriptManager,

_http_owner: HttpClient.Owner = .{},

// List of active live ranges (for mutation updates per DOM spec)
_live_ranges: std.DoublyLinkedList = .{},

// List of open BroadcastChannels, used to route postMessage between same-named
// channels in this frame's origin
_broadcast_channels: std.DoublyLinkedList = .{},

// MutationObserver / IntersectionObserver bookkeeping. See frame/observers.zig.
_mutation: observers.Mutation = .{},
_intersection: observers.Intersection = .{},

// Slots that need slotchange events to be fired, in signal order. Delivered
// by deliverMutations because there is specific timing with for these events
// with respect to mutations
_slots_pending_slotchange: std.AutoArrayHashMapUnmanaged(*Element.Html.Slot, void) = .{},

// Lookup for customized built-in elements. Maps element pointer to definition.
_customized_builtin_definitions: std.AutoHashMapUnmanaged(*Element, *CustomElementDefinition) = .{},
_customized_builtin_connected_callback_invoked: std.AutoHashMapUnmanaged(*Element, void) = .{},
_customized_builtin_disconnected_callback_invoked: std.AutoHashMapUnmanaged(*Element, void) = .{},

// This is set when an element is being upgraded (constructor is called).
// The constructor can access this to get the element being upgraded.
_upgrading_element: ?*Node = null,

// List of custom elements that were created before their definition was registered
_undefined_custom_elements: std.ArrayList(*Element.Html.Custom) = .{},

// Pending custom-element reactions (connected/disconnected/adopted/attribute
// changed). Reactions are enqueued during DOM mutation and drained at the
// outer algorithm boundary — set up by the JS bridge for [CEReactions]
// methods and by the parser pump on each yield.
_ce_reactions: CustomElementReactions,

// for heap allocations and managing WebAPI objects
_factory: *Factory,

_load_state: LoadState = .waiting,

_parse_state: ParseState = .pre,

/// `frameErrorCallback` swallows the failure into a placeholder page;
/// callers that need to detect it read this.
_last_navigate_error: ?anyerror = null,

// Browser-owned pointer state spanning separate CDP/FFI input commands. The
// hover pointer is Page-lifetime-safe and is cleared before Frame teardown;
// press state stores only integer addresses so an event-loop turn never leaves
// an owning DOM pointer in foreign-call state.
_native_pointer_state: user_input.PointerState = .{},
_native_primary_press_state: ?user_input.ClickSequenceState = null,

// User Activation v2 state belongs to the current Document. Only the
// browser-owned input path updates it; script-dispatched events remain inert.
_sticky_user_activation: bool = false,
_last_user_activation_ms: ?u64 = null,

// Sandboxing is a committed Document policy, not a live view of the owner
// iframe's attribute. The frame-policy mask is captured only when a
// cross-document navigation creates this Frame. CSP is kept separate because
// popup escape and local-document policy inheritance treat the two sources
// differently in Chromium's PolicyContainerBuilder.
_effective_frame_sandbox_flags: SandboxFlags.Mask = SandboxFlags.none,
_csp_sandbox_flags: SandboxFlags.Mask = SandboxFlags.none,
_can_navigate_top_without_user_gesture: bool = true,

// A navigated-away or discarded inner realm remains allocated until Page
// teardown so closures and detached DOM wrappers keep their original
// Context/Frame owner. It is no longer part of the active browsing-context
// tree and all producers of future work have been stopped by retire().  Keep
// the terminal mode separately: a navigation retirement can be upgraded to a
// discard by a re-entrant owner removal, which must close the Window and clear
// the exact iframe owner without running shutdown twice.
_retired: bool = false,
_retired_for_discard: bool = false,
// Synchronous page-unloading callbacks run while the browsing context is
// still usable. Keep this distinct from `_retired`: Web APIs such as Storage
// and timers must remain available during pagehide, while producers of new
// document work use isGoingAway() to avoid extending the dying document.
// Re-entrant owner removal can upgrade navigation to discard before the
// terminal shutdown below begins.
_retire_in_progress: ?RetireMode = null,
// Page teardown derives a single ownership forest, but keep deinit idempotent
// as the final native safety boundary against an unexpected overlapping root.
_deinitialized: bool = false,

_notified_network_idle: IdleNotification = .init,
_notified_network_almost_idle: IdleNotification = .init,

// A navigation event that happens from a script gets scheduled to run on the
// next tick.
_queued_navigation: ?*QueuedNavigation = null,

// The URL of the current frame
url: [:0]const u8 = "about:blank",

origin: ?[]const u8 = null,

// The base url specifies the base URL used to resolve the relative urls.
// It is set by a <base> tag.
// If null the url must be used.
base_url: ?[:0]const u8 = null,

// referer header cache.
referer_header: ?[:0]const u8 = null,

// Document charset (canonical name from encoding_rs, static lifetime)
charset: []const u8 = "UTF-8",

// Arbitrary buffer. Need to temporarily lowercase a value? Use this. No lifetime
// guarantee - it's valid until someone else uses it.
buf: [BUF_SIZE]u8 = undefined,

// access to the JavaScript engine
js: *JS.Context,

// An arena for the lifetime of the frame.
arena: Allocator,

// An arena with a lifetime for at least the scope of one Zig invocation from
// JS. Prefer local_arena where possible. Use call_arena when allocations may
// need to call back into JS (event dispatch, forEach callback, ....)
call_arena: Allocator,

// An arena with a lifetime guaranteed to be for exactly 1 invoking of a Zig
// function from JS. Best arena to use, when possible.
local_arena: Allocator,

parent: ?*Frame,
window: *Window,
document: *Document,
iframe: ?*IFrame = null,

child_frames: std.ArrayList(*Frame) = .{},
// Blink captures a child Frame's TreeScope when the browsing context is
// created.  Window's indexed getter only exposes document-scoped children;
// the raw FrameTree (and CDP) still contains shadow-scoped children.  This
// value deliberately does not follow later state-preserving DOM moves.
scoped_for_window: bool = true,
// Initial child navigation can synchronously execute script in the child and
// re-enter the parent through DOM mutations.  Track every structural change so
// callers never reuse an index or ordering assumption across that boundary.
child_frames_mutation_serial: u64 = 0,

// Workers created by this frame. Cleaned up when frame is destroyed.
workers: std.ArrayList(*Worker) = .{},

// This is maybe not great. It's a counter on the number of events that we're
// waiting on before triggering the "load" event. Essentially, we need all
// synchronous scripts and all iframes to be loaded. Scripts are handled by the
// ScriptManager, so all scripts just count as 1 pending load.
_pending_loads: u32,

// Ordinary connected-to-connected moves discard and recreate descendant
// browsing contexts. Do not let the removal half complete the parent document
// in the short gap before the insertion half has registered replacements.
_reconnect_load_guard_depth: u32 = 0,
_reconnect_load_completion_deferred: bool = false,

_parent_notified: bool = false,

// whether our parent's load event is waiting for us to load. For a root page,
// this is meaningless. For an iframe, it's false when loading=lazy. We'll still
// load the iframe, but we won't delay the parent
_delays_parent_load: bool = true,

_type: enum { root, frame }, // only used for logs right now
_req_id: u32 = 0,
_navigated_options: ?NavigatedOpts = null,
_http_status: ?u16 = null,
_http_headers: std.ArrayList(HttpHeader) = .empty,

pub const HttpHeader = struct {
    name: []const u8,
    value: []const u8,
};

pub const InitOpts = struct {
    parent: ?*Frame = null,
    opener: ?*Window = null,
    navigation_context: ?*NavigationContext = null,
    effective_frame_sandbox_flags: SandboxFlags.Mask = SandboxFlags.none,
    csp_sandbox_flags: SandboxFlags.Mask = SandboxFlags.none,
    scoped_for_window: bool = true,
};

pub fn init(self: *Frame, frame_id: u32, page: *Page, opts: InitOpts) !void {
    if (comptime IS_DEBUG) {
        log.debug(.frame, "frame.init", .{});
    }

    const parent = opts.parent;

    const session = page.session;
    const navigation_context = opts.navigation_context orelse blk: {
        const context = try session.arena.create(NavigationContext);
        context.* = .{};
        break :blk context;
    };
    const call_arena = try session.getArena(.medium, "call_arena");
    errdefer session.releaseArena(call_arena);

    const local_arena = try session.getArena(.medium, "local_arena");
    errdefer session.releaseArena(local_arena);

    const factory = &page.factory;
    const document = (try factory.document(Node.Document.HTMLDocument{
        ._proto = undefined,
    })).asDocument();

    const arena = page.frame_arena;

    self.* = .{
        .js = undefined,
        .arena = arena,
        .parent = parent,
        .document = document,
        .window = undefined,
        .call_arena = call_arena,
        .local_arena = local_arena,
        ._frame_id = frame_id,
        ._page = page,
        ._session = session,
        ._navigation_context = navigation_context,
        ._effective_frame_sandbox_flags = opts.effective_frame_sandbox_flags,
        ._csp_sandbox_flags = opts.csp_sandbox_flags,
        .scoped_for_window = opts.scoped_for_window,
        ._loader_id = session.nextLoaderId(),
        ._factory = factory,
        ._pending_loads = 1, // always 1 for the ScriptManager
        ._type = if (parent == null) .root else .frame,
        ._style_manager = undefined,
        ._script_manager = undefined,
        ._ce_reactions = .{ .allocator = arena },
        ._event_manager = EventManager.init(arena, self),
    };
    self._queued_events = &self._queued_events_1;
    self._http_owner.blob_urls = &page.blob_url_registry;
    self._http_owner.blob_releaser = .{ .ctx = page, .run = Page.releaseHttpBlob };

    var screen: *Screen = undefined;
    var visual_viewport: *VisualViewport = undefined;
    if (parent) |p| {
        screen = p.window._screen;
        visual_viewport = p.window._visual_viewport;
    } else {
        screen = try factory.eventTarget(Screen{
            ._proto = undefined,
            ._orientation = null,
        });
        visual_viewport = try factory.eventTarget(VisualViewport{
            ._proto = undefined,
        });
    }

    const window_template = Window{
        ._frame = self,
        ._proto = undefined,
        ._document = self.document,
        ._location = undefined,
        ._performance = .init(),
        ._screen = screen,
        ._visual_viewport = visual_viewport,
        ._cross_origin_wrapper = undefined,
    };

    // Every cross-document commit gets a fresh inner Window. JavaScript sees
    // the stable outer WindowProxy because Env keys/reuses that proxy by the
    // NavigationContext identity cell above, never by this Window address.
    self.window = try factory.eventTarget(window_template);
    // Performance is embedded in Window. Attach its EventTarget root only now,
    // after the containing object has reached its final stable address and
    // before createContext can expose/map it into V8.
    self.window._performance._proto = try factory.standaloneEventTarget(&self.window._performance);
    self.window._opener = opts.opener;
    self.window._cross_origin_wrapper = .{ .window = self.window };

    // Non-root browsing contexts are activated immediately. Root contexts are
    // activated by Session only when they become the live page; a provisional
    // root must not replace the active Navigation EventTarget before commit.
    if (self != &page.frame) {
        try self.activateNavigationContext();
    }

    self._style_manager = try StyleManager.init(self);
    errdefer self._style_manager.deinit();

    const browser = session.browser;
    self._script_manager = ScriptManager.init(browser.allocator, &browser.http_client, self);
    errdefer self._script_manager.deinit();

    self.js = try browser.env.createContext(self, .{
        .identity = &page.identity,
        .identity_arena = arena,
        .call_arena = self.call_arena,
        .local_arena = self.local_arena,
    });
    errdefer browser.env.destroyContext(self.js);

    // A newly-created child/popup exposes its initial about:blank Window
    // synchronously, before any queued navigation commit. Give that initial
    // realm the creator's exact Origin/security token immediately; navigate()
    // will reaffirm or replace it when the requested URL commits.
    if (parent) |creator| {
        try self.js.inheritOrigin(creator.js);
    } else if (opts.opener) |opener| {
        try self.js.inheritOrigin(opener._frame.js);
    }
    if (SandboxFlags.contains(self.activeSandboxFlags(), SandboxFlags.origin)) {
        // A sandboxed-origin Document receives a fresh opaque SecurityOrigin,
        // even for its initial about:blank realm. Keep Frame.origin as the URL
        // origin/opaque precursor (location.origin still exposes the URL tuple
        // for sandboxed HTTP); only the Document security identity is opaque.
        try self.js.setOriginKey(null);
    }
    try self.snapshotDocumentSecurityOrigin();
    try self.snapshotDocumentStorageOrigin(null);
    self.updateCanNavigateTopPolicy();

    document._frame = self;
    document._owner_frame = self;
    try self.materializeDocumentInOwnerRealm(document);

    const location = try Location.init("about:blank", self);
    // We're holding a reference in Zig-side.
    location.acquireRef();
    self.window._location = location;
    try self.materializeLocationInOwnerRealm(location);

    if (comptime builtin.is_test == false) {
        if (parent == null) {
            // HTML test runner manually calls these as necessary
            try self.js.scheduler.add(session.browser, struct {
                fn runIdleTasks(ctx: *anyopaque) !?u32 {
                    const b: *@import("Browser.zig") = @ptrCast(@alignCast(ctx));
                    b.runIdleTasks();
                    return 200;
                }
            }.runIdleTasks, 200, .{ .name = "frame.runIdleTasks", .low_priority = true });
        }
    }
}

// Document wrappers carry their creation Context's prototype/constructor
// identity. If the parent is the first realm to read iframe.document, mapping
// lazily there makes createElement() results fail the child realm's instanceof
// checks. Materialize the Document in its own Context before exposing it.
fn materializeDocumentInOwnerRealm(self: *Frame, document: *Document) !void {
    var ls: JS.Local.Scope = undefined;
    self.js.localScope(&ls);
    defer ls.deinit();
    _ = try ls.local.mapZigInstanceToJs(null, document);
}

// A cross-origin caller may be the first script to ask for target.location.
// Materializing the wrapper in that caller's Context would give the object the
// caller's creation context/security token and V8 would fast-path around the
// Location access check.  Register every new Location in its owner realm as
// part of commit instead.
fn materializeLocationInOwnerRealm(self: *Frame, location: *Location) !void {
    var ls: JS.Local.Scope = undefined;
    self.js.localScope(&ls);
    defer ls.deinit();
    _ = try ls.local.mapZigInstanceToJs(null, location);
}

fn detachDocumentOwner(self: *Frame) void {
    const document = self.window._document;
    document._url = self.url;
    document._frame = null;
}

const RetireMode = enum {
    // The browsing context survives a cross-document navigation. V8 must
    // detach the old inner global so its outer WindowProxy can be reattached
    // to the replacement Context.
    navigation,
    // The browsing context itself is discarded (iframe removal, or a child of
    // a navigating Document). Blink's ClearForClose deliberately leaves the
    // old global attached so cached Window/Location/DOM wrappers remain usable.
    discard,
};

fn mergeRetireMode(current: RetireMode, requested: RetireMode) RetireMode {
    if (current == .discard or requested == .discard) return .discard;
    return .navigation;
}

fn retireChildrenForDiscard(self: *Frame) void {
    // pagehide handlers can synchronously remove/move this or a later sibling.
    // Never walk the live FrameTree storage across a JavaScript boundary.
    const children = self.call_arena.dupe(*Frame, self.child_frames.items) catch
        @panic("OOM while snapshotting child frames for retirement");
    for (children) |child| {
        if (child.parent != self) continue;
        if (std.mem.indexOfScalar(*Frame, self.child_frames.items, child) == null) continue;
        child.retire(.discard);
    }
}

/// Stops an inner realm without destroying the native Frame, its V8 Context,
/// or either scratch arena. Those objects can still be reached by functions
/// and DOM wrappers created in the old realm. Page.retired_frames becomes their
/// sole owner and calls deinit at Page teardown, after no replacement can reuse
/// any of these native addresses.
fn applyDiscardRetirement(self: *Frame) void {
    if (self._retired_for_discard) return;
    self._retired_for_discard = true;
    self.window._closed = true;

    // A navigated-away inner Window can be upgraded to discard after a fresh
    // inner Window has already been published into the same iframe. Never let
    // that stale realm clear the replacement browsing context.
    if (self.iframe) |owner| {
        if (owner._window == self.window) {
            owner._window = null;
            owner._executed = false;
        }
    }

    // Descendants are owned by this retired Frame and are discarded with its
    // browsing context. This is idempotent and also upgrades descendants which
    // were first reached through a navigation-retirement path.
    self.retireChildrenForDiscard();
}

fn dispatchPageHide(self: *Frame) void {
    const target = self.window.asEventTarget();
    const handler = self.window._on_pagehide;
    if (!self._event_manager.hasDirectListeners(target, "pagehide", handler)) return;

    const event = PageTransitionEvent.initTrusted(comptime .wrap("pagehide"), .{
        .persisted = false,
        // Native pagehide uses the legacy Window-event flags; constructing a
        // PageTransitionEvent from JS still keeps the Web IDL defaults false.
        .bubbles = true,
        .cancelable = true,
    }, self) catch |err| {
        log.err(.frame, "pagehide event creation failed", .{ .url = self.url, .err = err });
        return;
    };
    const base_event = event.asEvent();
    // Blink's LocalDOMWindow dispatch uses the Document as the legacy event
    // target while Window remains currentTarget/AT_TARGET.
    base_event._target = self.document.asEventTarget();
    base_event._dispatch_target = base_event._target;
    self._event_manager.dispatchDirect(target, event.asEvent(), handler, .{
        .context = "page hide",
        .inject_target = false,
        // pagehide, visibilitychange and unload form one synchronous dismissal
        // cluster. Chromium performs the microtask checkpoint only after that
        // cluster and the caller's remove()/close()/navigation stack unwind.
        .microtask_checkpoint = false,
    }) catch |err| {
        log.err(.frame, "pagehide dispatch failed", .{ .url = self.url, .err = err });
    };
}

fn dispatchVisibilityChange(self: *Frame) void {
    const document = self.document;
    document._lifecycle_hidden = true;

    const event_type = String.init(self.call_arena, "visibilitychange", .{}) catch |err| {
        log.err(.frame, "visibilitychange event type creation failed", .{ .url = self.url, .err = err });
        return;
    };
    const event = Event.initTrusted(event_type, .{ .bubbles = true }, self._page) catch |err| {
        log.err(.frame, "visibilitychange event creation failed", .{ .url = self.url, .err = err });
        return;
    };
    self._event_manager.dispatchOpts(document.asEventTarget(), event, .{
        .microtask_checkpoint = false,
    }) catch |err| {
        log.err(.frame, "visibilitychange dispatch failed", .{ .url = self.url, .err = err });
    };
}

fn dispatchUnload(self: *Frame) void {
    const target = self.window.asEventTarget();
    const handler = self.window._on_unload;
    if (!self._event_manager.hasDirectListeners(target, "unload", handler)) return;

    const event = Event.initTrusted(comptime .wrap("unload"), null, self._page) catch |err| {
        log.err(.frame, "unload event creation failed", .{ .url = self.url, .err = err });
        return;
    };
    event._target = self.document.asEventTarget();
    event._dispatch_target = event._target;
    self._event_manager.dispatchDirect(target, event, handler, .{
        .context = "unload",
        .inject_target = false,
        .microtask_checkpoint = false,
    }) catch |err| {
        log.err(.frame, "unload dispatch failed", .{ .url = self.url, .err = err });
    };
}

fn dispatchDismissalEvents(self: *Frame) void {
    // popup.close() publishes closed=true first and, in Chromium, hides the
    // Document before pagehide. Navigation and iframe removal dispatch
    // pagehide while still visible, then visibilitychange. unload is last.
    if (self.window._closed) {
        self.dispatchVisibilityChange();
        self.dispatchPageHide();
    } else {
        self.dispatchPageHide();
        self.dispatchVisibilityChange();
    }
    self.dispatchUnload();
}

fn retire(self: *Frame, mode: RetireMode) void {
    if (self._retired) {
        if (mode == .discard) self.applyDiscardRetirement();
        return;
    }

    if (self._retire_in_progress) |current| {
        self._retire_in_progress = mergeRetireMode(current, mode);
        return;
    }
    self._retire_in_progress = mode;

    // HTML's page-unloading steps dispatch pagehide on the old Window before
    // its global is detached and before its task queues are stopped. The
    // separate in-progress state blocks new document work without making
    // synchronous Window/Storage/timer APIs observe a detached context.
    self.dispatchDismissalEvents();

    // A pagehide callback can synchronously remove the iframe whose navigation
    // first entered this function. Discard is the terminally stronger mode.
    const terminal_mode = self._retire_in_progress.?;
    self._retire_in_progress = null;
    self._retired = true;

    // Stop cross-thread realm deliveries at the first retirement boundary,
    // before IDB detaches, Scheduler stops, or navigation detaches V8 state.
    self.js.closeOwnerTarget();

    // ClearForClose leaves the old realm alive, but the browsing context no
    // longer exists. Make that state intrinsic to the discard transition so
    // descendants discarded by a parent navigation cannot remain observably
    // open merely because they did not pass through iframeRemovedCallback.
    if (terminal_mode == .discard) self.applyDiscardRetirement();

    // Descendant browsing contexts are closed when their owner Document goes
    // away. Chromium sends them through ClearForClose, not the parent's
    // ClearForNavigation path, so their globals remain attached too.
    if (terminal_mode == .navigation) {
        self.retireChildrenForDiscard();
    }

    self.navigation().onRemoveFrame();
    if (terminal_mode == .navigation) {
        // Unlike ClearForClose, navigation detaches this Context's global.
        // Materialize the old realm's replacement list before that boundary;
        // discard can follow Blink's lazy detached getter path exactly.
        self.window._location.prepareForDocumentDetach(&self.js.execution) catch |err| {
            log.err(.frame, "detached Location ancestorOrigins preparation failed", .{ .url = self.url, .err = err });
        };
        self.js.detachGlobal();
    }
    self.detachDocumentOwner();

    if (self.window._cookie_store) |cookie_store| cookie_store.detach();

    // A child may have queued a navigation in either Page double-buffer. The
    // list can keep the stable old pointer until its current pass ends; nulling
    // the payload makes that entry a no-op and we release its arena exactly
    // once here.
    if (self._queued_navigation) |queued| {
        self._queued_navigation = null;
        self._page.releaseArena(queued.arena);
    }

    self._parse_state.deinit(self);
    self._parse_state = .complete;

    self._script_manager.base.shutdown = true;
    self._session.idb.detachContext(self.js);
    self.js.scheduler.stop();

    // Abort only this Frame here; descendants did the same recursively above.
    const http_client = &self._session.browser.http_client;
    http_client.retireOwner(&self._http_owner);
    http_client.deferring_layer.cancelOwner(&self._http_owner);
    self._script_manager.reset();
    // Abort/shutdown callbacks are allowed to finalize pending work. Drop any
    // task they queued while unwinding so this retired Context stays inert.
    self.js.scheduler.stop();

    // Dedicated worker isolates/threads must not survive their active
    // Document, but their creator-side JS wrappers can. Retain the Worker
    // structs/arenas until Frame.deinit so cached references never dangle.
    for (self.workers.items) |worker| worker.shutdown();
}

pub fn retireForNavigation(self: *Frame) void {
    self.retire(.navigation);
}

pub fn retireForDiscard(self: *Frame) void {
    self.retire(.discard);
}

pub fn deinit(self: *Frame) void {
    if (self._deinitialized) return;
    self._deinitialized = true;

    for (self.child_frames.items) |frame| {
        frame.deinit();
    }

    if (comptime IS_DEBUG) {
        log.debug(.frame, "frame.deinit", .{ .url = self.url, .type = self._type });

        // Uncomment if you want slab statistics to print.
        // const stats = self._factory._slab.getStats(self.arena) catch unreachable;
        // var buffer: [256]u8 = undefined;
        // var stream = std.fs.File.stderr().writer(&buffer).interface;
        // stats.print(&stream) catch unreachable;
    }

    self._parse_state.deinit(self);

    // Unregister CookieStore from session notifications before the JS
    // context (and thus the scheduler) is destroyed, otherwise a late
    // mutation could schedule a callback that never runs.
    if (self.window._cookie_store) |cs| cs.detach();

    const page = self._page;

    if (self._queued_navigation) |qn| {
        page.releaseArena(qn.arena);
    }

    {
        // Release all objects we're referencing
        page.releaseOwnedBlobURLs(&self._blob_urls);

        for (self._file_lists.items) |file_list| {
            for (file_list._files) |file| {
                file._proto.releaseRef(page);
            }
        }

        observers.deinit(self, page);

        const document = self.window._document;
        document._selection.releaseRef(page);

        if (document._fonts) |f| {
            f.releaseRef(page);
        }

        // A navigated-away Document remains reachable through script-held
        // wrappers, but it is no longer associated with this browsing
        // context. Snapshot before final teardown as well; this is idempotent
        // for Frames already detached by either retirement path.
        self.detachDocumentOwner();

        // Release our reference to location.
        self.window._location.releaseRef(page);
    }

    const browser = page.session.browser;

    browser.http_client.abortOwner(&self._http_owner);
    // A completed request can still be buffered by DeferringLayer after its
    // Transfer has left this owner. Retire normally reaches this earlier;
    // keep final deinit idempotently closing the same cleanup-only lifetime.
    browser.http_client.deferring_layer.cancelOwner(&self._http_owner);

    // DedicatedWorkers may still be executing against immutable creator
    // settings. Stop and join them before destroying the creator Context or
    // any Page-owned data reachable from worker-compatible APIs.
    for (self.workers.items) |worker| {
        worker.deinit();
    }

    browser.env.destroyContext(self.js);

    self._script_manager.base.shutdown = true;

    self._script_manager.deinit();
    self._style_manager.deinit();

    page.releaseArena(self.call_arena);
    page.releaseArena(self.local_arena);
}

pub fn trackWorker(self: *Frame, worker: *Worker) !void {
    try self.workers.append(self.arena, worker);
}

pub fn removeWorker(self: *Frame, worker: *Worker) void {
    for (self.workers.items, 0..) |w, i| {
        if (w == worker) {
            _ = self.workers.swapRemove(i);
            break;
        }
    }
}

pub fn drainWorkerMessages(self: *Frame) !void {
    for (self.workers.items) |worker| try worker.drainOutbound();
    for (self.child_frames.items) |child| try child.drainWorkerMessages();
}

pub fn routeBroadcastToWorkers(
    self: *Frame,
    message: *JS.Value.BroadcastMessage,
    excluded: ?*anyopaque,
) void {
    for (self.workers.items) |worker| {
        if (excluded) |source| {
            if (source == @as(*anyopaque, @ptrCast(worker))) continue;
        }
        worker.enqueueBroadcast(message);
    }
    for (self.child_frames.items) |child| {
        child.routeBroadcastToWorkers(message, excluded);
    }
}

pub fn hasWorkerMessages(self: *Frame) bool {
    for (self.workers.items) |worker| {
        if (worker.hasOutbound()) return true;
    }
    for (self.child_frames.items) |child| {
        if (child.hasWorkerMessages()) return true;
    }
    return false;
}

pub fn hasWorkerActivity(self: *Frame) bool {
    for (self.workers.items) |worker| {
        if (worker.hasCreatorActivity()) return true;
    }
    for (self.child_frames.items) |child| {
        if (child.hasWorkerActivity()) return true;
    }
    return false;
}

pub fn base(self: *const Frame) [:0]const u8 {
    return self.base_url orelse self.url;
}

pub fn requestOrigin(self: *const Frame) HttpClient.RequestOrigin {
    // document.domain changes DOM access checks, not the serialized network
    // request origin. Frame.origin retains the committed URL's original
    // scheme/host/port tuple.
    return HttpClient.requestOriginFromRelaxableSecurityKey(self.js.origin.key, self.origin);
}

pub fn outgoingReferrerUrl(self: *const Frame) ?[]const u8 {
    return self.outgoingReferrerSource();
}

pub fn snapshotSiteForCookies(self: *const Frame, allocator: Allocator) !HttpClient.SiteForCookies {
    var top = self;
    while (top.parent) |parent| top = parent;

    const top_tuple = switch (top.requestOrigin()) {
        .tuple => |origin| origin,
        else => return .null_site,
    };
    const top_site = (try HttpClient.obtainSchemefulSite(allocator, top_tuple)) orelse
        return .null_site;

    // Document::SiteForCookies becomes null when any frame from creator to
    // top is not schemefully same-site with the top frame. This preserves the
    // A -> B -> A rule: the innermost A is still a cross-site cookie context.
    var current: ?*const Frame = self;
    while (current) |frame| : (current = frame.parent) {
        const tuple = switch (frame.requestOrigin()) {
            .tuple => |origin| origin,
            else => return .null_site,
        };
        const site = (try HttpClient.obtainSchemefulSite(allocator, tuple)) orelse
            return .null_site;
        if (!std.mem.eql(u8, top_site, site)) return .null_site;
    }
    return .{ .schemeful_site = top_site };
}

pub fn siteForCookies(self: *const Frame) HttpClient.SiteForCookies {
    return self.snapshotSiteForCookies(self.call_arena) catch .null_site;
}

pub fn history(self: *Frame) *History {
    return &self._navigation_context.history;
}

pub fn navigation(self: *Frame) *NavigationAPI {
    return &self._navigation_context.navigation;
}

pub fn activateNavigationContext(self: *Frame) !void {
    self._navigation_context.history._owner = self;
    try self._navigation_context.navigation.onNewFrame(self);
}

pub fn getTitle(self: *Frame) !?[]const u8 {
    if (self.window._document.is(Document.HTMLDocument)) |html_doc| {
        return try html_doc.getTitle(self);
    }
    return null;
}

pub const HttpMetadata = struct {
    url: [:0]const u8,
    status: ?u16,
    headers: []const HttpHeader,
};

pub fn httpMetadata(self: *const Frame) HttpMetadata {
    return .{
        .url = self.url,
        .status = self._http_status,
        .headers = self._http_headers.items,
    };
}

// Add common headers for a request:
// * referer
pub fn headersForRequest(self: *Frame, headers: *HttpClient.Headers) !void {
    // Build the referer
    const referer = blk: {
        if (self.referer_header == null) {
            // build the cache
            if (std.mem.startsWith(u8, self.url, "http")) {
                self.referer_header = try std.mem.concatWithSentinel(self.arena, u8, &.{ "Referer: ", self.url }, 0);
            } else {
                self.referer_header = "";
            }
        }

        break :blk self.referer_header.?;
    };

    // If the referer is empty, ignore the header.
    if (referer.len > 0) {
        try headers.add(referer);
    }
}

pub fn getArena(self: *Frame, size_or_bucket: anytype, debug: []const u8) !Allocator {
    return self._session.getArena(size_or_bucket, debug);
}

pub fn releaseArena(self: *Frame, allocator: Allocator) void {
    return self._session.releaseArena(allocator);
}

/// Preserve the current effective scripting origin on the Document itself.
/// The Page arena outlives every iframe navigation, so detached wrappers never
/// borrow the ref-counted js.Origin key that Context teardown releases.
pub fn snapshotDocumentSecurityOrigin(self: *Frame) !void {
    self.document._security_origin_key = try self.arena.dupe(u8, self.js.origin.key);
}

/// Preserve the storage origin independently from the effective scripting
/// origin. An explicit inherited key is captured by the navigation initiator;
/// otherwise tuple documents use Frame.origin and initial about:blank
/// Documents inherit their creator's already-frozen storage origin.
fn snapshotDocumentStorageOrigin(self: *Frame, inherited_key: ?[]const u8) !void {
    const key: []const u8 = inherited_key orelse
        self.origin orelse
        if (self.parent) |parent|
            parent.document._storage_origin_key
        else if (self.window._opener) |opener|
            opener._document._storage_origin_key
        else
            self.js.origin.key;
    self.document._storage_origin_key = try self.arena.dupe(u8, key);
}

pub fn isSameOrigin(self: *const Frame, url: [:0]const u8) bool {
    return isSameOriginKey(self.call_arena, self.js.origin.key, url);
}

fn isSameOriginKey(allocator: Allocator, current_origin: []const u8, url: [:0]const u8) bool {
    const parsed = URL.getOrigin(allocator, url) catch return false;
    const origin = parsed orelse return false;
    return std.mem.eql(u8, current_origin, origin);
}

pub fn notifyUserActivation(self: *Frame) void {
    const now = milliTimestamp(.monotonic);
    var current: ?*Frame = self;
    while (current) |frame| : (current = frame.parent) {
        frame._sticky_user_activation = true;
        frame._last_user_activation_ms = now;
    }
}

pub fn hasStickyUserActivation(self: *const Frame) bool {
    return self._sticky_user_activation;
}

pub fn hasTransientUserActivation(self: *const Frame) bool {
    const activated = self._last_user_activation_ms orelse return false;
    const now = milliTimestamp(.monotonic);
    return now >= activated and now - activated <= 5_000;
}

pub fn topFrame(self: *Frame) *Frame {
    var top = self;
    while (top.parent) |parent| top = parent;
    return top;
}

/// Web IDL's [CheckSecurity=ReturnValue] compares the current caller realm
/// with the realm which owns the returned DOM object.  Keep that comparison
/// on the effective scripting origin so document.domain and opaque-origin
/// identity follow the same security token used by WindowProxy.
pub fn sameEffectiveOrigin(first: *const Frame, second: *const Frame) bool {
    return first.js.origin == second.js.origin or
        std.mem.eql(u8, first.js.origin.key, second.js.origin.key);
}

fn updateCanNavigateTopPolicy(self: *Frame) void {
    const parent = self.parent orelse {
        self._can_navigate_top_without_user_gesture = true;
        return;
    };

    const top = self.topFrame();
    if (sameEffectiveOrigin(self, top)) {
        self._can_navigate_top_without_user_gesture = true;
        return;
    }

    // Chrome's PolicyContainer inherits an ancestor's denial. A cross-origin
    // child may preserve (but never elevate) that value only when its committed
    // frame policy explicitly cleared kTopNavigation via
    // allow-top-navigation.
    const explicitly_allows_top = self._effective_frame_sandbox_flags != SandboxFlags.none and
        !SandboxFlags.contains(self._effective_frame_sandbox_flags, SandboxFlags.top_navigation);
    self._can_navigate_top_without_user_gesture =
        parent._can_navigate_top_without_user_gesture and explicitly_allows_top;
}

fn canAccessAncestor(self: *const Frame, target: ?*const Frame) bool {
    var ancestor = target;
    while (ancestor) |frame| : (ancestor = frame.parent) {
        if (sameEffectiveOrigin(self, frame)) return true;
    }
    return false;
}

fn isDescendantOf(frame: *const Frame, ancestor: *const Frame) bool {
    var current = frame.parent;
    while (current) |parent| : (current = parent.parent) {
        if (parent == ancestor) return true;
    }
    return false;
}

pub fn activeSandboxFlags(self: *const Frame) SandboxFlags.Mask {
    return self._effective_frame_sandbox_flags | self._csp_sandbox_flags;
}

/// Computes the browser-side pending frame policy for a future child
/// Document. Mutating the iframe attribute changes this value, but the
/// current child's activeSandboxFlags remain untouched until a real
/// cross-document commit captures it.
pub fn pendingSandboxFlagsForChild(parent_frame: *const Frame, owner: *IFrame) SandboxFlags.Mask {
    const declared = SandboxFlags.parseAttribute(
        owner.asElement().getAttributeSafe(comptime .wrap("sandbox")),
    );
    return parent_frame.activeSandboxFlags() | declared;
}

fn destinationMatchesOrigin(self: *const Frame, target: *const Frame, destination: [:0]const u8) bool {
    const parsed = URL.getOrigin(self.call_arena, destination) catch return false;
    const origin = parsed orelse return false;
    return std.mem.eql(u8, target.js.origin.key, origin);
}

fn destinationMatchesTopSite(target: *const Frame, destination: [:0]const u8) bool {
    const target_origin = target.js.origin.key;
    const target_colon = std.mem.indexOfScalar(u8, target_origin, ':') orelse return false;
    const target_protocol = target_origin[0 .. target_colon + 1];
    if (!std.ascii.eqlIgnoreCase(target_protocol, URL.getProtocol(destination))) return false;

    const target_host = URL.getOriginHostname(target_origin);
    const destination_host = URL.getHostname(destination);
    if (target_host.len == 0 or destination_host.len == 0) return false;
    const target_domain = URL.domainAndRegistry(target_host) orelse return false;
    const destination_domain = URL.domainAndRegistry(destination_host) orelse return false;
    return std.ascii.eqlIgnoreCase(target_domain, destination_domain);
}

/// Core of Blink LocalFrame::CanNavigate from Chrome 149. API-specific callers
/// map a denial to null, a console warning, or a synchronous SecurityError;
/// every path still passes this final enqueue gate.
pub fn canNavigate(self: *Frame, target: *Frame, destination: [:0]const u8) bool {
    if (self == target) return true;

    if (std.ascii.eqlIgnoreCase(URL.getProtocol(destination), "javascript:") and
        !sameEffectiveOrigin(self, target))
    {
        return false;
    }

    const top = self.topFrame();
    const sandbox_flags = self.activeSandboxFlags();
    if (SandboxFlags.contains(sandbox_flags, SandboxFlags.navigation)) {
        const target_is_outermost = target.parent == null;

        // A sandboxed Document may navigate its descendants and, subject to
        // the checks below, an outermost main frame. Other ancestors/siblings
        // are never reachable. This reads the committed policy snapshot; it
        // deliberately does not inspect the current iframe DOM attribute.
        if (!isDescendantOf(target, self) and !target_is_outermost) {
            return false;
        }

        // A propagated sandbox can navigate only a popup it opened itself and
        // only when popup creation was allowed by its active policy.
        if (target_is_outermost and target != top and
            SandboxFlags.contains(sandbox_flags, SandboxFlags.propagates_to_auxiliary_browsing_contexts) and
            (SandboxFlags.contains(sandbox_flags, SandboxFlags.popups) or
                target.window._opener != self.window))
        {
            return false;
        }

        if (target == top) {
            const top_restricted = SandboxFlags.contains(sandbox_flags, SandboxFlags.top_navigation);
            const activation_restricted = SandboxFlags.contains(sandbox_flags, SandboxFlags.top_navigation_by_user_activation);

            // No allow-top token: both restrictions remain.
            if (top_restricted and activation_restricted) return false;

            // Only allow-top-navigation-by-user-activation clears the second
            // bit; Chromium requires transient (not merely sticky) activation.
            if (top_restricted and !activation_restricted and
                !self.hasTransientUserActivation())
            {
                return false;
            }

            // PolicyContainer's ancestor-chain defense. A sticky activation
            // remains the last-line exception; the persistent policy boolean
            // will be modeled separately from the flag snapshot.
            if (!self._can_navigate_top_without_user_gesture and
                !self.hasStickyUserActivation()) return false;

            return true;
        }
    }

    if (self.canAccessAncestor(target)) return true;

    if (target.parent == null) {
        // Blink: `target_frame == Opener()`, i.e. the source frame's opener is
        // the target. The inverse relationship accidentally allowed/denied the
        // wrong side of popup navigation.
        if (self.window._opener == target.window) return true;
        if (target.window._opener) |opener| {
            if (self.canAccessAncestor(opener._frame)) return true;
        }
    }

    if (target == top) {
        return self.hasStickyUserActivation() or
            self.destinationMatchesOrigin(target, destination) or
            destinationMatchesTopSite(target, destination);
    }
    return false;
}

/// Secure Contexts' "is environment settings object contextually secure?"
/// for Window realms. Blink first classifies this frame's effective origin,
/// then rejects it when any ancestor has a non-trustworthy origin.
pub fn isSecureContext(self: *const Frame) bool {
    if (!self.hasPotentiallyTrustworthyOrigin()) return false;

    var ancestor = self.parent;
    while (ancestor) |frame| : (ancestor = frame.parent) {
        if (!frame.hasPotentiallyTrustworthyOrigin()) return false;
    }
    return true;
}

fn hasPotentiallyTrustworthyOrigin(self: *const Frame) bool {
    if (self.origin) |origin| {
        return SecureContext.isOriginPotentiallyTrustworthy(origin);
    }

    // Initial about:blank and about:srcdoc inherit their creator's origin.
    // Normally navigate() has already materialized that in `origin`; this also
    // covers the short construction interval before the synchronous commit.
    if (SecureContext.isInheritedAboutURL(self.url)) {
        if (self.parent) |parent| return parent.hasPotentiallyTrustworthyOrigin();
        if (self.window._opener) |opener| return opener._frame.hasPotentiallyTrustworthyOrigin();
        return false;
    }

    return SecureContext.isTrustworthyMissingOriginURL(self.url);
}

// Install the navigation initiator's effective origin. Within one Page the
// captured key resolves to the creator's exact *Origin/security token; a root
// Page replacement resolves the copied key into a new Page-owned Origin and
// therefore never retains a pointer into the retiring Page.
fn inheritSyntheticNavigationOrigin(
    self: *Frame,
    initiator_key: ?[]const u8,
    prefer_parent: bool,
) !void {
    if (prefer_parent) {
        if (self.parent) |parent| {
            return self.js.inheritOrigin(parent.js);
        }
    }

    if (initiator_key) |key| {
        // Use the explicit pointer path for the common creator relationships.
        // The key lookup below covers sibling/other same-Page initiators and
        // reconstructs (rather than retains) the key after a root Page swap.
        if (self.parent) |parent| {
            if (std.mem.eql(u8, key, parent.js.origin.key)) {
                return self.js.inheritOrigin(parent.js);
            }
        }
        if (self.window._opener) |opener| {
            if (std.mem.eql(u8, key, opener._frame.js.origin.key)) {
                return self.js.inheritOrigin(opener._frame.js);
            }
        }
        return self.js.setOriginKey(key);
    }

    if (self.parent) |parent| {
        return self.js.inheritOrigin(parent.js);
    }
    if (self.window._opener) |opener| {
        return self.js.inheritOrigin(opener._frame.js);
    }
    return self.js.setOriginKey(null);
}

/// Window's outgoing referrer walks through srcdoc ancestors to the first real
/// Document, matching LocalDOMWindow::OutgoingReferrerUrl. An about:blank
/// document is intentionally not skipped.
fn outgoingReferrerSource(self: *const Frame) ?[:0]const u8 {
    const security_origin_key = self.js.origin.key;
    const tuple_key = if (std.mem.startsWith(u8, security_origin_key, "!"))
        security_origin_key[1..]
    else
        security_origin_key;
    // Opaque origins use UUID keys and have no serialized scheme. Chromium
    // returns no outgoing referrer before walking through srcdoc ancestors.
    if (std.mem.indexOf(u8, tuple_key, "://") == null) return null;

    var source = self;
    while (std.mem.eql(u8, source.url, "about:srcdoc")) {
        source = source.parent orelse return null;
    }
    return source.url;
}

fn setDocumentReferrer(
    self: *Frame,
    candidate: ?[]const u8,
    preserve_fragment: bool,
    policy: HttpClient.ReferrerPolicy,
) !void {
    if (candidate == null) {
        self.document._referrer = "";
        return;
    }

    // Initial about:blank Documents expose their creator's URL verbatim,
    // including its fragment, and ignore the owner iframe's referrerpolicy.
    // Srcdoc and network navigations expose the normal policy-selected value.
    if (preserve_fragment) {
        self.document._referrer = try self.arena.dupe(u8, candidate.?);
        return;
    }

    // Referrer same-origin comparison uses the navigation URL, not the
    // inherited security origin. about:srcdoc is therefore cross-origin for
    // policy selection even though its Document inherits the parent origin.
    const target_origin = try URL.getOrigin(self.arena, self.url);
    self.document._referrer = (try HttpClient.requestReferrerWithPolicy(
        self.arena,
        candidate,
        self.url,
        target_origin,
        policy,
    )) orelse "";
}

pub fn navigate(self: *Frame, request_url: [:0]const u8, opts: NavigateOpts) !void {
    lp.assert(self._load_state == .waiting, "frame.renavigate", .{});
    const session = self._session;
    self._native_pointer_state = .{};
    self._native_primary_press_state = null;
    self._load_state = .parsing;
    self._last_navigate_error = null;
    // Parsed/navigated HTML Documents default to quirks mode. A conforming
    // doctype callback will switch this back to no-quirks during parsing.
    self.document.beginHTMLDocumentParse();
    self.performance().prepareNavigation(switch (std.meta.activeTag(opts.kind)) {
        .reload => .reload,
        .traverse => .back_forward,
        .push, .replace => .navigate,
    });

    const req_id = self._session.browser.http_client.nextReqId();
    log.info(.frame, "navigate", .{
        .url = request_url,
        .method = opts.method,
        .reason = opts.reason,
        .body = opts.body != null,
        .req_id = req_id,
        .type = self._type,
    });

    // Handle synthetic navigations: inherited about: URLs and blob: URLs.
    const is_about_blank = std.mem.eql(u8, "about:blank", request_url);
    const is_about_srcdoc = std.mem.eql(u8, "about:srcdoc", request_url);
    const is_inherited_about = is_about_blank or is_about_srcdoc;
    const is_blob = !is_inherited_about and std.mem.startsWith(u8, request_url, "blob:");

    // A real network response supplies a new CSP policy container. Any CSP
    // inherited by the popup's initial empty Document must not leak into that
    // response; propagated frame-policy flags remain separate and persistent.
    if (!is_inherited_about and !is_blob) {
        self._csp_sandbox_flags = SandboxFlags.none;
    }

    if (is_inherited_about or is_blob) {
        self.url = if (is_about_blank)
            "about:blank"
        else if (is_about_srcdoc)
            "about:srcdoc"
        else
            try self.arena.dupeZ(u8, request_url);

        // even though about:blank navigations may share the same _data_, we
        // have to do this to make sure window.location is at a unique _address_.
        // If we don't do this, multiple window._location will have the same
        // address and thus be mapped to the same v8::Object in the identity map.
        const location = try Location.init(self.url, self);
        location.acquireRef();
        // We're not holding a ref to old location anymore.
        self.window._location.releaseRef(self._page);
        self.window._location = location;

        if (is_blob) {
            // strip out blob:
            self.origin = try URL.getOrigin(self.arena, request_url[5.. :0]);
        } else if (self.parent) |parent| {
            self.origin = parent.origin;
            self.base_url = parent.base();
        } else if (self.window._opener) |opener| {
            self.origin = opener._frame.origin;
            self.base_url = opener._frame.base();
        } else {
            self.origin = null;
        }

        try self.setDocumentReferrer(opts.referer, is_about_blank, opts.referrer_policy);

        if (SandboxFlags.contains(self.activeSandboxFlags(), SandboxFlags.origin)) {
            try self.js.setOriginKey(null);
        } else if (is_blob and self.origin != null) {
            // A tuple-origin blob serializes its creator origin in the URL.
            try self.js.setOriginKey(self.origin);
        } else {
            // about:srcdoc always uses its parent policy/origin. about:blank
            // and opaque blob: use the captured navigation initiator, falling
            // back to the live parent/opener for synchronous initial loads.
            try self.inheritSyntheticNavigationOrigin(
                opts.initiator_origin_key,
                is_about_srcdoc,
            );
        }
        try self.js.setWindowAgentCluster(self.js.origin.key);
        try self.snapshotDocumentSecurityOrigin();
        try self.snapshotDocumentStorageOrigin(if (is_blob and self.origin != null)
            null
        else
            opts.initiator_storage_origin_key);
        self.updateCanNavigateTopPolicy();
        try self.materializeLocationInOwnerRealm(location);

        // Chromium's PolicyContainerBuilder uses the parent policy for
        // about:srcdoc and the navigation initiator policy for every other
        // local scheme. Apply this before parsing, since a blob/srcdoc body can
        // execute parser-inserted script immediately.
        if (is_about_srcdoc) {
            if (self.parent) |parent| {
                try self.js.inheritContentSecurityPolicyCodeGeneration(parent.js);
            }
        } else if (opts.initiator_csp_eval != null or opts.initiator_csp_wasm != null) {
            if (opts.initiator_csp_eval) |directive| {
                try self.js.addContentSecurityPolicy(directive);
            }
            if (opts.initiator_csp_wasm) |directive| {
                if (opts.initiator_csp_eval == null or
                    !std.mem.eql(u8, opts.initiator_csp_eval.?, directive))
                {
                    try self.js.addContentSecurityPolicy(directive);
                }
            }
        } else if (self.parent) |parent| {
            // Initial/synchronous local document creation can bypass the
            // queued-navigation capture; its creator is the parent.
            try self.js.inheritContentSecurityPolicyCodeGeneration(parent.js);
        } else if (self.window._opener) |opener| {
            try self.js.inheritContentSecurityPolicyCodeGeneration(opener._frame.js);
        }

        // Local-scheme documents still get one Navigation Timing entry, and
        // parser-inserted script must be able to observe it immediately.
        try self.performance().ensureNavigationTiming(self.url, &self.js.execution);

        // Assume we parsed the document.
        // It's important to force a reset during the following navigation.
        self._parse_state = .complete;

        // Content injection
        if (is_blob) {
            // blob: URLs resolve across globals in this Page's agent cluster.
            // A root synthetic navigation replaces its Page before this
            // parser runs. Session pins and passes the already-resolved Blob
            // across that swap; subframes can continue using the live Page
            // registry directly.
            var acquired_blob: ?*Blob = null;
            defer if (acquired_blob) |blob| blob.releaseRef(self._page);
            const blob = opts.synthetic_blob orelse blk: {
                const value = self._page.acquireBlobURL(request_url) orelse {
                    log.warn(.js, "invalid blob", .{ .url = request_url });
                    return error.BlobNotFound;
                };
                acquired_blob = value;
                break :blk value;
            };
            const parse_arena = try self.getArena(.medium, "Frame.parseBlob");
            defer self.releaseArena(parse_arena);
            var parser = Parser.init(parse_arena, self.document.asNode(), self, .{ .allow_declarative_shadow = true });
            parser.parse(blob._slice);
        } else if (is_about_srcdoc and opts.srcdoc_body != null) {
            // srcdoc is a synthetic HTML document, not an empty about page.
            // Queued navigations own this slice in their navigation arena;
            // parsing is synchronous and completes before that arena is freed.
            const parse_arena = try self.getArena(.medium, "Frame.parseSrcdoc");
            defer self.releaseArena(parse_arena);
            var parser = Parser.init(parse_arena, self.document.asNode(), self, .{
                .allow_declarative_shadow = true,
                .iframe_srcdoc = true,
            });
            parser.parse(opts.srcdoc_body.?);
        } else {
            self.document.injectBlank(self) catch |err| {
                log.err(.browser, "inject blank", .{ .err = err });
                return error.InjectBlankFailed;
            };
        }

        session.notification.dispatch(.frame_navigate, &.{
            .opts = opts,
            .req_id = req_id,
            .frame_id = self._frame_id,
            .loader_id = self._loader_id,
            .url = request_url,
            .timestamp = timestamp(.monotonic),
        });

        session.notification.dispatch(.frame_navigated, &.{
            .req_id = req_id,
            .frame_id = self._frame_id,
            .loader_id = self._loader_id,
            .opts = .{
                .cdp_id = opts.cdp_id,
                .reason = opts.reason,
                .method = opts.method,
            },
            .url = request_url,
            .timestamp = timestamp(.monotonic),
        });

        // force next request id manually b/c we won't create a real req.
        _ = session.browser.http_client.incrReqId();

        const navigation_api = self.navigation();
        navigation_api._current_navigation_kind = opts.kind;
        try navigation_api.commitNavigation(self);

        self.documentIsComplete();
        return;
    }

    const http_client = &session.browser.http_client;

    self._http_status = null;
    self._http_headers = .empty;

    self.url = blk: {
        if (URL.isCompleteHTTPUrl(request_url)) {
            break :blk try self.arena.dupeZ(u8, request_url);
        }
        break :blk try std.mem.concatWithSentinel(self.arena, u8, &.{ "http://", request_url }, 0);
    };
    self.origin = try URL.getOrigin(self.arena, self.url);
    try self.setDocumentReferrer(opts.referer, false, opts.referrer_policy);

    self._req_id = req_id;
    self._navigated_options = .{
        .cdp_id = opts.cdp_id,
        .reason = opts.reason,
        .method = opts.method,
        .body = if (opts.body) |b| try self.arena.dupe(u8, b) else null,
        .header = if (opts.header) |h| try self.arena.dupeZ(u8, h) else null,
    };

    const root_browser_navigation = self.parent == null and
        opts.initiator_url == null and
        opts.reason == .address_bar;
    const top_level_url = blk: {
        var top = self;
        while (top.parent) |parent| top = parent;
        break :blk top.url;
    };
    var headers = try http_client.newRequestHeaders(self.url, .{
        .destination = if (self.parent == null) .document else .iframe,
        .mode = .navigate,
        .initiator_url = opts.initiator_url,
        .top_level_url = top_level_url,
        .referrer_url = opts.referer,
        .referrer_policy = opts.referrer_policy,
        .user_activation = root_browser_navigation,
        .method = opts.method,
        .has_body = opts.body != null,
        .credentials = .include,
    });
    if (opts.header) |hdr| {
        try headers.add(hdr);
    }

    // A root navigation issued against a pending Page (i.e. one allocated by
    // Session.initiateRootNavigation) flags both the notification and the
    // HTTP request itself: CDP skips its node-registry reset until commit,
    // and the in-flight transfer survives the OLD page's frame.deinit which
    // calls http_client.abortList() on the shared frame_id during
    // commitPendingPage.
    const is_pending_root = self._page.replaces != null;

    // We dispatch frame_navigate event before sending the request.
    // It ensures the event frame_navigated is not dispatched before this one.
    session.notification.dispatch(.frame_navigate, &.{
        .opts = opts,
        .url = self.url,
        .req_id = req_id,
        .frame_id = self._frame_id,
        .loader_id = self._loader_id,
        .timestamp = timestamp(.monotonic),
        .is_pending_root = is_pending_root,
    });

    self.navigation()._current_navigation_kind = opts.kind;

    self.makeRequest(.{
        .ctx = self,
        .url = self.url,
        .frame_id = self._frame_id,
        .loader_id = self._loader_id,
        .method = opts.method,
        .headers = headers,
        .body = opts.body,
        .cookie_jar = &session.cookie_jar,
        .cookie_origin = opts.initiator_url orelse self.url,
        .resource_type = .document,
        .resource_timing = self.performance().navigationTimingSink(
            &self.js.execution,
            if (self.parent) |parent|
                parent.performance().resourceTimingSink(&parent.js.execution, .iframe)
            else
                null,
        ),
        .notification = self._session.notification,
        .selected_referrer = if (self.document._referrer.len > 0)
            self.document._referrer
        else
            null,
        .referrer_policy = opts.referrer_policy,
        .referrer_managed = opts.referer != null,
        .header_callback = frameHeaderDoneCallback,
        .data_callback = frameDataCallback,
        .done_callback = frameDoneCallback,
        .error_callback = frameErrorCallback,
    }) catch |err| {
        log.err(.frame, "navigate request", .{ .url = self.url, .err = err, .type = self._type });
        return err;
    };
}

/// Whether this is a newly-created top-level browsing context which has not
/// started its first navigation yet. Only that state may call navigate()
/// directly through PageHandle; committed roots must use Session's replacement
/// navigation path, and subframes have their own queued-navigation lifecycle.
pub fn isInitialRootNavigation(self: *const Frame) bool {
    return self.parent == null and self._load_state == .waiting;
}

// Navigation can happen in many places, such as executing a <script> tag or
// a JavaScript callback, a CDP command, etc...It's rarely safe to do immediately
// as the caller almost certainly doesn't expect the frame to go away during the
// call. So, we schedule the navigation for the next tick.
pub fn scheduleNavigation(self: *Frame, request_url: []const u8, opts: NavigateOpts, nt: Navigation) !void {
    if (self.canScheduleNavigation(std.meta.activeTag(nt)) == false) {
        return;
    }
    const arena = try self._session.getArena(.small, "scheduleNavigation");
    errdefer self._session.releaseArena(arena);
    return self.scheduleNavigationWithArena(arena, request_url, opts, nt);
}

// Don't name the first parameter "self", because the target of this navigation
// might change inside the function. So the code should be explicit about the
// frame that it's acting on.
fn scheduleNavigationWithArena(originator: *Frame, arena: Allocator, request_url: []const u8, opts: NavigateOpts, nt: Navigation) !void {
    const resolved_url, const is_inherited_about = blk: {
        if (URL.isCompleteHTTPUrl(request_url)) {
            break :blk .{ try arena.dupeZ(u8, request_url), false };
        }

        if (std.mem.eql(u8, request_url, "about:blank")) {
            // navigate will handle this special case
            break :blk .{ "about:blank", true };
        }
        if (std.mem.eql(u8, request_url, "about:srcdoc")) {
            // navigate will handle this special case
            break :blk .{ "about:srcdoc", true };
        }

        // request_url isn't a "complete" URL, so it has to be resolved with the
        // originator's base. Unless, originator's base is "about:blank", in which
        // case we have to walk up the parents and find a real base.
        const frame_base = base_blk: {
            var maybe_not_blank_frame = originator;
            while (true) {
                const maybe_base = maybe_not_blank_frame.base();
                if (std.mem.eql(u8, maybe_base, "about:blank") == false) {
                    break :base_blk maybe_base;
                }
                // The orelse here is probably an invalid case, but there isn't
                // anything we can do about it. It should never happen?
                maybe_not_blank_frame = maybe_not_blank_frame.parent orelse break :base_blk "";
            }
        };

        const u = try URL.resolve(
            arena,
            frame_base,
            request_url,
            .{ .encoding = originator.charset },
        );
        break :blk .{ u, false };
    };

    const target = switch (nt) {
        .form, .anchor => |p| p,
        .script => |p| p orelse originator,
        .iframe => |iframe| iframe._window.?._frame, // only an frame with existing content (i.e. a window) can be navigated
    };

    const session = target._session;
    if (!originator.canNavigate(target, resolved_url)) {
        log.warn(.browser, "unsafe frame navigation blocked", .{
            .source = originator.url,
            .target = target.url,
            .destination = resolved_url,
        });
        return error.SecurityError;
    }
    // Short-circuit only true fragment-only navigations (same path/query, different
    // fragment). Identical URLs fall through and trigger a real reload.
    const is_fragment_navigation = !std.mem.eql(u8, target.url, resolved_url) and URL.eqlDocument(target.url, resolved_url);
    if (!opts.force and is_fragment_navigation) {
        const old_url = target.url;
        target.url = try target.arena.dupeZ(u8, resolved_url);
        try target.window._location.updateUrl(target.url, target);

        try target.navigation().updateEntries(target.url, opts.kind, target, true);

        try target.queueHashChange(old_url, target.url);

        // don't defer this, the caller is responsible for freeing it on error
        session.releaseArena(arena);
        return;
    }

    log.info(.browser, "schedule navigation", .{
        .url = resolved_url,
        .reason = opts.reason,
        .type = target._type,
    });

    // Navigation: kill in-flight HTTP transfers, but leave WebSockets
    // alive — they're cross-document by spec.
    session.browser.http_client.abortRequests(&target._http_owner);

    // Capture the originating frame's URL as the Referer for this
    // navigation. The originator's frame may be torn down before navigate()
    // runs (processRootQueuedNavigation rebuilds the Page in-place), so dup
    // into the QueuedNavigation arena which outlives that tear-down.
    var nav_opts = opts;
    if (nav_opts.srcdoc_body) |body| {
        // The source normally aliases an attribute in the creator document.
        // A queued iframe navigation destroys the old child Frame before
        // commit, so give the payload the same explicit lifetime as the URL
        // and policy snapshot.
        nav_opts.srcdoc_body = try arena.dupe(u8, body);
    }
    // Local-scheme documents inherit the navigation initiator's security
    // origin identity and policy container. Capture the narrow state we model
    // into the QueuedNavigation arena because a root commit destroys the
    // originating Frame before the replacement document is initialized.
    if (nav_opts.initiator_origin_key == null) {
        nav_opts.initiator_origin_key = try arena.dupe(u8, originator.js.origin.key);
    }
    if (nav_opts.initiator_storage_origin_key == null) {
        nav_opts.initiator_storage_origin_key = try arena.dupe(
            u8,
            originator.document._storage_origin_key,
        );
    }
    if (nav_opts.initiator_csp_eval == null) {
        if (originator.js.csp_code_generation.eval_blocking_directive) |directive| {
            nav_opts.initiator_csp_eval = try arena.dupe(u8, directive);
        }
    }
    if (nav_opts.initiator_csp_wasm == null) {
        if (originator.js.csp_code_generation.wasm_blocking_directive) |directive| {
            nav_opts.initiator_csp_wasm = try arena.dupe(u8, directive);
        }
    }
    const referrer_source = if (std.mem.eql(u8, resolved_url, "about:blank"))
        @as(?[]const u8, originator.url)
    else
        originator.outgoingReferrerSource();
    if (referrer_source) |source| {
        // about:blank exposes its immediate creator URL verbatim. Every other
        // navigation uses Window's outgoing referrer, which walks out of
        // srcdoc ancestors before applying policy. Capture it because the
        // originator may be retired before this queued navigation commits.
        const dup = try arena.dupeZ(u8, source);
        if (nav_opts.referer == null) {
            nav_opts.referer = dup;
        }
        if (nav_opts.initiator_url == null and std.mem.startsWith(u8, source, "http")) {
            nav_opts.initiator_url = dup;
        }
    }

    const qn = try arena.create(QueuedNavigation);
    qn.* = .{
        .opts = nav_opts,
        .arena = arena,
        .url = resolved_url,
        .is_inherited_about = is_inherited_about,
        .navigation_type = std.meta.activeTag(nt),
    };

    if (target._queued_navigation) |existing| {
        session.releaseArena(existing.arena);
    }

    target._queued_navigation = qn;
    return session.scheduleNavigation(target);
}

// A script can have multiple competing navigation events, say it starts off
// by doing top.location = 'x' and then does a form submission.
// You might think that we just stop at the first one, but that doesn't seem
// to be what browsers do, and it isn't particularly well supported by v8 (i.e.
// halting execution mid-script).
// From what I can tell, there are 4 "levels" of priority, in order:
// 1 - form submission
// 2 - JavaScript apis (e.g. top.location)
// 3 - anchor clicks
// 4 - iframe.src =
// Within, each category, it's last-one-wins.
fn canScheduleNavigation(self: *Frame, new_target_type: NavigationType) bool {
    if (self._retired) return false;

    if (self.parent) |parent| {
        if (parent.isGoingAway()) {
            return false;
        }
    }

    const existing_target_type = (self._queued_navigation orelse return true).navigation_type;

    if (existing_target_type == new_target_type) {
        // same reason, than this latest one wins
        return true;
    }

    return switch (existing_target_type) {
        .iframe => true, // everything is higher priority than iframe.src = "x"
        .anchor => new_target_type != .iframe, // an anchor is only higher priority than an iframe
        .form => false, // nothing is higher priority than a form
        .script => new_target_type == .form, // a form is higher priority than a script
    };
}

pub fn makeRequest(self: *Frame, req: HttpClient.Request) !void {
    if (self._retired) {
        // Frame.makeRequest normally transfers ownership of Request.headers to
        // HttpClient even on failure. Preserve that contract on this early
        // retired-context path too.
        req.deinit();
        if (req.unstarted_callback) |callback| callback(req.ctx);
        return error.ContextShuttingDown;
    }

    var timed = req;
    timed.root_frame_id = self._page.frame._frame_id;
    timed.initiator_context = .page;
    if (timed.resource_timing == null and !timed.internal) {
        switch (timed.resource_type) {
            .document => if (self.parent) |parent| {
                timed.resource_timing = parent.performance().resourceTimingSink(
                    &parent.js.execution,
                    .iframe,
                );
            },
            .script => timed.resource_timing = self.performance().resourceTimingSink(&self.js.execution, .script),
            .image => timed.resource_timing = self.performance().resourceTimingSink(&self.js.execution, .img),
            .fetch => timed.resource_timing = self.performance().resourceTimingSink(&self.js.execution, .fetch),
            .xhr => timed.resource_timing = self.performance().resourceTimingSink(&self.js.execution, .xmlhttprequest),
            .stylesheet => timed.resource_timing = self.performance().resourceTimingSink(&self.js.execution, .link),
        }
    }
    return self._session.browser.http_client.request(timed, &self._http_owner);
}

// Synchronously abort every transfer and WebSocket owned by this frame
// and all of its descendants.
pub fn abortTransfers(self: *Frame) void {
    for (self.child_frames.items) |child| {
        child.abortTransfers();
    }
    const http_client = &self._session.browser.http_client;
    http_client.abortOwner(&self._http_owner);
    // abortOwner misses deferred contexts whose transfer already completed.
    http_client.deferring_layer.cancelOwner(&self._http_owner);
}

pub fn documentIsLoaded(self: *Frame) void {
    if (self._load_state != .parsing) {
        // Ideally, documentIsLoaded would only be called once, but if a
        // script is dynamically added from an async script after
        // documentIsLoaded is already called, then ScriptManager will call
        // it again.
        return;
    }

    self._load_state = .load;
    self.document._ready_state = .interactive;
    self._documentIsLoaded() catch |err| switch (err) {
        error.JsException => {}, // already logged
        else => log.err(.frame, "document is loaded2", .{ .err = err, .type = self._type, .url = self.url }),
    };
}

pub fn _documentIsLoaded(self: *Frame) !void {
    const perf = self.performance();
    try perf.ensureNavigationTiming(self.url, &self.js.execution);
    perf.markNavigationDomInteractive();
    try self.dispatchReadyStateChange();

    perf.markNavigationDomContentLoadedStart();
    const event = try Event.initTrusted(.wrap("DOMContentLoaded"), .{ .bubbles = true }, self._page);
    try self._event_manager.dispatch(
        self.document.asEventTarget(),
        event,
    );
    perf.markNavigationDomContentLoadedEnd();

    self._session.notification.dispatch(.frame_dom_content_loaded, &.{
        .req_id = self._req_id,
        .frame_id = self._frame_id,
        .loader_id = self._loader_id,
        .timestamp = timestamp(.monotonic),
    });
}

// Fired at the document on every change to document.readyState: before
// DOMContentLoaded (readiness -> interactive) and before the load event
// (readiness -> complete). Does not bubble.
// https://html.spec.whatwg.org/multipage/dom.html#current-document-readiness
fn dispatchReadyStateChange(self: *Frame) !void {
    const event = try Event.initTrusted(.wrap("readystatechange"), .{}, self._page);
    try self._event_manager.dispatch(
        self.document.asEventTarget(),
        event,
    );
}

pub fn scriptsCompletedLoading(self: *Frame) void {
    self.pendingLoadCompleted();
}

pub fn iframeCompletedLoading(self: *Frame, iframe: *IFrame, delays_load: bool) void {
    // When parsing HTML, fire any load event for an iframe on the next tick.
    const parsing_html = switch (self._parse_state) {
        .html => true,
        else => false,
    };
    if (parsing_html and iframe._src.len > 0) {
        self.queueElementEvent(iframe._proto, .load) catch |err| {
            log.err(.frame, "iframe queue load", .{ .err = err, .url = iframe._src });
        };
        if (delays_load) {
            self.pendingLoadCompleted();
        }
        return;
    }

    var hs: JS.HandleScope = undefined;
    const entered = self.js.enter(&hs);
    defer entered.exit();

    blk: {
        const event = Event.initTrusted(comptime .wrap("load"), .{}, self._page) catch |err| {
            log.err(.frame, "iframe event init", .{ .err = err, .url = iframe._src });
            break :blk;
        };
        self._event_manager.dispatch(iframe.asNode().asEventTarget(), event) catch |err| {
            log.warn(.js, "iframe onload", .{ .err = err, .url = iframe._src });
        };
    }

    if (delays_load) {
        self.pendingLoadCompleted();
    }
}

pub const ReconnectLoadGuard = struct {
    frame: *Frame,
    active: bool,

    pub fn deinit(self: *ReconnectLoadGuard) void {
        if (!self.active) return;
        self.active = false;
        self.frame.endReconnectLoadGuard();
    }
};

pub fn beginReconnectLoadGuard(self: *Frame, enabled: bool) ReconnectLoadGuard {
    if (enabled) self._reconnect_load_guard_depth += 1;
    return .{ .frame = self, .active = enabled };
}

fn endReconnectLoadGuard(self: *Frame) void {
    std.debug.assert(self._reconnect_load_guard_depth > 0);
    self._reconnect_load_guard_depth -= 1;
    if (self._reconnect_load_guard_depth != 0 or !self._reconnect_load_completion_deferred) return;

    self._reconnect_load_completion_deferred = false;
    if (self._pending_loads == 0) self.documentIsComplete();
}

fn pendingLoadCompleted(self: *Frame) void {
    const pending_loads = self._pending_loads;
    if (pending_loads == 1) {
        self._pending_loads = 0;
        if (self._reconnect_load_guard_depth != 0) {
            self._reconnect_load_completion_deferred = true;
        } else {
            self.documentIsComplete();
        }
    } else {
        self._pending_loads = pending_loads - 1;
    }
}

pub fn documentIsComplete(self: *Frame) void {
    // Initial iframe documents can synchronously remove/reinsert their owner
    // while parser/module callbacks are still unwinding.  Removal retires the
    // old inner Frame and creates a replacement browsing context; the stale
    // navigation must not publish ready/load state into that retired realm.
    if (self._retired) return;

    if (self._load_state == .complete) {
        // Ideally, documentIsComplete would only be called once, but with
        // dynamic scripts, it can be hard to keep track of that. An async
        // script could be evaluated AFTER Loaded and Complete and load its
        // own non non-async script - which, upon completion, needs to check
        // whether Laoded/Complete have already been called, which is what
        // this guard is.
        return;
    }

    // documentIsComplete could be called directly, without first calling
    // documentIsLoaded, if there were _only_ async scripts
    if (self._load_state == .parsing) {
        self.documentIsLoaded();
    }

    self._load_state = .complete;
    self._documentIsComplete() catch |err| switch (err) {
        error.JsException => {}, // already logged
        else => log.err(.frame, "document is complete", .{ .err = err, .type = self._type, .url = self.url }),
    };
}

fn _documentIsComplete(self: *Frame) !void {
    const perf = self.performance();
    try perf.ensureNavigationTiming(self.url, &self.js.execution);
    perf.markNavigationDomComplete();
    self.document._ready_state = .complete;
    try self.dispatchReadyStateChange();

    // Run element load/error events before window.load.
    try self.dispatchQueuedEvents();

    // Dispatch window.load event.
    const window_target = self.window.asEventTarget();
    perf.markNavigationLoadEventStart();
    if (self._event_manager.hasDirectListeners(window_target, "load", self.window._on_load)) {
        const event = try Event.initTrusted(comptime .wrap("load"), .{}, self._page);
        // This event is weird, it's dispatched directly on the window, but
        // with the document as the target.
        event._target = self.document.asEventTarget();
        try self._event_manager.dispatchDirect(window_target, event, self.window._on_load, .{ .inject_target = false, .context = "page load" });
    }
    try perf.finishNavigation(&self.js.execution, self.parent == null);

    self._session.notification.dispatch(.frame_loaded, &.{
        .req_id = self._req_id,
        .frame_id = self._frame_id,
        .loader_id = self._loader_id,
        .timestamp = timestamp(.monotonic),
    });

    if (self._event_manager.hasDirectListeners(window_target, "pageshow", self.window._on_pageshow)) {
        const pageshow_event = (try PageTransitionEvent.initTrusted(comptime .wrap("pageshow"), .{}, self)).asEvent();
        try self._event_manager.dispatchDirect(window_target, pageshow_event, self.window._on_pageshow, .{ .context = "page show" });
    }

    if (comptime IS_DEBUG) {
        log.debug(.frame, "load", .{ .url = self.url, .type = self._type });
    }

    self.notifyParentLoadComplete();
}

fn notifyParentLoadComplete(self: *Frame) void {
    // A load/pageshow callback may discard this child after completion began.
    // iframeRemovedCallback already balanced the parent's pending-load count
    // before retirement, so the stale completion has nothing left to notify.
    if (self._retired) return;

    const parent = self.parent orelse return;

    if (self._parent_notified == true) {
        if (comptime IS_DEBUG) {
            std.debug.assert(false);
        }
        // shouldn't happen, don't want to crash a release build over it
        return;
    }

    self._parent_notified = true;
    parent.iframeCompletedLoading(self.iframe.?, self._delays_parent_load);
}

fn frameHeaderDoneCallback(response: HttpClient.Response) !HttpClient.HeaderResult {
    var self: *Frame = @ptrCast(@alignCast(response.ctx));

    // Commit point for a pending root navigation. The session has been
    // holding the OLD page alive during the round-trip; now that response
    // headers have arrived, swap pending → active. This dispatches
    // frame_remove (clears OLD V8 context group + CDP node_registry),
    // tears down the OLD page, flips the pointer, and dispatches
    // frame_created against the new (now active) frame.
    if (self._page.replaces != null) {
        try self._session.commitPendingPage(self._page);
    }

    const response_url = response.url();
    if (std.mem.eql(u8, response_url, self.url) == false) {
        // would be different than self.url in the case of a redirect
        self.url = try self.arena.dupeZ(u8, response_url);
        self.origin = try URL.getOrigin(self.arena, self.url);
    }

    const redirect_count = response.redirectCount() orelse 0;
    if (redirect_count > 0) {
        // Network redirect handling has already selected the final hop's
        // Referer. Store that exact value rather than recomputing from the
        // creator URL and accidentally restoring information lost earlier.
        self.document._referrer = if (response.selectedReferrer()) |referrer|
            try self.arena.dupe(u8, referrer)
        else
            "";
    }

    // Enforced response CSP participates in the Document's active sandbox
    // before its SecurityOrigin is committed. In particular, CSP sandbox
    // without allow-same-origin must never briefly install the URL tuple
    // origin or share its V8 security token with another realm.
    var sandbox_header_it = response.headerIterator();
    while (sandbox_header_it.next()) |hdr| {
        if (std.ascii.eqlIgnoreCase(hdr.name, "Content-Security-Policy")) {
            if (SandboxFlags.parseContentSecurityPolicy(hdr.value)) |flags| {
                self._csp_sandbox_flags |= flags;
            }
        }
    }

    if (SandboxFlags.contains(self.activeSandboxFlags(), SandboxFlags.origin)) {
        try self.js.setOriginKey(null);
    } else {
        try self.js.setOriginKey(self.origin);
    }
    try self.js.setWindowAgentCluster(self.js.origin.key);
    try self.snapshotDocumentSecurityOrigin();
    try self.snapshotDocumentStorageOrigin(null);
    self.updateCanNavigateTopPolicy();

    // After any redirect, drop the original method/body/header so a later
    // Page.reload doesn't re-POST form data to the redirect target. Conservative
    // default — 307/308 technically preserve the method per RFC 7231, but
    // resubmitting form data is the more dangerous failure mode.
    if (redirect_count > 0) {
        if (self._navigated_options) |*no| {
            no.method = .GET;
            no.body = null;
            no.header = null;
        }
    }

    // Init new location.
    const location = try Location.init(self.url, self);
    location.acquireRef();
    self.window._location.releaseRef(self._page);
    self.window._location = location;
    try self.materializeLocationInOwnerRealm(location);

    if (comptime IS_DEBUG) {
        log.debug(.frame, "navigate header", .{
            .url = self.url,
            .status = response.status(),
            .content_type = response.contentType(),
            .type = self._type,
        });
    }

    self._http_status = response.status();
    var it = response.headerIterator();
    while (it.next()) |hdr| {
        // Feed every field occurrence to the realm before response-body script
        // runs. Report-only TT still invokes the default policy and may change
        // successful sink values, while legacy eval/Wasm remains non-blocking.
        if (std.ascii.eqlIgnoreCase(hdr.name, "Content-Security-Policy")) {
            try self.js.addContentSecurityPolicy(hdr.value);
        } else if (std.ascii.eqlIgnoreCase(hdr.name, "Content-Security-Policy-Report-Only")) {
            try self.js.addContentSecurityPolicyReportOnly(hdr.value);
        }
        try self._http_headers.append(self.arena, .{
            .name = try self.arena.dupe(u8, hdr.name),
            .value = try self.arena.dupe(u8, hdr.value),
        });
    }

    if (self._navigated_options) |no| {
        // _navigated_options will be null in special short-circuit cases, like
        // "navigating" to about:blank, in which case this notification has
        // already been sent
        self._session.notification.dispatch(.frame_navigated, &.{
            .opts = no,
            .url = self.url,
            .req_id = self._req_id,
            .frame_id = self._frame_id,
            .loader_id = self._loader_id,
            .timestamp = timestamp(.monotonic),
        });
    }

    // If the response is a file download, stream its body to disk instead of
    // parsing it as a page. This sets _parse_state to .download, which the
    // data/done callbacks below special-case.
    _ = try self.maybeStartDownload(response);

    return .proceed;
}

// Returns true when the response was set up as a file download. A response is
// treated as a download when Browser.setDownloadBehavior opted in
// (allow/allowAndName) and the response carries Content-Disposition: attachment.
// See issue #2701.
fn maybeStartDownload(self: *Frame, response: HttpClient.Response) !bool {
    const session = self._session;
    switch (session.download_behavior) {
        .allow, .allow_and_name => {},
        .deny => return false,
    }

    const disposition: HttpClient.Header = blk: {
        var it = response.headerIterator();
        while (it.next()) |hdr| {
            if (std.ascii.eqlIgnoreCase(hdr.name, "content-disposition")) {
                break :blk hdr;
            }
        }
        return false;
    };
    if (std.ascii.eqlIgnoreCase(disposition.firstValue(), "attachment") == false) {
        return false;
    }

    const download_path = session.download_path orelse {
        log.warn(.frame, "download without downloadPath", .{ .url = self.url });
        return false;
    };

    // `guid` is the CDP "Global Unique Identifier" that ties the
    // downloadWillBegin / downloadProgress events to one download.
    var guid_buf: [36]u8 = undefined;
    @import("../id.zig").uuidv4(&guid_buf);
    const guid = try self.arena.dupe(u8, &guid_buf);

    const suggested = dispositionFilename(disposition) orelse (try urlBasename(self.arena, self.url)) orelse guid;
    const suggested_filename = try self.arena.dupe(u8, suggested);

    // allowAndName stores the file under its guid; allow uses the suggested name.
    const on_disk_name = switch (session.download_behavior) {
        .allow_and_name => guid,
        else => suggested_filename,
    };

    std.fs.cwd().makePath(download_path) catch |err| {
        log.err(.frame, "download makePath", .{ .err = err, .path = download_path });
        return false;
    };
    var dir = std.fs.cwd().openDir(download_path, .{}) catch |err| {
        log.err(.frame, "download openDir", .{ .err = err, .path = download_path });
        return false;
    };
    defer dir.close();
    const file = dir.createFile(on_disk_name, .{ .truncate = true }) catch |err| {
        log.err(.frame, "download createFile", .{ .err = err, .name = on_disk_name });
        return false;
    };

    const total: ?u64 = if (response.contentLength()) |cl| cl else null;

    self._parse_state = .{ .download = .{
        .guid = guid,
        .file = file,
        .filename = suggested_filename,
        .received = 0,
        .total = total,
    } };

    if (session.download_events_enabled) {
        session.notification.dispatch(.download_will_begin, &.{
            .frame_id = self._frame_id,
            .guid = guid,
            .url = self.url,
            .suggested_filename = suggested_filename,
        });
        session.notification.dispatch(.download_progress, &.{
            .guid = guid,
            .total_bytes = total orelse 0,
            .received_bytes = 0,
            .state = .in_progress,
        });
    }

    return true;
}

// Extracts the filename from a Content-Disposition header, handling the quoted,
// unquoted, and RFC 5987 (filename*=charset''value) forms. Path components are
// stripped so the result is always a bare basename.
fn dispositionFilename(disposition: HttpClient.Header) ?[]const u8 {
    // Prefer the extended filename*= form when present, per RFC 6266.
    if (disposition.param("filename*")) |ext| {
        // charset'lang'value — take everything after the second quote.
        if (std.mem.indexOfScalar(u8, ext, '\'')) |first| {
            if (std.mem.indexOfScalarPos(u8, ext, first + 1, '\'')) |second| {
                return sanitizeFilename(ext[second + 1 ..]);
            }
        }
        return sanitizeFilename(ext);
    }
    if (disposition.param("filename")) |name| {
        return sanitizeFilename(name);
    }
    return null;
}

// Strips any directory components, guarding against path traversal. Content-
// Disposition can carry Windows separators, so backslashes are stripped too,
// regardless of the host platform.
fn sanitizeFilename(name: []const u8) ?[]const u8 {
    var out = std.fs.path.basename(name);
    if (std.mem.lastIndexOfScalar(u8, out, '\\')) |i| {
        out = out[i + 1 ..];
    }
    if (out.len == 0 or std.mem.eql(u8, out, ".") or std.mem.eql(u8, out, "..")) {
        return null;
    }
    return out;
}

// Derives a filename from a URL's last path segment. The path is taken from a
// real URL parse (rust-url) so query/fragment and percent-encoding are handled
// the same way the rest of the browser handles URLs. The result is duped into
// `arena`, since the parsed URL is freed before this returns.
fn urlBasename(arena: Allocator, url: []const u8) !?[]const u8 {
    var err: i32 = 0;
    const u = sys_url.url_parse(url.ptr, url.len, &err) orelse return null;
    defer sys_url.url_free(u);

    var ptr: [*]const u8 = undefined;
    var len: usize = undefined;
    sys_url.url_get_path(u, &ptr, &len);

    const name = sanitizeFilename(ptr[0..len]) orelse return null;
    return try arena.dupe(u8, name);
}

fn isUtf16Encoding(charset: []const u8) bool {
    return std.mem.eql(u8, charset, "UTF-16LE") or std.mem.eql(u8, charset, "UTF-16BE");
}

fn frameDataCallback(response: HttpClient.Response, data: []const u8) !void {
    var self: *Frame = @ptrCast(@alignCast(response.ctx));

    if (self._parse_state == .pre) {
        // we lazily do this, because we might need the first chunk of data
        // to sniff the content type
        var mime: Mime = blk: {
            if (response.contentType()) |ct| {
                break :blk try Mime.parse(ct);
            }
            break :blk Mime.sniff(data);
        } orelse .unknown;

        // If the HTTP Content-Type header didn't specify a charset and this is HTML,
        // prescan the first 1024 bytes for a <meta charset> declaration.
        var html_prescan_found_charset = false;
        if (mime.content_type == .text_html and mime.is_default_charset) {
            if (Mime.prescanCharset(data)) |charset| {
                html_prescan_found_charset = true;
                if (charset.len <= 40) {
                    @memcpy(mime.charset[0..charset.len], charset);
                    mime.charset[charset.len] = 0;
                    mime.charset_len = charset.len;
                }
            }
        }

        if (comptime IS_DEBUG) {
            log.debug(.frame, "navigate first chunk", .{
                .content_type = mime.content_type,
                .len = data.len,
                .type = self._type,
                .url = self.url,
            });
        }

        switch (mime.content_type) {
            .text_html => {
                // Normalize and store the charset using encoding_rs canonical names
                const charset_str = mime.charsetString();
                const info = h5e.encoding_for_label(charset_str.ptr, charset_str.len);
                if (info.isValid()) {
                    const name = info.name();
                    self.charset = if (html_prescan_found_charset and isUtf16Encoding(name)) "UTF-8" else name;
                }
                self._parse_state = .{ .html = .{
                    .buffer = .empty,
                    .arena = try self.getArena(.large, "Frame.navigate"),
                } };
            },
            .application_json, .text_javascript, .text_css, .text_plain, .text_markdown => {
                var arr: std.ArrayList(u8) = .empty;
                try arr.appendSlice(self.arena, "<html><head><meta charset=\"utf-8\"></head><body><pre>");
                self._parse_state = .{ .text = arr };
            },
            .image_jpeg, .image_gif, .image_png, .image_webp => {
                self._parse_state = .{ .image = .empty };
            },
            else => self._parse_state = .{ .raw = .empty },
        }
    }

    switch (self._parse_state) {
        .html => |*html| try html.buffer.appendSlice(html.arena, data),
        .text => |*buf| {
            // we have to escape the data...
            var v = data;
            while (v.len > 0) {
                const index = std.mem.indexOfAnyPos(u8, v, 0, &.{ '<', '>' }) orelse {
                    return buf.appendSlice(self.arena, v);
                };
                try buf.appendSlice(self.arena, v[0..index]);
                switch (v[index]) {
                    '<' => try buf.appendSlice(self.arena, "&lt;"),
                    '>' => try buf.appendSlice(self.arena, "&gt;"),
                    else => unreachable,
                }
                v = v[index + 1 ..];
            }
        },
        .raw, .image => |*buf| try buf.appendSlice(self.arena, data),
        .download => |*download| {
            download.file.writeAll(data) catch |err| {
                // TODO(#2701 follow-up): surface the write failure properly. We
                // can't set `_parse_state = .err` here because the next chunk
                // would then hit the `.err => unreachable` branch below, and we
                // should also emit a `canceled` downloadProgress and remove the
                // partial file on disk. For now we just log and keep going.
                log.err(.frame, "download write", .{ .err = err, .guid = download.guid });
                return;
            };
            download.received += data.len;
        },
        .pre => unreachable,
        .complete => unreachable,
        .err => unreachable,
        .raw_done => unreachable,
    }
}

fn frameDoneCallback(ctx: *anyopaque) !void {
    var self: *Frame = @ptrCast(@alignCast(ctx));

    if (comptime IS_DEBUG) {
        log.debug(.frame, "navigate done", .{ .type = self._type, .url = self.url });
    }

    //We need to handle different navigation types differently.
    try self.navigation().commitNavigation(self);

    defer if (comptime IS_DEBUG) {
        log.debug(.frame, "frame load complete", .{
            .url = self.url,
            .type = self._type,
            .state = std.meta.activeTag(self._parse_state),
        });
    };

    const parse_arena = try self.getArena(.medium, "Frame.parse");
    defer self.releaseArena(parse_arena);

    var parser = Parser.init(parse_arena, self.document.asNode(), self, .{ .allow_declarative_shadow = true });

    switch (self._parse_state) {
        .html => |html| {
            // The response buffer is consumed on the parser stack. A parser-
            // inserted script can synchronously discard its own browsing
            // context (`window.close()` or removing its owner iframe), and
            // Frame.retire() deinitializes `_parse_state`. Move ownership out
            // of the union before entering html5ever so retirement cannot free
            // the bytes that the native parser is still reading, nor overwrite
            // an `|*html|` payload captured by this stack frame.
            self._parse_state = .complete;
            defer self.releaseArena(html.arena);

            const raw_html = html.buffer.items;
            if (std.mem.eql(u8, self.charset, "UTF-8")) {
                parser.parse(raw_html);
            } else {
                parser.parseWithEncoding(raw_html, self.charset);
            }

            // Discard stopped and reset the ScriptManager while the parser was
            // unwinding. Do not restart its completion tail or dispatch load
            // lifecycle events for a browsing context that no longer exists.
            if (self.isRetired()) return;
            self._script_manager.staticScriptsDone();
        },
        .text => |*buf| {
            try buf.appendSlice(self.arena, "</pre></body></html>");
            parser.parse(buf.items);
            self.documentIsComplete();
        },
        .image => |buf| {
            self._parse_state = .{ .raw_done = buf.items };

            // Use empty an HTML containing the image.
            const html = try std.mem.concat(parse_arena, u8, &.{
                "<html><head><meta charset=\"utf-8\"></head><body><img src=\"",
                self.url,
                "\"></body></html>",
            });
            parser.parse(html);
            self.documentIsComplete();
        },
        .raw => |buf| {
            self._parse_state = .{ .raw_done = buf.items };

            // Use empty an empty HTML document.
            parser.parse("<html><head><meta charset=\"utf-8\"></head><body></body></html>");
            self.documentIsComplete();
        },
        .pre => {
            // Received a response without a body like: https://httpbin.io/status/200
            // We assume we have received an OK status (checked in Client.headerCallback)
            // so we load a blank document to navigate away from any prior frame.
            self._parse_state = .{ .complete = {} };

            // Use empty an empty HTML document.
            parser.parse("<html><head><meta charset=\"utf-8\"></head><body></body></html>");
            self.documentIsComplete();
        },
        .err => |err| {
            // Generate a pseudo HTML page indicating the failure.
            const html = try std.mem.concat(parse_arena, u8, &.{
                "<html><head><meta charset=\"utf-8\"></head><body><h1>Navigation failed</h1><p>Reason: ",
                @errorName(err),
                "</p></body></html>",
            });

            parser.parse(html);
            self._parse_state = .complete;
            self.documentIsComplete();
        },
        .download => |*download| {
            download.file.close();

            // Capture before invalidating the union below.
            const guid = download.guid;
            const received = download.received;
            const total = download.total orelse download.received;
            self._parse_state = .complete;

            const session = self._session;
            if (session.download_events_enabled) {
                session.notification.dispatch(.download_progress, &.{
                    .guid = guid,
                    .total_bytes = total,
                    .received_bytes = received,
                    .state = .completed,
                });
            }

            // The body went to disk; commit an empty document so the frame
            // navigation still completes cleanly (mirrors the .raw path).
            parser.parse("<html><head><meta charset=\"utf-8\"></head><body></body></html>");
            self.documentIsComplete();
        },
        else => unreachable,
    }
}

fn frameErrorCallback(ctx: *anyopaque, err: anyerror) void {
    var self: *Frame = @ptrCast(@alignCast(ctx));

    self._last_navigate_error = err;
    log.err(.frame, "navigate failed", .{ .err = err, .type = self._type, .url = self.url });

    // A navigation that fails before any response headers arrive never
    // reaches the frame_navigated dispatch in frameHeaderCallback, so the
    // Page.navigate command that initiated it would stay unanswered forever.
    // Tell CDP so it can answer with an errorText (Chrome semantics).
    // _http_status is set as soon as headers are processed; non-null means
    // frameHeaderCallback already answered the command — don't answer twice.
    if (self._http_status == null) {
        self._session.notification.dispatch(.frame_navigate_failed, &.{
            .frame_id = self._frame_id,
            .loader_id = self._loader_id,
            .timestamp = timestamp(.monotonic),
            .url = self.url,
            .err = err,
            .opts = self._navigated_options orelse .{},
        });
    }

    // A pending root navigation that failed before commit: discard the
    // pending Page; the OLD active Page (and its V8 context) is untouched.
    // We do NOT run frameDoneCallback against the pending frame — the frame
    // is about to be freed.
    if (self._page.replaces != null) {
        self._session.discardPendingPage(self._page);
        return;
    }

    self._parse_state.deinit(self);
    self._parse_state = .{ .err = err };

    // In case of error, we want to complete the frame with a custom HTML
    // containing the error.
    frameDoneCallback(ctx) catch |e| {
        log.err(.browser, "frameErrorCallback", .{ .err = e, .type = self._type, .url = self.url });
        return;
    };
}
pub fn isGoingAway(self: *const Frame) bool {
    if (self._retired or self._retire_in_progress != null or self._queued_navigation != null) {
        return true;
    }
    const parent = self.parent orelse return false;
    return parent.isGoingAway();
}

pub fn isRetired(self: *const Frame) bool {
    return self._retired;
}

pub fn isRetiring(self: *const Frame) bool {
    return self._retire_in_progress != null;
}

pub fn scriptAddedCallback(self: *Frame, comptime from_parser: bool, script: *Element.Html.Script) !void {
    if (self.isGoingAway()) {
        // if we're planning on navigating to another frame, don't run this script
        return;
    }

    if (comptime from_parser) {
        // parser-inserted scripts have force-async set to false, but only if
        // they have src or non-empty content
        if (script._src.len > 0 or script.asNode().firstChild() != null) {
            script._force_async = false;
        }
    }

    self._script_manager.addFromElement(from_parser, script, "parsing") catch |err| {
        log.err(.frame, "frame.scriptAddedCallback", .{
            .err = err,
            .url = self.url,
            .src = script.asElement().getAttributeSafe(comptime .wrap("src")),
            .type = self._type,
        });
    };
}

pub fn iframeAddedCallback(self: *Frame, iframe: *IFrame) !void {
    if (self.isGoingAway()) {
        // if we're planning on navigating to another frame, don't load this iframe
        return;
    }
    if (iframe._executed) {
        return;
    }
    // A Document node is "connected" even when it was created by
    // DOMImplementation and has no browsing context. Never borrow the caller's
    // Frame for such a synthetic (or already-retired) owner Document.
    const owner_document = iframe.asNode().ownerDocument(self) orelse return;
    if (owner_document._frame != self) return;
    // An iframe in a detached subtree has no nested browsing context.  Keep
    // _executed clear so inserting that subtree into a connected Document (or
    // a connected ShadowRoot) can create it during the insertion steps.
    if (!iframe.asNode().isConnected()) {
        return;
    }
    if (!self._session.subframe_loading_enabled) {
        // configured not to load frames
        iframe._executed = true;
        return;
    }

    const srcdoc = iframe.asElement().getAttributeSafe(comptime .wrap("srcdoc"));
    var src = if (srcdoc != null)
        "about:srcdoc"
    else
        iframe.asElement().getAttributeSafe(comptime .wrap("src")) orelse "";
    if (src.len == 0) src = "about:blank";

    if (iframe._window != null) {
        // This frame is being re-navigated. We need to do this through a
        // scheduleNavigation phase. We can't navigate immediately here, for
        // the same reason that a "root" frame can't immediately navigate:
        // we could be in the middle of a JS callback or something else that
        // doesn't exit the frame to just suddenly go away.
        return self.scheduleNavigation(src, .{
            .reason = .script,
            .kind = .{ .push = null },
            .srcdoc_body = srcdoc,
            .referrer_policy = iframe.navigationReferrerPolicy(),
        }, .{ .iframe = iframe });
    }

    iframe._executed = true;
    const session = self._session;

    const new_frame = try self.arena.create(Frame);
    const frame_id = session.nextFrameId();

    try Frame.init(new_frame, frame_id, self._page, .{
        .parent = self,
        .effective_frame_sandbox_flags = pendingSandboxFlagsForChild(self, iframe),
        .scoped_for_window = !iframe.asNode().isInShadowTree(),
    });
    var deinit_new_frame_on_error = true;
    errdefer if (deinit_new_frame_on_error) new_frame.deinit();

    // A child browsing context captures the owner's name attribute exactly
    // once. Later iframe.name mutations do not rename the context; writes to
    // child.window.name do.
    new_frame.iframe = iframe;
    try new_frame.window.setName(iframe.getName(), new_frame);

    const delays_load = iframe.isLazyLoading() == false;
    new_frame._delays_parent_load = delays_load;
    if (delays_load) {
        self._pending_loads += 1;
    }
    iframe._window = new_frame.window;
    errdefer {
        if (iframe._window == new_frame.window) iframe._window = null;
    }

    // on first load, dispatch frame_created event
    self._session.notification.dispatch(.frame_child_frame_created, &.{
        .parent_id = self._frame_id,
        .frame_id = new_frame._frame_id,
        .loader_id = new_frame._loader_id,
        .timestamp = timestamp(.monotonic),
    });

    const url = blk: {
        if (std.mem.eql(u8, src, "about:blank")) {
            break :blk "about:blank"; // navigate will handle this special case
        }
        if (std.mem.eql(u8, src, "about:srcdoc")) {
            break :blk "about:srcdoc"; // navigate will handle this special case
        }
        break :blk try URL.resolve(
            self.call_arena, // ok to use, frame.navigate dupes this
            self.base(),
            src,
            .{ .encoding = self.charset },
        );
    };

    // Append the new frame before navigate() so synchronous navigation paths
    // (about:blank, blob:) and the notifications they dispatch can see this
    // frame in self.child_frames.
    try self.child_frames.append(self.arena, new_frame);
    self.child_frames_mutation_serial +%= 1;
    // The active tree now owns the frame.  If synchronous child script later
    // retires it, Page.retired_frames takes over that ownership.  Only an
    // error path which successfully removes this exact active entry may hand
    // ownership back to this stack frame for deinitialization.
    deinit_new_frame_on_error = false;

    // Initial about:blank uses the immediate parent URL verbatim. Srcdoc and
    // network navigations use the Window outgoing-referrer source, which
    // walks out through any srcdoc ancestors. The parent outlives this
    // synchronous navigate call, so these slices are safe.
    const referrer_source = if (std.mem.eql(u8, url, "about:blank"))
        @as(?[:0]const u8, self.url)
    else
        self.outgoingReferrerSource();
    const initiator_url = if (referrer_source) |source|
        if (std.mem.startsWith(u8, source, "http")) source else null
    else
        null;
    new_frame.navigate(url, .{
        .reason = .initialFrameNavigation,
        .referer = referrer_source,
        .initiator_url = initiator_url,
        .referrer_policy = iframe.navigationReferrerPolicy(),
        .srcdoc_body = srcdoc,
    }) catch |err| {
        // extra defensive..maybe navigate added a new frame, and the index it
        // was added at was removed. Or maybe this frame was removed somehow
        // (which I don't think is possible)
        if (std.mem.indexOfScalar(*Frame, self.child_frames.items, new_frame)) |idx| {
            _ = self.child_frames.orderedRemove(idx);
            self.child_frames_mutation_serial +%= 1;
            deinit_new_frame_on_error = true;
        }
        log.warn(.frame, "iframe navigate failure", .{ .url = url, .err = err });
        if (delays_load and !new_frame._parent_notified and self._pending_loads > 0) {
            new_frame._parent_notified = true;
            self._pending_loads -= 1;
        }
        if (iframe._window == new_frame.window) iframe._window = null;
        return error.IFrameLoadError;
    };

    // Child frames stay in FrameTree creation order, matching Blink's
    // FrameTree::ScopedChild indexed getter; current DOM order is irrelevant.
}

/// Removing a connected iframe discards its nested browsing context. Native
/// realms stay Page-owned so cached Window/Document/Location wrappers remain
/// safe, but the context leaves the active frame tree and can no longer run
/// tasks, workers, or network callbacks.
fn iframeRemovedCallback(self: *Frame, iframe: *IFrame) void {
    const child_window = iframe._window orelse return;
    const child = child_window._frame;
    _ = std.mem.indexOfScalar(*Frame, self.child_frames.items, child) orelse {
        log.err(.frame, "iframe browsing context missing from parent", .{ .url = child.url });
        return;
    };

    // Blink's Frame::DetachImpl can make the parent Document complete before
    // Frame::DisconnectOwnerElement and FrameTree unlinking run. Consequently
    // a synchronous parent load listener still observes this child through
    // window.length and iframe.contentWindow, with Window.closed == false.
    // Publish the load completion first, then revalidate exact ownership: the
    // listener may itself move/remove this iframe and retire the captured
    // context through a nested mutation.
    if (!child._parent_notified) {
        child._parent_notified = true;
        if (child._delays_parent_load and self._pending_loads > 0) {
            self.pendingLoadCompleted();
        }
    }

    if (iframe._window != child_window) return;
    _ = std.mem.indexOfScalar(*Frame, self.child_frames.items, child) orelse return;

    self._page.retireFrameForDiscard(child) catch |err| {
        log.err(.frame, "iframe browsing context retirement failed", .{ .url = child.url, .err = err });
        return;
    };

    // Retirement shuts down network/worker producers and can itself complete
    // callbacks.  Re-find the child after that re-entrant boundary rather than
    // applying an index captured from the old list topology.
    const index = std.mem.indexOfScalar(*Frame, self.child_frames.items, child) orelse return;
    _ = self.child_frames.orderedRemove(index);
    self.child_frames_mutation_serial +%= 1;
}

/// FrameTree::ScopedChildCount equivalent used by Window's named/indexed
/// accessors.  CDP and lifecycle code intentionally continue to use the raw
/// child_frames list.
pub fn scopedChildCount(self: *const Frame) usize {
    var count: usize = 0;
    for (self.child_frames.items) |child| {
        if (child.scoped_for_window) count += 1;
    }
    return count;
}

/// FrameTree::ScopedChild equivalent. The index is creation order among the
/// browsing contexts whose scope was captured as the owning Document.
pub fn scopedChild(self: *Frame, wanted: usize) ?*Frame {
    var index: usize = 0;
    for (self.child_frames.items) |child| {
        if (!child.scoped_for_window) continue;
        if (index == wanted) return child;
        index += 1;
    }
    return null;
}

const OpenPopupOpts = struct {
    url: []const u8,
    name: []const u8,
    opener: ?*Window,
};

// Create a new top-level browsing context as a sibling of the root frame.
// The popup shares the Page's arena, factory, and identity map, but has no
// parent and is not attached to the frame tree — it lives in page.popups.
pub fn openPopup(self: *Frame, opts: OpenPopupOpts) !*Frame {
    const page = self._page;
    const session = self._session;

    const resolved_url: [:0]const u8 = blk: {
        if (opts.url.len == 0) {
            break :blk "about:blank";
        }
        if (std.mem.eql(u8, opts.url, "about:blank")) {
            break :blk "about:blank";
        }
        const frame_base = base_blk: {
            var frame = self;
            while (true) {
                const maybe_base = frame.base();
                if (!std.mem.eql(u8, maybe_base, "about:blank")) {
                    break :base_blk maybe_base;
                }
                frame = frame.parent orelse break :base_blk "";
            }
        };
        break :blk try URL.resolve(self.call_arena, frame_base, opts.url, .{ .encoding = self.charset });
    };

    const popup = try page.frame_arena.create(Frame);
    errdefer page.frame_arena.destroy(popup);

    const frame_id = session.nextFrameId();
    const source_sandbox_flags = self.activeSandboxFlags();
    const propagated_sandbox_flags = if (SandboxFlags.contains(
        source_sandbox_flags,
        SandboxFlags.propagates_to_auxiliary_browsing_contexts,
    )) source_sandbox_flags else SandboxFlags.none;
    try Frame.init(popup, frame_id, page, .{
        .opener = opts.opener,
        // This is based on the creation source even for `noopener`; opener
        // exposure and sandbox propagation are separate concepts in Chrome.
        .effective_frame_sandbox_flags = propagated_sandbox_flags,
        // A non-noopener initial empty Document clones the creator's policy
        // container. This is deliberately separate from frame propagation:
        // CSP sandbox survives an escape token for about:blank, while an
        // iframe-attribute sandbox does not.
        .csp_sandbox_flags = if (opts.opener != null)
            self._csp_sandbox_flags
        else
            SandboxFlags.none,
    });
    errdefer popup.deinit();

    // Chrome snapshots the opener's whole sessionStorage namespace when a new
    // auxiliary browsing context is created. The maps diverge immediately
    // afterwards. noopener/noreferrer pass no opener and therefore start with
    // a fresh lazy namespace; named-window reuse never reaches this path.
    if (opts.opener) |opener| {
        const allocator = session.browser.app.allocator;
        try session.storage_shed.cloneSessionNamespace(
            allocator,
            @intFromPtr(opener._frame.topFrame()._navigation_context),
            @intFromPtr(popup._navigation_context),
        );
        errdefer session.storage_shed.removeSessionNamespace(
            allocator,
            @intFromPtr(popup._navigation_context),
        );
    }

    popup.window._opener = opts.opener;
    if (opts.name.len > 0 and
        !std.ascii.eqlIgnoreCase(opts.name, "_blank") and
        !std.ascii.eqlIgnoreCase(opts.name, "_self") and
        !std.ascii.eqlIgnoreCase(opts.name, "_parent") and
        !std.ascii.eqlIgnoreCase(opts.name, "_top"))
    {
        popup.window._name = try page.frame_arena.dupe(u8, opts.name);
    }

    const popup_index = page.popups.items.len;
    try page.popups.append(page.frame_arena, popup);
    // not impossible that navigate adds popups, so remove by index
    errdefer _ = page.popups.swapRemove(popup_index);

    popup.navigate(resolved_url, .{ .reason = .script }) catch |err| {
        log.warn(.frame, "popup navigate failure", .{ .url = resolved_url, .err = err });
        return err;
    };

    return popup;
}

pub fn domChanged(self: *Frame) void {
    self._page.dom_version += 1;

    if (self._intersection.check_scheduled) {
        return;
    }

    self._intersection.check_scheduled = true;
    self.js.queueIntersectionChecks() catch |err| {
        log.err(.frame, "frame.schedIntersectChecks", .{ .err = err, .type = self._type, .url = self.url });
    };
}

pub const ElementIdMaps = struct { lookup: *std.StringHashMapUnmanaged(*Element), removed_ids: *std.StringHashMapUnmanaged(void) };

fn findElementIdMap(node: *Node) ?ElementIdMaps {
    // Walk up the tree checking for ShadowRoot and tracking the root
    var current = node;
    while (true) {
        if (current.is(ShadowRoot)) |shadow_root| {
            return .{
                .lookup = &shadow_root._elements_by_id,
                .removed_ids = &shadow_root._removed_ids,
            };
        }

        const parent = current._parent orelse {
            if (current._type == .document) {
                return .{
                    .lookup = &current._type.document._elements_by_id,
                    .removed_ids = &current._type.document._removed_ids,
                };
            }
            return null;
        };

        current = parent;
    }
}

fn getElementIdMap(frame: *Frame, node: *Node) ElementIdMaps {
    return findElementIdMap(node) orelse {
        // Callers registering an ID must only pass a Document- or
        // ShadowRoot-scoped node. Keep the release fallback for robustness.
        if (IS_DEBUG) std.debug.assert(false);
        return .{
            .lookup = &frame.document._elements_by_id,
            .removed_ids = &frame.document._removed_ids,
        };
    };
}

pub fn addElementId(self: *Frame, parent: *Node, element: *Element, id: []const u8) !void {
    return self.addElementIdWithMaps(self.getElementIdMap(parent), element, id);
}

fn addElementIdWithMaps(self: *Frame, id_maps: ElementIdMaps, element: *Element, id: []const u8) !void {
    const gop = try id_maps.lookup.getOrPut(self.arena, id);
    if (!gop.found_existing) {
        gop.value_ptr.* = element;
        return;
    }

    const existing = gop.value_ptr.*.asNode();
    // DOCUMENT_POSITION_FOLLOWING is a bitmask. Ancestor/descendant results
    // combine it with CONTAINED_BY/CONTAINS (for example 0x14), so an exact
    // equality check can leave a later descendant cached ahead of its newly
    // ID'd ancestor.
    if ((element.asNode().compareDocumentPosition(existing) & 0x04) != 0) {
        gop.value_ptr.* = element;
    }
}

pub fn removeElementId(self: *Frame, element: *Element, id: []const u8) void {
    const node = element.asNode();
    self.removeElementIdWithMaps(self.getElementIdMap(node), id);
}

pub fn removeElementIdWithMaps(self: *Frame, id_maps: ElementIdMaps, id: []const u8) void {
    if (id_maps.lookup.remove(id)) {
        const owned_id = self.dupeString(id) catch return;
        id_maps.removed_ids.put(self.arena, owned_id, {}) catch |err| {
            log.warn(.frame, "removeElementIdWithMaps", .{ .err = err });
        };
    }
}

pub fn getElementByIdFromNode(self: *Frame, node: *Node, id: []const u8) ?*Element {
    // The id map lives on the node's root: a Document, or a ShadowRoot for
    // shadow DOM. Walk to the root once and consult the matching map.
    const root = node.getRootNode(.{});
    if (root._type == .document) {
        return root._type.document.getElementById(id, self);
    }
    if (root.is(ShadowRoot)) |shadow_root| {
        return shadow_root.getElementById(id, self);
    }
    // Detached subtree (root is neither a Document nor a ShadowRoot): no id map
    // exists, so scan it.
    var tw = @import("webapi/TreeWalker.zig").Full.Elements.init(node, .{});
    while (tw.next()) |el| {
        const element_id = el.getAttributeSafe(comptime .wrap("id")) orelse continue;
        if (std.mem.eql(u8, element_id, id)) {
            return el;
        }
    }
    return null;
}

pub fn performance(self: *Frame) *Performance {
    return &self.window._performance;
}

// Tracks a file input's FileList so its File refs are released at teardown.
pub fn trackFileList(self: *Frame, file_list: *FileList) !void {
    try self._file_lists.append(self.arena, file_list);
}

pub const QueuedEvent = struct {
    kind: Kind,
    element: *Element.Html,
    // Image requests can settle and queue an event just before script changes
    // src.  Carry the request generation through to actual dispatch so that
    // the old task cannot leak a load/error event after the replacement.
    image_generation: ?u64 = null,

    pub const Kind = enum { load, @"error" };
};

pub fn queueLoad(self: *Frame, html: *Element.Html) !void {
    try self.queueElementEvent(html, .load);
}

pub fn queueImageEvent(
    self: *Frame,
    image: *Element.Html.Image,
    generation: u64,
    kind: QueuedEvent.Kind,
) !void {
    try self.queueElementEventWithGeneration(image._proto, kind, generation);
}

pub fn queueElementEvent(self: *Frame, element: *Element.Html, kind: QueuedEvent.Kind) !void {
    return self.queueElementEventWithGeneration(element, kind, null);
}

fn queueElementEventWithGeneration(
    self: *Frame,
    element: *Element.Html,
    kind: QueuedEvent.Kind,
    image_generation: ?u64,
) !void {
    try self._queued_events.append(self.arena, .{
        .element = element,
        .kind = kind,
        .image_generation = image_generation,
    });
    if (self._queued_events.items.len == 1) {
        try self.js.scheduler.add(self, struct {
            fn cleanup(ctx: *anyopaque) !?u32 {
                const f: *Frame = @ptrCast(@alignCast(ctx));
                try f.dispatchQueuedEvents();
                return null;
            }
        }.cleanup, 0, .{ .name = "frame.dispatchQueuedEvents" });
    }
}

const HashChangeCallback = struct {
    frame: *Frame,
    old_url: []const u8,
    new_url: []const u8,

    // Called by the scheduler if the task is dropped before it runs (e.g. the
    // page is torn down).
    fn cancelled(ctx: *anyopaque) void {
        const self: *HashChangeCallback = @ptrCast(@alignCast(ctx));
        self.frame._factory.destroy(self);
    }

    fn run(ctx: *anyopaque) !?u32 {
        const self: *HashChangeCallback = @ptrCast(@alignCast(ctx));
        defer self.frame._factory.destroy(self);

        const frame = self.frame;
        const target = frame.window.asEventTarget();
        if (!frame._event_manager.hasDirectListeners(target, "hashchange", frame.window._on_hashchange)) {
            return null;
        }

        const event = (try HashChangeEvent.initTrusted(comptime .wrap("hashchange"), .{
            .oldURL = self.old_url,
            .newURL = self.new_url,
        }, frame)).asEvent();
        try frame._event_manager.dispatchDirect(target, event, frame.window._on_hashchange, .{ .context = "Hash Change" });
        return null;
    }
};

pub fn queueHashChange(self: *Frame, old_url: []const u8, new_url: []const u8) !void {
    const callback = try self._factory.create(HashChangeCallback{
        .frame = self,
        .old_url = old_url,
        .new_url = new_url,
    });
    try self.js.scheduler.add(callback, HashChangeCallback.run, 0, .{
        .name = "frame.hashChange",
        .finalizer = HashChangeCallback.cancelled,
    });
}

// Hard cap on a single external stylesheet body. CSS rule storage is per-
// arena so a hostile sheet could otherwise inflate page memory; 2 MiB is
// well above anything seen on real sites (Tailwind's `preflight + utilities`
// build is ~400 KiB gzipped, ~3 MiB raw — at which point a site should be
// splitting by route anyway).
const MAX_STYLESHEET_BYTES: usize = 2 * 1024 * 1024;

// start prefetching <link rel="preload" as="script" href=...>`
pub fn preloadScriptHint(self: *Frame, element: *Element.Html, href: []const u8) bool {
    if (self.isGoingAway() or self._parse_mode == .fragment) {
        return false;
    }

    const arena = self.getArena(.small, "Frame.preloadScriptHint") catch return false;
    defer self.releaseArena(arena);

    const resolved = URL.resolve(arena, self.base(), href, .{ .encoding = self.charset }) catch return false;
    if (!std.ascii.startsWithIgnoreCase(resolved, "http:") and !std.ascii.startsWithIgnoreCase(resolved, "https:")) {
        // data:/blob: are synthesized locally — no round-trip to hide.
        return false;
    }
    return self._script_manager.preloadScript(element, resolved) catch false;
}

// start prefetching <link rel="modulepreload" href=...>
pub fn preloadModuleHint(self: *Frame, element: *Element.Html, href: []const u8) bool {
    if (self.isGoingAway() or self._parse_mode == .fragment) {
        return false;
    }

    // The url becomes the imported_modules key, which must outlive the fetch
    // so it lives on the frame arena
    const resolved = URL.resolve(self.arena, self.base(), href, .{ .encoding = self.charset }) catch return false;
    if (!std.ascii.startsWithIgnoreCase(resolved, "http:") and !std.ascii.startsWithIgnoreCase(resolved, "https:")) {
        // data:/blob: are synthesized locally — no round-trip to hide.
        return false;
    }

    return self._script_manager.base.preloadModuleHint(element, resolved, self.url) catch false;
}

/// Register an owner-backed stylesheet in its current DOM TreeScope. The
/// cached StyleSheetList object stays stable; its contents are mutated live.
pub fn registerStyleSheet(self: *Frame, sheet: *CSSStyleSheet) !void {
    const owner = sheet.getOwnerNode() orelse return;
    const owner_node = owner.asNode();
    if (!owner_node.isConnected()) {
        self.unregisterStyleSheet(sheet);
        return;
    }

    const root = owner_node.getRootNode(.{});
    const document = root.is(Document);
    const shadow_root = root.is(ShadowRoot);
    if (document == null and shadow_root == null) return;

    if (self._style_sheet_roots.get(sheet)) |old_root| {
        if (old_root != root) self.unregisterStyleSheet(sheet);
    }

    const already_registered = self._style_sheet_roots.get(sheet) != null;
    if (!already_registered) {
        try self._style_sheet_roots.put(self.arena, sheet, root);
        errdefer _ = self._style_sheet_roots.remove(sheet);
    }
    if (document) |doc| {
        try (try doc.getStyleSheets(self)).add(sheet, self);
    } else {
        try (try shadow_root.?.getStyleSheets(self)).add(sheet, self);
    }
}

/// Deregister using the remembered TreeScope rather than the owner's current
/// root. DOM removal has already cleared `_parent` by the time disconnect
/// callbacks run, so recomputing the root there would lose a shadow boundary.
pub fn unregisterStyleSheet(self: *Frame, sheet: *CSSStyleSheet) void {
    const root = self._style_sheet_roots.get(sheet) orelse return;
    if (root.is(Document)) |document| {
        if (document._style_sheets) |sheets| sheets.remove(sheet);
    } else if (root.is(ShadowRoot)) |shadow_root| {
        if (shadow_root._style_sheets) |sheets| sheets.remove(sheet);
    }
    _ = self._style_sheet_roots.remove(sheet);
}

/// Fragment parsing and insertion of an already-built subtree bypass the
/// per-node ready callback for descendant `<style>` elements. Reconcile their
/// cached sheets once the final parent links (and therefore TreeScopes) exist.
fn registerStyleSheetsInSubtree(self: *Frame, root: *Node) !void {
    if (!root.isConnected()) return;
    var elements: std.ArrayList(*Element) = .empty;
    try self.collectShadowIncludingElements(root, &elements);
    for (elements.items) |element| {
        if (element.is(Element.Html.Style)) |style| {
            _ = try style.getSheet(self);
        } else if (element.is(Element.Html.Link)) |link| {
            if (link._sheet) |sheet| try self.registerStyleSheet(sheet);
        }
    }
}

// Synchronously fetch and parse an external `<link rel=stylesheet>`.
// href is passed in as an optimization since the [currently] only callsite has
// it, so why look it up again?
pub fn loadExternalStylesheet(self: *Frame, link: *Element.Html.Link, href: []const u8) !void {
    if (self.isGoingAway() or href.len == 0) {
        return;
    }

    const session = self._session;

    // this feature is disabled by default, and can be turned on via a command
    // line flag or via an CDP command
    if (session.load_external_stylesheets == false) {
        return self.queueLoad(link._proto);
    }

    // Fragment-parsed links (innerHTML, DOMParser, ...) may not be attached.
    // TODO: this isn't correct in all cases. If the link is added into an
    // attached node, I think we SHOULD load it.
    if (self._parse_mode == .fragment) {
        return;
    }
    const element = link.asElement();

    const arena = try session.getArena(.medium, "Frame.loadExternalStylesheet");
    defer session.releaseArena(arena);

    const resolved = URL.resolve(arena, self.base(), href, .{ .encoding = self.charset }) catch |err| {
        log.warn(.http, "external stylesheet resolve", .{ .err = err, .href = href });
        try self.fireElementEvent(element, comptime .wrap("error"));
        return;
    };

    const http_client = &session.browser.http_client;

    // `syncRequest` below registers a blocking request for this frame, which
    // makes the DeferringLayer hold back the completion callbacks of every
    // OTHER in-flight transfer for the frame (e.g. a `<script defer>` still
    // loading) so they don't run JS while we're on the parser stack. Those
    // deferred completions must be flushed once the sync fetch returns —
    // otherwise a `<script defer>` whose fetch finishes during this window is
    // left at `complete == false` forever, the deferred-script queue never
    // drains, and `documentIsLoaded` (readyState -> "interactive",
    // DOMContentLoaded, the load event) never fires. The blocking-`<script>`
    // path (ScriptManager.addFromElement) and the worker path already flush;
    // the external-stylesheet path must too.
    defer http_client.deferring_layer.flushFrame(self._frame_id);

    const headers = try http_client.newRequestHeaders(resolved, .{
        .destination = .style,
        .mode = .no_cors,
        .initiator_url = self.url,
        .top_level_url = self.url,
        .referrer_url = self.url,
        .credentials = .include,
    });

    // Set the script-manager `is_evaluating` flag for the same reason
    // `ScriptManager.addFromElement` does: `syncRequest` pumps the CDP
    // socket inline, so a `Target.closeTarget` / `Page.close` arriving
    // mid-fetch would otherwise drive `Session.removePage` while this
    // function still holds pointers to `self`. The check in
    // `Session.removePage` (Session.zig:253) consults
    // `frame.anyScriptEvaluating()`, which only sees this flag.
    const sm = &self._script_manager.base;
    const was_evaluating = sm.is_evaluating;
    sm.is_evaluating = true;
    defer sm.endEvaluationWindow(was_evaluating);

    var response = http_client.syncRequest(arena, .{
        .url = resolved,
        .method = .GET,
        .frame_id = self._frame_id,
        .loader_id = self._loader_id,
        .headers = headers,
        .cookie_jar = &session.cookie_jar,
        .cookie_origin = self.url,
        .resource_type = .stylesheet,
        .notification = session.notification,
        .resource_timing = self.performance().resourceTimingSink(&self.js.execution, .link),
    }) catch |err| {
        log.warn(.http, "external stylesheet fetch", .{ .err = err, .url = resolved });
        return self.fireElementEvent(element, comptime .wrap("error"));
    };
    defer response.deinit(arena);

    if (response.status < 200 or response.status >= 300) {
        log.info(.http, "external stylesheet status", .{ .status = response.status, .url = resolved });
        return self.fireElementEvent(element, comptime .wrap("error"));
    }

    if (response.body.items.len > MAX_STYLESHEET_BYTES) {
        log.warn(.http, "external stylesheet too large", .{
            .bytes = response.body.items.len,
            .max = MAX_STYLESHEET_BYTES,
            .url = resolved,
        });
        return self.fireElementEvent(element, comptime .wrap("error"));
    }

    // Reuse the cached sheet on re-fetch (href mutation on a connected
    // link) so `document.styleSheets` keeps a single entry per <link>
    // instead of accumulating one per href change. On first load, create
    // and register; on subsequent loads, replace content in place.
    //
    // First-load creation assigns `link._sheet` AFTER `sheets.add`
    // succeeds so an OOM during registration doesn't cache an unregistered
    // sheet (which would short-circuit every future re-fetch via the
    // `orelse` branch, leaving the sheet permanently unreachable through
    // its TreeScope's styleSheets).
    const sheet = link._sheet orelse blk: {
        const new_sheet = try CSSStyleSheet.initWithOwner(element, self);
        try self.registerStyleSheet(new_sheet);
        link._sheet = new_sheet;
        break :blk new_sheet;
    };
    // A retained sheet can be reloaded after a state-preserving move. Refresh
    // its TreeScope membership and DOM-order position before replacing rules.
    try self.registerStyleSheet(sheet);

    // Parse first, only swap `_href` on success. `replaceSync` itself is
    // not atomic (clears rules before the insert loop), so a mid-parse
    // OOM still drops the old rules — full atomicity would require a
    // scratch-list pattern in `CSSStyleSheet.replaceSync`. Keeping
    // `_href` consistent with what the sheet actually contains is the
    // minimum.
    sheet.replaceSync(response.body.items, self) catch |err| {
        log.warn(.http, "external stylesheet parse", .{ .err = err, .url = resolved });
        return self.fireElementEvent(element, comptime .wrap("error"));
    };
    sheet._href = try self.arena.dupe(u8, resolved);

    try self.fireElementEvent(element, comptime .wrap("load"));
}

fn fireElementEvent(self: *Frame, el: *Element, name: String) !void {
    const event = try Event.initTrusted(name, .{}, self._page);
    try self._event_manager.dispatch(el.asEventTarget(), event);
}

fn dispatchQueuedEvents(self: *Frame) !void {
    const has_dom_load_listener = self._event_manager.has_dom_load_listener;

    // Swap buffers - new additions during dispatch go to the other buffer
    const to_process = self._queued_events;
    self._queued_events = if (self._queued_events == &self._queued_events_1)
        &self._queued_events_2
    else
        &self._queued_events_1;

    for (to_process.items) |queued| {
        const html_element = queued.element;
        if (queued.image_generation) |generation| {
            const image = html_element.is(Element.Html.Image) orelse continue;
            if (!image.isCurrentGeneration(generation)) continue;
        }
        const element = html_element.asElement();
        switch (queued.kind) {
            // hasAttributeFunction only sees handlers compiled via property
            // access; a parsed `onload="..."` attribute is compiled lazily at
            // dispatch (EventManager.getInlineHandler), so check it raw too.
            .load => {
                if (has_dom_load_listener or
                    html_element.hasAttributeFunction(.onload, self) or
                    element.getAttributeSafe(comptime .wrap("onload")) != null)
                {
                    try self.fireElementEvent(element, comptime .wrap("load"));
                }
            },
            .@"error" => {
                // errors are rare; not worth a listener-presence check
                try self.fireElementEvent(element, comptime .wrap("error"));
            },
        }
    }

    to_process.clearRetainingCapacity();
}

pub fn scheduleCustomElementBackupDrain(self: *Frame) !void {
    try self.js.queueCustomElementBackupDrain();
}

// Run the network-idle notification checks for this frame and, recursively,
// its child frames. CDP clients (e.g. puppeteer's networkidle0) expect the
// networkIdle/networkAlmostIdle lifecycle events on every frame, like Chrome
// emits them, not just on the root frame.
pub fn checkIdleNotifications(self: *Frame, total_http_activity: usize) void {
    switch (self._parse_state) {
        .html, .complete => {
            if (self._notified_network_almost_idle.check(total_http_activity <= 2)) {
                self.notifyNetworkAlmostIdle();
            }
            if (self._notified_network_idle.check(total_http_activity == 0)) {
                self.notifyNetworkIdle();
            }
        },
        else => {},
    }
    for (self.child_frames.items) |child| {
        child.checkIdleNotifications(total_http_activity);
    }
}

pub fn notifyNetworkIdle(self: *Frame) void {
    lp.assert(self._notified_network_idle == .done, "Frame.notifyNetworkIdle", .{});
    self._session.notification.dispatch(.frame_network_idle, &.{
        .req_id = self._req_id,
        .frame_id = self._frame_id,
        .loader_id = self._loader_id,
        .timestamp = timestamp(.monotonic),
    });
}

pub fn notifyNetworkAlmostIdle(self: *Frame) void {
    lp.assert(self._notified_network_almost_idle == .done, "Frame.notifyNetworkAlmostIdle", .{});
    self._session.notification.dispatch(.frame_network_almost_idle, &.{
        .req_id = self._req_id,
        .frame_id = self._frame_id,
        .loader_id = self._loader_id,
        .timestamp = timestamp(.monotonic),
    });
}

// called from the parser. Text-node merging is the parser's responsibility
// (see Parser.appendTextChunk in src/browser/parser/Parser.zig); this is the
// "insert this fully-formed node as a new last child of parent" entry point.
pub fn appendNew(self: *Frame, parent: *Node, child: *Node) !void {
    lp.assert(child._parent == null, "Frame.appendNew", .{});
    try self._insertNodeRelative(true, parent, child, .append, .{
        // this opts has no meaning since we're passing `true` as the first
        // parameter, which indicates this comes from the parser, and has its
        // own special processing. Still, set it to be clear.
        .child_already_connected = false,
    });
}

// called from the parser when the node and all its children have been added
pub fn nodeComplete(self: *Frame, node: *Node) !void {
    Node.Build.call(node, "complete", .{ node, self }) catch |err| {
        log.err(.bug, "build.complete", .{ .tag = node.getNodeName(&self.buf), .err = err, .type = self._type, .url = self.url });
        return err;
    };
    return self.nodeIsReady(true, node);
}

// Sets the owner document for a node. Only stores entries for nodes whose owner
// is NOT frame.document to minimize memory overhead.
pub fn setNodeOwnerDocument(self: *Frame, node: *Node, owner: *Document) !void {
    if (owner == self.document) {
        // No need to store if it's the main document - remove if present
        _ = self._node_owner_documents.remove(node);
    } else {
        try self._node_owner_documents.put(self.arena, node, owner);
    }
}

// Recursively sets the owner document for a node and all its descendants
pub fn adoptNodeTree(self: *Frame, node: *Node, old_owner: *Document, new_owner: *Document) !void {
    try self.setNodeOwnerDocument(node, new_owner);

    // Per spec, adopted steps run on each element after its document is set.
    if (node.is(Element)) |el| {
        Element.Html.Custom.enqueueAdoptedCallbackOnElement(el, old_owner, new_owner, self);

        // Adoption walks shadow-including inclusive descendants. An attached
        // ShadowRoot is not in the host's light child list, but its own Node
        // and every descendant still receive the new owner Document (and any
        // custom elements inside enqueue adoptedCallback in tree order).
        if (self._element_shadow_roots.get(el)) |shadow_root| {
            try self.adoptNodeTree(shadow_root.asNode(), old_owner, new_owner);
        }
    }

    var it = node.childrenIterator();
    while (it.next()) |child| {
        try self.adoptNodeTree(child, old_owner, new_owner);
    }
}

pub fn dupeString(self: *Frame, value: []const u8) ![]const u8 {
    if (String.intern(value)) |v| {
        return v;
    }
    return self.arena.dupe(u8, value);
}

// Direct (non-propagating) dispatch of an event. Mirrors WorkerGlobalScope.dispatch
// so worker-compatible APIs can uniformly call `global.dispatch(...)` across both
// Frame and Worker contexts.
pub fn dispatch(
    self: *Frame,
    target: *EventTarget,
    event: *Event,
    handler: anytype,
    comptime opts: EventManager.DispatchDirectOptions,
) !void {
    return self._event_manager.dispatchDirect(target, event, handler, opts);
}

pub fn hasDirectListeners(self: *Frame, target: *EventTarget, typ: []const u8, handler: anytype) bool {
    return self._event_manager.hasDirectListeners(target, typ, handler);
}

pub fn dupeSSO(self: *Frame, value: []const u8) !String {
    return String.init(self.arena, value, .{ .dupe = true });
}

const RemoveNodeOpts = struct {
    will_be_reconnected: bool,
    // Only Node.moveBefore performs a state-preserving atomic move. Ordinary
    // appendChild/insertBefore operations may use the fast DOM reconnect path,
    // but still discard and recreate every descendant browsing context.
    preserve_browsing_contexts: bool = false,
};

pub const RemoveNodeResult = enum {
    proceed,
    reentered,
};

const DisconnectedElementSnapshot = struct {
    element: *Element,
    id_maps: ElementIdMaps,
    iframe_window: ?*Window,
    mutation_serial: u64,
};

const ConnectedElementSnapshot = struct {
    element: *Element,
    mutation_serial: u64,
};

pub const StatePreservingMoveIdEntry = struct {
    element: *Element,
    old_maps: ?ElementIdMaps,
    old_id: []const u8,
};

pub const StatePreservingMoveIdSnapshot = struct {
    entries: std.ArrayList(StatePreservingMoveIdEntry) = .empty,
};

/// Snapshot elements in shadow-including tree order. TreeWalker intentionally
/// follows only the light DOM `_children` links, while lifecycle and nested
/// browsing-context insertion/removal also cross an attached ShadowRoot.
fn collectShadowIncludingElements(
    self: *Frame,
    root: *Node,
    elements: *std.ArrayList(*Element),
) !void {
    var stack: std.ArrayList(*Node) = .empty;
    try stack.append(self.call_arena, root);

    while (stack.pop()) |node| {
        if (node.is(Element)) |element| {
            try elements.append(self.call_arena, element);

            // Push light children first (in reverse), then the shadow root so
            // LIFO traversal visits the shadow tree immediately after its host.
            var light_child = node.lastChild();
            while (light_child) |current| : (light_child = current.previousSibling()) {
                try stack.append(self.call_arena, current);
            }
            if (self._element_shadow_roots.get(element)) |shadow_root| {
                try stack.append(self.call_arena, shadow_root.asNode());
            }
            continue;
        }

        var child_node = node.lastChild();
        while (child_node) |current| : (child_node = current.previousSibling()) {
            try stack.append(self.call_arena, current);
        }
    }
}

/// Capture ID registrations before an atomic move. A host's light descendants
/// can change TreeScope while descendants of its own shadow root remain in
/// that nested ShadowRoot, so the snapshot must be shadow-including and retain
/// each element's exact old map.
pub fn snapshotStatePreservingMoveIds(self: *Frame, root: *Node) !StatePreservingMoveIdSnapshot {
    var elements: std.ArrayList(*Element) = .empty;
    try self.collectShadowIncludingElements(root, &elements);

    var snapshot: StatePreservingMoveIdSnapshot = .{};
    for (elements.items) |element| {
        const id = element.getAttributeSafe(comptime .wrap("id")) orelse continue;
        try snapshot.entries.append(self.call_arena, .{
            .element = element,
            .old_maps = findElementIdMap(element.asNode()),
            .old_id = try self.call_arena.dupe(u8, id),
        });
    }
    return snapshot;
}

fn sameElementIdMaps(first: ?ElementIdMaps, second: ?ElementIdMaps) bool {
    if (first) |first_maps| {
        const second_maps = second orelse return false;
        return first_maps.lookup == second_maps.lookup;
    }
    return second == null;
}

/// Repair only registrations whose TreeScope changed. Removal is a separate
/// first pass so duplicate IDs in either scope are resolved against the final
/// tree order when the second pass adds current IDs. No browsing-context or
/// custom-element lifecycle work is performed here.
pub fn migrateStatePreservingMoveIds(self: *Frame, snapshot: *const StatePreservingMoveIdSnapshot) !void {
    for (snapshot.entries.items) |entry| {
        const new_maps = findElementIdMap(entry.element.asNode());
        if (sameElementIdMaps(entry.old_maps, new_maps)) continue;
        if (entry.old_maps) |old_maps| {
            self.removeElementIdWithMaps(old_maps, entry.old_id);
        }
    }

    for (snapshot.entries.items) |entry| {
        const new_maps = findElementIdMap(entry.element.asNode());
        if (sameElementIdMaps(entry.old_maps, new_maps)) continue;
        const maps = new_maps orelse continue;
        const id = entry.element.getAttributeSafe(comptime .wrap("id")) orelse continue;
        try self.addElementIdWithMaps(maps, entry.element, id);
    }
}

/// State-preserving atomic moves enqueue connectedMoveCallback for every
/// custom element in the shadow-including subtree, not just light-DOM nodes.
pub fn enqueueConnectedMoveCallbacks(self: *Frame, root: *Node) !void {
    var elements: std.ArrayList(*Element) = .empty;
    try self.collectShadowIncludingElements(root, &elements);
    for (elements.items) |element| {
        if (!root.shadowIncludingContains(element.asNode())) continue;
        Element.Html.Custom.enqueueMoveCallbackOnElement(element, self);
    }
}

pub fn removeNode(self: *Frame, parent: *Node, child: *Node, opts: RemoveNodeOpts) RemoveNodeResult {
    // Every caller can cross an iframe-discard/load-completion boundary. A
    // previously captured sibling may have been moved by re-entrant script;
    // removing its intrusive link from the stale parent's list corrupts both
    // lists. Treat stale membership exactly like any other re-entry and let the
    // nested mutation win.
    if (child._parent != parent) return .reentered;
    const children = parent._children orelse return .reentered;
    const initial_child_mutation_serial = child._tree_mutation_serial;

    // Capture siblings before removing
    const previous_sibling = child.previousSibling();
    const next_sibling = child.nextSibling();

    const was_connected = child.isConnected();
    const state_preserving_move = opts.will_be_reconnected and opts.preserve_browsing_contexts;

    // Capture every element, its current TreeScope ID maps, and the exact
    // browsing context before detaching. iframe retirement can synchronously
    // run parent completion work, so no live walker may cross that boundary.
    var disconnected_elements: std.ArrayList(DisconnectedElementSnapshot) = .empty;
    if (was_connected and !state_preserving_move) {
        var elements: std.ArrayList(*Element) = .empty;
        self.collectShadowIncludingElements(child, &elements) catch
            @panic("out of memory while snapshotting shadow-including removal");
        for (elements.items) |element| {
            disconnected_elements.append(self.call_arena, .{
                .element = element,
                .id_maps = self.getElementIdMap(element.asNode()),
                .iframe_window = if (element.is(IFrame)) |iframe| iframe._window else null,
                .mutation_serial = element.asNode()._tree_mutation_serial,
            }) catch @panic("out of memory while snapshotting removal element state");
        }
    }

    // Blink disconnects descendant browsing contexts from WillRemoveChild,
    // before RemoveBetween unlinks the subtree. Besides matching observable
    // isConnected state during a synchronous load/unload callback, this makes
    // a re-entrant ordinary move of a later iframe see a genuinely connected
    // owner and retire/recreate that iframe's context itself. Snapshot the
    // owners first, then revalidate both root membership and exact Window
    // identity at every script boundary. A later owner moved outside the root
    // is skipped, matching ChildFrameDisconnector's containment check.
    if (was_connected and !state_preserving_move) {
        for (disconnected_elements.items) |snapshot| {
            const child_window = snapshot.iframe_window orelse continue;
            const iframe = snapshot.element.is(IFrame) orelse continue;
            if (child._parent != parent or
                child._tree_mutation_serial != initial_child_mutation_serial)
            {
                return .reentered;
            }
            if (!child.shadowIncludingContains(iframe.asNode())) continue;
            if (iframe._window != child_window) continue;

            const browsing_context_parent = child_window._frame.parent orelse self;
            browsing_context_parent.iframeRemovedCallback(iframe);

            if (child._parent != parent or
                child._tree_mutation_serial != initial_child_mutation_serial)
            {
                return .reentered;
            }
        }
    }

    // Capture child's index before removal for live range updates (DOM spec remove steps 4-7)
    const child_index_for_ranges: ?u32 = if (self._live_ranges.first != null)
        parent.getChildIndex(child)
    else
        null;

    children.remove(&child._child_link);
    if (children.first == null) {
        // last child removed; drop the list so a childless node holds no allocation
        parent._children = null;
        self._factory.destroy(children);
    }
    child._parent = null;
    child._child_link = .{};
    child._tree_mutation_serial +%= 1;
    const removal_serial = child._tree_mutation_serial;

    // Update live ranges for removal (DOM spec remove steps 4-7)
    if (child_index_for_ranges) |idx| {
        self.updateRangesForNodeRemoval(parent, child, idx);
    }

    slotting.removalSteps(parent, child, self);

    if (observers.hasMutationObservers(self)) {
        const removed = [_]*Node{child};
        observers.notifyChildListChange(self, parent, &.{}, &removed, previous_sibling, next_sibling);
    }

    if (state_preserving_move) {
        // We might be removing the node only to re-insert it. If the node will
        // remain connected, we can skip the expensive process of fully
        // disconnecting it.
        return .proceed;
    }

    if (was_connected == false) {
        // If the child wasn't connected, then there should be nothing left for
        // us to do
        return .proceed;
    }

    // The child was connected and now it no longer is. Perform the remaining
    // shadow-including disconnect steps from the immutable snapshot.
    for (disconnected_elements.items) |snapshot| {
        if (child._parent != null or child._tree_mutation_serial != removal_serial) return .reentered;
        const el = snapshot.element;
        if (!child.shadowIncludingContains(el.asNode())) continue;
        const expected_serial = snapshot.mutation_serial +% @as(u64, if (el.asNode() == child) 1 else 0);
        if (el.asNode()._tree_mutation_serial != expected_serial) continue;

        if (el.getAttributeSafe(comptime .wrap("id"))) |id| {
            self.removeElementIdWithMaps(snapshot.id_maps, id);
        }

        Element.Html.Custom.enqueueDisconnectedCallbackOnElement(el, self);

        popover.removeFromOpen(el, self);

        // If a <style> element is being removed, remove its sheet from the list
        if (el.is(Element.Html.Style)) |style| {
            if (style._sheet) |sheet| {
                self.unregisterStyleSheet(sheet);
                style._sheet = null;
            }
            self._style_manager.sheetModified();
        } else if (el.is(Element.Html.Link)) |link| {
            // External stylesheet links registered via Frame.loadExternalStylesheet
            // must be symmetrically deregistered on disconnect, or
            // `document.styleSheets` accumulates phantom entries and the
            // visibility cascade keeps honoring rules from removed links —
            // exactly the SPA theme-switch pattern (append new sheet,
            // remove old) the feature exists to serve.
            if (link._sheet) |sheet| {
                self.unregisterStyleSheet(sheet);
                link._sheet = null;
                self._style_manager.sheetModified();
            }
        }
    }

    return .proceed;
}

pub fn appendNode(self: *Frame, parent: *Node, child: *Node, opts: InsertNodeOpts) !void {
    return self._insertNodeRelative(false, parent, child, .append, opts);
}

pub fn appendAllChildren(self: *Frame, parent: *Node, target: *Node) !void {
    self.domChanged();
    const dest_connected = target.isConnected();

    while (parent.firstChild()) |child| {
        const child_was_connected = child.isConnected();
        {
            var load_guard = self.beginReconnectLoadGuard(child_was_connected and dest_connected);
            defer load_guard.deinit();
            if (self.removeNode(parent, child, .{ .will_be_reconnected = dest_connected }) == .reentered) return;
            try self.appendNode(target, child, .{ .child_already_connected = child_was_connected });
        }
    }
}

pub fn insertAllChildrenBefore(self: *Frame, fragment: *Node, parent: *Node, ref_node: *Node) !void {
    self.domChanged();
    const dest_connected = parent.isConnected();

    while (fragment.firstChild()) |child| {
        const child_was_connected = child.isConnected();
        {
            var load_guard = self.beginReconnectLoadGuard(child_was_connected and dest_connected);
            defer load_guard.deinit();
            if (self.removeNode(fragment, child, .{ .will_be_reconnected = dest_connected }) == .reentered) return;
            try self.insertNodeRelative(
                parent,
                child,
                .{ .before = ref_node },
                .{ .child_already_connected = child_was_connected },
            );
        }
    }
}

const InsertNodeRelative = union(enum) {
    append,
    after: *Node,
    before: *Node,
};
const InsertNodeOpts = struct {
    child_already_connected: bool = false,
    adopting_to_new_document: bool = false,
    preserve_browsing_contexts: bool = false,
};
pub fn insertNodeRelative(self: *Frame, parent: *Node, child: *Node, relative: InsertNodeRelative, opts: InsertNodeOpts) !void {
    return self._insertNodeRelative(false, parent, child, relative, opts);
}
pub fn _insertNodeRelative(self: *Frame, comptime from_parser: bool, parent: *Node, child: *Node, relative: InsertNodeRelative, opts: InsertNodeOpts) !void {
    // caller should have made sure this was the case

    lp.assert(child._parent == null, "Frame.insertNodeRelative parent", .{});

    const children = parent._children orelse blk: {
        const list = try self._factory.create(std.DoublyLinkedList{});
        parent._children = list;
        break :blk list;
    };

    switch (relative) {
        .append => children.append(&child._child_link),
        .after => |ref_node| {
            // caller should have made sure this was the case
            lp.assert(ref_node._parent.? == parent, "Frame.insertNodeRelative after", .{ .url = self.url });
            children.insertAfter(&ref_node._child_link, &child._child_link);
        },
        .before => |ref_node| {
            // caller should have made sure this was the case
            lp.assert(ref_node._parent.? == parent, "Frame.insertNodeRelative before", .{ .url = self.url });
            children.insertBefore(&ref_node._child_link, &child._child_link);
        },
    }
    child._parent = parent;
    child._tree_mutation_serial +%= 1;
    const insertion_serial = child._tree_mutation_serial;

    // Update live ranges for insertion (DOM spec insert step 6).
    // For .before/.after the child was inserted at a specific position;
    // ranges on parent with offsets past that position must be incremented.
    // For .append no range update is needed (spec: "if child is non-null").
    if (self._live_ranges.first != null) {
        switch (relative) {
            .append => {},
            .before, .after => {
                if (parent.getChildIndex(child)) |idx| {
                    self.updateRangesForNodeInsertion(parent, idx);
                }
            },
        }
    }

    if (self._element_shadow_roots.count() != 0) {
        // html5ever wraps fragment parses in a temporary <html> element that
        // gets unwrapped later; it must not take part in slot assignment.
        const in_fragment_parse = from_parser and self._parse_mode == .fragment;
        const is_fragment_wrapper = in_fragment_parse and child.is(Element.Html.Html) != null;
        if (is_fragment_wrapper == false) {
            slotting.insertionSteps(parent, child, in_fragment_parse, self);
        }
    }

    // The parser path does its own (limited) notification and connected-callback
    // work, then returns.
    if (comptime from_parser) {
        // <meta> is a void element and never reaches nodeComplete. Process an
        // enforced CSP at the insertion point so it affects the next parser
        // script, matching HTML's in-order meta processing.
        if (child.is(Element.Html.Meta)) |meta| {
            try meta.processContentSecurityPolicy(self);
        }

        // Of the parser insertions, only fragment parses (innerHTML) mutate a
        // live tree; the initial document parse suppresses notifications.
        if (self._parse_mode == .fragment) {
            self.notifyChildInserted(parent, child);
        }

        if (child.is(Element)) |el| {
            // Invoke connectedCallback for custom elements during parsing.
            // For main document parsing we know nodes are connected (fast path);
            // for fragment parsing (innerHTML) we check connectivity.
            if (child.isConnected() or child.isInShadowTree()) {
                if (el.getAttributeSafe(comptime .wrap("id"))) |id| {
                    try self.addElementId(parent, el, id);
                }
                try Element.Html.Custom.enqueueConnectedCallbackOnElement(true, el, self);
            }
        }
        // Void parser-created <link> elements perform their synchronous fetch
        // from Build.created, before the parser has inserted the owner node.
        // Once the final parent is known, register that cached sheet in the
        // actual Document/ShadowRoot TreeScope.
        try self.registerStyleSheetsInSubtree(child);
        return;
    }

    const parent_is_connected = parent.isConnected();

    // nodeIsReady resolves the node's owning frame itself (only for the few node
    // types that have ready work), so pass the incumbent `self`.
    try self.nodeIsReady(false, child);

    // Ready work is a script boundary: an iframe's initial document or a
    // custom-element reaction can synchronously remove or move the very node
    // being inserted.  The nested mutation has already run its own removal /
    // insertion steps, so do not notify or dereference the stale original
    // parent relationship after returning from it.
    if (child._parent != parent or child._tree_mutation_serial != insertion_serial) return;

    // Connecting an already-built subtree must create browsing contexts for
    // every descendant iframe. Parser-created detached fragments and ordinary
    // DOM moves both reach this path. iframeAddedCallback's connected/_executed
    // guards make the direct-child case idempotent.
    var connected_elements_raw: std.ArrayList(*Element) = .empty;
    try self.collectShadowIncludingElements(child, &connected_elements_raw);
    var connected_elements: std.ArrayList(ConnectedElementSnapshot) = .empty;
    for (connected_elements_raw.items) |element| {
        try connected_elements.append(self.call_arena, .{
            .element = element,
            .mutation_serial = element.asNode()._tree_mutation_serial,
        });
    }
    for (connected_elements.items) |snapshot| {
        const element = snapshot.element;
        if (element.asNode()._tree_mutation_serial != snapshot.mutation_serial) continue;
        const iframe = element.is(IFrame) orelse continue;
        // A preceding initial navigation may have synchronously moved or
        // removed a later owner. The snapshot protects traversal topology;
        // containment protects semantics.
        if (!child.shadowIncludingContains(iframe.asNode())) continue;
        const browsing_context_parent = iframe.asNode().ownerFrame(self);
        try browsing_context_parent.iframeAddedCallback(iframe);
        // Initial navigation may synchronously remove or move the inserted
        // subtree. Stop before dereferencing stale parent relationships.
        if (child._parent != parent or child._tree_mutation_serial != insertion_serial) return;
    }

    // Check if text was added to a script that hasn't started yet.
    if (child._type == .cdata and parent_is_connected) {
        if (parent.is(Element.Html.Script)) |script| {
            if (!script._executed) {
                try self.nodeIsReady(false, parent);
            }
        }
    }

    self.notifyChildInserted(parent, child);
    try self.registerStyleSheetsInSubtree(child);

    if (opts.child_already_connected and
        opts.preserve_browsing_contexts and
        !opts.adopting_to_new_document)
    {
        // The child is already connected in the same document, we don't have to reconnect it.
        // On cross-document adoption the child has already fired
        // disconnectedCallback against the old tree and must re-fire
        // connectedCallback for the new tree, so we fall through.
        return;
    }

    const parent_in_shadow = parent.is(ShadowRoot) != null or parent.isInShadowTree();

    if (!parent_in_shadow and !parent_is_connected) {
        return;
    }

    // If we're here, it means either:
    // 1. A disconnected child became connected (parent.isConnected() == true)
    // 2. Child is being added to a shadow tree (parent_in_shadow == true)
    // In both cases, we need to update ID maps and invoke callbacks

    // Only invoke connectedCallback if the root child is transitioning from
    // disconnected to connected. When that happens, all descendants should also
    // get connectedCallback invoked (they're becoming connected as a group).
    // Cross-document adoption also counts as a transition: the element fired
    // disconnectedCallback against the old tree during removeNode and must
    // now fire connectedCallback against the new tree.
    const should_invoke_connected = parent_is_connected;

    for (connected_elements.items) |snapshot| {
        const el = snapshot.element;
        if (child._parent != parent or child._tree_mutation_serial != insertion_serial) return;
        if (el.asNode()._tree_mutation_serial != snapshot.mutation_serial) continue;
        if (!child.shadowIncludingContains(el.asNode())) continue;
        if (el.getAttributeSafe(comptime .wrap("id"))) |id| {
            const element_parent = el.asNode()._parent orelse continue;
            try self.addElementId(element_parent, el, id);
        }

        if (should_invoke_connected) {
            try Element.Html.Custom.enqueueConnectedCallbackOnElement(false, el, self);
        }
    }
}

fn notifyChildInserted(self: *Frame, parent: *Node, child: *Node) void {
    if (!observers.hasMutationObservers(self)) {
        return;
    }

    const previous_sibling = child.previousSibling();
    const next_sibling = child.nextSibling();
    const added = [_]*Node{child};
    observers.notifyChildListChange(self, parent, &added, &.{}, previous_sibling, next_sibling);
}

pub fn attributeChange(self: *Frame, element: *Element, name: String, value: String, old_value: ?String) void {
    _ = Element.Build.call(element, "attributeChange", .{ element, name, value, self }) catch |err| {
        log.err(.bug, "build.attributeChange", .{ .tag = element.getTag(), .name = name, .value = value, .err = err, .type = self._type, .url = self.url });
    };

    Element.Html.Custom.enqueueAttributeChangedCallbackOnElement(element, name, old_value, value, null, self);

    observers.notifyAttributeChange(self, element, name, old_value);

    // Handle slot assignment changes
    if (name.eql(comptime .wrap("slot"))) {
        const old = if (old_value) |o| o.str() else "";
        slotting.slotAttributeChanged(element.asNode(), old, value.str(), self);
    } else if (name.eql(comptime .wrap("name"))) {
        if (element.is(Element.Html.Slot)) |slot| {
            const old = if (old_value) |o| o.str() else "";
            slotting.nameAttributeChanged(slot, old, value.str(), self);
        }
    } else if (name.eql(comptime .wrap("popover"))) {
        const old = if (old_value) |o| o.str() else null;
        popover.attributeChanged(element, old, value.str(), self);
    }
}

pub fn attributeRemove(self: *Frame, element: *Element, name: String, old_value: String) void {
    _ = Element.Build.call(element, "attributeRemove", .{ element, name, self }) catch |err| {
        log.err(.bug, "build.attributeRemove", .{ .tag = element.getTag(), .name = name, .err = err, .type = self._type, .url = self.url });
    };

    Element.Html.Custom.enqueueAttributeChangedCallbackOnElement(element, name, old_value, null, null, self);

    observers.notifyAttributeChange(self, element, name, old_value);

    // Handle slot assignment changes
    if (name.eql(comptime .wrap("slot"))) {
        slotting.slotAttributeChanged(element.asNode(), old_value.str(), "", self);
    } else if (name.eql(comptime .wrap("name"))) {
        if (element.is(Element.Html.Slot)) |slot| {
            slotting.nameAttributeChanged(slot, old_value.str(), "", self);
        }
    } else if (name.eql(comptime .wrap("popover"))) {
        popover.attributeChanged(element, old_value.str(), null, self);
    }
}

pub fn signalSlotChange(self: *Frame, slot: *Element.Html.Slot) void {
    self._slots_pending_slotchange.put(self.arena, slot, {}) catch |err| {
        log.err(.frame, "signalSlotChange.put", .{ .err = err, .type = self._type, .url = self.url });
        return;
    };
    observers.scheduleMutationDelivery(self) catch |err| {
        log.err(.frame, "signalSlotChange.schedule", .{ .err = err, .type = self._type, .url = self.url });
    };
}

pub fn getCustomizedBuiltInDefinition(self: *Frame, element: *Element) ?*CustomElementDefinition {
    return self._customized_builtin_definitions.get(element);
}

pub fn setCustomizedBuiltInDefinition(self: *Frame, element: *Element, definition: *CustomElementDefinition) !void {
    try self._customized_builtin_definitions.put(self.arena, element, definition);
}

// --- Live range update methods (DOM spec §4.2.3, §4.2.4, §4.7, §4.8) ---

/// Update all live ranges after a replaceData mutation on a CharacterData node.
/// Per DOM spec: insertData = replaceData(offset, 0, data),
///               deleteData = replaceData(offset, count, "").
/// All parameters are in UTF-16 code unit offsets.
pub fn updateRangesForCharacterDataReplace(self: *Frame, target: *Node, offset: u32, count: u32, data_len: u32) void {
    var it: ?*std.DoublyLinkedList.Node = self._live_ranges.first;
    while (it) |link| : (it = link.next) {
        const ar: *AbstractRange = @fieldParentPtr("_range_link", link);
        ar.updateForCharacterDataReplace(target, offset, count, data_len);
    }
}

/// Update all live ranges after a splitText operation.
/// Steps 7b-7e of the DOM spec splitText algorithm.
/// Steps 7d-7e complement (not overlap) updateRangesForNodeInsertion:
/// the insert update handles offsets > child_index, while 7d/7e handle
/// offsets == node_index+1 (these are equal values but with > vs == checks).
pub fn updateRangesForSplitText(self: *Frame, target: *Node, new_node: *Node, offset: u32, parent: *Node, node_index: u32) void {
    var it: ?*std.DoublyLinkedList.Node = self._live_ranges.first;
    while (it) |link| : (it = link.next) {
        const ar: *AbstractRange = @fieldParentPtr("_range_link", link);
        ar.updateForSplitText(target, new_node, offset, parent, node_index);
    }
}

/// Update all live ranges after a node insertion.
/// Per DOM spec insert algorithm step 6: only applies when inserting before a
/// non-null reference node.
pub fn updateRangesForNodeInsertion(self: *Frame, parent: *Node, child_index: u32) void {
    var it: ?*std.DoublyLinkedList.Node = self._live_ranges.first;
    while (it) |link| : (it = link.next) {
        const ar: *AbstractRange = @fieldParentPtr("_range_link", link);
        ar.updateForNodeInsertion(parent, child_index);
    }
}

/// Update all live ranges after a node removal.
/// Per DOM spec remove algorithm steps 4-7.
pub fn updateRangesForNodeRemoval(self: *Frame, parent: *Node, child: *Node, child_index: u32) void {
    var it: ?*std.DoublyLinkedList.Node = self._live_ranges.first;
    while (it) |link| : (it = link.next) {
        const ar: *AbstractRange = @fieldParentPtr("_range_link", link);
        ar.updateForNodeRemoval(parent, child, child_index);
    }
}

// TODO: optimize and cleanup, this is called a lot (e.g., innerHTML = '')
pub fn parseHtmlAsChildren(self: *Frame, node: *Node, html: []const u8) !void {
    return self.parseHtmlAsChildrenInner(node, html, .{});
}

// setHTMLUnsafe variant: parse a fragment that may contain declarative shadow node
pub fn parseHtmlUnsafeAsChildren(self: *Frame, node: *Node, html: []const u8) !void {
    return self.parseHtmlAsChildrenInner(node, html, .{ .allow_declarative_shadow = true });
}

// Range.createContextualFragment variant: unlike innerHTML et al., its scripts
// are run when the fragment is inserted into a document.
pub fn parseContextualFragment(self: *Frame, node: *Node, html: []const u8) !void {
    return self.parseHtmlAsChildrenInner(node, html, .{ .scripts_runnable = true });
}

const FragmentParseOpts = struct {
    scripts_runnable: bool = false,
    allow_declarative_shadow: bool = false,
};

fn parseHtmlAsChildrenInner(self: *Frame, node: *Node, html: []const u8, opts: FragmentParseOpts) !void {
    const previous_parse_mode = self._parse_mode;
    self._parse_mode = .fragment;
    defer self._parse_mode = previous_parse_mode;

    // The html5ever wrapper-unwrap below rebinds children without going
    // through the insertion path, so recompute slot assignments for any
    // shadow tree this fragment landed in (idempotent; signals only on diff).
    defer if (self._element_shadow_roots.count() != 0) {
        const root = node.getRootNode(.{});
        if (root.is(ShadowRoot) != null) {
            slotting.assignSlottablesForTree(root, self);
        }
        if (node.is(Element)) |el| {
            if (self._element_shadow_roots.get(el)) |shadow_root| {
                slotting.assignSlottablesForTree(shadow_root.asNode(), self);
            }
        }
    };

    const previous_scripts_runnable = self._fragment_scripts_runnable;
    self._fragment_scripts_runnable = opts.scripts_runnable;
    defer self._fragment_scripts_runnable = previous_scripts_runnable;

    var parser = Parser.init(self.call_arena, node, self, .{ .allow_declarative_shadow = opts.allow_declarative_shadow });
    parser.parseFragment(html);

    // html5ever wraps fragment output in an <html> element; unwrap so its
    // children land directly on `node`. See https://github.com/servo/html5ever/issues/583.
    // Because of custom element callbacks, the structure might not be what
    // we expect, and nodes might be altogether removed. We deal with this in a
    // few different places, but always the same way: leave it as-is.
    const children = node._children orelse return;
    const first = Node.linkToNode(children.first.?);
    if (first.is(Element.Html.Html) == null) {
        return;
    }
    node._children = first._children;

    if (observers.hasMutationObservers(self)) {
        var it = node.childrenIterator();
        while (it.next()) |child| {
            child._parent = node;
            // Notify mutation observers for each unwrapped child
            const previous_sibling = child.previousSibling();
            const next_sibling = child.nextSibling();
            const added = [_]*Node{child};
            observers.notifyChildListChange(self, node, &added, &.{}, previous_sibling, next_sibling);
        }
    } else {
        var it = node.childrenIterator();
        while (it.next()) |child| {
            child._parent = node;
        }
    }

    try self.registerStyleSheetsInSubtree(node);
}

fn nodeIsReady(self: *Frame, comptime from_parser: bool, node: *Node) !void {
    if ((comptime from_parser) and self._parse_mode == .fragment) {
        if (self._fragment_scripts_runnable == false) {
            // We don't execute scripts added via innerHTML = '<script...'. Mark
            // them "already started" so they stay inert even after the parsed
            // nodes are inserted into a connected document.
            if (node.is(Element.Html.Script)) |script| {
                script._executed = true;
            }
        }
        return;
    }
    // A node's "ready" work (running a <script>, loading an <iframe> / <link> /
    // <style>) must happen in the frame that owns the node's document — not
    // necessarily `self`. When an async callback (e.g. a postMessage listener)
    // running in frame A appends a node to frame B's document, `self` is the
    // incumbent frame A, but the script's base URL and execution realm must come
    // from B (its node document). Resolving that owner frame is a parent-chain
    // walk, so we only do it once we've matched a node type that has ready work
    // (the common text/element insertion does nothing here). The parser inserts
    // into its own document, so from_parser always uses `self`.
    if (node.is(Element.Html.Meta)) |meta| {
        const frame = if (comptime from_parser) self else node.ownerFrame(self);
        try meta.processContentSecurityPolicy(frame);
    } else if (node.is(Element.Html.Script)) |script| {
        if ((comptime from_parser == false) and script._src.len == 0) {
            // Script was added via JavaScript without a src attribute.
            // Only skip if it has no inline content either — scripts with
            // textContent/text should still execute per spec.
            if (node.firstChild() == null) {
                return;
            }
        }

        const frame = if (comptime from_parser) self else node.ownerFrame(self);
        frame.scriptAddedCallback(from_parser, script) catch |err| {
            log.err(.frame, "frame.nodeIsReady", .{ .err = err, .element = "script", .type = frame._type, .url = frame.url });
            return err;
        };
    } else if (node.is(IFrame)) |iframe| {
        const frame = if (comptime from_parser) self else node.ownerFrame(self);
        frame.iframeAddedCallback(iframe) catch |err| {
            log.err(.frame, "frame.nodeIsReady", .{ .err = err, .element = "iframe", .type = frame._type, .url = frame.url });
            return err;
        };
    } else if (node.is(Element.Html.Link)) |link| {
        const frame = if (comptime from_parser) self else node.ownerFrame(self);
        link.linkAddedCallback(frame) catch |err| {
            log.err(.frame, "frame.nodeIsReady", .{ .err = err, .element = "link", .type = frame._type });
            return error.LinkLoadError;
        };
    } else if (node.is(Element.Html.Style)) |style| {
        const frame = if (comptime from_parser) self else node.ownerFrame(self);
        style.styleAddedCallback(frame) catch |err| {
            log.err(.frame, "frame.nodeIsReady", .{ .err = err, .element = "style", .type = frame._type });
            return error.StyleLoadError;
        };
    }
}

const ParseState = union(enum) {
    pre,
    complete,
    err: anyerror,
    html: struct {
        arena: Allocator,
        buffer: std.ArrayList(u8),
    },
    text: std.ArrayList(u8),
    image: std.ArrayList(u8),
    raw: std.ArrayList(u8),
    raw_done: []const u8,
    download: Download,

    fn deinit(self: *ParseState, frame: *Frame) void {
        switch (self.*) {
            .html => |html| frame.releaseArena(html.arena),
            // Only reached when a frame is torn down mid-download (the normal
            // completion path in frameDoneCallback already closes the file and
            // transitions to .complete).
            .download => |*download| download.file.close(),
            else => {},
        }
    }
};

// An in-flight file download (Content-Disposition: attachment under an
// allow/allowAndName Browser.setDownloadBehavior). The response body is
// streamed straight to `file` rather than parsed as a page. See issue #2701.
const Download = struct {
    // uuidv4, arena-owned. Matches the guid reported in the CDP events.
    guid: []const u8,
    file: std.fs.File,
    // suggested filename surfaced to the client, arena-owned.
    filename: []const u8,
    received: u64,
    // from Content-Length, when the response advertised one.
    total: ?u64,
};

const LoadState = enum {
    // waiting for the main HTML
    waiting,

    // the main HTML is being parsed (or downloaded)
    parsing,

    // the main HTML has been parsed and the JavaScript (including deferred
    // scripts) have been loaded. Corresponds to the DOMContentLoaded event
    load,

    // the frame has been loaded and all async scripts (if any) are done
    // Corresponds to the load event
    complete,
};

const IdleNotification = union(enum) {
    // hasn't started yet.
    init,

    // timestamp where the state was first triggered. If the state stays
    // true (e.g. 0 network activity for NetworkIdle, or <= 2 for NetworkAlmostIdle)
    // for 500ms, it'll send the notification and transition to .done. If
    // the state doesn't stay true, it'll revert to .init.
    triggered: u64,

    // notification sent - should never be reset
    done,

    // Returns `true` if we should send a notification. Only returns true if it
    // was previously triggered 500+ milliseconds ago.
    // active == true when the condition for the notification is true
    // active == false when the condition for the notification is false
    pub fn check(self: *IdleNotification, active: bool) bool {
        if (active) {
            switch (self.*) {
                .done => {
                    // Notification was already sent.
                },
                .init => {
                    // This is the first time the condition was triggered (or
                    // the first time after being un-triggered). Record the time
                    // so that if the condition holds for long enough, we can
                    // send a notification.
                    self.* = .{ .triggered = milliTimestamp(.monotonic) };
                },
                .triggered => |ms| {
                    // The condition was already triggered and was triggered
                    // again. When this condition holds for 500+ms, we'll send
                    // a notification.
                    if (milliTimestamp(.monotonic) - ms >= 500) {
                        // This is the only place in this function where we can
                        // return true. The only place where we can tell our caller
                        // "send the notification!".
                        self.* = .done;
                        return true;
                    }
                    // the state hasn't held for 500ms.
                },
            }
        } else {
            switch (self.*) {
                .done => {
                    // The condition became false, but we already sent the notification
                    // There's nothing we can do, it stays .done. We never re-send
                    // a notification or "undo" a sent notification (not that we can).
                },
                .init => {
                    // The condition remains false
                },
                .triggered => {
                    // The condition _had_ been true, and we were waiting (500ms)
                    // for it to hold, but it hasn't. So we go back to waiting.
                    self.* = .init;
                },
            }
        }

        // See above for the only case where we ever return true. All other
        // paths go here. This means "don't send the notification". Maybe
        // because it's already been sent, maybe because active is false, or
        // maybe because the condition hasn't held long enough.
        return false;
    }
};

pub const NavigateReason = enum {
    anchor,
    address_bar,
    form,
    script,
    history,
    navigation,
    initialFrameNavigation,
};

pub const NavigateOpts = struct {
    cdp_id: ?i64 = null,
    reason: NavigateReason = .address_bar,
    method: HttpClient.Method = .GET,
    body: ?[]const u8 = null,
    header: ?[:0]const u8 = null,
    // Set by scheduleNavigationWithArena from the originating frame's URL so
    // anchor click / form submit / location.href navigations carry a Referer.
    // null on CDP Page.navigate (address-bar) and Page.reload — matches Chrome.
    referer: ?[]const u8 = null,
    // The URL of the document that initiated this navigation, used as the
    // "site for cookies" when computing SameSite. Distinct from `referer`
    // because a Referrer-Policy can suppress the Referer header without
    // affecting SameSite (which always considers the real initiator).
    initiator_url: ?[:0]const u8 = null,
    // Concrete policy selected by the navigation initiator or iframe owner.
    // Chrome 149 resolves a missing/invalid value to this default before the
    // request enters the network redirect chain.
    referrer_policy: HttpClient.ReferrerPolicy = HttpClient.default_referrer_policy,
    // Internal policy-container snapshot for local-scheme commits. These
    // values are copied into the QueuedNavigation arena by author-initiated
    // navigation and are intentionally ignored for network responses.
    initiator_origin_key: ?[]const u8 = null,
    // Storage origin is not the effective scripting origin: document.domain
    // may have changed the latter. Local-scheme commits inherit this immutable
    // per-Document key across queued Frame/Page replacement.
    initiator_storage_origin_key: ?[]const u8 = null,
    initiator_csp_eval: ?[]const u8 = null,
    initiator_csp_wasm: ?[]const u8 = null,
    // Internal HTML payload for an iframe srcdoc navigation. scheduleNavigation
    // copies it into the QueuedNavigation arena before the old child Frame is
    // destroyed; direct initial iframe navigation parses it synchronously.
    srcdoc_body: ?[]const u8 = null,
    // Resolved body retained across an immediate root Page swap. This is an
    // internal navigation-loader token, never supplied by external callers.
    synthetic_blob: ?*Blob = null,
    force: bool = false,
    kind: NavigationKind = .{ .push = null },
};

pub const NavigatedOpts = struct {
    cdp_id: ?i64 = null,
    reason: NavigateReason = .address_bar,
    method: HttpClient.Method = .GET,
    // Retained on the frame's arena so Page.reload can replay the prior
    // navigation's HTTP method — matches Chrome's F5 behavior on POST pages.
    body: ?[]const u8 = null,
    header: ?[:0]const u8 = null,
};

const NavigationType = enum {
    form,
    script,
    anchor,
    iframe,
};

const Navigation = union(NavigationType) {
    form: *Frame,
    script: ?*Frame,
    anchor: *Frame,
    iframe: *IFrame,
};

pub const QueuedNavigation = struct {
    arena: Allocator,
    url: [:0]const u8,
    opts: NavigateOpts,
    is_inherited_about: bool,
    navigation_type: NavigationType,
};

/// Resolves a target attribute value (e.g., "_self", "_parent", "_top", or frame name)
/// to the appropriateFrame to navigate.
/// Returns null if the target is "_blank" (which would open a new window/tab).
/// Note: Callers should handle empty target separately (for owner document resolution).
pub fn resolveTargetFrame(self: *Frame, target_name: []const u8) ?*Frame {
    if (std.ascii.eqlIgnoreCase(target_name, "_self")) {
        return self;
    }

    if (std.ascii.eqlIgnoreCase(target_name, "_blank")) {
        return null;
    }

    if (std.ascii.eqlIgnoreCase(target_name, "_parent")) {
        return self.parent orelse self;
    }

    if (std.ascii.eqlIgnoreCase(target_name, "_top")) {
        var frame = self;
        while (frame.parent) |f| {
            frame = f;
        }
        return frame;
    }

    // Named frame lookup: search current frame's descendants first, then from root
    // This follows the HTML spec's "implementation-defined" search order.
    if (findFrameByName(self, target_name)) |f| {
        return f;
    }

    // If not found in descendants, search from root (catches siblings and ancestors' descendants)
    var root = self;
    while (root.parent) |f| {
        root = f;
    }
    if (root != self) {
        if (findFrameByName(root, target_name)) |f| {
            return f;
        }
    }

    // If no frame found with that name, navigate in current frame
    // (this matches browser behavior - unknown targets act like _self)
    return self;
}

fn findFrameByName(frame: *Frame, name: []const u8) ?*Frame {
    for (frame.child_frames.items) |f| {
        // FrameTree lookup uses the browsing-context name captured at context
        // creation and subsequently changed by window.name. Mutating the owner
        // iframe's content attribute does not rename an existing context.
        if (!f.window._closed and std.mem.eql(u8, f.window._name, name)) {
            return f;
        }
        // Recursively search child frames
        if (findFrameByName(f, name)) |found| {
            return found;
        }
    }
    return null;
}

const SubmitFormOpts = struct {
    fire_event: bool = true,
};
pub fn submitForm(self: *Frame, submitter_: ?*Element, form_: ?*Element.Html.Form, submit_opts: SubmitFormOpts) !void {
    const form = form_ orelse return;

    // see the `_constructing_entry_list` field documentation
    if (form._constructing_entry_list) {
        return;
    }

    if (submitter_) |submitter| {
        if (submitter.getAttributeSafe(comptime .wrap("disabled")) != null) {
            return;
        }
    }

    if (self.canScheduleNavigation(.form) == false) {
        return;
    }

    const form_element = form.asElement();

    const submit_button: ?*Element = blk: {
        const s = submitter_ orelse break :blk null;
        break :blk if (Element.Html.Form.isSubmitButton(s)) s else null;
    };

    const target_name_: ?[]const u8 = blk: {
        if (submit_button) |s| {
            if (s.getAttributeSafe(comptime .wrap("formtarget"))) |ft| {
                break :blk ft;
            }
        }
        break :blk form_element.getAttributeSafe(comptime .wrap("target"));
    };

    const target_frame = blk: {
        const target_name = target_name_ orelse {
            break :blk form_element.ownerFrame(self);
        };
        break :blk self.resolveTargetFrame(target_name) orelse {
            log.warn(.not_implemented, "target", .{ .type = self._type, .url = self.url, .target = target_name });
            return;
        };
    };

    if (submit_opts.fire_event) {
        // Prevent a submit on the form from firing while we're submit the form.
        // This is both spec-correct AND prevents infinite recursion.
        if (form._firing_submission_events) {
            return;
        }
        form._firing_submission_events = true;
        defer form._firing_submission_events = false;

        // Per the HTML "submit a form element" algorithm: unless the form (or the
        // submitter, via formnovalidate) is in the no-validate state, interactively
        // validate the form's constraints and abort submission if it fails.
        // checkValidity() fires the `invalid` events on the offending controls.
        // https://html.spec.whatwg.org/multipage/form-control-infrastructure.html#concept-form-submit
        const skip_validation = form.getNoValidate() or blk: {
            const s = submit_button orelse break :blk false;
            if (s.is(Element.Html.Form.Input)) |input| break :blk input.getFormNoValidate();
            if (s.is(Element.Html.Form.Button)) |button| break :blk button.getFormNoValidate();
            break :blk false;
        };
        if (!skip_validation and !try form.checkValidity(self)) {
            return;
        }

        // Per HTML spec "submit a form element" algorithm: SubmitEvent.submitter
        // must be null when the submitter is the form itself, which is what
        // Form.requestSubmit() passes when called with no submitter argument.
        // https://html.spec.whatwg.org/multipage/form-control-infrastructure.html#concept-form-submit
        const submitter_html: ?*HtmlElement = blk: {
            const s = submitter_ orelse break :blk null;
            if (s == form_element) break :blk null;
            break :blk s.is(HtmlElement);
        };
        const submit_event = (try SubmitEvent.initTrusted(comptime .wrap("submit"), .{ .bubbles = true, .cancelable = true, .submitter = submitter_html }, self)).asEvent();

        // so submit_event is still valid when we check _prevent_default
        submit_event.acquireRef();
        defer _ = submit_event.releaseRef(self._page);

        try self._event_manager.dispatch(form_element.asEventTarget(), submit_event);
        // If the submit event was prevented, don't submit the form
        if (submit_event._prevent_default) {
            return;
        }
    }

    const FormData = @import("webapi/net/FormData.zig");

    // The submitter can be an input box (if enter was entered on the box)
    // I don't think this is technically correct, but FormData handles it ok
    const form_data = try FormData.init(form, submitter_, &self.js.execution);
    form_data.acquireRef();
    defer form_data.releaseRef(self._page);

    const arena = try self._session.getArena(.medium, "submitForm");
    errdefer self._session.releaseArena(arena);

    // Per HTML spec form-submission algorithm, when the submitter is a submit
    // button, its formaction/formmethod/formenctype attributes override the
    // form's corresponding attributes (matching how formtarget is honored above).
    // https://html.spec.whatwg.org/multipage/form-control-infrastructure.html#concept-form-submit
    const enctype_attr = blk: {
        if (submit_button) |s| {
            if (s.getAttributeSafe(comptime .wrap("formenctype"))) |fe| break :blk fe;
        }
        break :blk form_element.getAttributeSafe(comptime .wrap("enctype"));
    };
    const method_attr: ?[]const u8 = blk: {
        if (submit_button) |s| {
            if (s.getAttributeSafe(comptime .wrap("formmethod"))) |fm| break :blk fm;
        }
        break :blk form_element.getAttributeSafe(comptime .wrap("method"));
    };
    const method = Element.Html.Form.normalizeMethod(method_attr, "get");
    const is_post = std.mem.eql(u8, method, "post");

    // Get charset from accept-charset attribute or fall back to document charset
    const charset: []const u8 = blk: {
        if (form_element.getAttributeSafe(.wrap("accept-charset"))) |ac| {
            // Normalize to canonical encoding name
            const info = h5e.encoding_for_label(ac.ptr, ac.len);
            if (info.isValid()) {
                break :blk info.name();
            }
        }
        break :blk self.charset;
    };

    var boundary_buf: [36]u8 = undefined;
    // GET ignores enctype per HTML spec; only resolve the union for POST.
    const encoding: FormData.EncType = blk: {
        if (!is_post) break :blk .urlencode;
        const canonical = Element.Html.Form.normalizeEnctype(enctype_attr, "application/x-www-form-urlencoded");
        if (std.mem.eql(u8, canonical, "multipart/form-data")) {
            @import("../id.zig").uuidv4(&boundary_buf);
            break :blk .{ .formdata = &boundary_buf };
        }
        if (std.mem.eql(u8, canonical, "text/plain")) {
            break :blk .plaintext;
        }
        break :blk .urlencode;
    };

    var buf = std.Io.Writer.Allocating.init(arena);
    try form_data.write(.{ .encoding = encoding, .charset = charset, .allocator = arena }, &buf.writer);

    var action = blk: {
        if (submit_button) |s| {
            if (s.getAttributeSafe(comptime .wrap("formaction"))) |fa| break :blk fa;
        }
        break :blk form_element.getAttributeSafe(comptime .wrap("action")) orelse self.url;
    };

    var opts = NavigateOpts{
        .reason = .form,
        .kind = .{ .push = null },
    };
    if (is_post) {
        opts.method = .POST;
        opts.body = buf.written();
        opts.header = switch (encoding) {
            .urlencode => "Content-Type: application/x-www-form-urlencoded",
            .formdata => |b| try std.fmt.allocPrintSentinel(arena, "Content-Type: multipart/form-data; boundary={s}", .{b}, 0),
            // Per WHATWG HTML §4.10.21.6, text/plain submissions include the form's
            // resolved encoding (accept-charset or document charset).
            .plaintext => try std.fmt.allocPrintSentinel(arena, "Content-Type: text/plain; charset={s}", .{charset}, 0),
        };
    } else {
        action = try URL.concatQueryString(arena, action, buf.written());
    }

    return self.scheduleNavigationWithArena(arena, action, opts, .{ .form = target_frame }) catch |err| switch (err) {
        // Form submission aborts silently after the browser emits its unsafe
        // navigation diagnostic. Because this path supplied the arena, convert
        // the error only after releasing it here.
        error.SecurityError => {
            self._session.releaseArena(arena);
            return;
        },
        else => return err,
    };
}

const testing = @import("../testing.zig");

fn dispositionHeader(value: []const u8) HttpClient.Header {
    return .{ .name = "content-disposition", .value = value };
}

test "Frame: dispositionFilename" {
    try testing.expectEqualSlices(u8, "report.csv", dispositionFilename(dispositionHeader("attachment; filename=\"report.csv\"")).?);
    try testing.expectEqualSlices(u8, "report.csv", dispositionFilename(dispositionHeader("attachment; filename=report.csv")).?);
    try testing.expectEqualSlices(u8, "r e.csv", dispositionFilename(dispositionHeader("attachment; filename=\"r e.csv\"")).?);
    // RFC 5987 extended form is preferred over the plain filename when present
    // (the value is taken verbatim after the charset'lang' prefix).
    try testing.expectEqualSlices(u8, "extended.txt", dispositionFilename(dispositionHeader("attachment; filename=\"fallback.txt\"; filename*=UTF-8''extended.txt")).?);
    try testing.expect(dispositionFilename(dispositionHeader("attachment")) == null);
    // Path components are stripped to guard against traversal.
    try testing.expectEqualSlices(u8, "evil.sh", dispositionFilename(dispositionHeader("attachment; filename=\"../../evil.sh\"")).?);
    try testing.expectEqualSlices(u8, "evil.sh", dispositionFilename(dispositionHeader("attachment; filename=\"..\\..\\evil.sh\"")).?);
    try testing.expect(dispositionFilename(dispositionHeader("attachment; filename=\"..\"")) == null);
}

test "Frame: urlBasename" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expectEqualSlices(u8, "report.csv", (try urlBasename(a, "http://x.com/a/b/report.csv")).?);
    try testing.expectEqualSlices(u8, "report.csv", (try urlBasename(a, "http://x.com/report.csv?v=1#x")).?);
    try testing.expect((try urlBasename(a, "http://x.com/")) == null);
}

test "WebApi: Frame" {
    const filter: testing.LogFilter = .init(&.{.http});
    defer filter.deinit();
    try testing.htmlRunner("page", .{});
}

test "WebApi: Frames" {
    try testing.htmlRunner("frames", .{});
}

test "WebApi: iframe initial navigation re-entrant parent mutation" {
    try testing.htmlRunner("frames/iframe_reentrant_mutation.html", .{});
}

test "WebApi: FrameTree scope and state-preserving moves" {
    try testing.htmlRunner("frames/frame_tree_scope_and_move.html", .{});
}

test "WebApi: FrameTree pre-detach iframe disconnection re-entry" {
    try testing.htmlRunner("frames/frame_tree_reentrant_removal.html", .{});
}

test "WebApi: Window named child browsing contexts" {
    try testing.htmlRunner("frames/window_named_child.html", .{});
}

test "WebApi: Integration" {
    try testing.htmlRunner("integration", .{});
}

test "WebApi: inject_script" {
    try testing.htmlRunner("inject_script.html", .{
        .inject_script = "window.__injected = true; window.__injectValue = 42;",
    });
}

test "Page: isSameOrigin" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const origin = try URL.getOrigin(allocator, "https://origin.com/foo/bar") orelse unreachable;
    try testing.expectEqual(true, isSameOriginKey(allocator, origin, "https://origin.com/foo/bar")); // exact same
    try testing.expectEqual(true, isSameOriginKey(allocator, origin, "https://origin.com/bar/bar")); // path differ
    try testing.expectEqual(true, isSameOriginKey(allocator, origin, "https://origin.com/")); // path differ
    try testing.expectEqual(true, isSameOriginKey(allocator, origin, "https://origin.com")); // no path
    try testing.expectEqual(true, isSameOriginKey(allocator, origin, "https://origin.com/foo?q=1"));
    try testing.expectEqual(true, isSameOriginKey(allocator, origin, "https://origin.com/foo#hash"));
    try testing.expectEqual(true, isSameOriginKey(allocator, origin, "https://origin.com/foo?q=1#hash"));
    // FIXME try testing.expectEqual(true, isSameOriginKey(allocator, origin, "https://foo:bar@origin.com"));
    // FIXME try testing.expectEqual(true, isSameOriginKey(allocator, origin, "https://origin.com:443/foo"));

    try testing.expectEqual(false, isSameOriginKey(allocator, origin, "http://origin.com/")); // another proto
    try testing.expectEqual(false, isSameOriginKey(allocator, origin, "https://origin.com:123/")); // another port
    try testing.expectEqual(false, isSameOriginKey(allocator, origin, "https://sub.origin.com/")); // another subdomain
    try testing.expectEqual(false, isSameOriginKey(allocator, origin, "https://target.com/")); // different domain
    try testing.expectEqual(false, isSameOriginKey(allocator, origin, "https://origin.com.target.com/")); // different domain
    try testing.expectEqual(false, isSameOriginKey(allocator, origin, "https://target.com/@origin.com"));

    const alternate_port = try URL.getOrigin(allocator, "https://origin.com:8443/foo") orelse unreachable;
    try testing.expectEqual(true, isSameOriginKey(allocator, alternate_port, "https://origin.com:8443/bar"));
    try testing.expectEqual(false, isSameOriginKey(allocator, alternate_port, "https://origin.com/bar")); // missing port
    try testing.expectEqual(false, isSameOriginKey(allocator, alternate_port, "https://origin.com:9999/bar")); // wrong port

    try testing.expectEqual(false, isSameOriginKey(allocator, origin, ""));
    try testing.expectEqual(false, isSameOriginKey(allocator, origin, "not-a-url"));
    try testing.expectEqual(false, isSameOriginKey(allocator, origin, "//origin.com/foo"));
}

test "Frame: httpMetadata after navigation" {
    const page = try testing.pageTest("page/meta.html", .{});
    defer page.close();

    const meta = page.frame().?.httpMetadata();
    try testing.expect(meta.status != null);
    try std.testing.expectEqual(@as(u16, 200), meta.status.?);
    try testing.expect(meta.headers.len > 0);
    try testing.expect(meta.url.len > 0);
}

test "Frame: httpMetadata 404" {
    const page = try testing.pageTest("nonexistent_page_xyz.html", .{});
    defer page.close();

    const meta = page.frame().?.httpMetadata();
    try testing.expect(meta.status != null);
    try testing.expectEqual(404, meta.status.?);
}

test "Frame: 401" {
    defer testing.reset();

    var page = try testing.pageTest("401", .{});
    defer page.close();

    const frame = page.frame().?;

    var buf = std.Io.Writer.Allocating.init(testing.allocator);
    defer buf.deinit();
    try @import("dump.zig").root(frame.document, .{}, &buf.writer, frame);
    try testing.expectEqual("<!DOCTYPE html><html><head><meta charset=\"utf-8\"></head><body><pre>No</pre></body></html>", buf.written());
}
