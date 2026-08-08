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

const js = @import("../js/js.zig");
const Frame = @import("../Frame.zig");
const StyleManager = @import("../StyleManager.zig");
const reflect = @import("../reflect.zig");

const CSS = @import("CSS.zig");
const DOMException = @import("DOMException.zig");
const DOMMatrixReadOnly = @import("DOMMatrixReadOnly.zig");
const Node = @import("Node.zig");
const ShadowRoot = @import("ShadowRoot.zig");
const TrustedTypes = @import("TrustedTypes.zig");
const EventTarget = @import("EventTarget.zig");
const InputDeviceCapabilities = @import("InputDeviceCapabilities.zig");
const collections = @import("collections.zig");
pub const DOMRect = @import("DOMRect.zig");

const Selector = @import("selector/Selector.zig");
const Animation = @import("animation/Animation.zig");
const CSSStyleProperties = @import("css/CSSStyleProperties.zig");

pub const Svg = @import("element/Svg.zig");
pub const Html = @import("element/Html.zig");
const slotting = @import("element/slotting.zig");
pub const Attribute = @import("element/Attribute.zig");
const DOMStringMap = @import("element/DOMStringMap.zig");

const log = lp.log;
const String = lp.String;

const Element = @This();

pub const DatasetLookup = std.AutoHashMapUnmanaged(*Element, *DOMStringMap);
pub const StyleLookup = std.AutoHashMapUnmanaged(*Element, *CSSStyleProperties);
pub const ClassListLookup = std.AutoHashMapUnmanaged(*Element, *collections.DOMTokenList);
pub const RelListLookup = std.AutoHashMapUnmanaged(*Element, *collections.DOMTokenList);
pub const ShadowRootLookup = std.AutoHashMapUnmanaged(*Element, *ShadowRoot);
pub const NamespaceUriLookup = std.AutoHashMapUnmanaged(*Element, []const u8);

pub const ScrollPosition = struct {
    x: u32 = 0,
    y: u32 = 0,
};
pub const ScrollPositionLookup = std.AutoHashMapUnmanaged(*Element, ScrollPosition);

pub const Namespace = enum(u8) {
    html,
    svg,
    mathml,
    xml,
    // We should keep the original value, but don't.  If this becomes important
    // consider storing it in a frame lookup, like `_element_class_lists`, rather
    // that adding a slice directly here (directly in every element).
    unknown,
    null,

    pub fn toUri(self: Namespace) ?[]const u8 {
        return switch (self) {
            .html => "http://www.w3.org/1999/xhtml",
            .svg => "http://www.w3.org/2000/svg",
            .mathml => "http://www.w3.org/1998/Math/MathML",
            .xml => "http://www.w3.org/XML/1998/namespace",
            .unknown => "http://lightpanda.io/unsupported/namespace",
            .null => null,
        };
    }

    pub fn parse(namespace_: ?[]const u8) Namespace {
        const namespace = namespace_ orelse return .null;
        if (namespace.len == "http://www.w3.org/1999/xhtml".len) {
            // Common case, avoid the string comparison. Recklessly
            @branchHint(.likely);
            return .html;
        }
        if (std.mem.eql(u8, namespace, "http://www.w3.org/XML/1998/namespace")) {
            return .xml;
        }
        if (std.mem.eql(u8, namespace, "http://www.w3.org/2000/svg")) {
            return .svg;
        }
        if (std.mem.eql(u8, namespace, "http://www.w3.org/1998/Math/MathML")) {
            return .mathml;
        }
        return .unknown;
    }
};

_type: Type,
_proto: *Node,
_namespace: Namespace = .html,
_attributes: Attribute.List = .{},

pub const Type = union(enum) {
    html: *Html,
    svg: *Svg,
};

pub fn is(self: *Element, comptime T: type) ?*T {
    const type_name = @typeName(T);
    switch (self._type) {
        .html => |el| {
            if (T == Html) {
                return el;
            }
            if (comptime std.mem.startsWith(u8, type_name, "browser.webapi.element.html.")) {
                return el.is(T);
            }
        },
        .svg => |svg| {
            if (T == Svg) {
                return svg;
            }
            if (comptime std.mem.startsWith(u8, type_name, "browser.webapi.element.svg.")) {
                return svg.is(T);
            }
        },
    }
    return null;
}

pub fn as(self: *Element, comptime T: type) *T {
    return self.is(T).?;
}

pub fn asNode(self: *Element) *Node {
    return self._proto;
}

pub fn asEventTarget(self: *Element) *EventTarget {
    return self._proto.asEventTarget();
}

pub fn asConstNode(self: *const Element) *const Node {
    return self._proto;
}

/// TODO: localName and prefix comparison.
pub fn isEqualNode(self: *Element, other: *Element) bool {
    const self_tag = self.getTagNameDump();
    const other_tag = other.getTagNameDump();
    // Compare namespaces and tags.
    const dirty = self._namespace != other._namespace or !std.mem.eql(u8, self_tag, other_tag);
    if (dirty) {
        return false;
    }

    if (self._attributes.eql(&other._attributes) == false) {
        return false;
    }

    return self.asNode().isEqualChildren(other.asNode());
}

pub fn getTagNameLower(self: *const Element) []const u8 {
    switch (self._type) {
        .html => |he| switch (he._type) {
            .custom => |ce| {
                @branchHint(.unlikely);
                return ce._tag_name.str();
            },
            else => return switch (he._type) {
                .anchor => "a",
                .area => "area",
                .base => "base",
                .body => "body",
                .br => "br",
                .button => "button",
                .canvas => "canvas",
                .custom => |e| e._tag_name.str(),
                .data => "data",
                .datalist => "datalist",
                .details => "details",
                .dialog => "dialog",
                .directory => "dir",
                .div => "div",
                .dl => "dl",
                .embed => "embed",
                .fieldset => "fieldset",
                .font => "font",
                .frameset => "frameset",
                .form => "form",
                .generic => |e| e._tag_name.str(),
                .heading => |e| e._tag_name.str(),
                .head => "head",
                .html => "html",
                .hr => "hr",
                .iframe => "iframe",
                .img => "img",
                .input => "input",
                .label => "label",
                .legend => "legend",
                .li => "li",
                .link => "link",
                .map => "map",
                .marquee => "marquee",
                .media => |m| switch (m._type) {
                    .audio => "audio",
                    .video => "video",
                    .generic => "media",
                },
                .meta => "meta",
                .meter => "meter",
                .mod => |e| e._tag_name.str(),
                .object => "object",
                .ol => "ol",
                .optgroup => "optgroup",
                .option => "option",
                .output => "output",
                .p => "p",
                .picture => "picture",
                .param => "param",
                .pre => "pre",
                .progress => "progress",
                .quote => |e| e._tag_name.str(),
                .script => "script",
                .select => "select",
                .slot => "slot",
                .source => "source",
                .span => "span",
                .style => "style",
                .table => "table",
                .table_caption => "caption",
                .table_cell => |e| e._tag_name.str(),
                .table_col => |e| e._tag_name.str(),
                .table_row => "tr",
                .table_section => |e| e._tag_name.str(),
                .template => "template",
                .textarea => "textarea",
                .time => "time",
                .title => "title",
                .track => "track",
                .ul => "ul",
                .unknown => |e| e._tag_name.str(),
            },
        },
        .svg => |svg| return svg._tag_name.str(),
    }
}

pub fn getTagNameSpec(self: *const Element, buf: []u8) []const u8 {
    return switch (self._type) {
        .html => |he| switch (he._type) {
            .anchor => "A",
            .area => "AREA",
            .base => "BASE",
            .body => "BODY",
            .br => "BR",
            .button => "BUTTON",
            .canvas => "CANVAS",
            .custom => |e| upperTagName(&e._tag_name, buf),
            .data => "DATA",
            .datalist => "DATALIST",
            .details => "DETAILS",
            .dialog => "DIALOG",
            .directory => "DIR",
            .div => "DIV",
            .dl => "DL",
            .embed => "EMBED",
            .fieldset => "FIELDSET",
            .font => "FONT",
            .frameset => "FRAMESET",
            .form => "FORM",
            .generic => |e| upperTagName(&e._tag_name, buf),
            .heading => |e| upperTagName(&e._tag_name, buf),
            .head => "HEAD",
            .html => "HTML",
            .hr => "HR",
            .iframe => "IFRAME",
            .img => "IMG",
            .input => "INPUT",
            .label => "LABEL",
            .legend => "LEGEND",
            .li => "LI",
            .link => "LINK",
            .map => "MAP",
            .marquee => "MARQUEE",
            .meta => "META",
            .media => |m| switch (m._type) {
                .audio => "AUDIO",
                .video => "VIDEO",
                .generic => "MEDIA",
            },
            .meter => "METER",
            .mod => |e| upperTagName(&e._tag_name, buf),
            .object => "OBJECT",
            .ol => "OL",
            .optgroup => "OPTGROUP",
            .option => "OPTION",
            .output => "OUTPUT",
            .p => "P",
            .picture => "PICTURE",
            .param => "PARAM",
            .pre => "PRE",
            .progress => "PROGRESS",
            .quote => |e| upperTagName(&e._tag_name, buf),
            .script => "SCRIPT",
            .select => "SELECT",
            .slot => "SLOT",
            .source => "SOURCE",
            .span => "SPAN",
            .style => "STYLE",
            .table => "TABLE",
            .table_caption => "CAPTION",
            .table_cell => |e| upperTagName(&e._tag_name, buf),
            .table_col => |e| upperTagName(&e._tag_name, buf),
            .table_row => "TR",
            .table_section => |e| upperTagName(&e._tag_name, buf),
            .template => "TEMPLATE",
            .textarea => "TEXTAREA",
            .time => "TIME",
            .title => "TITLE",
            .track => "TRACK",
            .ul => "UL",
            .unknown => |e| switch (self._namespace) {
                .html => upperTagName(&e._tag_name, buf),
                .svg, .xml, .mathml, .unknown, .null => e._tag_name.str(),
            },
        },
        .svg => |svg| svg._tag_name.str(),
    };
}

pub fn getTagNameDump(self: *const Element) []const u8 {
    switch (self._type) {
        .html => return self.getTagNameLower(),
        .svg => |svg| return svg._tag_name.str(),
    }
}

pub fn getNamespaceURI(self: *const Element) ?[]const u8 {
    return self._namespace.toUri();
}

pub fn getNamespaceUri(self: *Element, frame: *Frame) ?[]const u8 {
    if (self._namespace != .unknown) return self._namespace.toUri();
    return frame._element_namespace_uris.get(self);
}

pub fn lookupNamespaceURIForElement(self: *Element, prefix: ?[]const u8, frame: *Frame) ?[]const u8 {
    // Hardcoded reserved prefixes
    if (prefix) |p| {
        if (std.mem.eql(u8, p, "xml")) return "http://www.w3.org/XML/1998/namespace";
        if (std.mem.eql(u8, p, "xmlns")) return "http://www.w3.org/2000/xmlns/";
    }

    // Step 1: check element's own namespace/prefix
    if (self.getNamespaceUri(frame)) |ns_uri| {
        const el_prefix = self._prefix();
        const match = if (prefix == null and el_prefix == null)
            true
        else if (prefix != null and el_prefix != null)
            std.mem.eql(u8, prefix.?, el_prefix.?)
        else
            false;
        if (match) return ns_uri;
    }

    // Step 2: search xmlns attributes
    for (self._attributes.entries()) |*entry| {
        if (prefix == null) {
            if (std.mem.eql(u8, entry.name(), "xmlns")) {
                const val = entry.value();
                return if (val.len == 0) null else val;
            }
        } else {
            const name = entry.name();
            if (std.mem.startsWith(u8, name, "xmlns:")) {
                if (std.mem.eql(u8, name["xmlns:".len..], prefix.?)) {
                    const val = entry.value();
                    return if (val.len == 0) null else val;
                }
            }
        }
    }

    // Step 3: recurse to parent element
    const parent = self.asNode().parentElement() orelse return null;
    return parent.lookupNamespaceURIForElement(prefix, frame);
}

