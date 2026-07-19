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

const js = @import("../../js/js.zig");
const Page = @import("../../Page.zig");
const Allocator = std.mem.Allocator;

// not registered in collections.zig, because this is one of the rare
// collections that's also available in Worker
pub fn registerTypes() []const type {
    return &.{DOMStringList};
}

pub const DOMStringList = @This();

_rc: lp.RC(u8) = .{},
_arena: Allocator,
_items: []const []const u8,

pub fn acquireRef(self: *DOMStringList) void {
    self._rc.acquire();
}

pub fn deinit(self: *DOMStringList, page: *Page) void {
    page.releaseArena(self._arena);
}

pub fn releaseRef(self: *DOMStringList, page: *Page) void {
    self._rc.release(self, page);
}

pub fn length(self: *const DOMStringList) u32 {
    return @intCast(self._items.len);
}

pub fn item(self: *const DOMStringList, index: usize) ?[]const u8 {
    if (index >= self._items.len) {
        return null;
    }
    return self._items[index];
}

pub fn contains(self: *const DOMStringList, string: []const u8) bool {
    for (self._items) |entry| {
        if (std.mem.eql(u8, entry, string)) {
            return true;
        }
    }
    return false;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(DOMStringList);

    pub const Meta = struct {
        pub const name = "DOMStringList";
        pub const prototype_template_properties = [_]js.bridge.InstanceTemplateProperty{.{
            .key = .{ .well_known_symbol = .iterator },
            .value = .{ .intrinsic = .array_prototype_values },
            .writable = true,
            .enumerable = false,
            .configurable = true,
            .phase = .after_members,
        }};
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const length = bridge.accessor(DOMStringList.length, null, .{});
    pub const contains = bridge.function(DOMStringList.contains, .{});
    pub const item = bridge.function(_item, .{});
    fn _item(self: *const DOMStringList, index: i32) ?[]const u8 {
        if (index < 0) {
            return null;
        }
        return self.item(@intCast(index));
    }

    pub const @"[]" = bridge.indexed(DOMStringList.item, null, .{ .null_as_undefined = true });
};
