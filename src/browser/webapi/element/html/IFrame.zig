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

const js = @import("../../../js/js.zig");
const Frame = @import("../../../Frame.zig");
const HttpClient = @import("../../../HttpClient.zig");
const Window = @import("../../Window.zig");
const Document = @import("../../Document.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");
const DOMTokenList = @import("../../collections.zig").DOMTokenList;
const TrustedTypes = @import("../../TrustedTypes.zig");

const IFrame = @This();
_proto: *HtmlElement,
_src: []const u8 = "",
_executed: bool = false,
_window: ?*Window = null,
_sandbox: ?*DOMTokenList = null,

pub fn asElement(self: *IFrame) *Element {
    return self._proto._proto;
}
pub fn asConstElement(self: *const IFrame) *const Element {
    return self._proto._proto;
}
pub fn asNode(self: *IFrame) *Node {
    return self.asElement().asNode();
}

pub fn getContentWindow(self: *const IFrame, frame: *Frame) ?Window.Access {
    const frame_window = self._window orelse return null;
    return Window.Access.init(frame.window, frame_window);
}

/// Browser-internal tree traversal is not a Web IDL access and therefore must
/// not invent a JavaScript caller realm. Callers which expose this value to JS
/// must use getContentDocument so [CheckSecurity=ReturnValue] is applied.
pub fn contentDocumentUnchecked(self: *const IFrame) ?*Document {
    const window = self._window orelse return null;
    if (window._document._frame == null) return null;
    return window._document;
}

pub fn getContentDocument(self: *const IFrame, frame: *Frame) ?*Document {
    const document = self.contentDocumentUnchecked() orelse return null;
    const document_frame = document._frame orelse return null;
    // Blink declares this attribute [CheckSecurity=ReturnValue]. Its generated
    // binding compares the current calling Window with the returned Document,
    // rather than merely comparing the iframe owner with its child. This is
    // observable when the native getter is borrowed across same-origin realms.
    if (!Frame.sameEffectiveOrigin(frame, document_frame)) return null;
    return document;
}

// loading=lazy iframes are still but don't delay the page's "load" event
pub fn isLazyLoading(self: *IFrame) bool {
    const loading = self.asElement().getAttributeSafe(comptime .wrap("loading")) orelse return false;
    return std.ascii.eqlIgnoreCase(loading, "lazy");
}

pub fn getSrc(self: *IFrame, frame: *Frame) ![]const u8 {
    if (self._src.len == 0) return "";
    return self.asNode().resolveURLReflect(self._src, frame, .{});
}

pub fn setSrc(self: *IFrame, src: []const u8, frame: *Frame) !void {
    const element = self.asElement();
    try element.setAttributeSafe(comptime .wrap("src"), .wrap(src), frame);
    self._src = element.getAttributeSafe(comptime .wrap("src")) orelse unreachable;
    if (element.asNode().isConnected()) {
        // unlike script, an iframe is reloaded every time the src is set
        // even if it's set to the same URL.
        self._executed = false;
        try frame.iframeAddedCallback(self);
    }
}

pub fn getSrcdoc(self: *IFrame) []const u8 {
    return self.asElement().getAttributeSafe(comptime .wrap("srcdoc")) orelse "";
}

pub fn setSrcdoc(self: *IFrame, srcdoc: []const u8, frame: *Frame) !void {
    const element = self.asElement();
    try element.setAttributeSafe(comptime .wrap("srcdoc"), .wrap(srcdoc), frame);
    if (element.asNode().isConnected()) {
        // The srcdoc document takes precedence over src. Setting it on an
        // already-connected iframe therefore navigates just like setting src.
        self._executed = false;
        try frame.iframeAddedCallback(self);
    }
}

pub fn getName(self: *IFrame) []const u8 {
    return self.asElement().getAttributeSafe(comptime .wrap("name")) orelse "";
}

pub fn setName(self: *IFrame, value: []const u8, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("name"), .wrap(value), frame);
}

pub fn getWidth(self: *const IFrame) []const u8 {
    return self.asConstElement().getAttributeSafe(comptime .wrap("width")) orelse "";
}

pub fn setWidth(self: *IFrame, value: []const u8, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("width"), .wrap(value), frame);
}