// Locate a namespace prefix: the inverse of lookupNamespaceURIForElement.
// Given a namespace URI, find the prefix that declares it.
pub fn lookupPrefixForElement(self: *Element, namespace: []const u8, frame: *Frame) ?[]const u8 {
    // Step 1: element's own namespace/prefix
    if (self.getNamespaceUri(frame)) |ns_uri| {
        if (self._prefix()) |el_prefix| {
            if (std.mem.eql(u8, ns_uri, namespace)) {
                return el_prefix;
            }
        }
    }

    // Step 2: search xmlns: attribute declarations for one whose value is the namespace
    for (self._attributes.entries()) |*entry| {
        const name = entry.name();
        if (std.mem.startsWith(u8, name, "xmlns:") and std.mem.eql(u8, entry.value(), namespace)) {
            return name["xmlns:".len..];
        }
    }

    // Step 3: recurse to parent element
    const parent = self.asNode().parentElement() orelse return null;
    return parent.lookupPrefixForElement(namespace, frame);
}

fn _prefix(self: *const Element) ?[]const u8 {
    const name = self.getTagNameLower();
    if (std.mem.indexOfPos(u8, name, 0, ":")) |pos| {
        return name[0..pos];
    }
    return null;
}

pub fn getLocalName(self: *Element) []const u8 {
    const name = self.getTagNameLower();
    if (std.mem.indexOfPos(u8, name, 0, ":")) |pos| {
        return name[pos + 1 ..];
    }

    return name;
}

// Wrapper methods that delegate to Html implementations
pub fn getInnerText(self: *Element, writer: *std.Io.Writer, frame: *Frame) !void {
    const he = self.is(Html) orelse return error.NotHtmlElement;
    return he.getInnerText(writer, frame);
}

pub fn setInnerText(self: *Element, text: []const u8, frame: *Frame) !void {
    const he = self.is(Html) orelse return error.NotHtmlElement;
    return he.setInnerText(text, frame);
}

pub fn insertAdjacentHTML(
    self: *Element,
    position: []const u8,
    html_or_xml: []const u8,
    frame: *Frame,
) !void {
    const he = self.is(Html) orelse return error.NotHtmlElement;
    return he.insertAdjacentHTML(position, html_or_xml, frame);
}

pub fn getOuterHTML(self: *Element, writer: *std.Io.Writer, frame: *Frame) !void {
    const dump = @import("../dump.zig");
    return dump.deep(self.asNode(), .{ .shadow = .skip }, writer, frame);
}

pub fn setOuterHTML(self: *Element, html: []const u8, frame: *Frame) !void {
    const node = self.asNode();
    const parent = node._parent orelse return;

    frame.domChanged();
    if (html.len > 0) {
        const fragment = (try Node.DocumentFragment.init(frame)).asNode();
        try frame.parseHtmlAsChildren(fragment, html);
        try frame.insertAllChildrenBefore(fragment, parent, node);
    }

    _ = frame.removeNode(parent, node, .{ .will_be_reconnected = false });
}

pub fn getInnerHTML(self: *Element, writer: *std.Io.Writer, frame: *Frame) !void {
    const dump = @import("../dump.zig");
    return dump.children(self.asNode(), .{ .shadow = .skip }, writer, frame);
}

pub fn setInnerHTML(self: *Element, html: []const u8, frame: *Frame) !void {
    const parent = self.asNode();
    return parent.setHTML(html, false, frame);
}

/// allows declarative shadow dom
pub fn setHTMLUnsafe(self: *Element, html: []const u8, frame: *Frame) !void {
    const parent = self.asNode();
    return parent.setHTML(html, true, frame);
}

pub fn getId(self: *const Element) []const u8 {
    return self.getAttributeSafe(comptime .wrap("id")) orelse "";
}

pub fn setId(self: *Element, value: []const u8, frame: *Frame) !void {
    return self.setAttributeSafe(comptime .wrap("id"), .wrap(value), frame);
}

pub fn getSlot(self: *const Element) []const u8 {
    return self.getAttributeSafe(comptime .wrap("slot")) orelse "";
}

pub fn setSlot(self: *Element, value: []const u8, frame: *Frame) !void {
    return self.setAttributeSafe(comptime .wrap("slot"), .wrap(value), frame);
}

pub fn getDir(self: *const Element) []const u8 {
    return self.getAttributeSafe(comptime .wrap("dir")) orelse "";
}

pub fn setDir(self: *Element, value: []const u8, frame: *Frame) !void {
    return self.setAttributeSafe(comptime .wrap("dir"), .wrap(value), frame);
}

// ARIAMixin - ARIA attribute reflection
pub fn getAriaAtomic(self: *const Element) ?[]const u8 {
    return self.getAttributeSafe(comptime .wrap("aria-atomic"));
}

pub fn setAriaAtomic(self: *Element, value: ?[]const u8, frame: *Frame) !void {
    if (value) |v| {
        try self.setAttributeSafe(comptime .wrap("aria-atomic"), .wrap(v), frame);
    } else {
        try self.removeAttribute(comptime .wrap("aria-atomic"), frame);
    }
}

pub fn getAriaLive(self: *const Element) ?[]const u8 {
    return self.getAttributeSafe(comptime .wrap("aria-live"));
}

pub fn setAriaLive(self: *Element, value: ?[]const u8, frame: *Frame) !void {
    if (value) |v| {
        try self.setAttributeSafe(comptime .wrap("aria-live"), .wrap(v), frame);
    } else {
        try self.removeAttribute(comptime .wrap("aria-live"), frame);
    }
}

pub fn getClassName(self: *const Element) []const u8 {
    return self.getAttributeSafe(comptime .wrap("class")) orelse "";
}

pub fn setClassName(self: *Element, value: []const u8, frame: *Frame) !void {
    return self.setAttributeSafe(comptime .wrap("class"), .wrap(value), frame);
}

/// DANGER: Invalidated by mutation of the attribute list.
pub fn attributeEntries(self: *const Element) []const Attribute.List.Entry {
    return self._attributes.entries();
}

pub fn getAttribute(self: *const Element, name: String, frame: *Frame) !?String {
    return self._attributes.get(name, frame);
}

/// For simplicity, the namespace is currently ignored and only the local name is used.
pub fn getAttributeNS(
    self: *const Element,
    maybe_namespace: ?[]const u8,
    local_name: String,
    frame: *Frame,
) !?String {
    if (maybe_namespace) |namespace| {
        if (!std.mem.eql(u8, namespace, "http://www.w3.org/1999/xhtml")) {
            log.warn(.not_implemented, "Element.getAttributeNS", .{ .namespace = namespace });
        }
    }

    return self.getAttribute(local_name, frame);
}

pub fn getAttributeSafe(self: *const Element, name: String) ?[]const u8 {
    return self._attributes.getSafe(name);
}

pub fn hasAttribute(self: *const Element, name: String, frame: *Frame) !bool {
    const value = try self._attributes.get(name, frame);
    return value != null;
}

/// Like getAttributeNS, the namespace is currently ignored.
pub fn hasAttributeNS(
    self: *const Element,
    maybe_namespace: ?[]const u8,
    local_name: String,
    frame: *Frame,
) !bool {
    if (maybe_namespace) |namespace| {
        if (!std.mem.eql(u8, namespace, "http://www.w3.org/1999/xhtml")) {
            log.warn(.not_implemented, "Element.hasAttributeNS", .{ .namespace = namespace });
        }
    }

    return self.hasAttribute(local_name, frame);
}

pub fn hasAttributeSafe(self: *const Element, name: String) bool {
    return self._attributes.hasSafe(name);
}

// Per HTML "concept-fe-disabled", only listed elements participate in the
// disabled concept. Anything else (e.g. <div disabled>) has no disabled
// state and never matches :disabled / :enabled.
pub fn hasDisabledConcept(self: *const Element) bool {
    return switch (self.getTag()) {
        .button, .input, .select, .textarea, .optgroup, .option, .fieldset => true,
        else => false,
    };
}

pub fn isDisabled(self: *Element) bool {
    if (!self.hasDisabledConcept()) {
        return false;
    }

    if (self.getAttributeSafe(comptime .wrap("disabled")) != null) {
        return true;
    }

    // <option> takes a different inheritance path: per HTML
    // "concept-option-disabled" an option is disabled when its parent is an
    // <optgroup disabled>. It does NOT inherit from <select disabled> or
    // an ancestor <fieldset disabled>.
    if (self.getTag() == .option) {
        if (self.asNode()._parent) |parent_node| {
            if (parent_node.is(Element)) |parent_el| {
                if (parent_el.getTag() == .optgroup and
                    parent_el.getAttributeSafe(comptime .wrap("disabled")) != null)
                {
                    return true;
                }
            }
        }
        return false;
    }

    const element_node = self.asNode();
    var current: ?*Node = element_node._parent;
    while (current) |node| {
        current = node._parent;
        const ancestor = node.is(Element) orelse continue;

        if (ancestor.getTag() == .fieldset and ancestor.getAttributeSafe(comptime .wrap("disabled")) != null) {
            var child = ancestor.firstElementChild();
            while (child) |c| {
                if (c.getTag() == .legend) {
                    if (c.asNode().contains(element_node)) return false;
                    break;
                }
                child = c.nextElementSibling();
            }
            return true;
        }
    }
    return false;
}

pub fn hasAttributes(self: *const Element) bool {
    return self._attributes.isEmpty() == false;
}

pub fn getAttributeNode(self: *Element, name: String, frame: *Frame) !?*Attribute {
    return self._attributes.getAttribute(name, self, frame);
}

pub fn setAttribute(self: *Element, name: String, value: String, frame: *Frame) !void {
    try Attribute.validateAttributeName(name);
    _ = try self._attributes.put(name, value, self, frame);
}

pub fn setAttributeNS(
    self: *Element,
    maybe_namespace: ?[]const u8,
    qualified_name: []const u8,
    value: String,
    frame: *Frame,
) !void {
    const attr_name = if (maybe_namespace) |namespace| blk: {
        // For xmlns namespace, store the full qualified name (e.g. "xmlns:bar")
        // so lookupNamespaceURI can find namespace declarations.
        if (std.mem.eql(u8, namespace, "http://www.w3.org/2000/xmlns/")) {
            break :blk qualified_name;
        }
        if (!std.mem.eql(u8, namespace, "http://www.w3.org/1999/xhtml")) {
            log.warn(.not_implemented, "Element.setAttributeNS", .{ .namespace = namespace });
        }
        break :blk if (std.mem.indexOfScalarPos(u8, qualified_name, 0, ':')) |idx|
            qualified_name[idx + 1 ..]
        else
            qualified_name;
    } else blk: {
        break :blk if (std.mem.indexOfScalarPos(u8, qualified_name, 0, ':')) |idx|
            qualified_name[idx + 1 ..]
        else
            qualified_name;
    };
    return self.setAttribute(.wrap(attr_name), value, frame);
}

