const std = @import("std");
const js = @import("../../js/js.zig");
const Frame = @import("../../Frame.zig");
const CSSStyleSheet = @import("CSSStyleSheet.zig");

const StyleSheetList = @This();

_sheets: std.ArrayList(*CSSStyleSheet) = .empty,

pub fn init(frame: *Frame) !*StyleSheetList {
    return frame._factory.create(StyleSheetList{});
}

pub fn length(self: *const StyleSheetList) u32 {
    return @intCast(self._sheets.items.len);
}

pub fn item(self: *const StyleSheetList, index: usize) ?*CSSStyleSheet {
    if (index >= self._sheets.items.len) return null;
    return self._sheets.items[index];
}

pub fn add(self: *StyleSheetList, sheet: *CSSStyleSheet, frame: *Frame) !void {
    // Blink exposes the candidate sheets in TreeScope tree order, not in the
    // historical order in which lifecycle callbacks happened to register
    // them. Re-registering is also how a state-preserving move updates the
    // position of an existing sheet without changing its identity.
    self.remove(sheet);

    const owner = sheet.getOwnerNode() orelse {
        try self._sheets.append(frame.arena, sheet);
        return;
    };
    for (self._sheets.items, 0..) |existing, index| {
        const existing_owner = existing.getOwnerNode() orelse continue;
        if ((owner.asNode().compareDocumentPosition(existing_owner.asNode()) & 0x04) != 0) {
            try self._sheets.insert(frame.arena, index, sheet);
            return;
        }
    }
    try self._sheets.append(frame.arena, sheet);
}

pub fn remove(self: *StyleSheetList, sheet: *CSSStyleSheet) void {
    for (self._sheets.items, 0..) |s, i| {
        if (s == sheet) {
            _ = self._sheets.orderedRemove(i);
            return;
        }
    }
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(StyleSheetList);

    pub const Meta = struct {
        pub const name = "StyleSheetList";
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

    // Declaration order is observable through Reflect.ownKeys and matches the
    // Chrome 149 binding: length, item, constructor, @@toStringTag, @@iterator.
    pub const length = bridge.accessor(StyleSheetList.length, null, .{});
    pub const item = bridge.function(StyleSheetList.item, .{});
    pub const @"[]" = bridge.indexed(StyleSheetList.item, null, .{ .null_as_undefined = true });
};
