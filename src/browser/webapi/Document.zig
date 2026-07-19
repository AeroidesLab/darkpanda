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
const Frame = @import("../Frame.zig");
const URL = @import("../URL.zig");
const SandboxFlags = @import("../SandboxFlags.zig");
const idna = @import("../../sys/idna.zig");
const public_suffix_list = @import("../../data/public_suffix_list.zig");

const Node = @import("Node.zig");
const Element = @import("Element.zig");
const Location = @import("Location.zig");
const DOMException = @import("DOMException.zig");
const Parser = @import("../parser/Parser.zig");
const collections = @import("collections.zig");
const Selector = @import("selector/Selector.zig");
const DOMTreeWalker = @import("DOMTreeWalker.zig");
const DOMNodeIterator = @import("DOMNodeIterator.zig");
const DOMImplementation = @import("DOMImplementation.zig");
const StyleSheetList = @import("css/StyleSheetList.zig");
const FontFaceSet = @import("css/FontFaceSet.zig");
const Selection = @import("Selection.zig");
const XPathResult = @import("XPathResult.zig");
const XPathExpression = @import("XPathExpression.zig");
const TrustedTypes = @import("TrustedTypes.zig");

pub const XMLDocument = @import("XMLDocument.zig");
pub const HTMLDocument = @import("HTMLDocument.zig");

const log = lp.log;
const String = lp.String;
const IS_DEBUG = @import("builtin").mode == .Debug;

const Document = @This();

_type: Type,
_proto: *Node,
_frame: ?*Frame = null,
// FrameDestroyed clears _frame, but detached Document algorithms must never
// fall back to the caller's Frame. Keep the creation owner alive with the
// retired realm so DOM mutation remains local and script/resource production
// stays blocked by Frame.isGoingAway(). Synthetic DOMParser/implementation
// Documents have no browsing-context owner and leave this null.
_owner_frame: ?*Frame = null,
_url: ?[:0]const u8 = null, // URL for documents created via DOMImplementation (about:blank)
// Stable, Page-lifetime snapshot of this Document's effective scripting
// origin. A Frame address is reused by the next Document after navigation;
// detached Location wrappers must compare against this value instead of the
// new Frame's Context. This legacy key is replaced by SecurityOriginState in
// the staged structured-origin migration.
_security_origin_key: []const u8 = "",
// Immutable storage origin for this Document. Unlike the effective scripting
// origin above, document.domain must never change the key used by localStorage
// or sessionStorage. Cross-document navigation installs a fresh snapshot, and
// inherited local-scheme Documents receive their creator's storage key.
_storage_origin_key: []const u8 = "",
// Compatibility mode is parser state, not a live function of the current
// doctype: removing a parsed doctype must not change compatMode. Synthetic
// Documents start in no-quirks mode; an HTML document parser switches to
// quirks until a conforming doctype says otherwise.
_compatibility_mode: CompatibilityMode = .no_quirks,
_compatibility_mode_locked: bool = false,
// The referrer selected for this navigation. Detached/synthetic Documents
// expose the empty string even though a retired Frame remains alive as their
// native owner.
_referrer: []const u8 = "",
_ready_state: ReadyState = .loading,
// Page dismissal makes the still-attached Document hidden before
// visibilitychange/unload run. Frame retirement detaches it only after the
// synchronous lifecycle cluster has completed.
_lifecycle_hidden: bool = false,
_current_script: ?*Element.Html.Script = null,
_elements_by_id: std.StringHashMapUnmanaged(*Element) = .empty,
// Track IDs that were removed from the map - they might have duplicates in the tree
_removed_ids: std.StringHashMapUnmanaged(void) = .empty,
_active_element: ?*Element = null,
_style_sheets: ?*StyleSheetList = null,
_implementation: ?*DOMImplementation = null,
_fonts: ?*FontFaceSet = null,
_all: ?*collections.HTMLAllCollection = null,
_write_insertion_point: ?*Node = null,
_script_created_parser: ?Parser.Streaming = null,
_close_requested: bool = false,
_adopted_style_sheets: ?js.Object.Global = null,
_selection: Selection = .{ ._rc = .init(1) },
// Ordered stack of currently-showing popovers
_open_popovers: std.ArrayList(*Element) = .empty,

// https://html.spec.whatwg.org/multipage/dynamic-markup-insertion.html#throw-on-dynamic-markup-insertion-counter
// Incremented during custom element reactions when parsing. When > 0,
// document.open/close/write/writeln must throw InvalidStateError.
_throw_on_dynamic_markup_insertion_counter: u32 = 0,

_on_selectionchange: ?js.Function.Global = null,

pub fn getOnSelectionChange(self: *Document) ?js.Function.Global {
    return self._on_selectionchange;
}

pub fn setOnSelectionChange(self: *Document, listener: ?js.Function) !void {
    if (listener) |listen| {
        self._on_selectionchange = try listen.persistWithThis(self);
    } else {
        self._on_selectionchange = null;
    }
}

pub fn getOnVisibilityChange(self: *Document, caller_frame: *Frame) ?js.Function.Global {
    const owner = self._owner_frame orelse caller_frame;
    return owner._event_target_attr_listeners.get(.{
        .target = self.asEventTarget(),
        .handler = .onvisibilitychange,
    });
}

pub fn setOnVisibilityChange(self: *Document, listener: ?js.Function.Global, caller_frame: *Frame) !void {
    const owner = self._owner_frame orelse caller_frame;
    if (listener) |callback| {
        try owner._event_target_attr_listeners.put(owner.arena, .{
            .target = self.asEventTarget(),
            .handler = .onvisibilitychange,
        }, callback);
    } else {
        _ = owner._event_target_attr_listeners.remove(.{
            .target = self.asEventTarget(),
            .handler = .onvisibilitychange,
        });
    }
}

pub const Type = union(enum) {
    generic,
    html: *HTMLDocument,
    xml: *XMLDocument,
};

pub fn is(self: *Document, comptime T: type) ?*T {
    switch (self._type) {
        .html => |html| {
            if (T == HTMLDocument) {
                return html;
            }
        },
        .xml => |xml| {
            if (T == XMLDocument) {
                return xml;
            }
        },
        .generic => {},
    }
    return null;
}

pub fn as(self: *Document, comptime T: type) *T {
    return self.is(T).?;
}

pub fn asNode(self: *Document) *Node {
    return self._proto;
}

pub fn asEventTarget(self: *Document) *@import("EventTarget.zig") {
    return self._proto.asEventTarget();
}

pub fn getURL(self: *const Document, frame: *const Frame) [:0]const u8 {
    return self._url orelse (self._frame orelse frame).url;
}

pub fn getLocation(self: *const Document) ?*Location {
    if (self._type != .html) return null;
    const doc_frame = self._frame orelse return null;
    return doc_frame.window._location;
}

pub fn setLocation(self: *Document, url: [:0]const u8) !void {
    if (self._type != .html) return;
    const frame = self._frame orelse return;
    return frame.scheduleNavigation(url, .{ .reason = .script, .kind = .{ .push = null } }, .{ .script = frame });
}

pub fn getContentType(self: *const Document) []const u8 {
    return switch (self._type) {
        .html => "text/html",
        .xml => "application/xml",
        .generic => "application/xml",
    };
}

pub fn beginHTMLDocumentParse(self: *Document) void {
    if (self._compatibility_mode_locked) return;
    if (self._type == .html) self._compatibility_mode = .quirks;
}

pub fn lockNoQuirksCompatibilityMode(self: *Document) void {
    if (self._type != .html) return;
    self._compatibility_mode = .no_quirks;
    self._compatibility_mode_locked = true;
}

pub fn setHTMLCompatibilityMode(self: *Document, raw_mode: u8) void {
    if (self._type != .html or self._compatibility_mode_locked) return;
    self._compatibility_mode = switch (raw_mode) {
        1 => .quirks,
        2 => .limited_quirks,
        else => .no_quirks,
    };
}

pub fn getCompatMode(self: *const Document) []const u8 {
    return if (self._compatibility_mode == .quirks) "BackCompat" else "CSS1Compat";
}