pub fn setAttributeSafe(self: *Element, name: String, value: String, frame: *Frame) !void {
    _ = try self._attributes.putSafe(name, value, self, frame);
}

pub fn getShadowRoot(self: *Element, frame: *Frame) ?*ShadowRoot {
    const shadow_root = frame._element_shadow_roots.get(self) orelse return null;
    if (shadow_root._mode == .closed) return null;
    return shadow_root;
}

pub fn getAssignedSlot(self: *Element, frame: *Frame) ?*Html.Slot {
    // Hidden by a closed shadow tree
    return slotting.findSlot(self.asNode(), true, frame);
}

// Whether this element may host a shadow root
fn isValidShadowHost(self: *const Element) bool {
    if (self._namespace != .html) {
        return false;
    }

    return switch (self.getTag()) {
        .article, .aside, .blockquote, .body, .div, .footer, .header, .main, .nav, .p, .section, .span, .h1, .h2, .h3, .h4, .h5, .h6, .custom => true,
        else => false,
    };
}

pub fn attachShadow(self: *Element, opts: ShadowRoot.AttachOptions, frame: *Frame) !*ShadowRoot {
    if (self.attachShadowFailureReason(opts, frame) != null) return error.NotSupported;

    if (frame._element_shadow_roots.get(self)) |existing| {
        // Imperative attachShadow over a declarative shadow root with a matching
        // mode empties it and returns the same root. The parser
        // (opts.declarative) never replaces an existing root.
        if (opts.declarative or !existing._declarative or existing._mode != opts.mode) {
            return error.NotSupported;
        }
        try existing.asNode().replaceChildren(&.{}, frame);
        existing._declarative = false;
        return existing;
    }

    const shadow_root = try ShadowRoot.init(self, opts, frame);
    try frame._element_shadow_roots.put(frame.arena, self, shadow_root);
    return shadow_root;
}

// Keep the DOM algorithm's distinct failure reasons available to the Web IDL
// wrapper. Internal parser/clone callers continue to receive error.NotSupported,
// while JavaScript gets Blink's exact NotSupportedError message.
fn attachShadowFailureReason(self: *Element, opts: ShadowRoot.AttachOptions, frame: *Frame) ?[]const u8 {
    if (!self.isValidShadowHost()) {
        return "This element does not support attachShadow";
    }

    // A custom element whose definition lists "shadow" in disabledFeatures
    // cannot host a shadow root (imperative or declarative).
    if (self.is(Html.Custom)) |custom| {
        if (frame.window._custom_elements._definitions.get(custom._tag_name.str())) |def| {
            if (def.disable_shadow) {
                return "attachShadow() is disabled by disabledFeatures static field.";
            }
        }
    }

    const existing = frame._element_shadow_roots.get(self) orelse return null;
    if (opts.declarative) {
        return "A second declarative shadow root cannot be created on a host.";
    }
    if (!existing._declarative) {
        return "Shadow root cannot be created on a host which already hosts a shadow tree.";
    }
    if (existing._mode != opts.mode) {
        return "The requested mode does not match the existing declarative shadow root's mode";
    }
    return null;
}

fn throwAttachShadowDictionaryTypeError(frame: *Frame, member: []const u8, reason: []const u8) anyerror {
    const detail = std.fmt.allocPrint(
        frame.call_arena,
        "Failed to read the '{s}' property from 'ShadowRootInit': {s}",
        .{ member, reason },
    ) catch return error.OutOfMemory;
    return throwAttachShadowTypeError(frame, detail, reason);
}

fn throwAttachShadowTypeError(frame: *Frame, detail: []const u8, stack_reason: []const u8) anyerror {
    const full_message = std.fmt.allocPrint(
        frame.call_arena,
        "Failed to execute 'attachShadow' on 'Element': {s}",
        .{detail},
    ) catch return error.OutOfMemory;

    const local = frame.js.local.?;
    const exception = local.isolate.createTypeError(stack_reason);

    // V8 retains the constructor-time reason for Error.stack. Replacing the
    // writable message property afterwards reproduces Blink's split between
    // the compact stack line and the contextual Web IDL Error.message.
    const key = local.isolate.initStringHandle("message");
    const value = local.isolate.initStringHandle(full_message);
    var maybe_result: js.v8.MaybeBool = undefined;
    js.v8.v8__Object__DefineOwnProperty(
        @ptrCast(exception),
        local.handle,
        @ptrCast(key),
        @ptrCast(value),
        js.v8.None,
        &maybe_result,
    );

    _ = local.isolate.throwException(exception);
    return error.TryCatchRethrow;
}

fn throwAttachShadowNotSupported(frame: *Frame, reason: []const u8) anyerror {
    const full_message = std.fmt.allocPrint(
        frame.call_arena,
        "Failed to execute 'attachShadow' on 'Element': {s}",
        .{reason},
    ) catch return error.OutOfMemory;

    const local = frame.js.local.?;
    const exception = local.zigValueToJs(DOMException.init(full_message, "NotSupportedError"), .{}) catch |err| return err;
    _ = js.v8.v8__Exception__CaptureStackTrace(local.handle, @ptrCast(exception.handle));
    _ = local.isolate.throwException(exception.handle);
    return error.TryCatchRethrow;
}

pub fn insertAdjacentElement(
    self: *Element,
    position: []const u8,
    element: *Element,
    frame: *Frame,
) !void {
    const target_node, const prev_node = try self.asNode().findAdjacentNodes(position);
    _ = try target_node.insertBefore(element.asNode(), prev_node, frame);
}

pub fn insertAdjacentText(
    self: *Element,
    where: []const u8,
    data: []const u8,
    frame: *Frame,
) !void {
    const text_node = try Frame.node_factory.createTextNode(frame, data);
    const target_node, const prev_node = try self.asNode().findAdjacentNodes(where);
    _ = try target_node.insertBefore(text_node, prev_node, frame);
}

pub fn setAttributeNode(self: *Element, attr: *Attribute, frame: *Frame) !?*Attribute {
    if (attr._element) |el| {
        if (el == self) {
            return attr;
        }
        attr._element = null;
        _ = try el.removeAttributeNode(attr, frame);
    }

    return self._attributes.putAttribute(attr, self, frame);
}

pub fn removeAttribute(self: *Element, name: String, frame: *Frame) !void {
    return self._attributes.delete(name, self, frame);
}

pub fn toggleAttribute(self: *Element, name: String, force: ?bool, frame: *Frame) !bool {
    try Attribute.validateAttributeName(name);
    const has = try self.hasAttribute(name, frame);

    const should_add = force orelse !has;

    if (should_add and !has) {
        try self.setAttribute(name, String.empty, frame);
        return true;
    } else if (!should_add and has) {
        try self.removeAttribute(name, frame);
        return false;
    }

    return should_add;
}

pub fn removeAttributeNode(self: *Element, attr: *Attribute, frame: *Frame) !*Attribute {
    if (attr._element == null or attr._element.? != self) {
        return error.NotFound;
    }
    try self.removeAttribute(attr._name, frame);
    attr._element = null;
    return attr;
}

pub fn getAttributeNames(self: *const Element, frame: *Frame) ![][]const u8 {
    return self._attributes.getNames(frame.local_arena);
}

pub fn getAttributeNamedNodeMap(self: *Element, frame: *Frame) !*Attribute.NamedNodeMap {
    const gop = try frame._attribute_named_node_map_lookup.getOrPut(frame.arena, @intFromPtr(self));
    if (!gop.found_existing) {
        gop.value_ptr.* = try frame._factory.create(Attribute.NamedNodeMap{ ._element = self });
    }
    return gop.value_ptr.*;
}

pub fn getOrCreateStyle(self: *Element, frame: *Frame) !*CSSStyleProperties {
    const gop = try frame._element_styles.getOrPut(frame.arena, self);
    if (!gop.found_existing) {
        gop.value_ptr.* = try CSSStyleProperties.init(self, false, frame);
    }
    return gop.value_ptr.*;
}

fn getStyle(self: *Element, frame: *Frame) ?*CSSStyleProperties {
    return frame._element_styles.get(self);
}

pub fn setStyle(self: *Element, value: []const u8, frame: *Frame) !void {
    const style = try self.getOrCreateStyle(frame);
    try style.asCSSStyleDeclaration().setCssTextFromParser(value, frame);
}

pub fn getClassList(self: *Element, frame: *Frame) !*collections.DOMTokenList {
    const gop = try frame._element_class_lists.getOrPut(frame.arena, self);
    if (!gop.found_existing) {
        gop.value_ptr.* = try frame._factory.create(collections.DOMTokenList{
            ._element = self,
            ._attribute_name = comptime .wrap("class"),
        });
    }
    return gop.value_ptr.*;
}

pub fn setClassList(self: *Element, value: String, frame: *Frame) !void {
    const class_list = try self.getClassList(frame);
    try class_list.setValue(value, frame);
}

pub fn getRelList(self: *Element, frame: *Frame) !*collections.DOMTokenList {
    const gop = try frame._element_rel_lists.getOrPut(frame.arena, self);
    if (!gop.found_existing) {
        gop.value_ptr.* = try frame._factory.create(collections.DOMTokenList{
            ._element = self,
            ._attribute_name = comptime .wrap("rel"),
        });
    }
    return gop.value_ptr.*;
}

pub fn getDataset(self: *Element, frame: *Frame) !*DOMStringMap {
    const gop = try frame._element_datasets.getOrPut(frame.arena, self);
    if (!gop.found_existing) {
        gop.value_ptr.* = try frame._factory.create(DOMStringMap{
            ._element = self,
        });
    }
    return gop.value_ptr.*;
}

pub fn replaceChildren(self: *Element, nodes: []const Node.NodeOrText, frame: *Frame) !void {
    return self.asNode().replaceChildren(nodes, frame);
}

pub fn replaceWith(self: *Element, nodes: []const Node.NodeOrText, frame: *Frame) !void {
    const ref_node = self.asNode();
    const parent = ref_node._parent orelse return;
    frame.domChanged();

    const parent_is_connected = parent.isConnected();

    // Detect if the ref_node must be removed (by default) or kept.
    // We kept it when ref_node is present into the nodes list.
    var rm_ref_node = true;

    for (nodes) |node_or_text| {
        const child = try node_or_text.toNode(frame);

        // If a child is the ref node. We keep it at its own current position.
        if (child == ref_node) {
            rm_ref_node = false;
            continue;
        }

        // A DocumentFragment contributes its children, not itself
        if (child.is(Node.DocumentFragment)) |_| {
            try frame.insertAllChildrenBefore(child, parent, ref_node);
            continue;
        }

        const child_connected = child.isConnected();
        {
            var load_guard = frame.beginReconnectLoadGuard(child._parent != null and child_connected and parent_is_connected);
            defer load_guard.deinit();
            if (child._parent) |current_parent| {
                if (frame.removeNode(current_parent, child, .{ .will_be_reconnected = parent_is_connected }) == .reentered) return;
            }

            try frame.insertNodeRelative(
                parent,
                child,
                .{ .before = ref_node },
                .{ .child_already_connected = child_connected },
            );
        }
    }

    // Re-check parent after insertNodeRelative since callbacks (e.g. connectedCallback)
    // could have already removed ref_node from parent.
    if (rm_ref_node and ref_node._parent == parent) {
        _ = frame.removeNode(parent, ref_node, .{ .will_be_reconnected = false });
    }
}