pub fn getHeight(self: *const IFrame) []const u8 {
    return self.asConstElement().getAttributeSafe(comptime .wrap("height")) orelse "";
}

pub fn setHeight(self: *IFrame, value: []const u8, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("height"), .wrap(value), frame);
}

pub fn getReferrerPolicy(self: *const IFrame) []const u8 {
    const valid_referrer_policy = [_][]const u8{
        "",
        "no-referrer",
        "origin",
        "no-referrer-when-downgrade",
        "origin-when-cross-origin",
        "unsafe-url",
        "same-origin",
        "strict-origin",
        "strict-origin-when-cross-origin",
    };
    return HtmlElement.reflectEnumerated(
        self.asConstElement().getAttributeSafe(.wrap("referrerpolicy")),
        &valid_referrer_policy,
        "",
        "",
    ).?;
}

pub fn setReferrerPolicy(self: *IFrame, value: []const u8, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(.wrap("referrerpolicy"), .wrap(value), frame);
}

pub fn getSandbox(self: *IFrame, frame: *Frame) !*DOMTokenList {
    if (self._sandbox) |sandbox| return sandbox;
    const sandbox = try frame._factory.create(DOMTokenList{
        ._element = self.asElement(),
        ._attribute_name = comptime .wrap("sandbox"),
    });
    self._sandbox = sandbox;
    return sandbox;
}

pub fn navigationReferrerPolicy(self: *const IFrame) HttpClient.ReferrerPolicy {
    const value = self.getReferrerPolicy();
    if (std.mem.eql(u8, value, "no-referrer")) return .no_referrer;
    if (std.mem.eql(u8, value, "no-referrer-when-downgrade")) return .no_referrer_when_downgrade;
    if (std.mem.eql(u8, value, "origin")) return .origin;
    if (std.mem.eql(u8, value, "origin-when-cross-origin")) return .origin_when_cross_origin;
    if (std.mem.eql(u8, value, "same-origin")) return .same_origin;
    if (std.mem.eql(u8, value, "strict-origin")) return .strict_origin;
    if (std.mem.eql(u8, value, "unsafe-url")) return .unsafe_url;
    return HttpClient.default_referrer_policy;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(IFrame);

    pub const Meta = struct {
        pub const name = "HTMLIFrameElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const src = bridge.accessor(IFrame.getSrc, IFrame.setSrc, .{ .ce_reactions = true });
    pub const srcdoc = bridge.accessor(IFrame.getSrcdoc, _setSrcdoc, .{ .ce_reactions = true });
    fn _setSrcdoc(self: *IFrame, value: js.Value, frame: *Frame) !void {
        const owner_frame = self.asNode().ownerFrame(frame);
        const compliant = try TrustedTypes.getCompliantString(
            value,
            owner_frame.js,
            owner_frame.window.getTrustedTypes(),
            .html,
            "HTMLIFrameElement",
            "srcdoc",
            .{ .attribute_set = .{ .interface = "HTMLIFrameElement", .name = "srcdoc" } },
            .dom_string,
            &frame.js.execution,
        );
        return self.setSrcdoc(try compliant.toSlice(), self.asNode().ownerFrame(frame));
    }
    pub const name = bridge.accessor(IFrame.getName, IFrame.setName, .{ .ce_reactions = true });
    pub const width = bridge.accessor(IFrame.getWidth, IFrame.setWidth, .{ .ce_reactions = true });
    pub const height = bridge.accessor(IFrame.getHeight, IFrame.setHeight, .{ .ce_reactions = true });
    pub const contentDocument = bridge.accessor(IFrame.getContentDocument, null, .{});
    pub const contentWindow = bridge.accessor(IFrame.getContentWindow, null, .{});
    pub const referrerPolicy = bridge.accessor(IFrame.getReferrerPolicy, IFrame.setReferrerPolicy, .{ .ce_reactions = true });
    pub const sandbox = bridge.accessor(IFrame.getSandbox, null, .{});
};

pub const Build = struct {
    pub fn complete(node: *Node, _: *Frame) !void {
        const self = node.as(IFrame);
        const element = self.asElement();
        self._src = element.getAttributeSafe(comptime .wrap("src")) orelse "";
    }
};