pub fn getCDPCompatibilityMode(self: *const Document) []const u8 {
    return switch (self._compatibility_mode) {
        .quirks => "QuirksMode",
        .limited_quirks => "LimitedQuirksMode",
        .no_quirks => "NoQuirksMode",
    };
}

pub fn getScrollingElement(self: *Document) ?*Element {
    if (self._type != .html) return null;
    if (self._compatibility_mode == .quirks) {
        const body = self.getBody() orelse return null;
        return body.asElement();
    }
    return self.getDocumentElement();
}

pub fn getReferrer(self: *const Document) []const u8 {
    if (self._frame == null) return "";
    return self._referrer;
}

pub fn getHidden(self: *const Document) bool {
    // DarkPanda currently has no background-tab lifecycle. Its active Frame is
    // visible; synthetic and retired Documents have no active browsing context
    // and match Blink's hidden state.
    return self._lifecycle_hidden or self._frame == null;
}

pub fn getVisibilityState(self: *const Document) []const u8 {
    return if (self.getHidden()) "hidden" else "visible";
}

pub fn getPrerendering(_: *const Document) bool {
    // There is no prerender browsing-context state in the current engine.
    return false;
}

// HTML's document-specific members are declared on Document, not on the
// legacy HTMLDocument interface.  HTMLDocument.prototype contains only its
// constructor in Chromium; these thin delegates preserve the existing DOM
// implementations while placing the Web IDL accessors on the correct holder.
pub fn getHead(self: *Document) ?*Element.Html.Head {
    const html = self.is(HTMLDocument) orelse return null;
    return html.getHead();
}

pub fn getBody(self: *Document) ?*Element.Html.Body {
    const html = self.is(HTMLDocument) orelse return null;
    return html.getBody();
}

pub fn setBody(self: *Document, value: []const u8, frame: *Frame) !void {
    const html = self.is(HTMLDocument) orelse return error.HierarchyError;
    return html.setBody(value, frame);
}

pub fn getTitle(self: *Document, frame: *Frame) ![]const u8 {
    const html = self.is(HTMLDocument) orelse return "";
    return html.getTitle(frame);
}

pub fn setTitle(self: *Document, value: []const u8, frame: *Frame) !void {
    const html = self.is(HTMLDocument) orelse return;
    return html.setTitle(value, frame);
}

pub fn getImages(self: *Document, frame: *Frame) !collections.NodeLive(.tag) {
    return collections.NodeLive(.tag).init(self.asNode(), .img, frame);
}

pub fn getScripts(self: *Document, frame: *Frame) !collections.NodeLive(.tag) {
    return collections.NodeLive(.tag).init(self.asNode(), .script, frame);
}

pub fn getLinks(self: *Document, frame: *Frame) !collections.NodeLive(.links) {
    return collections.NodeLive(.links).init(self.asNode(), {}, frame);
}

pub fn getAnchors(self: *Document, frame: *Frame) !collections.NodeLive(.anchors) {
    return collections.NodeLive(.anchors).init(self.asNode(), {}, frame);
}

pub fn getForms(self: *Document, frame: *Frame) !collections.NodeLive(.tag) {
    return collections.NodeLive(.tag).init(self.asNode(), .form, frame);
}

pub fn getEmbeds(self: *Document, frame: *Frame) !collections.NodeLive(.tag) {
    return collections.NodeLive(.tag).init(self.asNode(), .embed, frame);
}

pub fn getApplets(_: *const Document) collections.HTMLCollection {
    return .{ ._data = .empty };
}

pub fn getCurrentScript(self: *const Document) ?*Element.Html.Script {
    return self._current_script;
}

pub fn getDir(self: *Document) []const u8 {
    const element = self.getDocumentElement() orelse return "";
    const html = element.is(Element.Html) orelse return "";
    return html.getDir();
}

pub fn setDir(self: *Document, value: []const u8, frame: *Frame) !void {
    const element = self.getDocumentElement() orelse return;
    const html = element.is(Element.Html) orelse return;
    return html.setDir(value, frame);
}

pub fn getAll(self: *Document, frame: *Frame) !*collections.HTMLAllCollection {
    if (self._all) |all| return all;
    const owner = self._frame orelse self._owner_frame orelse frame;
    const all = try owner._factory.create(collections.HTMLAllCollection.init(self.asNode(), owner));
    self._all = all;
    return all;
}

pub fn getDomain(self: *const Document, _: *const Frame) []const u8 {
    // A detached Document has no active browsing context. Do not borrow the
    // caller's Frame (and therefore its origin) for a cached child Document.
    const doc_frame = self._frame orelse return "";

    // When document.domain has been set, the effective domain is encoded in
    // the origin key with a leading '!' marker. The key is a "!scheme://host"
    // serialization with the port already dropped, so the host *is* the
    // effective domain.
    const key = doc_frame.js.origin.key;
    if (key.len != 0 and key[0] == '!') {
        return URL.getHost(key[1..]);
    }

    // Derive from the origin, not the URL: an about:blank child inherits the
    // parent origin while keeping url == "about:blank". Opaque origin => "".
    const origin = doc_frame.origin orelse return "";
    return URL.getOriginHostname(origin);
}

pub fn setDomain(self: *Document, value: []const u8) !void {
    // e.g. (new Document().domain = '')
    const doc_frame = self._frame orelse {
        const owner = self._owner_frame orelse return error.SecurityError;
        const local = owner.js.local orelse return error.SecurityError;
        const message = "Failed to set the 'domain' property on 'Document': A browsing context is required to set a domain.";
        const exception = try local.zigValueToJs(DOMException.init(message, "SecurityError"), .{});
        _ = js.v8.v8__Exception__CaptureStackTrace(local.handle, @ptrCast(exception.handle));
        _ = local.isolate.throwException(exception.handle);
        return error.TryCatchRethrow;
    };
    if (SandboxFlags.contains(doc_frame.activeSandboxFlags(), SandboxFlags.document_domain)) {
        const message = "Failed to set the 'domain' property on 'Document': Assignment is forbidden for sandboxed iframes.";
        const local = doc_frame.js.local orelse return error.SecurityError;
        const exception = try local.zigValueToJs(DOMException.init(message, "SecurityError"), .{});
        _ = js.v8.v8__Exception__CaptureStackTrace(local.handle, @ptrCast(exception.handle));
        _ = local.isolate.throwException(exception.handle);
        return error.TryCatchRethrow;
    }
    const origin = doc_frame.origin orelse return error.SecurityError;

    const arena = doc_frame.local_arena;
    const requested = if (idna.needsAscii(value)) try idna.toAscii(arena, value) else value;

    // Validate against the current effective domain. Once relaxed,
    // document.domain can only broaden further.
    const base = self.getDomain(doc_frame);
    if (isRelaxableTo(base, requested) == false) {
        return error.SecurityError;
    }

    // When the domain is explicitly set, it only matches other explicitly set
    // domains. We do this by prepending a '!' to the origin, so that it can
    // only ever match another explicitly set domain.
    // The scheme is preserved (http and https must never collide) and the
    // port is dropped, per spec.
    const scheme_end = (std.mem.indexOf(u8, origin, "://") orelse return error.SecurityError) + 3;
    const key = try std.mem.concat(arena, u8, &.{ "!", origin[0..scheme_end], requested });
    try doc_frame.js.setOrigin(key);
    try doc_frame.snapshotDocumentSecurityOrigin();
}

fn denySandboxedCookie(self: *Document, frame: *Frame, comptime is_write: bool) !void {
    const owner = self._frame orelse return;
    switch (owner.requestOrigin()) {
        .tuple => return,
        else => {},
    }
    if (!SandboxFlags.contains(owner.activeSandboxFlags(), SandboxFlags.origin)) {
        return error.SecurityError;
    }

    const message = if (is_write)
        "Failed to set the 'cookie' property on 'Document': The document is sandboxed and lacks the 'allow-same-origin' flag."
    else
        "Failed to read the 'cookie' property from 'Document': The document is sandboxed and lacks the 'allow-same-origin' flag.";
    const local = frame.js.local orelse return error.SecurityError;
    const exception = try local.zigValueToJs(DOMException.init(message, "SecurityError"), .{});
    _ = js.v8.v8__Exception__CaptureStackTrace(local.handle, @ptrCast(exception.handle));
    _ = local.isolate.throwException(exception.handle);
    return error.TryCatchRethrow;
}