pub fn remove(self: *Element, frame: *Frame) void {
    const node = self.asNode();
    const parent = node._parent orelse return;
    frame.domChanged();
    _ = frame.removeNode(parent, node, .{ .will_be_reconnected = false });
}

pub fn focus(self: *Element, frame: *Frame) !void {
    return self.focusWithSourceCapabilities(null, frame);
}

/// Internal focus entry point for a platform input action. Script-facing
/// HTMLElement.focus() deliberately calls this with null; native mouse/pointer
/// focus passes the same per-realm InputDeviceCapabilities object carried by
/// the initiating compatibility event. Keyboard focus also keeps null.
pub fn focusWithSourceCapabilities(
    self: *Element,
    source_capabilities: ?*InputDeviceCapabilities,
    frame: *Frame,
) !void {
    if (self.asNode().isConnected() == false) {
        // a disconnected node cannot take focus
        return;
    }

    const FocusEvent = @import("event/FocusEvent.zig");

    const new_target = self.asEventTarget();
    const doc = self.asNode().ownerDocument(frame) orelse frame.document;
    const old_active = doc._active_element;
    doc._active_element = self;

    if (old_active) |old| {
        if (old == self) {
            return;
        }

        const old_target = old.asEventTarget();

        // Dispatch blur on old element (no bubble, composed)
        const blur_event = try FocusEvent.initTrusted(comptime .wrap("blur"), .{ .composed = true, .relatedTarget = new_target, .sourceCapabilities = source_capabilities }, frame);
        try frame._event_manager.dispatch(old_target, blur_event.asEvent());

        // Dispatch focusout on old element (bubbles, composed)
        const focusout_event = try FocusEvent.initTrusted(comptime .wrap("focusout"), .{ .bubbles = true, .composed = true, .relatedTarget = new_target, .sourceCapabilities = source_capabilities }, frame);
        try frame._event_manager.dispatch(old_target, focusout_event.asEvent());
    }

    const old_related: ?*EventTarget = if (old_active) |old| old.asEventTarget() else null;

    // Dispatch focus on new element (no bubble, composed)
    const focus_event = try FocusEvent.initTrusted(comptime .wrap("focus"), .{ .composed = true, .relatedTarget = old_related, .sourceCapabilities = source_capabilities }, frame);
    try frame._event_manager.dispatch(new_target, focus_event.asEvent());

    // Dispatch focusin on new element (bubbles, composed)
    const focusin_event = try FocusEvent.initTrusted(comptime .wrap("focusin"), .{ .bubbles = true, .composed = true, .relatedTarget = old_related, .sourceCapabilities = source_capabilities }, frame);
    try frame._event_manager.dispatch(new_target, focusin_event.asEvent());
}

pub fn blur(self: *Element, frame: *Frame) !void {
    const doc = self.asNode().ownerDocument(frame) orelse frame.document;
    if (doc._active_element != self) {
        // document.activeElement retargets a focused shadow descendant to its
        // outer host. Calling blur() on that returned host must still blur the
        // actual inner control and dispatch retargeted blur/focusout events.
        const focused = doc._active_element orelse return;
        var retargeted = focused;
        while (retargeted.asNode().getRootNode(.{}).is(@import("ShadowRoot.zig"))) |shadow| {
            retargeted = shadow._host;
        }
        if (retargeted != self) return;
        return focused.blur(frame);
    }

    doc._active_element = null;

    const FocusEvent = @import("event/FocusEvent.zig");
    const old_target = self.asEventTarget();

    // Dispatch blur (no bubble, composed)
    const blur_event = try FocusEvent.initTrusted(comptime .wrap("blur"), .{ .composed = true }, frame);
    try frame._event_manager.dispatch(old_target, blur_event.asEvent());

    // Dispatch focusout (bubbles, composed)
    const focusout_event = try FocusEvent.initTrusted(comptime .wrap("focusout"), .{ .bubbles = true, .composed = true }, frame);
    try frame._event_manager.dispatch(old_target, focusout_event.asEvent());
}

pub fn getChildren(self: *Element, frame: *Frame) !collections.NodeLive(.child_elements) {
    return collections.NodeLive(.child_elements).init(self.asNode(), {}, frame);
}

pub fn append(self: *Element, nodes: []const Node.NodeOrText, frame: *Frame) !void {
    const parent = self.asNode();
    for (nodes) |node_or_text| {
        const child = try node_or_text.toNode(frame);
        _ = try parent.appendChild(child, frame);
    }
}

pub fn prepend(self: *Element, nodes: []const Node.NodeOrText, frame: *Frame) !void {
    const parent = self.asNode();
    var i = nodes.len;
    while (i > 0) {
        i -= 1;
        const child = try nodes[i].toNode(frame);
        _ = try parent.insertBefore(child, parent.firstChild(), frame);
    }
}

pub fn moveBefore(self: *Element, node: js.Value, child: js.Value, frame: *Frame) !void {
    return self.asNode().moveBefore(node, child, frame);
}

pub fn before(self: *Element, nodes: []const Node.NodeOrText, frame: *Frame) !void {
    const node = self.asNode();
    const parent = node.parentNode() orelse return;

    for (nodes) |node_or_text| {
        const child = try node_or_text.toNode(frame);
        _ = try parent.insertBefore(child, node, frame);
    }
}

pub fn after(self: *Element, nodes: []const Node.NodeOrText, frame: *Frame) !void {
    const node = self.asNode();
    const parent = node.parentNode() orelse return;
    const viable_next = Node.NodeOrText.viableNextSibling(node, nodes);

    for (nodes) |node_or_text| {
        const child = try node_or_text.toNode(frame);
        _ = try parent.insertBefore(child, viable_next, frame);
    }
}

pub fn firstElementChild(self: *Element) ?*Element {
    var maybe_child = self.asNode().firstChild();
    while (maybe_child) |child| {
        if (child.is(Element)) |el| return el;
        maybe_child = child.nextSibling();
    }
    return null;
}

pub fn lastElementChild(self: *Element) ?*Element {
    var maybe_child = self.asNode().lastChild();
    while (maybe_child) |child| {
        if (child.is(Element)) |el| return el;
        maybe_child = child.previousSibling();
    }
    return null;
}

pub fn nextElementSibling(self: *Element) ?*Element {
    var maybe_sibling = self.asNode().nextSibling();
    while (maybe_sibling) |sibling| {
        if (sibling.is(Element)) |el| return el;
        maybe_sibling = sibling.nextSibling();
    }
    return null;
}

pub fn previousElementSibling(self: *Element) ?*Element {
    var maybe_sibling = self.asNode().previousSibling();
    while (maybe_sibling) |sibling| {
        if (sibling.is(Element)) |el| return el;
        maybe_sibling = sibling.previousSibling();
    }
    return null;
}

pub fn getChildElementCount(self: *Element) usize {
    var count: usize = 0;
    var it = self.asNode().childrenIterator();
    while (it.next()) |node| {
        if (node.is(Element) != null) {
            count += 1;
        }
    }
    return count;
}

pub fn matches(self: *Element, selector: []const u8, frame: *Frame) !bool {
    return Selector.matches(self, selector, frame) catch |err| Selector.mapErrorToDOM(err);
}

pub fn querySelector(self: *Element, selector: []const u8, frame: *Frame) !?*Element {
    return Selector.querySelector(self.asNode(), selector, frame) catch |err| Selector.mapErrorToDOM(err);
}

pub fn querySelectorAll(self: *Element, input: []const u8, frame: *Frame) !*Selector.List {
    return Selector.querySelectorAll(self.asNode(), input, frame) catch |err| Selector.mapErrorToDOM(err);
}

pub fn getAnimations(_: *const Element) []*Animation {
    return &.{};
}

pub fn animate(_: *Element, _: ?js.Object, _: ?js.Object, frame: *Frame) !*Animation {
    return Animation.init(frame);
}

pub fn closest(self: *Element, input: []const u8, frame: *Frame) !?*Element {
    if (input.len == 0) {
        return error.SyntaxError;
    }

    const selector = try Selector.cachedParse(frame._session.browser, input);

    var current: ?*Element = self;
    while (current) |el| {
        if (try Selector.matchesWithScope(el, selector, self, frame)) {
            return el;
        }

        const parent = el._proto._parent orelse break;

        if (parent.is(ShadowRoot) != null) {
            break;
        }

        current = parent.is(Element);
    }
    return null;
}

pub fn parentElement(self: *Element) ?*Element {
    return self._proto.parentElement();
}

/// Cache for visibility checks - re-exported from StyleManager for convenience.
pub const VisibilityCache = StyleManager.VisibilityCache;

/// Cache for pointer-events checks - re-exported from StyleManager for convenience.
pub const PointerEventsCache = StyleManager.PointerEventsCache;

pub fn hasPointerEventsNone(self: *Element, cache: ?*PointerEventsCache, frame: *Frame) bool {
    return frame._style_manager.hasPointerEventsNone(self, cache);
}

pub fn checkVisibilityCached(self: *Element, cache: ?*VisibilityCache, frame: *Frame) bool {
    if (!self.participatesInLayout(frame)) return false;
    return !frame._style_manager.isHidden(self, cache, .{});
}

const CheckVisibilityOpts = struct {
    checkOpacity: bool = false,
    opacityProperty: bool = false,
    checkVisibilityCSS: bool = false,
    visibilityProperty: bool = false,
};
pub fn checkVisibility(self: *Element, opts_: ?CheckVisibilityOpts, frame: *Frame) bool {
    if (!self.participatesInLayout(frame)) return false;
    // content-visibility:hidden skips the contents, not the principal box of
    // the element that establishes the skipped subtree. Chrome checks this
    // ancestor condition for every option combination, including the default.
    if (frame._style_manager.hasContentVisibilityHiddenAncestor(self)) return false;
    const opts = opts_ orelse CheckVisibilityOpts{};
    return !frame._style_manager.isHidden(self, null, .{
        .check_opacity = opts.checkOpacity or opts.opacityProperty,
        .check_visibility = opts.visibilityProperty or opts.checkVisibilityCSS,
    });
}

/// Whether this element has a layout tree in its own active document and in
/// every embedding document. CSS visibility and opacity do not remove layout;
/// display:none on an iframe owner (or one of its ancestors) does.
fn participatesInLayout(self: *Element, frame: *Frame) bool {
    if (!self.asNode().isConnected()) return false;

    var current = frame;
    while (current.parent) |parent| {
        const iframe = current.iframe orelse break;
        const owner = iframe.asElement();
        if (!owner.asNode().isConnected() or parent._style_manager.isHidden(owner, null, .{})) {
            return false;
        }
        current = parent;
    }
    return true;
}

