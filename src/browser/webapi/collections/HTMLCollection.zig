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

const js = @import("../../js/js.zig");
const Frame = @import("../../Frame.zig");
const Node = @import("../Node.zig");
const Element = @import("../Element.zig");
const TreeWalker = @import("../TreeWalker.zig");
const NodeLive = @import("node_live.zig").NodeLive;
const Execution = js.Execution;

const Mode = enum {
    tag,
    tag_name,
    tag_name_ns,
    class_name,
    all_elements,
    child_elements,
    child_tag,
    selected_options,
    links,
    anchors,
    form,
    document_all_named,
    empty,
};

const HTMLCollection = @This();

_data: union(Mode) {
    tag: NodeLive(.tag),
    tag_name: NodeLive(.tag_name),
    tag_name_ns: NodeLive(.tag_name_ns),
    class_name: NodeLive(.class_name),
    all_elements: NodeLive(.all_elements),
    child_elements: NodeLive(.child_elements),
    child_tag: NodeLive(.child_tag),
    selected_options: NodeLive(.selected_options),
    links: NodeLive(.links),
    anchors: NodeLive(.anchors),
    form: NodeLive(.form),
    document_all_named: DocumentAllNamed,
    empty: void,
},

pub fn length(self: *HTMLCollection, frame: *const Frame) u32 {
    return switch (self._data) {
        .empty => 0,
        inline else => |*impl| impl.length(frame),
    };
}

pub fn getAtIndex(self: *HTMLCollection, index: usize, frame: *const Frame) ?*Element {
    return switch (self._data) {
        .empty => null,
        inline else => |*impl| impl.getAtIndex(index, frame),
    };
}

pub fn getByName(self: *HTMLCollection, name: []const u8, frame: *Frame) ?*Element {
    if (name.len == 0) {
        return null;
    }

    return switch (self._data) {
        .empty => null,
        inline else => |*impl| impl.getByName(name, frame),
    };
}

pub fn iterator(self: *HTMLCollection, exec: *const Execution) !*Iterator {
    return Iterator.init(.{
        .list = self,
        .tw = switch (self._data) {
            .tag => |*impl| .{ .tag = impl._tw.clone() },
            .tag_name => |*impl| .{ .tag_name = impl._tw.clone() },
            .tag_name_ns => |*impl| .{ .tag_name_ns = impl._tw.clone() },
            .class_name => |*impl| .{ .class_name = impl._tw.clone() },
            .all_elements => |*impl| .{ .all_elements = impl._tw.clone() },
            .child_elements => |*impl| .{ .child_elements = impl._tw.clone() },
            .child_tag => |*impl| .{ .child_tag = impl._tw.clone() },
            .selected_options => |*impl| .{ .selected_options = impl._tw.clone() },
            .links => |*impl| .{ .links = impl._tw.clone() },
            .anchors => |*impl| .{ .anchors = impl._tw.clone() },
            .form => |*impl| .{ .form = impl._tw.clone() },
            .document_all_named => |*impl| .{ .document_all_named = TreeWalker.FullExcludeSelf.init(impl.root, .{}) },
            .empty => .empty,
        },
    }, exec);
}

const GenericIterator = @import("iterator.zig").Entry;
pub const Iterator = GenericIterator(struct {
    list: *HTMLCollection,
    tw: union(Mode) {
        tag: TreeWalker.FullExcludeSelf,
        tag_name: TreeWalker.FullExcludeSelf,
        tag_name_ns: TreeWalker.FullExcludeSelf,
        class_name: TreeWalker.FullExcludeSelf,
        all_elements: TreeWalker.FullExcludeSelf,
        child_elements: TreeWalker.Children,
        child_tag: TreeWalker.Children,
        selected_options: TreeWalker.Children,
        links: TreeWalker.FullExcludeSelf,
        anchors: TreeWalker.FullExcludeSelf,
        form: TreeWalker.FullExcludeSelf,
        document_all_named: TreeWalker.FullExcludeSelf,
        empty: void,
    },

    pub fn next(self: *@This(), _: *const Execution) ?*Element {
        return switch (self.list._data) {
            .tag => |*impl| impl.nextTw(&self.tw.tag),
            .tag_name => |*impl| impl.nextTw(&self.tw.tag_name),
            .tag_name_ns => |*impl| impl.nextTw(&self.tw.tag_name_ns),
            .class_name => |*impl| impl.nextTw(&self.tw.class_name),
            .all_elements => |*impl| impl.nextTw(&self.tw.all_elements),
            .child_elements => |*impl| impl.nextTw(&self.tw.child_elements),
            .child_tag => |*impl| impl.nextTw(&self.tw.child_tag),
            .selected_options => |*impl| impl.nextTw(&self.tw.selected_options),
            .links => |*impl| impl.nextTw(&self.tw.links),
            .anchors => |*impl| impl.nextTw(&self.tw.anchors),
            .form => |*impl| impl.nextTw(&self.tw.form),
            .document_all_named => |*impl| impl.nextTw(&self.tw.document_all_named),
            .empty => return null,
        };
    }
}, null);