pub fn getCookie(self: *Document, frame: *Frame) ![]const u8 {
    try self.denySandboxedCookie(frame, false);
    const owner = self._frame orelse return "";
    var buf: std.ArrayList(u8) = .empty;
    try owner._session.cookie_jar.forRequest(owner.url, buf.writer(frame.local_arena), .{
        .is_http = false,
        .is_navigation = true,
    });
    return buf.items;
}

pub fn setCookie(self: *Document, cookie_str: []const u8, frame: *Frame) ![]const u8 {
    try self.denySandboxedCookie(frame, true);
    const owner = self._frame orelse return cookie_str;
    // we use the cookie jar's allocator to parse the cookie because it
    // outlives the frame's arena.
    const Cookie = @import("storage/Cookie.zig");
    const c = Cookie.parse(owner._session.cookie_jar.allocator, owner.url, cookie_str) catch {
        // Invalid cookies should be silently ignored, not throw errors
        return "";
    };
    if (c.http_only) {
        c.deinit();
        return ""; // HttpOnly cookies cannot be set from JS
    }
    try owner._session.cookie_jar.add(c, std.time.timestamp(), false);
    return cookie_str;
}

// Returns true if the requested domain is valid for the given host
fn isRelaxableTo(host: []const u8, requested: []const u8) bool {
    if (requested.len == 0) {
        return false;
    }

    // Pure opt-in: relaxing to your own host is always allowed (and it's the
    // only valid value for IPs)
    if (std.mem.eql(u8, host, requested)) {
        return true;
    }

    // request must be a subset of host, so it must be smaller
    if (host.len <= requested.len) {
        return false;
    }

    if (host[host.len - requested.len - 1] != '.') {
        return false;
    }

    if (std.mem.endsWith(u8, host, requested) == false) {
        return false;
    }

    // it can't be a bare TLD, "com"
    if (std.mem.indexOfScalar(u8, requested, '.') == null) {
        return false;
    }

    // and it can't be a public suffix (e.g. "gov.uk")
    return public_suffix_list.lookup(requested) == false;
}

const CreateElementOptions = struct {
    is: ?[]const u8 = null,
};

pub fn createElement(self: *Document, name: []const u8, options_: ?CreateElementOptions, frame: *Frame) !*Element {
    try validateElementName(name);
    const ns: Element.Namespace, const normalized_name = blk: {
        if (self._type == .html) {
            break :blk .{ .html, std.ascii.lowerString(&frame.buf, name) };
        }
        // Generic and XML documents create elements with null namespace
        break :blk .{ .null, name };
    };
    // HTML documents are case-insensitive - lowercase the tag name

    const node = try Frame.node_factory.createElementNS(frame, ns, normalized_name, null);
    const element = node.as(Element);

    // Track owner document if it's not the main document
    if (self != frame.document) {
        try frame.setNodeOwnerDocument(node, self);
    }

    const options = options_ orelse return element;
    if (options.is) |is_value| {
        try element.setAttribute(comptime .wrap("is"), .wrap(is_value), frame);
        try Element.Html.Custom.checkAndAttachBuiltIn(element, frame);
    }

    return element;
}

pub fn createElementNS(self: *Document, namespace: ?[]const u8, name: []const u8, frame: *Frame) !*Element {
    try validateElementName(name);
    const ns = Element.Namespace.parse(namespace);
    // Per spec, createElementNS does NOT lowercase (unlike createElement).
    const node = try Frame.node_factory.createElementNS(frame, ns, name, null);

    // Store original URI for unknown namespaces so lookupNamespaceURI can return it
    if (ns == .unknown) {
        if (namespace) |uri| {
            const duped = try frame.dupeString(uri);
            try frame._element_namespace_uris.put(frame.arena, node.as(Element), duped);
        }
    }

    // Track owner document if it's not the main document
    if (self != frame.document) {
        try frame.setNodeOwnerDocument(node, self);
    }
    return node.as(Element);
}

pub fn createAttribute(_: *const Document, name: String.Global, frame: *Frame) !?*Element.Attribute {
    try Element.Attribute.validateAttributeName(name.str);
    return frame._factory.node(Element.Attribute{
        ._proto = undefined,
        ._name = name.str,
        ._value = String.empty,
        ._element = null,
    });
}

pub fn createAttributeNS(_: *const Document, namespace: []const u8, name: String.Global, frame: *Frame) !?*Element.Attribute {
    if (std.mem.eql(u8, namespace, "http://www.w3.org/1999/xhtml") == false) {
        log.warn(.not_implemented, "document.createAttributeNS", .{ .namespace = namespace });
    }

    try Element.Attribute.validateAttributeName(name.str);
    return frame._factory.node(Element.Attribute{
        ._proto = undefined,
        ._name = name.str,
        ._value = String.empty,
        ._element = null,
    });
}

pub fn getElementById(self: *Document, id: []const u8, frame: *Frame) ?*Element {
    if (id.len == 0) {
        return null;
    }

    // A removal invalidates the entire first-in-tree-order answer for this ID,
    // not merely an empty map slot. A later insertion may already have filled
    // the fast map with a duplicate while the dirty marker is still present;
    // consume the marker and repair from tree order before trusting that map.
    if (self._removed_ids.remove(id)) {
        _ = self._elements_by_id.remove(id);
        var tw = @import("TreeWalker.zig").Full.Elements.init(self.asNode(), .{});
        while (tw.next()) |el| {
            const element_id = el.getAttributeSafe(comptime .wrap("id")) orelse continue;
            if (std.mem.eql(u8, element_id, id)) {
                // we ignore this error to keep getElementById easy to call
                // if it really failed, then we're out of memory and nothing's
                // going to work like it should anyways.
                const owned_id = frame.dupeString(id) catch return null;
                self._elements_by_id.put(frame.arena, owned_id, el) catch return null;
                return el;
            }
        }
        return null;
    }

    if (self._elements_by_id.get(id)) |element| {
        return element;
    }

    return null;
}

pub fn getElementsByTagName(self: *Document, tag_name: []const u8, frame: *Frame) !Node.GetElementsByTagNameResult {
    return self.asNode().getElementsByTagName(tag_name, frame);
}

pub fn getElementsByTagNameNS(self: *Document, namespace: ?[]const u8, local_name: []const u8, frame: *Frame) !collections.NodeLive(.tag_name_ns) {
    return self.asNode().getElementsByTagNameNS(namespace, local_name, frame);
}

pub fn getElementsByClassName(self: *Document, class_name: []const u8, frame: *Frame) !collections.NodeLive(.class_name) {
    return self.asNode().getElementsByClassName(class_name, frame);
}

pub fn getElementsByName(self: *Document, name: []const u8, frame: *Frame) !collections.NodeLive(.name) {
    const arena = frame.arena;
    const filter = try arena.dupe(u8, name);
    return collections.NodeLive(.name).init(self.asNode(), filter, frame);
}

pub fn getChildren(self: *Document, frame: *Frame) !collections.NodeLive(.child_elements) {
    return collections.NodeLive(.child_elements).init(self.asNode(), {}, frame);
}

pub fn getDocumentElement(self: *Document) ?*Element {
    var child = self.asNode().firstChild();
    while (child) |node| {
        if (node.is(Element)) |el| {
            return el;
        }
        child = node.nextSibling();
    }
    return null;
}

pub fn getSelection(self: *Document) *Selection {
    return &self._selection;
}

pub fn querySelector(self: *Document, input: String, frame: *Frame) !?*Element {
    return Selector.querySelector(self.asNode(), input.str(), frame) catch |err| Selector.mapErrorToDOM(err);
}

pub fn querySelectorAll(self: *Document, input: String, frame: *Frame) !*Selector.List {
    return Selector.querySelectorAll(self.asNode(), input.str(), frame) catch |err| Selector.mapErrorToDOM(err);
}