pub fn getElementDimensions(self: *Element, frame: *Frame) struct { width: f64, height: f64 } {
    var width: f64 = 5.0;
    var height: f64 = 5.0;

    if (frame._style_manager.resolvedAuthoredPropertyValue(
        self,
        comptime .wrap("width"),
        false,
    )) |value| width = CSS.parseDimension(value) orelse width;
    if (frame._style_manager.resolvedAuthoredPropertyValue(
        self,
        comptime .wrap("height"),
        false,
    )) |value| height = CSS.parseDimension(value) orelse height;

    if (width == 5.0 or height == 5.0) {
        const tag = self.getTag();

        // Root containers get large default size to contain descendant positions.
        // With calculateDocumentPosition using linear depth scaling (100px per level),
        // even very deep trees (100 levels) stay within 10,000px.
        // 100M pixels is plausible for very long documents.
        if (tag == .html or tag == .body) {
            if (width == 5.0) width = 1920.0;
            if (height == 5.0) height = 100_000_000.0;
        } else if (tag == .iframe) {
            // HTML's default replaced-element dimensions for an iframe are
            // 300x150 CSS px. Reflected width/height attributes override each
            // axis independently when no authored CSS dimension wins.
            if (width == 5.0) width = 300.0;
            if (height == 5.0) height = 150.0;
            if (self.getAttributeSafe(comptime .wrap("width"))) |w| {
                width = std.fmt.parseFloat(f64, w) catch width;
            }
            if (self.getAttributeSafe(comptime .wrap("height"))) |h| {
                height = std.fmt.parseFloat(f64, h) catch height;
            }
        } else if (tag == .img) {
            if (self.getAttributeSafe(comptime .wrap("width"))) |w| {
                width = std.fmt.parseFloat(f64, w) catch width;
            }
            if (self.getAttributeSafe(comptime .wrap("height"))) |h| {
                height = std.fmt.parseFloat(f64, h) catch height;
            }
        }
    }

    return .{ .width = width, .height = height };
}

pub fn getClientWidth(self: *Element, frame: *Frame) f64 {
    if (!self.checkVisibilityCached(null, frame)) {
        return 0.0;
    }
    const dims = self.getElementDimensions(frame);
    return dims.width;
}

pub fn getClientHeight(self: *Element, frame: *Frame) f64 {
    if (!self.checkVisibilityCached(null, frame)) {
        return 0.0;
    }
    const dims = self.getElementDimensions(frame);
    return dims.height;
}

pub fn getBoundingClientRect(self: *Element, frame: *Frame) DOMRect {
    if (!self.checkVisibilityCached(null, frame)) {
        return .{
            ._x = 0.0,
            ._y = 0.0,
            ._width = 0.0,
            ._height = 0.0,
        };
    }

    return self.getBoundingClientRectForVisible(frame);
}

// Some cases need a the BoundingClientRect but have already done the
// visibility check.
pub fn getBoundingClientRectForVisible(self: *Element, frame: *Frame) DOMRect {
    var y = calculateDocumentPosition(self.asNode());
    const dims = self.getElementDimensions(frame);

    var x: f64 = 0;
    if (frame._style_manager.resolvedAuthoredPropertyValue(
        self,
        comptime .wrap("margin-left"),
        false,
    )) |margin_left| x = CSS.parseDimension(margin_left) orelse x;
    const position = self.positionStyle(frame);
    const fixed_or_absolute = std.mem.eql(u8, position, "fixed") or
        std.mem.eql(u8, position, "absolute");
    const relative = std.mem.eql(u8, position, "relative");
    if (fixed_or_absolute or relative) {
        if (frame._style_manager.resolvedAuthoredPropertyValue(
            self,
            comptime .wrap("left"),
            false,
        )) |left| {
            if (CSS.parseDimension(left)) |offset| {
                x += offset;
            }
        }
        if (frame._style_manager.resolvedAuthoredPropertyValue(
            self,
            comptime .wrap("top"),
            false,
        )) |top| {
            if (CSS.parseDimension(top)) |offset| {
                if (fixed_or_absolute) y = offset else y += offset;
            }
        }
    }

    var rect = DOMRect{
        ._x = x,
        ._y = y,
        ._width = dims.width,
        ._height = dims.height,
    };
    if (frame._style_manager.resolvedAuthoredPropertyValue(
        self,
        comptime .wrap("transform"),
        false,
    )) |transform| applyTransform(&rect, transform);
    quantizeLayoutRect(&rect);
    return rect;
}

pub fn getClientRects(self: *Element, frame: *Frame) ![]DOMRect {
    if (!self.checkVisibilityCached(null, frame)) {
        return &.{};
    }
    const rects = try frame.local_arena.alloc(DOMRect, 1);
    rects[0] = self.getBoundingClientRectForVisible(frame);
    return rects;
}

pub fn getScrollTop(self: *Element, frame: *Frame) u32 {
    const pos = frame._element_scroll_positions.get(self) orelse return 0;
    return pos.y;
}

pub fn setScrollTop(self: *Element, value: i32, frame: *Frame) !void {
    const gop = try frame._element_scroll_positions.getOrPut(frame.arena, self);
    if (!gop.found_existing) {
        gop.value_ptr.* = .{};
    }
    gop.value_ptr.y = @intCast(@max(0, value));
}

pub fn getScrollLeft(self: *Element, frame: *Frame) u32 {
    const pos = frame._element_scroll_positions.get(self) orelse return 0;
    return pos.x;
}

pub fn setScrollLeft(self: *Element, value: i32, frame: *Frame) !void {
    const gop = try frame._element_scroll_positions.getOrPut(frame.arena, self);
    if (!gop.found_existing) {
        gop.value_ptr.* = .{};
    }
    gop.value_ptr.x = @intCast(@max(0, value));
}

pub fn getScrollHeight(self: *Element, frame: *Frame) f64 {
    // In our dummy layout engine, content doesn't overflow
    return self.getClientHeight(frame);
}

pub fn getScrollWidth(self: *Element, frame: *Frame) f64 {
    // In our dummy layout engine, content doesn't overflow
    return self.getClientWidth(frame);
}

pub fn getOffsetHeight(self: *Element, frame: *Frame) f64 {
    if (!self.checkVisibilityCached(null, frame)) {
        return 0.0;
    }
    const dims = self.getElementDimensions(frame);
    return dims.height;
}

pub fn getOffsetWidth(self: *Element, frame: *Frame) f64 {
    if (!self.checkVisibilityCached(null, frame)) {
        return 0.0;
    }
    const dims = self.getElementDimensions(frame);
    return dims.width;
}

pub fn getOffsetTop(self: *Element, frame: *Frame) f64 {
    if (!self.checkVisibilityCached(null, frame)) {
        return 0.0;
    }
    return calculateDocumentPosition(self.asNode());
}

pub fn getOffsetLeft(self: *Element, frame: *Frame) f64 {
    if (!self.checkVisibilityCached(null, frame)) {
        return 0.0;
    }
    var x: f64 = 0;
    if (frame._style_manager.resolvedAuthoredPropertyValue(
        self,
        comptime .wrap("margin-left"),
        false,
    )) |margin_left| x = CSS.parseDimension(margin_left) orelse x;
    if (frame._style_manager.resolvedAuthoredPropertyValue(
        self,
        comptime .wrap("left"),
        false,
    )) |left| {
        if (!std.mem.eql(u8, self.positionStyle(frame), "static")) {
            x += CSS.parseDimension(left) orelse 0;
        }
    }
    return x;
}

pub fn getOffsetParent(self: *Element, frame: *Frame) ?*Element {
    if (!self.asNode().isConnected() or !self.checkVisibilityCached(null, frame)) {
        return null;
    }

    switch (self.getTag()) {
        .html, .body => return null,
        else => {},
    }

    const self_position = self.positionStyle(frame);
    if (std.mem.eql(u8, self_position, "fixed")) {
        return null;
    }
    const self_static = self_position.len == 0 or std.mem.eql(u8, self_position, "static");

    var node: ?*Node = self.asNode()._parent;
    while (node) |n| {
        if (n.is(ShadowRoot)) |sr| {
            // this always pokes through the shadow dom
            node = sr.getHost().asNode();
            continue;
        }
        const ancestor = n.is(Element) orelse break;

        const tag = ancestor.getTag();
        if (tag == .body) {
            return ancestor;
        }
        const position = ancestor.positionStyle(frame);
        if (position.len > 0 and !std.mem.eql(u8, position, "static")) {
            return ancestor;
        }
        if (self_static and (tag == .td or tag == .th or tag == .table)) {
            return ancestor;
        }
        node = n._parent;
    }
    return null;
}

fn positionStyle(self: *Element, frame: *Frame) []const u8 {
    return frame._style_manager.resolvedAuthoredPropertyValue(
        self,
        comptime .wrap("position"),
        false,
    ) orelse "static";
}

pub fn getClientTop(self: *Element, frame: *Frame) f64 {
    return self.clientBorderWidth(frame, .top);
}

pub fn getClientLeft(self: *Element, frame: *Frame) f64 {
    return self.clientBorderWidth(frame, .left);
}

const ClientBorderSide = enum { top, left };

fn clientBorderWidth(self: *Element, frame: *Frame, side: ClientBorderSide) f64 {
    const style = self.getStyle(frame) orelse return 0;
    const declaration = style.asCSSStyleDeclaration();
    if (!clientBorderIsPainted(declaration, frame, side)) return 0;
    const side_width_name = if (side == .top) "border-top-width" else "border-left-width";
    if (parseBorderWidth(declaration.getPropertyValue(side_width_name, frame))) |width| return width;

    if (borderWidthList(declaration.getPropertyValue("border-width", frame), side)) |width| return width;

    const side_name = if (side == .top) "border-top" else "border-left";
    if (borderShorthandWidth(declaration.getPropertyValue(side_name, frame))) |width| return width;
    return borderShorthandWidth(declaration.getPropertyValue("border", frame)) orelse 0;
}

fn clientBorderIsPainted(declaration: anytype, frame: *Frame, side: ClientBorderSide) bool {
    const side_style_name = if (side == .top) "border-top-style" else "border-left-style";
    if (parseBorderPaint(declaration.getPropertyValue(side_style_name, frame))) |painted| return painted;
    if (borderStyleList(declaration.getPropertyValue("border-style", frame), side)) |painted| return painted;

    const side_name = if (side == .top) "border-top" else "border-left";
    if (borderShorthandPaint(declaration.getPropertyValue(side_name, frame))) |painted| return painted;
    return borderShorthandPaint(declaration.getPropertyValue("border", frame)) orelse false;
}

fn parseBorderPaint(value: []const u8) ?bool {
    if (std.mem.eql(u8, value, "none") or std.mem.eql(u8, value, "hidden")) return false;
    const painted = [_][]const u8{
        "dotted", "dashed", "solid", "double", "groove", "ridge", "inset", "outset",
    };
    for (painted) |candidate| {
        if (std.mem.eql(u8, value, candidate)) return true;
    }
    return null;
}

fn borderStyleList(value: []const u8, side: ClientBorderSide) ?bool {
    var styles: [4]bool = undefined;
    var len: usize = 0;
    var tokens = std.mem.tokenizeAny(u8, value, " \t\r\n");
    while (tokens.next()) |token| {
        if (len == styles.len) return null;
        styles[len] = parseBorderPaint(token) orelse return null;
        len += 1;
    }
    if (len == 0) return null;
    if (side == .top) return styles[0];
    return switch (len) {
        1 => styles[0],
        2, 3 => styles[1],
        4 => styles[3],
        else => unreachable,
    };
}

fn borderShorthandPaint(value: []const u8) ?bool {
    var tokens = std.mem.tokenizeAny(u8, value, " \t\r\n");
    while (tokens.next()) |token| {
        if (parseBorderPaint(token)) |painted| return painted;
    }
    return null;
}

fn parseBorderWidth(value: []const u8) ?f64 {
    if (std.mem.eql(u8, value, "thin")) return 1;
    if (std.mem.eql(u8, value, "medium")) return 3;
    if (std.mem.eql(u8, value, "thick")) return 5;
    const width = CSS.parseDimension(value) orelse return null;
    if (!std.math.isFinite(width)) return null;
    return @max(width, 0);
}

