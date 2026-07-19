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

const js = @import("../../../js/js.zig");
const Frame = @import("../../../Frame.zig");
const Node = @import("../../Node.zig");
const Element = @import("../../Element.zig");
const HtmlElement = @import("../Html.zig");

const Meta = @This();
// Because we have a JsApi.Meta, "Meta" can be ambiguous in some scopes.
// Create a different alias we can use when in such ambiguous cases.
const MetaElement = Meta;
const String = lp.String;

_proto: *HtmlElement,

pub fn asElement(self: *Meta) *Element {
    return self._proto._proto;
}
pub fn asNode(self: *Meta) *Node {
    return self.asElement().asNode();
}

pub fn getName(self: *Meta) []const u8 {
    return self.asElement().getAttributeSafe(comptime .wrap("name")) orelse return "";
}

pub fn setName(self: *Meta, value: []const u8, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("name"), .wrap(value), frame);
}

pub fn getHttpEquiv(self: *Meta) []const u8 {
    return self.asElement().getAttributeSafe(comptime .wrap("http-equiv")) orelse return "";
}

pub fn setHttpEquiv(self: *Meta, value: []const u8, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("http-equiv"), .wrap(value), frame);
}

pub fn getContent(self: *Meta) []const u8 {
    return self.asElement().getAttributeSafe(comptime .wrap("content")) orelse return "";
}

pub fn setContent(self: *Meta, value: []const u8, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("content"), .wrap(value), frame);
}

pub fn getMedia(self: *Meta) []const u8 {
    return self.asElement().getAttributeSafe(comptime .wrap("media")) orelse return "";
}

pub fn setMedia(self: *Meta, value: []const u8, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("media"), .wrap(value), frame);
}

pub fn getScheme(self: *Meta) []const u8 {
    return self.asElement().getAttributeSafe(comptime .wrap("scheme")) orelse return "";
}

pub fn setScheme(self: *Meta, value: []const u8, frame: *Frame) !void {
    try self.asElement().setAttributeSafe(comptime .wrap("scheme"), .wrap(value), frame);
}

/// Match Chromium's InDocumentHead check: the element must be connected and
/// have an HTMLHeadElement anywhere in its ancestor chain. This intentionally
/// also accepts script-created, non-canonical head elements.
fn inDocumentHead(self: *Meta, frame: *Frame) bool {
    const node = self.asNode();
    if (!node.isConnected()) return false;
    if (node.ownerDocument(frame) != frame.document) return false;

    var ancestor = node.parentNode();
    while (ancestor) |current| : (ancestor = current.parentNode()) {
        if (current.is(Element.Html.Head) != null) return true;
    }
    return false;
}

/// Process the code-generation portion of a CSP meta element. Once processed,
/// a policy is not removed by later attribute mutation/removal.
pub fn processContentSecurityPolicy(self: *Meta, frame: *Frame) !void {
    if (!self.inDocumentHead(frame)) return;

    const http_equiv = std.mem.trim(u8, self.getHttpEquiv(), " \t\r\n\x0c");
    if (!std.ascii.eqlIgnoreCase(http_equiv, "Content-Security-Policy")) return;
    return frame.js.addContentSecurityPolicy(self.getContent());
}

pub const Build = struct {
    pub fn attributeChange(element: *Element, name: String, _: String, frame: *Frame) !void {
        if (!name.eql(comptime .wrap("http-equiv")) and !name.eql(comptime .wrap("content"))) return;
        return element.as(MetaElement).processContentSecurityPolicy(frame);
    }
};

pub const JsApi = struct {
    pub const bridge = js.Bridge(MetaElement);

    pub const Meta = struct {
        pub const name = "HTMLMetaElement";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const name = bridge.accessor(MetaElement.getName, MetaElement.setName, .{ .ce_reactions = true });
    pub const httpEquiv = bridge.accessor(MetaElement.getHttpEquiv, MetaElement.setHttpEquiv, .{ .ce_reactions = true });
    pub const content = bridge.accessor(MetaElement.getContent, MetaElement.setContent, .{ .ce_reactions = true });
    pub const media = bridge.accessor(MetaElement.getMedia, MetaElement.setMedia, .{ .ce_reactions = true });
    pub const scheme = bridge.accessor(MetaElement.getScheme, MetaElement.setScheme, .{ .ce_reactions = true });
};

const testing = @import("../../../../testing.zig");
test "WebApi: CSP code generation callbacks" {
    try testing.htmlRunner("csp", .{});
}