pub fn getImplementation(self: *Document, frame: *Frame) !*DOMImplementation {
    if (self._implementation) |impl| return impl;
    const impl = try frame._factory.create(DOMImplementation{});
    self._implementation = impl;
    return impl;
}

pub fn createDocumentFragment(self: *Document, frame: *Frame) !*Node.DocumentFragment {
    const frag = try Node.DocumentFragment.init(frame);
    // Track owner document if it's not the main document
    if (self != frame.document) {
        try frame.setNodeOwnerDocument(frag.asNode(), self);
    }
    return frag;
}

pub fn createComment(self: *Document, data: []const u8, frame: *Frame) !*Node {
    const node = try Frame.node_factory.createComment(frame, data);
    // Track owner document if it's not the main document
    if (self != frame.document) {
        try frame.setNodeOwnerDocument(node, self);
    }
    return node;
}

pub fn createTextNode(self: *Document, data: []const u8, frame: *Frame) !*Node {
    const node = try Frame.node_factory.createTextNode(frame, data);
    // Track owner document if it's not the main document
    if (self != frame.document) {
        try frame.setNodeOwnerDocument(node, self);
    }
    return node;
}

pub fn createCDATASection(self: *Document, data: []const u8, frame: *Frame) !*Node {
    const node = switch (self._type) {
        .html => return error.NotSupported, // cannot create a CDataSection in an HTMLDocument
        .xml => try Frame.node_factory.createCDATASection(frame, data),
        .generic => try Frame.node_factory.createCDATASection(frame, data),
    };
    // Track owner document if it's not the main document
    if (self != frame.document) {
        try frame.setNodeOwnerDocument(node, self);
    }
    return node;
}

pub fn createProcessingInstruction(self: *Document, target: []const u8, data: []const u8, frame: *Frame) !*Node {
    const node = try Frame.node_factory.createProcessingInstruction(frame, target, data);
    // Track owner document if it's not the main document
    if (self != frame.document) {
        try frame.setNodeOwnerDocument(node, self);
    }
    return node;
}

const Range = @import("Range.zig");
pub fn createRange(_: *const Document, frame: *Frame) !*Range {
    return Range.init(frame);
}

pub fn createEvent(_: *const Document, event_type: []const u8, frame: *Frame) !*@import("Event.zig") {
    const Event = @import("Event.zig");
    if (event_type.len > 100) {
        return error.NotSupported;
    }
    const normalized = std.ascii.lowerString(&frame.buf, event_type);

    if (std.mem.eql(u8, normalized, "event") or std.mem.eql(u8, normalized, "events") or std.mem.eql(u8, normalized, "htmlevents")) {
        return Event.init("", null, frame._page);
    }

    if (std.mem.eql(u8, normalized, "customevent") or std.mem.eql(u8, normalized, "customevents")) {
        const CustomEvent = @import("event/CustomEvent.zig");
        return (try CustomEvent.init("", null, frame._page)).asEvent();
    }

    if (std.mem.eql(u8, normalized, "keyboardevent")) {
        const KeyboardEvent = @import("event/KeyboardEvent.zig");
        return (try KeyboardEvent.init("", null, frame)).asEvent();
    }

    if (std.mem.eql(u8, normalized, "inputevent")) {
        const InputEvent = @import("event/InputEvent.zig");
        return (try InputEvent.init("", null, frame)).asEvent();
    }

    if (std.mem.eql(u8, normalized, "mouseevent") or std.mem.eql(u8, normalized, "mouseevents")) {
        const MouseEvent = @import("event/MouseEvent.zig");
        return (try MouseEvent.init("", null, frame)).asEvent();
    }

    if (std.mem.eql(u8, normalized, "messageevent")) {
        const MessageEvent = @import("event/MessageEvent.zig");
        return (try MessageEvent.init("", null, frame._page)).asEvent();
    }

    if (std.mem.eql(u8, normalized, "uievent") or std.mem.eql(u8, normalized, "uievents")) {
        const UIEvent = @import("event/UIEvent.zig");
        return (try UIEvent.init("", null, frame)).asEvent();
    }

    if (std.mem.eql(u8, normalized, "focusevent") or std.mem.eql(u8, normalized, "focusevents")) {
        const FocusEvent = @import("event/FocusEvent.zig");
        return (try FocusEvent.init("", null, frame)).asEvent();
    }

    if (std.mem.eql(u8, normalized, "textevent") or std.mem.eql(u8, normalized, "textevents")) {
        const TextEvent = @import("event/TextEvent.zig");
        return (try TextEvent.init("", null, frame)).asEvent();
    }

    if (std.mem.eql(u8, normalized, "compositionevent")) {
        const CompositionEvent = @import("event/CompositionEvent.zig");
        return (try CompositionEvent.init("", null, frame)).asEvent();
    }

    return error.NotSupported;
}

pub fn createTreeWalker(_: *const Document, root: *Node, what_to_show: ?js.Value, filter: ?DOMTreeWalker.FilterOpts, frame: *Frame) !*DOMTreeWalker {
    return DOMTreeWalker.init(root, try whatToShow(what_to_show), filter, frame);
}

pub fn createNodeIterator(_: *const Document, root: *Node, what_to_show: ?js.Value, filter: ?DOMNodeIterator.FilterOpts, frame: *Frame) !*DOMNodeIterator {
    return DOMNodeIterator.init(root, try whatToShow(what_to_show), filter, frame);
}

pub fn evaluate(
    self: *Document,
    expression: []const u8,
    context_node: ?*Node,
    resolver: ?js.Function,
    result_type: ?u16,
    result: ?*XPathResult,
    frame: *Frame,
) !*XPathResult {
    // resolver/result are no-ops in HTML mode (decision #2).
    // Null/missing context_node falls back to the document — matches the
    // polyfill (decision #2). Firefox throws TypeError on a *missing*
    // arg, but the bridge can't distinguish "missing" from "explicit
    // null" here, so polyfill parity wins for the ambiguity.
    _ = resolver;
    _ = result;
    return XPathResult.fromExpression(
        expression,
        context_node orelse self.asNode(),
        result_type orelse XPathResult.ANY_TYPE,
        frame,
    );
}

pub fn createExpression(
    _: *const Document,
    expression: []const u8,
    resolver: ?js.Function,
    frame: *Frame,
) !*XPathExpression {
    _ = resolver;
    return XPathExpression.init(expression, frame);
}

pub fn createNSResolver(_: *const Document, node: *Node) ?*Node {
    return node;
}

fn whatToShow(value_: ?js.Value) !u32 {
    const value = value_ orelse return 4294967295; // show all when undefined
    if (value.isUndefined()) {
        // undefined explicitly passed
        return 4294967295;
    }

    if (value.isNull()) {
        return 0;
    }

    return value.toZig(u32);
}

pub fn getReadyState(self: *const Document) []const u8 {
    return @tagName(self._ready_state);
}

pub fn getActiveElement(self: *Document) ?*Element {
    if (self._active_element) |focused| {
        // Retarget focus through every shadow boundary. document.activeElement
        // is the outermost host, never an otherwise-unreachable closed-root
        // descendant.
        var active = focused;
        while (active.asNode().getRootNode(.{}).is(@import("ShadowRoot.zig"))) |shadow| {
            active = shadow._host;
        }
        return active;
    }

    // Default to body if it exists
    if (self.is(HTMLDocument)) |html_doc| {
        if (html_doc.getBody()) |body| {
            return body.asElement();
        }
    }

    // Fallback to document element
    return self.getDocumentElement();
}

pub fn getStyleSheets(self: *Document, frame: *Frame) !*StyleSheetList {
    if (self._style_sheets) |sheets| {
        return sheets;
    }
    const sheets = try StyleSheetList.init(frame);
    self._style_sheets = sheets;
    return sheets;
}

pub fn getFonts(self: *Document, frame: *Frame) !*FontFaceSet {
    if (self._fonts) |fonts| {
        return fonts;
    }
    const fonts = try FontFaceSet.init(frame);
    fonts.acquireRef();
    self._fonts = fonts;
    return fonts;
}