fn borderWidthList(value: []const u8, side: ClientBorderSide) ?f64 {
    var widths: [4]f64 = undefined;
    var len: usize = 0;
    var tokens = std.mem.tokenizeAny(u8, value, " \t\r\n");
    while (tokens.next()) |token| {
        if (len == widths.len) return null;
        widths[len] = parseBorderWidth(token) orelse return null;
        len += 1;
    }
    if (len == 0) return null;
    if (side == .top) return widths[0];
    return switch (len) {
        1 => widths[0],
        2, 3 => widths[1],
        4 => widths[3],
        else => unreachable,
    };
}

fn borderShorthandWidth(value: []const u8) ?f64 {
    if (value.len == 0) return null;
    var tokens = std.mem.tokenizeAny(u8, value, " \t\r\n");
    var width: ?f64 = null;
    while (tokens.next()) |token| {
        if (std.mem.eql(u8, token, "none") or std.mem.eql(u8, token, "hidden")) return 0;
        if (width == null) width = parseBorderWidth(token);
    }
    return width;
}

// Calculates document position by counting all nodes that appear before this one
// in tree order, but only traversing the "left side" of the tree.
//
// This walks up from the target node to the root, and at each level counts:
// 1. All previous siblings and their descendants
// 2. The parent itself
//
// Example:
//   <body>              → y=0
//     <h1>Text</h1>     → y=1    (body=1)
//     <h2>              → y=2    (body=1 + h1=1)
//       <a>Link1</a>    → y=3    (body=1 + h1=1 + h2=1)
//     </h2>
//     <p>Text</p>       → y=5    (body=1 + h1=1 + h2=2)
//     <h2>              → y=6    (body=1 + h1=1 + h2=2 + p=1)
//       <a>Link2</a>    → y=7    (body=1 + h1=1 + h2=2 + p=1 + h2=1)
//     </h2>
//   </body>
//
// Trade-offs:
// - O(depth × siblings × subtree_height) - only left-side traversal
// - Linear scaling: 5px per node
// - Perfect document order, guaranteed unique positions
// - Compact coordinates (1000 nodes ≈ 5,000px)
fn calculateDocumentPosition(node: *Node) f64 {
    var position: f64 = 0.0;
    var current = node;

    // Walk up to root, counting preceding nodes
    while (current.parentNode()) |parent| {
        // Count all previous siblings and their descendants
        var sibling = parent.firstChild();
        while (sibling) |s| {
            if (s == current) break;
            position += countSubtreeNodes(s);
            sibling = s.nextSibling();
        }

        // Count the parent itself
        position += 1.0;
        current = parent;
    }

    return position * 5.0; // 5px per node
}

// Counts total nodes in a subtree (node + all descendants)
fn countSubtreeNodes(node: *Node) f64 {
    var count: f64 = 1.0; // Count this node

    var child = node.firstChild();
    while (child) |c| {
        count += countSubtreeNodes(c);
        child = c.nextSibling();
    }

    return count;
}

fn applyTransform(rect: *DOMRect, value: []const u8) void {
    var matrix = DOMMatrixReadOnly.identity();
    var is_2d = true;
    DOMMatrixReadOnly.parseTransformList(value, &matrix, &is_2d) catch return;

    const origin_x = rect._width / 2;
    const origin_y = rect._height / 2;
    const corners = [4][2]f64{
        .{ 0, 0 },
        .{ rect._width, 0 },
        .{ 0, rect._height },
        .{ rect._width, rect._height },
    };
    var min_x = std.math.inf(f64);
    var min_y = std.math.inf(f64);
    var max_x = -std.math.inf(f64);
    var max_y = -std.math.inf(f64);
    for (corners) |corner| {
        const local_x = corner[0] - origin_x;
        const local_y = corner[1] - origin_y;
        const w = matrix[3] * local_x + matrix[7] * local_y + matrix[15];
        if (w == 0) return;
        const x = rect._x + origin_x +
            (matrix[0] * local_x + matrix[4] * local_y + matrix[12]) / w;
        const y = rect._y + origin_y +
            (matrix[1] * local_x + matrix[5] * local_y + matrix[13]) / w;
        min_x = @min(min_x, x);
        min_y = @min(min_y, y);
        max_x = @max(max_x, x);
        max_y = @max(max_y, y);
    }
    rect.* = .{
        ._x = min_x,
        ._y = min_y,
        ._width = max_x - min_x,
        ._height = max_y - min_y,
    };
}

fn quantizeLayoutRect(rect: *DOMRect) void {
    rect._x = blinkLayoutFloat(rect._x);
    rect._y = blinkLayoutFloat(rect._y);
    rect._width = blinkLayoutFloat(rect._width);
    rect._height = blinkLayoutFloat(rect._height);
}

fn blinkLayoutFloat(value: f64) f64 {
    const value32: f32 = @floatCast(value);
    return @floatCast(value32);
}

pub fn getElementsByTagName(self: *Element, tag_name: []const u8, frame: *Frame) !Node.GetElementsByTagNameResult {
    return self.asNode().getElementsByTagName(tag_name, frame);
}

pub fn getElementsByTagNameNS(self: *Element, namespace: ?[]const u8, local_name: []const u8, frame: *Frame) !collections.NodeLive(.tag_name_ns) {
    return self.asNode().getElementsByTagNameNS(namespace, local_name, frame);
}

pub fn getElementsByClassName(self: *Element, class_name: []const u8, frame: *Frame) !collections.NodeLive(.class_name) {
    return self.asNode().getElementsByClassName(class_name, frame);
}

pub fn clone(self: *Element, deep: bool, frame: *Frame) !*Node {
    const tag_name = self.getTagNameDump();
    const node = try Frame.node_factory.createElementNS(frame, self._namespace, tag_name, &self._attributes);

    // Allow element-specific types to copy their runtime state
    _ = Element.Build.call(node.as(Element), "cloned", .{ self, node.as(Element), deep, frame }) catch |err| {
        log.err(.dom, "element.clone.failed", .{ .err = err });
    };

    // Per spec, a clonable shadow root is cloned along with its host — its
    // children always deep-cloned, even when the host clone is shallow.
    if (frame._element_shadow_roots.get(self)) |shadow| {
        if (shadow._clonable) {
            const cloned_shadow = node.as(Element).attachShadow(.{
                .mode = shadow._mode,
                .clonable = true,
                .delegates_focus = shadow._delegates_focus,
                .slot_assignment = shadow._slot_assignment,
                .serializable = shadow._serializable,
                .declarative = shadow._declarative,
            }, frame) catch return error.CloneError;

            const cloned_shadow_node = cloned_shadow.asNode();
            var shadow_child_it = shadow.asNode().childrenIterator();
            while (shadow_child_it.next()) |child| {
                if (try child.cloneNodeForAppending(true, frame)) |cloned_child| {
                    try frame.appendNode(cloned_shadow_node, cloned_child, .{ .child_already_connected = true });
                }
            }
        }
    }

    if (deep) {
        var child_it = self.asNode().childrenIterator();
        while (child_it.next()) |child| {
            if (try child.cloneNodeForAppending(true, frame)) |cloned_child| {
                // We pass `true` to `child_already_connected` as a hacky optimization
                // We _know_ this child isn't connected (Because the parent isn't connected)
                // setting this to `true` skips all connection checks.
                try frame.appendNode(node, cloned_child, .{ .child_already_connected = true });
            }
        }
    }

    return node;
}

pub fn scrollIntoViewIfNeeded(self: *Element, center_if_needed: ?bool, frame: *Frame) void {
    _ = center_if_needed;
    const y = calculateDocumentPosition(self.asNode());
    const scroll_y: f64 = @floatFromInt(frame.window.getScrollY());
    const viewport_height: f64 = @floatFromInt(frame.window.getInnerHeight(frame));
    if (y >= scroll_y and y <= scroll_y + viewport_height) {
        return;
    }
    self.scrollIntoView(null, frame);
}

const ScrollIntoViewOpts = union {
    align_to_top: bool,
    obj: js.Object,
};
pub fn scrollIntoView(self: *Element, opts: ?ScrollIntoViewOpts, frame: *Frame) void {
    _ = opts;
    // Scroll the window so the element's top is brought into the viewport.
    // Positions come from the faux-layout document position (top = preorder
    // depth-scaled y), the same source getBoundingClientRect uses.
    const y = calculateDocumentPosition(self.asNode());
    frame.window.scrollTo(.{ .x = 0 }, @intFromFloat(@max(0, y)), frame) catch {};
}

const ScrollToOpts = union(enum) {
    x: i32,
    opts: Opts,

    const Opts = struct {
        top: ?i32 = null,
        left: ?i32 = null,
        behavior: []const u8 = "",
    };
};

pub fn scrollTo(self: *Element, opts: ?ScrollToOpts, y: ?i32, frame: *Frame) !void {
    const o = opts orelse return;
    const gop = try frame._element_scroll_positions.getOrPut(frame.arena, self);
    if (!gop.found_existing) {
        gop.value_ptr.* = .{};
    }
    switch (o) {
        .x => |x| {
            gop.value_ptr.x = @intCast(@max(0, x));
            gop.value_ptr.y = @intCast(@max(0, y orelse 0));
        },
        .opts => |dict| {
            if (dict.left) |left| gop.value_ptr.x = @intCast(@max(0, left));
            if (dict.top) |top| gop.value_ptr.y = @intCast(@max(0, top));
        },
    }
}

// scrollBy(): like scrollTo() but relative to the current position.
pub fn scrollBy(self: *Element, opts: ?ScrollToOpts, y: ?i32, frame: *Frame) !void {
    const o = opts orelse return;
    const gop = try frame._element_scroll_positions.getOrPut(frame.arena, self);
    if (!gop.found_existing) {
        gop.value_ptr.* = .{};
    }
    const dx: i32, const dy: i32 = switch (o) {
        .x => |x| .{ x, y orelse 0 },
        .opts => |dict| .{ dict.left orelse 0, dict.top orelse 0 },
    };
    gop.value_ptr.x = @intCast(@max(0, @as(i32, @intCast(gop.value_ptr.x)) + dx));
    gop.value_ptr.y = @intCast(@max(0, @as(i32, @intCast(gop.value_ptr.y)) + dy));
}

pub fn format(self: *Element, writer: *std.Io.Writer) !void {
    try writer.writeByte('<');
    try writer.writeAll(self.getTagNameDump());

    for (self._attributes.entries()) |*attr| {
        try writer.print(" {f}", .{attr});
    }
    try writer.writeByte('>');
}

fn upperTagName(tag_name: *String, buf: []u8) []const u8 {
    if (tag_name.len > buf.len) {
        log.info(.dom, "tag.long.name", .{ .name = tag_name.str() });
        return tag_name.str();
    }
    const tag = tag_name.str();
    return std.ascii.upperString(buf, tag);
}