/// A live DocumentNameCollection used for duplicate document.all name hits.
/// This is deliberately concrete rather than another NodeLive specialization:
/// NodeLive's generic wrapping imports HTMLCollection, so making HTMLCollection
/// contain that specialization creates a recursive generic type in Zig.
pub const DocumentAllNamed = struct {
    root: *Node,
    name: []const u8,

    pub fn init(root: *Node, name: []const u8) DocumentAllNamed {
        return .{ .root = root, .name = name };
    }

    pub fn length(self: *const DocumentAllNamed, _: *const Frame) u32 {
        var tw = TreeWalker.FullExcludeSelf.init(self.root, .{});
        var count: u32 = 0;
        while (self.nextTw(&tw)) |_| count += 1;
        return count;
    }

    pub fn getAtIndex(self: *const DocumentAllNamed, index: usize, _: *const Frame) ?*Element {
        var tw = TreeWalker.FullExcludeSelf.init(self.root, .{});
        var current: usize = 0;
        while (self.nextTw(&tw)) |element| {
            if (current == index) return element;
            current += 1;
        }
        return null;
    }

    pub fn getByName(self: *const DocumentAllNamed, name: []const u8, _: *Frame) ?*Element {
        var tw = TreeWalker.FullExcludeSelf.init(self.root, .{});
        while (self.nextTw(&tw)) |element| {
            if (element.getAttributeSafe(comptime .wrap("id"))) |id| {
                if (std.mem.eql(u8, id, name)) return element;
            }
            if (element.getAttributeSafe(comptime .wrap("name"))) |element_name| {
                if (std.mem.eql(u8, element_name, name)) return element;
            }
        }
        return null;
    }

    pub fn nextTw(self: *const DocumentAllNamed, tw: *TreeWalker.FullExcludeSelf) ?*Element {
        while (tw.next()) |node| {
            const element = node.is(Element) orelse continue;
            if (self.matches(element)) return element;
        }
        return null;
    }

    fn matches(self: *const DocumentAllNamed, element: *Element) bool {
        if (element.getAttributeSafe(comptime .wrap("id"))) |id| {
            if (std.mem.eql(u8, id, self.name)) return true;
        }
        if (!nameVisibleInDocumentAll(element)) return false;
        const name = element.getAttributeSafe(comptime .wrap("name")) orelse return false;
        return std.mem.eql(u8, name, self.name);
    }
};

/// HTML's legacy document.all name matching accepts every element by id, but
/// accepts a name attribute only on this historical HTMLElement allow-list.
pub fn nameVisibleInDocumentAll(element: *const Element) bool {
    if (element._namespace != .html) return false;
    return std.StaticStringMap(void).initComptime(.{
        .{ "a", {} },
        .{ "button", {} },
        .{ "embed", {} },
        .{ "form", {} },
        .{ "frame", {} },
        .{ "frameset", {} },
        .{ "iframe", {} },
        .{ "img", {} },
        .{ "input", {} },
        .{ "map", {} },
        .{ "meta", {} },
        .{ "object", {} },
        .{ "select", {} },
        .{ "textarea", {} },
    }).has(element.getTagNameLower());
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(HTMLCollection);

    pub const Meta = struct {
        pub const name = "HTMLCollection";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const length = bridge.accessor(HTMLCollection.length, null, .{});
    pub const @"[int]" = bridge.indexed(HTMLCollection.getAtIndex, null, .{ .null_as_undefined = true });
    pub const @"[str]" = bridge.namedIndexed(struct {
        pub fn wrap(self: *HTMLCollection, name: []const u8, frame: *Frame) !?*Element {
            if (name.len == 0) {
                return error.NotHandled;
            }

            return self.getByName(name, frame) orelse error.NotHandled;
        }
    }.wrap, null, null, null, null, .{ .null_as_undefined = true });

    pub const item = bridge.function(_item, .{});
    fn _item(self: *HTMLCollection, index: i32, frame: *Frame) ?*Element {
        if (index < 0) {
            return null;
        }
        return self.getAtIndex(@intCast(index), frame);
    }

    pub const namedItem = bridge.function(HTMLCollection.getByName, .{});
    pub const symbol_iterator = bridge.iterator(HTMLCollection.iterator, .{});
};