pub fn adoptNode(self: *Document, node: *Node, frame: *Frame) !*Node {
    if (node._type == .document) {
        return error.NotSupported;
    }

    const old_owner = node.ownerDocument(frame) orelse frame.document;

    if (node._parent) |parent| {
        _ = frame.removeNode(parent, node, .{ .will_be_reconnected = false });
    }

    if (old_owner != self) {
        try frame.adoptNodeTree(node, old_owner, self);
    }

    return node;
}

pub fn importNode(_: *const Document, node: *Node, deep_: ?bool, frame: *Frame) !*Node {
    if (node._type == .document) {
        return error.NotSupported;
    }

    return node.cloneNode(deep_, frame);
}

pub fn append(self: *Document, nodes: []const Node.NodeOrText, frame: *Frame) !void {
    try validateDocumentNodes(self, nodes, false);

    const parent = self.asNode();
    frame.domChanged();
    const parent_is_connected = parent.isConnected();

    for (nodes) |node_or_text| {
        const child = try node_or_text.toNode(frame);

        // DocumentFragments are special - append all their children
        if (child.is(Node.DocumentFragment)) |_| {
            try frame.appendAllChildren(child, parent);
            continue;
        }

        const child_connected = child.isConnected();
        {
            var load_guard = frame.beginReconnectLoadGuard(child._parent != null and child_connected and parent_is_connected);
            defer load_guard.deinit();
            if (child._parent) |previous_parent| {
                if (frame.removeNode(previous_parent, child, .{ .will_be_reconnected = parent_is_connected }) == .reentered) return;
            }
            try frame.appendNode(parent, child, .{ .child_already_connected = child_connected });
        }
    }
}

pub fn prepend(self: *Document, nodes: []const Node.NodeOrText, frame: *Frame) !void {
    try validateDocumentNodes(self, nodes, false);

    const parent = self.asNode();
    frame.domChanged();
    const parent_is_connected = parent.isConnected();

    var i = nodes.len;
    while (i > 0) {
        i -= 1;
        const child = try nodes[i].toNode(frame);

        // DocumentFragments are special - need to insert all their children
        if (child.is(Node.DocumentFragment)) |frag| {
            const first_child = parent.firstChild();
            var frag_child = frag.asNode().lastChild();
            while (frag_child) |fc| {
                const prev = fc.previousSibling();
                const child_connected = fc.isConnected();
                {
                    var load_guard = frame.beginReconnectLoadGuard(child_connected and parent_is_connected);
                    defer load_guard.deinit();
                    if (frame.removeNode(frag.asNode(), fc, .{ .will_be_reconnected = parent_is_connected }) == .reentered) return;
                    if (first_child) |before| {
                        try frame.insertNodeRelative(parent, fc, .{ .before = before }, .{ .child_already_connected = child_connected });
                    } else {
                        try frame.appendNode(parent, fc, .{ .child_already_connected = child_connected });
                    }
                }
                frag_child = prev;
            }
            continue;
        }

        const child_connected = child.isConnected();
        {
            var load_guard = frame.beginReconnectLoadGuard(child._parent != null and child_connected and parent_is_connected);
            defer load_guard.deinit();
            if (child._parent) |previous_parent| {
                if (frame.removeNode(previous_parent, child, .{ .will_be_reconnected = parent_is_connected }) == .reentered) return;
            }

            const first_child = parent.firstChild();
            if (first_child) |before| {
                try frame.insertNodeRelative(parent, child, .{ .before = before }, .{ .child_already_connected = child_connected });
            } else {
                try frame.appendNode(parent, child, .{ .child_already_connected = child_connected });
            }
        }
    }
}

pub fn replaceChildren(self: *Document, nodes: []const Node.NodeOrText, frame: *Frame) !void {
    try validateDocumentNodes(self, nodes, false);
    return self.asNode().replaceChildren(nodes, frame);
}

pub fn moveBefore(self: *Document, node: js.Value, child: js.Value, frame: *Frame) !void {
    return self.asNode().moveBefore(node, child, frame);
}

pub fn elementFromPoint(self: *Document, x: f64, y: f64, frame: *Frame) !?*Element {
    // DFS in document order; topmost = last visited element whose rect contains (x, y).
    //
    // Faux-layout shortcut: rect.top is calculateDocumentPosition × 5, which is
    // monotonically increasing in document order. So we maintain a running
    // preorder counter instead of calling calculateDocumentPosition per node
    // (which itself is O(N)). Once the counter's y passes the query y, no
    // later element can contain the point, and we can return.
    //
    // We also share a single VisibilityCache across all elements so the
    // ancestor-walk inside isHidden gets amortized.
    var topmost: ?*Element = null;

    const root = self.asNode();
    var stack: std.ArrayList(*Node) = .empty;
    try stack.append(frame.local_arena, root);

    var visibility_cache: Element.VisibilityCache = .{};
    var preorder_index: f64 = 0;

    while (stack.items.len > 0) {
        const node = stack.pop() orelse break;
        const pos = preorder_index * 5.0;

        if (pos > y) {
            // Monotonic: no later element has top <= y, so none can contain (x, y).
            return topmost;
        }

        preorder_index += 1;
        if (node.is(Element)) |element| {
            if (element.checkVisibilityCached(&visibility_cache, frame)) {
                const dims = element.getElementDimensions(frame);
                // x and y both come from preorder position in our faux layout.
                const left = pos;
                const top = pos;
                const right = pos + dims.width;
                const bottom = pos + dims.height;
                if (x >= left and x <= right and y >= top and y <= bottom) {
                    topmost = element;
                }
            }
        }

        // Add children to stack in reverse order so we process them in document order
        var child = node.lastChild();
        while (child) |c| {
            try stack.append(frame.local_arena, c);
            child = c.previousSibling();
        }
    }

    return topmost;
}

pub fn elementsFromPoint(self: *Document, x: f64, y: f64, frame: *Frame) ![]const *Element {
    // Get topmost element
    var current: ?*Element = (try self.elementFromPoint(x, y, frame)) orelse return &.{};
    var result: std.ArrayList(*Element) = .empty;
    while (current) |el| {
        try result.append(frame.local_arena, el);
        current = el.parentElement();
    }
    return result.items;
}

pub fn getDocType(self: *Document) ?*Node {
    var tw = @import("TreeWalker.zig").Full.init(self.asNode(), .{});
    while (tw.next()) |node| {
        if (node._type == .document_type) {
            return node;
        }
    }
    return null;
}

// document.write is complicated and works differently based on the state of
// parsing. But, generally, it's supposed to be additive/streaming. Multiple
// document.writes are parsed a single unit. Well, that causes issues with
// html5ever if we're trying to parse 1 document which is really many. So we
// try to detect "new" documents. (This is particularly problematic because we
// don't have proper frame support, so document.write into a frame can get
// sent to the main document (instead of the frame document)...and it's completely
// reasonable for 2 frames to document.write("<html>...</html>") into their own
// frame.
fn looksLikeNewDocument(html: []const u8) bool {
    const trimmed = std.mem.trimLeft(u8, html, &std.ascii.whitespace);
    return std.ascii.startsWithIgnoreCase(trimmed, "<!DOCTYPE") or
        std.ascii.startsWithIgnoreCase(trimmed, "<html");
}

pub fn write(self: *Document, values: []js.Value, frame: *Frame) !void {
    return self.writeValues(values, false, "write", frame);
}

// https://html.spec.whatwg.org/multipage/dynamic-markup-insertion.html#dom-document-writeln
// `writeln(...text)` runs the document write steps with `text` followed by a
// U+000A LINE FEED character.
pub fn writeln(self: *Document, values: []js.Value, frame: *Frame) !void {
    return self.writeValues(values, true, "writeln", frame);
}