pub fn getTag(self: *const Element) Tag {
    return switch (self._type) {
        .html => |he| switch (he._type) {
            .anchor => .anchor,
            .area => .area,
            .base => .base,
            .div => .div,
            .dl => .dl,
            .embed => .embed,
            .form => .form,
            .p => .p,
            .custom => .custom,
            .data => .data,
            .datalist => .datalist,
            .details => .details,
            .dialog => .dialog,
            .directory => .directory,
            .iframe => .iframe,
            .img => .img,
            .br => .br,
            .button => .button,
            .canvas => .canvas,
            .fieldset => .fieldset,
            .font => .font,
            .frameset => .frameset,
            .heading => |h| h._tag,
            .label => .label,
            .legend => .legend,
            .li => .li,
            .map => .map,
            .marquee => .marquee,
            .ul => .ul,
            .ol => .ol,
            .object => .object,
            .optgroup => .optgroup,
            .output => .output,
            .picture => .picture,
            .param => .param,
            .pre => .pre,
            .generic => |g| g._tag,
            .media => |m| switch (m._type) {
                .audio => .audio,
                .video => .video,
                .generic => .media,
            },
            .meter => .meter,
            .mod => |m| m._tag,
            .progress => .progress,
            .quote => |q| q._tag,
            .script => .script,
            .select => .select,
            .slot => .slot,
            .source => .source,
            .span => .span,
            .option => .option,
            .table => .table,
            .table_caption => .caption,
            .table_cell => |tc| tc._tag,
            .table_col => |tc| tc._tag,
            .table_row => .tr,
            .table_section => |ts| ts._tag,
            .template => .template,
            .textarea => .textarea,
            .time => .time,
            .track => .track,
            .input => .input,
            .link => .link,
            .meta => .meta,
            .hr => .hr,
            .style => .style,
            .title => .title,
            .body => .body,
            .html => .html,
            .head => .head,
            .unknown => .unknown,
        },
        .svg => |se| se.getTag(),
    };
}

pub fn ownerFrame(self: *const Element, default: *Frame) *Frame {
    return self._proto.ownerFrame(default);
}

pub const Tag = enum {
    address,
    anchor,
    audio,
    area,
    aside,
    article,
    b,
    blockquote,
    body,
    br,
    button,
    base,
    canvas,
    caption,
    circle,
    code,
    col,
    colgroup,
    custom,
    data,
    datalist,
    dd,
    details,
    del,
    dfn,
    dialog,
    div,
    directory,
    dl,
    dt,
    embed,
    ellipse,
    em,
    fieldset,
    figure,
    frameset,
    form,
    font,
    footer,
    g,
    h1,
    h2,
    h3,
    h4,
    h5,
    h6,
    head,
    header,
    heading,
    hgroup,
    hr,
    html,
    i,
    iframe,
    img,
    input,
    ins,
    label,
    legend,
    li,
    line,
    link,
    main,
    map,
    marquee,
    media,
    menu,
    meta,
    meter,
    nav,
    noscript,
    object,
    ol,
    optgroup,
    option,
    output,
    p,
    path,
    param,
    picture,
    polygon,
    polyline,
    pre,
    progress,
    quote,
    rect,
    s,
    script,
    section,
    select,
    slot,
    source,
    span,
    strong,
    style,
    sub,
    summary,
    sup,
    svg,
    table,
    time,
    tbody,
    td,
    text,
    template,
    textarea,
    tfoot,
    th,
    thead,
    title,
    tr,
    track,
    ul,
    video,
    unknown,

    // If the tag is "unknown", we can't use the optimized tag matching, but
    // need to fallback to the actual tag name
    pub fn parseForMatch(lower: []const u8) ?Tag {
        const tag = std.meta.stringToEnum(Tag, lower) orelse return null;
        return switch (tag) {
            .unknown, .custom => null,
            else => tag,
        };
    }

    pub fn isBlock(self: Tag) bool {
        // zig fmt: off
        return switch (self) {
            // Semantic Layout
            .article, .aside, .footer, .header, .main, .nav, .section,
            // Grouping / Containers
            .address, .div, .fieldset, .figure, .p,
            // Headings
            .h1, .h2, .h3, .h4, .h5, .h6,
            // Lists
            .dl, .ol, .ul,
            // Preformatted / Quotes
            .blockquote, .pre,
            // Tables
            .table,
            // Other
            .hr,
            => true,
            else => false,
        };
        // zig fmt: on
    }

    pub fn isMetadata(self: Tag) bool {
        return switch (self) {
            .base, .head, .link, .meta, .noscript, .script, .style, .template, .title => true,
            else => false,
        };
    }

    // UA stylesheet display:none defaults per HTML Rendering §15.3.1
    // "Hidden elements" (https://html.spec.whatwg.org/multipage/rendering.html#hidden-elements).
    // The spec also lists basefont, noembed, noframes, rp; those tags are
    // obsolete and not represented in this enum, so they fall through to
    // `.unknown`/`.custom` and aren't matched here.
    pub fn isHiddenByUaStylesheet(self: Tag) bool {
        return switch (self) {
            .area,
            .base,
            .datalist,
            .head,
            .link,
            .meta,
            .noscript,
            .param,
            .script,
            .source,
            .style,
            .template,
            .title,
            .track,
            => true,
            else => false,
        };
    }
};