fn writeValues(
    self: *Document,
    values: []js.Value,
    append_newline: bool,
    member: []const u8,
    call_frame: *Frame,
) !void {
    const frame = self._frame orelse self._owner_frame orelse call_frame;
    const context: js.WebIDL.ConversionContext = .{
        .operation = .{ .interface = "Document", .name = member },
    };
    const local = call_frame.js.local.?;

    var joined: std.ArrayList(u8) = .empty;
    var all_trusted = true;
    for (values) |value| {
        const string = TrustedTypes.trustedPayload(value, .html, local) orelse blk: {
            all_trusted = false;
            break :blk try js.WebIDL.toDOMStringValueWithContext(
                value,
                &call_frame.js.execution,
                context,
            );
        };
        try joined.appendSlice(call_frame.call_arena, try string.toSlice());
    }

    var html = joined.items;
    if (!all_trusted) {
        const combined = js.String{
            .local = local,
            .handle = local.isolate.initStringHandle(html),
        };
        const compliant = try TrustedTypes.getCompliantString(
            combined.toValue(),
            frame.js,
            frame.window.getTrustedTypes(),
            .html,
            "Document",
            member,
            context,
            .dom_string,
            &call_frame.js.execution,
        );
        html = try compliant.toSlice();
    }

    if (append_newline) {
        // Chromium appends U+000A only after the single default-policy call.
        var with_newline: std.ArrayList(u8) = .empty;
        try with_newline.appendSlice(call_frame.call_arena, html);
        try with_newline.append(call_frame.call_arena, '\n');
        html = with_newline.items;
    }
    return self.writeInternal(html, call_frame);
}

fn writeInternal(self: *Document, html: []const u8, call_frame: *Frame) !void {
    // document.write acts on this document's own frame, which isn't necessarily
    // the calling frame — e.g. a parent frame writing into an iframe's document.
    // The markup (and any scripts it contains) must be parsed and run in that
    // document's context, not the caller's.
    const frame = self._frame orelse self._owner_frame orelse call_frame;

    if (self._type == .xml) {
        return error.InvalidStateError;
    }

    if (self._throw_on_dynamic_markup_insertion_counter > 0) {
        return error.InvalidStateError;
    }

    if (self._current_script == null or frame._load_state != .parsing) {
        if (self._script_created_parser == null or looksLikeNewDocument(html)) {
            _ = try self.open(frame);
        }

        if (html.len > 0) {
            if (self._script_created_parser) |*parser| {
                parser.read(html) catch |err| {
                    log.warn(.dom, "document.write parser error", .{ .err = err });
                    // html5ever's handle was destroyed inside read(), but the
                    // pending text buffer (if any) still wants to land on its
                    // text node's _data — flushPendingText doesn't depend on
                    // the handle, so attempt a final flush before dropping.
                    parser.parser.flushPendingText() catch |flush_err| {
                        log.warn(.dom, "flush after parser panic", .{ .err = flush_err });
                    };
                    self._script_created_parser = null;
                    self._close_requested = false;
                };
            }
        }

        if (self._close_requested) {
            // document.close was executed during a document.write. We couldn't
            // execute that during the write, but we can now.
            if (self._script_created_parser) |*parser| {
                if (parser.feeding == false) {
                    try self.finishScriptCreatedParser(frame);
                }
            } else {
                self._close_requested = false;
            }
        }
        return;
    }

    // Inline script during parsing
    const script = self._current_script.?;
    const parent = script.asNode().parentNode() orelse return;

    // Our implementation is hacky. We'll write to a DocumentFragment, then
    // append its children.
    const fragment = try Node.DocumentFragment.init(frame);
    const fragment_node = fragment.asNode();

    const previous_parse_mode = frame._parse_mode;
    frame._parse_mode = .document_write;
    defer frame._parse_mode = previous_parse_mode;

    const arena = try frame.getArena(.medium, "Document.write");
    defer frame.releaseArena(arena);

    var parser = Parser.init(arena, fragment_node, frame, .{ .allow_declarative_shadow = true });
    parser.parseFragment(html);

    // Extract children from wrapper HTML element (html5ever wraps fragments)
    // https://github.com/servo/html5ever/issues/583
    const children = fragment_node._children orelse return;
    const first = Node.linkToNode(children.first.?);

    // Collect all children to insert (to avoid iterator invalidation)
    var children_to_insert: std.ArrayList(*Node) = .empty;

    var it = if (first.is(Element.Html.Html) == null) fragment_node.childrenIterator() else first.childrenIterator();
    while (it.next()) |child| {
        try children_to_insert.append(arena, child);
    }

    if (children_to_insert.items.len == 0) {
        return;
    }

    // Determine insertion point:
    // - If _write_insertion_point is set and still parented correctly, continue from there
    // - Otherwise, start after the script (first write, or previous insertion point was removed)
    // parseFragment above can synchronously execute a parser-blocking script
    // (e.g. <script src=...> with from_parser=true). That script's side
    // effects can detach `script` from `parent` — for instance, by writing
    // to parent.innerHTML — leaving us nowhere sensible to splice in.
    var insert_after: ?*Node = blk: {
        if (self._write_insertion_point) |wip| {
            if (wip._parent == parent) {
                break :blk wip;
            }
        }
        if (script.asNode()._parent == parent) {
            break :blk script.asNode();
        }
        return;
    };

    for (children_to_insert.items) |child| {
        // Clear parent pointer (child is currently parented to fragment/HTML wrapper)
        child._parent = null;
        try frame.insertNodeRelative(parent, child, .{ .after = insert_after.? }, .{});
        insert_after = child;
    }

    frame.domChanged();
    self._write_insertion_point = children_to_insert.getLast();
}

pub fn open(self: *Document, call_frame: *Frame) !*Document {
    const frame = self._frame orelse self._owner_frame orelse call_frame;

    if (self._type == .xml) {
        return error.InvalidStateError;
    }

    if (self._throw_on_dynamic_markup_insertion_counter > 0) {
        return error.InvalidStateError;
    }

    if (frame._load_state == .parsing) {
        return self;
    }

    if (self._script_created_parser != null) {
        return self;
    }

    // If we aren't parsing, then open clears the document.
    const doc_node = self.asNode();

    {
        // Snapshot before the first browsing-context discard. Parent load
        // completion can re-enter and move a sibling, invalidating an intrusive
        // linked-list iterator's cached next pointer.
        var original_children: std.ArrayList(*Node) = .empty;
        var it = doc_node.childrenIterator();
        while (it.next()) |child| try original_children.append(frame.call_arena, child);
        for (original_children.items) |child| {
            if (child._parent != doc_node) continue;
            _ = frame.removeNode(doc_node, child, .{ .will_be_reconnected = false });
        }
    }

    // reset the document
    self._elements_by_id.clearAndFree(frame.arena);
    self._active_element = null;
    self._open_popovers = .empty;
    self._style_sheets = null;
    self._implementation = null;
    self._ready_state = .loading;

    self._script_created_parser = Parser.Streaming.init(frame.arena, doc_node, frame, .{ .allow_declarative_shadow = true });
    try self._script_created_parser.?.start();
    frame._parse_mode = .document;

    return self;
}

pub fn close(self: *Document, call_frame: *Frame) !void {
    const frame = self._frame orelse self._owner_frame orelse call_frame;

    if (self._type == .xml) {
        return error.InvalidStateError;
    }

    if (self._throw_on_dynamic_markup_insertion_counter > 0) {
        return error.InvalidStateError;
    }

    if (self._script_created_parser) |*parser| {
        if (parser.feeding) {
            // we're currently in a document.write, we cannot close. We flag
            // the close and process it at the next safe spot.
            self._close_requested = true;
            return;
        }
    } else {
        return;
    }

    try self.finishScriptCreatedParser(frame);
}

fn finishScriptCreatedParser(self: *Document, frame: *Frame) !void {
    self._close_requested = false;

    // done() finishes html5ever's handle and runs the final flushPendingText.
    // Even if flushPendingText errors, the handle is already finished and we
    // must not retain the Streaming — defer so the error path also drops it.
    // (Streaming.done nulls its own handle, so dropping the struct is safe.)
    defer self._script_created_parser = null;
    try self._script_created_parser.?.done();

    // The write'd markup is fully parsed; run any deferred scripts it produced
    // (e.g. inline modules) before firing the load event. This frame's initial
    // parse may never have set static_scripts_done (e.g. a freshly-loaded
    // iframe written into via document.write), so we can't rely on it.
    frame._script_manager.base.scriptCreatedParseDone();

    frame.documentIsComplete();
}

pub fn getFirstElementChild(self: *Document) ?*Element {
    var it = self.asNode().childrenIterator();
    while (it.next()) |child| {
        if (child.is(Element)) |el| {
            return el;
        }
    }
    return null;
}

pub fn getLastElementChild(self: *Document) ?*Element {
    var maybe_child = self.asNode().lastChild();
    while (maybe_child) |child| {
        if (child.is(Element)) |el| {
            return el;
        }
        maybe_child = child.previousSibling();
    }
    return null;
}

pub fn getChildElementCount(self: *Document) u32 {
    var i: u32 = 0;
    var it = self.asNode().childrenIterator();
    while (it.next()) |child| {
        if (child.is(Element) != null) {
            i += 1;
        }
    }
    return i;
}

pub fn getAdoptedStyleSheets(self: *Document, frame: *Frame) !js.Object.Global {
    if (self._adopted_style_sheets) |ass| {
        return ass;
    }
    const js_arr = frame.js.local.?.newArray(0);
    const js_obj = js_arr.toObject();
    self._adopted_style_sheets = try js_obj.persist();
    return self._adopted_style_sheets.?;
}

pub fn hasFocus(_: *Document) bool {
    log.debug(.not_implemented, "Document.hasFocus", .{});
    return true;
}

pub fn setAdoptedStyleSheets(self: *Document, sheets: js.Object) !void {
    self._adopted_style_sheets = try sheets.persist();
}

// Validates that nodes can be inserted into a Document, respecting Document constraints:
// - At most one Element child
// - At most one DocumentType child
// - No Document, Attribute, or Text nodes
// - Only Element, DocumentType, Comment, and ProcessingInstruction are allowed
// When replacing=true, existing children are not counted (for replaceChildren)
fn validateDocumentNodes(self: *Document, nodes: []const Node.NodeOrText, comptime replacing: bool) !void {
    const parent = self.asNode();

    // Check existing elements and doctypes (unless we're replacing all children)
    var has_element = false;
    var has_doctype = false;

    if (!replacing) {
        var it = parent.childrenIterator();
        while (it.next()) |child| {
            if (child._type == .element) {
                has_element = true;
            } else if (child._type == .document_type) {
                has_doctype = true;
            }
        }
    }

    // Validate new nodes
    for (nodes) |node_or_text| {
        switch (node_or_text) {
            .text => {
                // Text nodes are not allowed as direct children of Document
                return error.HierarchyError;
            },
            .node => |child| {
                // Check if it's a DocumentFragment - need to validate its children
                if (child.is(Node.DocumentFragment)) |frag| {
                    var frag_it = frag.asNode().childrenIterator();
                    while (frag_it.next()) |frag_child| {
                        // Document can only contain: Element, DocumentType, Comment, ProcessingInstruction
                        switch (frag_child._type) {
                            .element => {
                                if (has_element) {
                                    return error.HierarchyError;
                                }
                                has_element = true;
                            },
                            .document_type => {
                                if (has_doctype) {
                                    return error.HierarchyError;
                                }
                                if (has_element) {
                                    // Doctype cannot be inserted if document already has an element
                                    return error.HierarchyError;
                                }
                                has_doctype = true;
                            },
                            .cdata => |cd| switch (cd._type) {
                                .comment, .processing_instruction => {}, // Allowed
                                .text, .cdata_section => return error.HierarchyError, // Not allowed in Document
                            },
                            .document, .attribute, .document_fragment => return error.HierarchyError,
                        }
                    }
                } else {
                    // Validate node type for direct insertion
                    switch (child._type) {
                        .element => {
                            if (has_element) {
                                return error.HierarchyError;
                            }
                            has_element = true;
                        },
                        .document_type => {
                            if (has_doctype) {
                                return error.HierarchyError;
                            }
                            if (has_element) {
                                // Doctype cannot be inserted if document already has an element
                                return error.HierarchyError;
                            }
                            has_doctype = true;
                        },
                        .cdata => |cd| switch (cd._type) {
                            .comment, .processing_instruction => {}, // Allowed
                            .text, .cdata_section => return error.HierarchyError, // Not allowed in Document
                        },
                        .document, .attribute, .document_fragment => return error.HierarchyError,
                    }
                }

                // Check for cycles
                if (child.contains(parent)) {
                    return error.HierarchyError;
                }
            },
        }
    }
}

fn validateElementName(name: []const u8) !void {
    if (name.len == 0) {
        return error.InvalidCharacterError;
    }

    const first = name[0];
    // Element names cannot start with: digits, period, hyphen
    if ((first >= '0' and first <= '9') or first == '.' or first == '-') {
        return error.InvalidCharacterError;
    }

    for (name[1..]) |c| {
        const is_valid = std.ascii.isAlphanumeric(c) or
            c == '_' or c == '-' or c == '.' or c == ':' or
            c >= 128; // Allow non-ASCII UTF-8

        if (!is_valid) {
            return error.InvalidCharacterError;
        }
    }
}

// When a frame's URL is about:blank, or as soon as a frame is
// programmatically created, it has this default "blank" content
pub fn injectBlank(self: *Document, frame: *Frame) error{InjectBlankError}!void {
    self._injectBlank(frame) catch |err| {
        // we wrap _injectBlank like this so that injectBlank can only return an
        // InjectBlankError. injectBlank is used in when nodes are inserted
        // as since it inserts node itself, Zig can't infer the error set.
        log.err(.browser, "inject blank", .{ .err = err });
        return error.InjectBlankError;
    };
}

fn _injectBlank(self: *Document, frame: *Frame) !void {
    if (comptime IS_DEBUG) {
        // should only be called on an empty document
        std.debug.assert(self.asNode()._children == null);
    }

    const html = try Frame.node_factory.createElementNS(frame, .html, "html", null);
    const head = try Frame.node_factory.createElementNS(frame, .html, "head", null);
    const body = try Frame.node_factory.createElementNS(frame, .html, "body", null);
    try frame.appendNode(html, head, .{});
    try frame.appendNode(html, body, .{});
    try frame.appendNode(self.asNode(), html, .{});
}

const ReadyState = enum {
    loading,
    interactive,
    complete,
};

pub const CompatibilityMode = enum {
    quirks,
    limited_quirks,
    no_quirks,
};