pub const JsApi = struct {
    pub const bridge = js.Bridge(Element);

    pub const Meta = struct {
        pub const name = "Element";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const tagName = bridge.accessor(_tagName, null, .{});
    fn _tagName(self: *Element, frame: *Frame) []const u8 {
        return self.getTagNameSpec(&frame.buf);
    }
    pub const namespaceURI = bridge.accessor(Element.getNamespaceURI, null, .{});

    pub const innerText = bridge.accessor(_innerText, Element.setInnerText, .{ .ce_reactions = true });
    fn _innerText(self: *Element, frame: *Frame) ![]const u8 {
        var buf = std.Io.Writer.Allocating.init(frame.local_arena);
        try self.getInnerText(&buf.writer, frame);
        return buf.written();
    }

    pub const outerHTML = bridge.accessor(_getOuterHTML, _setOuterHTML, .{ .ce_reactions = true });
    fn _getOuterHTML(self: *Element, frame: *Frame) ![]const u8 {
        // local_arena: serialization is read-only and the returned string is
        // converted to v8 before this call returns. No JS runs in between.
        var buf = std.Io.Writer.Allocating.init(frame.local_arena);
        try self.getOuterHTML(&buf.writer, frame);
        return buf.written();
    }
    fn _setOuterHTML(self: *Element, value: js.Value, frame: *Frame) !void {
        const owner_frame = self.asNode().ownerFrame(frame);
        const compliant = try TrustedTypes.getCompliantString(
            value,
            owner_frame.js,
            owner_frame.window.getTrustedTypes(),
            .html,
            "Element",
            "outerHTML",
            .{ .attribute_set = .{ .interface = "Element", .name = "outerHTML" } },
            .legacy_null_to_empty,
            &frame.js.execution,
        );
        return self.setOuterHTML(try compliant.toSlice(), owner_frame);
    }

    pub const innerHTML = bridge.accessor(_getInnerHTML, _setInnerHTML, .{ .ce_reactions = true });
    fn _getInnerHTML(self: *Element, frame: *Frame) ![]const u8 {
        // local_arena: read-only serialization, result converted to v8 before
        // returning; no JS runs in between.
        var buf = std.Io.Writer.Allocating.init(frame.local_arena);
        try self.getInnerHTML(&buf.writer, frame);
        return buf.written();
    }
    fn _setInnerHTML(self: *Element, value: js.Value, frame: *Frame) !void {
        const owner_frame = self.asNode().ownerFrame(frame);
        const compliant = try TrustedTypes.getCompliantString(
            value,
            owner_frame.js,
            owner_frame.window.getTrustedTypes(),
            .html,
            "Element",
            "innerHTML",
            .{ .attribute_set = .{ .interface = "Element", .name = "innerHTML" } },
            .legacy_null_to_empty,
            &frame.js.execution,
        );
        return self.setInnerHTML(try compliant.toSlice(), owner_frame);
    }

    pub const prefix = bridge.accessor(Element._prefix, null, .{});

    pub const setAttribute = bridge.function(_setAttribute, .{ .ce_reactions = true });
    fn _setAttribute(self: *Element, name: String, value: js.Value, frame: *Frame) !void {
        try Attribute.validateAttributeName(name);
        const context: js.WebIDL.ConversionContext = .{
            .operation = .{ .interface = "Element", .name = "setAttribute" },
        };
        const owner_frame = self.asNode().ownerFrame(frame);
        const converted = if (TrustedTypes.attributeSink(
            self.getTagNameLower(),
            name.str(),
            self._namespace.toUri(),
            null,
        )) |sink|
            try TrustedTypes.getCompliantString(
                value,
                owner_frame.js,
                owner_frame.window.getTrustedTypes(),
                sink.required,
                sink.interface,
                sink.member,
                context,
                if (sink.required == .script_url) .usv_string else .dom_string,
                &frame.js.execution,
            )
        else
            try js.WebIDL.toDOMStringValueWithContext(value, &frame.js.execution, context);
        // The default policy may run author code and adopt the element into a
        // different same-origin document. Resolve its owner again at commit.
        return self.setAttribute(
            name,
            .wrap(try converted.toSlice()),
            self.asNode().ownerFrame(frame),
        );
    }

    pub const setAttributeNS = bridge.function(_setAttributeNS, .{ .ce_reactions = true });
    fn _setAttributeNS(self: *Element, maybe_ns: ?[]const u8, qn: []const u8, value: js.Value, frame: *Frame) !void {
        const local_name = if (std.mem.indexOfScalarPos(u8, qn, 0, ':')) |index|
            qn[index + 1 ..]
        else
            qn;
        try Attribute.validateAttributeName(.wrap(local_name));
        const context: js.WebIDL.ConversionContext = .{
            .operation = .{ .interface = "Element", .name = "setAttributeNS" },
        };
        const owner_frame = self.asNode().ownerFrame(frame);
        const converted = if (TrustedTypes.attributeSink(
            self.getTagNameLower(),
            local_name,
            self._namespace.toUri(),
            maybe_ns,
        )) |sink|
            try TrustedTypes.getCompliantString(
                value,
                owner_frame.js,
                owner_frame.window.getTrustedTypes(),
                sink.required,
                sink.interface,
                sink.member,
                context,
                if (sink.required == .script_url) .usv_string else .dom_string,
                &frame.js.execution,
            )
        else
            try js.WebIDL.toDOMStringValueWithContext(value, &frame.js.execution, context);
        return self.setAttributeNS(
            maybe_ns,
            qn,
            .wrap(try converted.toSlice()),
            self.asNode().ownerFrame(frame),
        );
    }

    pub const localName = bridge.accessor(Element.getLocalName, null, .{});
    pub const id = bridge.accessor(Element.getId, Element.setId, .{ .ce_reactions = true });
    pub const slot = bridge.accessor(Element.getSlot, Element.setSlot, .{ .ce_reactions = true });
    pub const ariaAtomic = bridge.accessor(Element.getAriaAtomic, Element.setAriaAtomic, .{ .ce_reactions = true });
    pub const ariaLive = bridge.accessor(Element.getAriaLive, Element.setAriaLive, .{ .ce_reactions = true });
    pub const dir = bridge.accessor(Element.getDir, Element.setDir, .{ .ce_reactions = true });
    pub const className = bridge.accessor(Element.getClassName, Element.setClassName, .{ .ce_reactions = true });
    pub const classList = bridge.accessor(Element.getClassList, Element.setClassList, .{ .ce_reactions = true });
    pub const dataset = bridge.accessor(Element.getDataset, null, .{});
    pub const style = bridge.accessor(Element.getOrCreateStyle, Element.setStyle, .{});
    pub const attributes = bridge.accessor(Element.getAttributeNamedNodeMap, null, .{});
    pub const hasAttribute = bridge.function(Element.hasAttribute, .{});
    pub const hasAttributeNS = bridge.function(Element.hasAttributeNS, .{});
    pub const hasAttributes = bridge.function(Element.hasAttributes, .{});
    pub const getAttribute = bridge.function(Element.getAttribute, .{});
    pub const getAttributeNS = bridge.function(Element.getAttributeNS, .{});
    pub const getAttributeNode = bridge.function(Element.getAttributeNode, .{});
    pub const setAttributeNode = bridge.function(Element.setAttributeNode, .{ .ce_reactions = true });
    pub const removeAttribute = bridge.function(Element.removeAttribute, .{ .ce_reactions = true });
    pub const toggleAttribute = bridge.function(Element.toggleAttribute, .{ .ce_reactions = true });
    pub const getAttributeNames = bridge.function(Element.getAttributeNames, .{});
    pub const removeAttributeNode = bridge.function(Element.removeAttributeNode, .{ .ce_reactions = true });
    pub const shadowRoot = bridge.accessor(Element.getShadowRoot, null, .{});
    pub const assignedSlot = bridge.accessor(Element.getAssignedSlot, null, .{});
    pub const attachShadow = bridge.function(_attachShadow, .{ .arity = 1, .required_args = 1 });
    pub const insertAdjacentHTML = bridge.function(_insertAdjacentHTML, .{ .ce_reactions = true });
    fn _insertAdjacentHTML(self: *Element, position: []const u8, value: js.Value, frame: *Frame) !void {
        const owner_frame = self.asNode().ownerFrame(frame);
        const compliant = try TrustedTypes.getCompliantString(
            value,
            owner_frame.js,
            owner_frame.window.getTrustedTypes(),
            .html,
            "Element",
            "insertAdjacentHTML",
            .{ .operation = .{ .interface = "Element", .name = "insertAdjacentHTML" } },
            .dom_string,
            &frame.js.execution,
        );
        return self.insertAdjacentHTML(position, try compliant.toSlice(), owner_frame);
    }

    pub const setHTMLUnsafe = bridge.function(_setHTMLUnsafe, .{ .ce_reactions = true });
    fn _setHTMLUnsafe(self: *Element, value: js.Value, frame: *Frame) !void {
        const owner_frame = self.asNode().ownerFrame(frame);
        const compliant = try TrustedTypes.getCompliantString(
            value,
            owner_frame.js,
            owner_frame.window.getTrustedTypes(),
            .html,
            "Element",
            "setHTMLUnsafe",
            .{ .operation = .{ .interface = "Element", .name = "setHTMLUnsafe" } },
            .dom_string,
            &frame.js.execution,
        );
        return self.setHTMLUnsafe(try compliant.toSlice(), owner_frame);
    }
    pub const insertAdjacentElement = bridge.function(Element.insertAdjacentElement, .{ .ce_reactions = true });
    pub const insertAdjacentText = bridge.function(Element.insertAdjacentText, .{ .ce_reactions = true });

    fn _attachShadow(self: *Element, init_: ?js.Value, frame: *Frame) !*ShadowRoot {
        const init_value = init_ orelse return throwAttachShadowTypeError(
            frame,
            "1 argument required, but only 0 present.",
            "1 argument required, but only 0 present.",
        );
        if (init_value.isNullOrUndefined() or !init_value.isObject()) {
            return throwAttachShadowTypeError(
                frame,
                "The provided value is not of type 'ShadowRootInit'.",
                "The provided value is not of type 'ShadowRootInit'.",
            );
        }

        const init = init_value.toObject();

        // Blink's generated dictionary converter visits members in the
        // canonical (lexicographic) order observable through a Proxy.
        const raw_clonable = init.get("clonable") catch return error.TryCatchRethrow;
        _ = init.get("customElementRegistry") catch return error.TryCatchRethrow;
        const raw_delegates_focus = init.get("delegatesFocus") catch return error.TryCatchRethrow;
        const raw_mode = init.get("mode") catch return error.TryCatchRethrow;
        if (raw_mode.isUndefined()) {
            const reason = "Required member is undefined.";
            return throwAttachShadowDictionaryTypeError(frame, "mode", reason);
        }
        if (raw_mode.isSymbol()) {
            return throwAttachShadowDictionaryTypeError(frame, "mode", "Cannot convert a Symbol value to a string");
        }
        const mode_string = raw_mode.toStringSlice() catch return error.TryCatchRethrow;
        const mode: ShadowRoot.Mode = blk: {
            if (std.mem.eql(u8, mode_string, "open")) break :blk .open;
            if (std.mem.eql(u8, mode_string, "closed")) break :blk .closed;
            const reason = try std.fmt.allocPrint(
                frame.call_arena,
                "The provided value '{s}' is not a valid enum value of type ShadowRootMode.",
                .{mode_string},
            );
            return throwAttachShadowDictionaryTypeError(frame, "mode", reason);
        };

        const raw_serializable = init.get("serializable") catch return error.TryCatchRethrow;
        const raw_slot_assignment = init.get("slotAssignment") catch return error.TryCatchRethrow;
        const slot_assignment: ShadowRoot.SlotAssignment = blk: {
            if (raw_slot_assignment.isUndefined()) break :blk .named;
            if (raw_slot_assignment.isSymbol()) {
                return throwAttachShadowDictionaryTypeError(frame, "slotAssignment", "Cannot convert a Symbol value to a string");
            }
            const slot_string = raw_slot_assignment.toStringSlice() catch return error.TryCatchRethrow;
            if (std.mem.eql(u8, slot_string, "named")) break :blk .named;
            if (std.mem.eql(u8, slot_string, "manual")) break :blk .manual;
            const reason = try std.fmt.allocPrint(
                frame.call_arena,
                "The provided value '{s}' is not a valid enum value of type SlotAssignmentMode.",
                .{slot_string},
            );
            return throwAttachShadowDictionaryTypeError(frame, "slotAssignment", reason);
        };

        const opts: ShadowRoot.AttachOptions = .{
            .mode = mode,
            .delegates_focus = if (raw_delegates_focus.isUndefined()) false else raw_delegates_focus.toBool(),
            .slot_assignment = slot_assignment,
            .clonable = if (raw_clonable.isUndefined()) false else raw_clonable.toBool(),
            .serializable = if (raw_serializable.isUndefined()) false else raw_serializable.toBool(),
        };

        return self.attachShadow(opts, frame) catch |err| {
            switch (err) {
                error.NotSupported => return throwAttachShadowNotSupported(
                    frame,
                    self.attachShadowFailureReason(opts, frame) orelse "The operation is not supported",
                ),
                else => return err,
            }
        };
    }
    pub const replaceChildren = bridge.function(Element.replaceChildren, .{ .ce_reactions = true, .variadic = true });
    pub const replaceWith = bridge.function(Element.replaceWith, .{ .ce_reactions = true, .variadic = true });
    pub const remove = bridge.function(Element.remove, .{ .ce_reactions = true });
    pub const append = bridge.function(Element.append, .{ .ce_reactions = true, .variadic = true });
    pub const prepend = bridge.function(Element.prepend, .{ .ce_reactions = true, .variadic = true });
    pub const moveBefore = bridge.function(Element.moveBefore, .{ .ce_reactions = true });
    pub const before = bridge.function(Element.before, .{ .ce_reactions = true, .variadic = true });
    pub const after = bridge.function(Element.after, .{ .ce_reactions = true, .variadic = true });
    pub const firstElementChild = bridge.accessor(Element.firstElementChild, null, .{});
    pub const lastElementChild = bridge.accessor(Element.lastElementChild, null, .{});
    pub const nextElementSibling = bridge.accessor(Element.nextElementSibling, null, .{});
    pub const previousElementSibling = bridge.accessor(Element.previousElementSibling, null, .{});
    pub const childElementCount = bridge.accessor(Element.getChildElementCount, null, .{});
    pub const matches = bridge.function(Element.matches, .{});
    pub const querySelector = bridge.function(Element.querySelector, .{});
    pub const querySelectorAll = bridge.function(Element.querySelectorAll, .{});
    pub const closest = bridge.function(Element.closest, .{});
    pub const getAnimations = bridge.function(Element.getAnimations, .{});
    pub const animate = bridge.function(Element.animate, .{});
    pub const checkVisibility = bridge.function(Element.checkVisibility, .{});
    pub const clientWidth = bridge.accessor(Element.getClientWidth, null, .{});
    pub const clientHeight = bridge.accessor(Element.getClientHeight, null, .{});
    pub const clientTop = bridge.accessor(Element.getClientTop, null, .{});
    pub const clientLeft = bridge.accessor(Element.getClientLeft, null, .{});
    pub const scrollTop = bridge.accessor(Element.getScrollTop, Element.setScrollTop, .{});
    pub const scrollLeft = bridge.accessor(Element.getScrollLeft, Element.setScrollLeft, .{});
    pub const scrollHeight = bridge.accessor(Element.getScrollHeight, null, .{});
    pub const scrollWidth = bridge.accessor(Element.getScrollWidth, null, .{});
    pub const offsetTop = bridge.accessor(Element.getOffsetTop, null, .{});
    pub const offsetLeft = bridge.accessor(Element.getOffsetLeft, null, .{});
    pub const offsetWidth = bridge.accessor(Element.getOffsetWidth, null, .{});
    pub const offsetHeight = bridge.accessor(Element.getOffsetHeight, null, .{});
    pub const offsetParent = bridge.accessor(Element.getOffsetParent, null, .{});
    pub const getClientRects = bridge.function(Element.getClientRects, .{});
    pub const getBoundingClientRect = bridge.function(Element.getBoundingClientRect, .{});
    pub const getElementsByTagName = bridge.function(Element.getElementsByTagName, .{});
    pub const getElementsByTagNameNS = bridge.function(Element.getElementsByTagNameNS, .{});
    pub const getElementsByClassName = bridge.function(Element.getElementsByClassName, .{});
    pub const children = bridge.accessor(Element.getChildren, null, .{});
    pub const focus = bridge.function(Element.focus, .{});
    pub const blur = bridge.function(Element.blur, .{});
    pub const scrollIntoView = bridge.function(Element.scrollIntoView, .{});
    pub const scrollIntoViewIfNeeded = bridge.function(Element.scrollIntoViewIfNeeded, .{});
    pub const scroll = bridge.function(Element.scrollTo, .{});
    pub const scrollTo = bridge.function(Element.scrollTo, .{});
    pub const scrollBy = bridge.function(Element.scrollBy, .{});
};

pub const Build = struct {
    // Calls `func_name` with `args` on the most specific type where it is
    // implement. This could be on the Element itself.
    pub fn call(self: *const Element, comptime func_name: []const u8, args: anytype) !bool {
        inline for (@typeInfo(Element.Type).@"union".fields) |f| {
            if (@field(Element.Type, f.name) == self._type) {
                // The inner type implements this function. Call it and we're done.
                const S = reflect.Struct(f.type);
                if (@hasDecl(S, "Build")) {
                    if (@hasDecl(S.Build, "call")) {
                        const sub = @field(self._type, f.name);
                        return S.Build.call(sub, func_name, args);
                    }

                    // The inner type implements this function. Call it and we're done.
                    if (@hasDecl(f.type, func_name)) {
                        return @call(.auto, @field(f.type, func_name), args);
                    }
                }
            }
        }

        if (@hasDecl(Element.Build, func_name)) {
            // Our last resort - the element implements this function.
            try @call(.auto, @field(Element.Build, func_name), args);
            return true;
        }

        // inform our caller (the Node) that we didn't find anything that implemented
        // func_name and it should keep searching for a match.
        return false;
    }
};

const testing = @import("../../testing.zig");
test "WebApi: Element" {
    try testing.htmlRunner("element", .{});
}