pub const JsApi = struct {
    pub const bridge = js.Bridge(Document);

    pub const Meta = struct {
        pub const name = "Document";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(_constructor, .{});
    fn _constructor(frame: *Frame) !*Document {
        return frame._factory.node(Document{
            ._proto = undefined,
            ._type = .generic,
        });
    }

    fn getCharacterSet(self: *const Document) []const u8 {
        const doc_frame = self._frame orelse return "UTF-8";
        return doc_frame.charset;
    }

    pub const implementation = bridge.accessor(Document.getImplementation, null, .{});
    pub const URL = bridge.accessor(Document.getURL, null, .{});
    pub const documentURI = bridge.accessor(Document.getURL, null, .{});
    pub const compatMode = bridge.accessor(Document.getCompatMode, null, .{});
    pub const characterSet = bridge.accessor(getCharacterSet, null, .{});
    pub const charset = bridge.accessor(getCharacterSet, null, .{});
    pub const inputEncoding = bridge.accessor(getCharacterSet, null, .{});
    pub const contentType = bridge.accessor(Document.getContentType, null, .{});
    pub const doctype = bridge.accessor(Document.getDocType, null, .{});
    pub const documentElement = bridge.accessor(Document.getDocumentElement, null, .{});
    pub const domain = bridge.accessor(Document.getDomain, Document.setDomain, .{});
    pub const referrer = bridge.accessor(Document.getReferrer, null, .{});
    pub const cookie = bridge.accessor(Document.getCookie, Document.setCookie, .{});
    pub const readyState = bridge.accessor(Document.getReadyState, null, .{});
    pub const title = bridge.accessor(Document.getTitle, Document.setTitle, .{ .ce_reactions = true });
    pub const dir = bridge.accessor(Document.getDir, Document.setDir, .{ .ce_reactions = true });
    pub const body = bridge.accessor(Document.getBody, Document.setBody, .{ .ce_reactions = true });
    pub const head = bridge.accessor(Document.getHead, null, .{});
    pub const images = bridge.accessor(Document.getImages, null, .{});
    pub const embeds = bridge.accessor(Document.getEmbeds, null, .{});
    pub const plugins = bridge.accessor(Document.getEmbeds, null, .{});
    pub const links = bridge.accessor(Document.getLinks, null, .{});
    pub const forms = bridge.accessor(Document.getForms, null, .{});
    pub const scripts = bridge.accessor(Document.getScripts, null, .{});
    pub const currentScript = bridge.accessor(Document.getCurrentScript, null, .{});
    pub const defaultView = bridge.accessor(struct {
        fn defaultView(self: *const Document) ?*@import("Window.zig") {
            const frame = self._frame orelse return null;
            return frame.window;
        }
    }.defaultView, null, .{});
    pub const anchors = bridge.accessor(Document.getAnchors, null, .{});
    pub const applets = bridge.accessor(Document.getApplets, null, .{});
    pub const all = bridge.accessor(Document.getAll, null, .{});
    pub const scrollingElement = bridge.accessor(Document.getScrollingElement, null, .{});
    pub const hidden = bridge.accessor(Document.getHidden, null, .{});
    pub const visibilityState = bridge.accessor(Document.getVisibilityState, null, .{});
    pub const prerendering = bridge.accessor(Document.getPrerendering, null, .{});
    pub const onselectionchange = bridge.accessor(Document.getOnSelectionChange, Document.setOnSelectionChange, .{});
    pub const onvisibilitychange = bridge.accessor(Document.getOnVisibilityChange, Document.setOnVisibilityChange, .{});
    pub const children = bridge.accessor(Document.getChildren, null, .{});
    pub const firstElementChild = bridge.accessor(Document.getFirstElementChild, null, .{});
    pub const lastElementChild = bridge.accessor(Document.getLastElementChild, null, .{});
    pub const childElementCount = bridge.accessor(Document.getChildElementCount, null, .{});
    pub const activeElement = bridge.accessor(Document.getActiveElement, null, .{});
    pub const styleSheets = bridge.accessor(Document.getStyleSheets, null, .{});
    pub const adoptedStyleSheets = bridge.accessor(Document.getAdoptedStyleSheets, Document.setAdoptedStyleSheets, .{});
    pub const fonts = bridge.accessor(Document.getFonts, null, .{});

    pub const adoptNode = bridge.function(Document.adoptNode, .{ .ce_reactions = true });
    pub const append = bridge.function(Document.append, .{ .ce_reactions = true, .variadic = true });
    pub const close = bridge.function(Document.close, .{ .ce_reactions = true });
    pub const createAttribute = bridge.function(Document.createAttribute, .{});
    pub const createAttributeNS = bridge.function(Document.createAttributeNS, .{});
    pub const createCDATASection = bridge.function(Document.createCDATASection, .{});
    pub const createComment = bridge.function(Document.createComment, .{});
    pub const createDocumentFragment = bridge.function(Document.createDocumentFragment, .{});
    pub const createElement = bridge.function(Document.createElement, .{});
    pub const createElementNS = bridge.function(Document.createElementNS, .{});
    pub const createEvent = bridge.function(Document.createEvent, .{});
    pub const createExpression = bridge.function(Document.createExpression, .{});
    pub const createNSResolver = bridge.function(Document.createNSResolver, .{});
    pub const createNodeIterator = bridge.function(Document.createNodeIterator, .{});
    pub const createProcessingInstruction = bridge.function(Document.createProcessingInstruction, .{});
    pub const createRange = bridge.function(Document.createRange, .{});
    pub const createTextNode = bridge.function(Document.createTextNode, .{});
    pub const createTreeWalker = bridge.function(Document.createTreeWalker, .{});
    pub const elementFromPoint = bridge.function(Document.elementFromPoint, .{});
    pub const elementsFromPoint = bridge.function(Document.elementsFromPoint, .{});
    pub const evaluate = bridge.function(Document.evaluate, .{});

    fn _getElementById(self: *Document, value_: ?js.Value, frame: *Frame) !?*Element {
        const value = value_ orelse return null;
        if (value.isNull()) return self.getElementById("null", frame);
        if (value.isUndefined()) return self.getElementById("undefined", frame);
        return self.getElementById(try value.toZig([]const u8), frame);
    }

    pub const getElementById = bridge.function(_getElementById, .{});
    pub const getElementsByClassName = bridge.function(Document.getElementsByClassName, .{});
    pub const getElementsByName = bridge.function(Document.getElementsByName, .{});
    pub const getElementsByTagName = bridge.function(Document.getElementsByTagName, .{});
    pub const getElementsByTagNameNS = bridge.function(Document.getElementsByTagNameNS, .{});
    pub const getSelection = bridge.function(Document.getSelection, .{});
    pub const hasFocus = bridge.function(Document.hasFocus, .{});
    pub const importNode = bridge.function(Document.importNode, .{ .ce_reactions = true });
    pub const moveBefore = bridge.function(Document.moveBefore, .{ .ce_reactions = true });
    pub const open = bridge.function(Document.open, .{ .ce_reactions = true });
    pub const prepend = bridge.function(Document.prepend, .{ .ce_reactions = true, .variadic = true });
    pub const querySelector = bridge.function(Document.querySelector, .{});
    pub const querySelectorAll = bridge.function(Document.querySelectorAll, .{});
    pub const replaceChildren = bridge.function(Document.replaceChildren, .{ .ce_reactions = true, .variadic = true });
    pub const write = bridge.function(Document.write, .{ .ce_reactions = true, .variadic = true });
    pub const writeln = bridge.function(Document.writeln, .{ .ce_reactions = true, .variadic = true });

    pub const location = bridge.legacyUnforgeableAccessor(Document.getLocation, Document.setLocation, .{});
};

const testing = @import("../../testing.zig");
test "WebApi: Document" {
    try testing.htmlRunner("document", .{});
}

test "WebApi: Document.evaluate" {
    try testing.htmlRunner("xpath/document_evaluate.html", .{});
}

test "Document: isRelaxableTo" {
    // Pure opt-in (relax to self) is always allowed, including IP hosts.
    try testing.expectEqual(true, isRelaxableTo("a.example.com", "a.example.com"));
    try testing.expectEqual(true, isRelaxableTo("127.0.0.1", "127.0.0.1"));

    // Relaxing to a registrable superdomain.
    try testing.expectEqual(true, isRelaxableTo("a.example.com", "example.com"));
    try testing.expectEqual(true, isRelaxableTo("a.b.example.com", "example.com"));
    try testing.expectEqual(true, isRelaxableTo("a.b.example.com", "b.example.com"));

    // Bare TLDs (single label) are never registrable. Multi-label public
    // suffixes are rejected via the PSL — note the test build stubs the PSL
    // to {gov.uk, api.gov.uk}, so those are the entries exercised here.
    try testing.expectEqual(false, isRelaxableTo("a.example.com", "com"));
    try testing.expectEqual(false, isRelaxableTo("foo.gov.uk", "gov.uk"));
    try testing.expectEqual(false, isRelaxableTo("a.api.gov.uk", "api.gov.uk"));
    // ...but a registrable domain sitting under that suffix is fine.
    try testing.expectEqual(true, isRelaxableTo("a.dept.gov.uk", "dept.gov.uk"));

    // Must be a label-boundary suffix, not a substring suffix.
    try testing.expectEqual(false, isRelaxableTo("a.example.com", "ample.com"));
    try testing.expectEqual(false, isRelaxableTo("notexample.com", "example.com"));

    // Unrelated domain, and the empty string.
    try testing.expectEqual(false, isRelaxableTo("a.example.com", "example.org"));
    try testing.expectEqual(false, isRelaxableTo("a.example.com", ""));
}
