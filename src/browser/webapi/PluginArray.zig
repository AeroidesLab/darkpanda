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

const js = @import("../js/js.zig");

pub fn registerTypes() []const type {
    return &.{
        PluginArray,
        PluginArray.Iterator,
        Plugin,
        Plugin.Iterator,
        MimeTypeArray,
        MimeTypeArray.Iterator,
        MimeType,
    };
}

const PluginArray = @This();

_pad: bool = false,

pub fn refresh(_: *const PluginArray) void {}
pub fn getAtIndex(_: *const PluginArray, index: usize) ?*Plugin {
    if (index >= plugins.len) return null;
    return &plugins[index];
}

pub fn getByName(_: *const PluginArray, name: []const u8) ?*Plugin {
    for (plugin_names, 0..) |plugin_name, index| {
        if (std.mem.eql(u8, name, plugin_name)) return &plugins[index];
    }
    return null;
}

pub fn iterator(self: *PluginArray, exec: *const js.Execution) !*Iterator {
    return Iterator.init(.{ .index = 0, .array = self }, exec);
}

const GenericIterator = @import("collections/iterator.zig").Entry;
pub const Iterator = GenericIterator(struct {
    index: usize,
    array: *PluginArray,

    pub fn next(self: *@This(), _: *const js.Execution) ?*Plugin {
        const plugin = self.array.getAtIndex(self.index) orelse return null;
        self.index += 1;
        return plugin;
    }
}, null);

const plugin_names = [_][]const u8{
    "PDF Viewer",
    "Chrome PDF Viewer",
    "Chromium PDF Viewer",
    "Microsoft Edge PDF Viewer",
    "WebKit built-in PDF",
};
const mime_type_names = [_][]const u8{ "application/pdf", "text/pdf" };

var plugins = [_]Plugin{
    .{ ._index = 0 },
    .{ ._index = 1 },
    .{ ._index = 2 },
    .{ ._index = 3 },
    .{ ._index = 4 },
};
var mime_types = [_][mime_type_names.len]MimeType{
    .{ .{ ._plugin_index = 0, ._type_index = 0 }, .{ ._plugin_index = 0, ._type_index = 1 } },
    .{ .{ ._plugin_index = 1, ._type_index = 0 }, .{ ._plugin_index = 1, ._type_index = 1 } },
    .{ .{ ._plugin_index = 2, ._type_index = 0 }, .{ ._plugin_index = 2, ._type_index = 1 } },
    .{ .{ ._plugin_index = 3, ._type_index = 0 }, .{ ._plugin_index = 3, ._type_index = 1 } },
    .{ .{ ._plugin_index = 4, ._type_index = 0 }, .{ ._plugin_index = 4, ._type_index = 1 } },
};

const Plugin = struct {
    _index: usize,

    pub fn getName(self: *const Plugin) []const u8 {
        return plugin_names[self._index];
    }

    pub fn getFilename(_: *const Plugin) []const u8 {
        return "internal-pdf-viewer";
    }

    pub fn getDescription(_: *const Plugin) []const u8 {
        return "Portable Document Format";
    }

    pub fn getAtIndex(self: *const Plugin, index: usize) ?*MimeType {
        if (index >= mime_type_names.len) return null;
        return &mime_types[self._index][index];
    }

    pub fn getByName(self: *const Plugin, name: []const u8) ?*MimeType {
        for (mime_type_names, 0..) |mime_type, index| {
            if (std.mem.eql(u8, name, mime_type)) return &mime_types[self._index][index];
        }
        return null;
    }

    pub fn iterator(self: *Plugin, exec: *const js.Execution) !*Plugin.Iterator {
        return Plugin.Iterator.init(.{ .index = 0, .plugin = self }, exec);
    }

    pub const Iterator = GenericIterator(struct {
        index: usize,
        plugin: *Plugin,

        pub fn next(self: *@This(), _: *const js.Execution) ?*MimeType {
            const mime_type = self.plugin.getAtIndex(self.index) orelse return null;
            self.index += 1;
            return mime_type;
        }
    }, null);

    pub const JsApi = struct {
        pub const bridge = js.Bridge(Plugin);
        pub const Meta = struct {
            pub const name = "Plugin";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const name = bridge.accessor(Plugin.getName, null, .{});
        pub const filename = bridge.accessor(Plugin.getFilename, null, .{});
        pub const description = bridge.accessor(Plugin.getDescription, null, .{});
        pub const length = bridge.constantAccessor(mime_type_names.len);
        pub const item = bridge.function(_item, .{});
        pub const namedItem = bridge.function(Plugin.getByName, .{});
        pub const @"[int]" = bridge.indexedLegacyReadOnly(Plugin.getAtIndex, pluginMimeIndexQuery, getPluginMimeIndexes, "Plugin", .{ .null_as_undefined = true });
        pub const @"[str]" = bridge.namedIndexedLegacyReadOnly(Plugin.getByName, getPluginMimeNames, pluginMimeNameQuery, "Plugin", .{ .null_as_undefined = true });
        pub const symbol_iterator = bridge.iterator(Plugin.iterator, .{});

        fn _item(self: *const Plugin, index: i32) ?*MimeType {
            if (index < 0) return null;
            return self.getAtIndex(@intCast(index));
        }
    };
};

pub const MimeTypeArray = struct {
    _pad: bool = false,

    pub fn getAtIndex(_: *const MimeTypeArray, index: usize) ?*MimeType {
        if (index >= mime_type_names.len) return null;
        return &mime_types[0][index];
    }

    pub fn getByName(_: *const MimeTypeArray, name: []const u8) ?*MimeType {
        for (mime_type_names, 0..) |mime_type, index| {
            if (std.mem.eql(u8, name, mime_type)) return &mime_types[0][index];
        }
        return null;
    }

    pub fn iterator(self: *MimeTypeArray, exec: *const js.Execution) !*MimeTypeArray.Iterator {
        return MimeTypeArray.Iterator.init(.{ .index = 0, .array = self }, exec);
    }

    pub const Iterator = GenericIterator(struct {
        index: usize,
        array: *MimeTypeArray,

        pub fn next(self: *@This(), _: *const js.Execution) ?*MimeType {
            const mime_type = self.array.getAtIndex(self.index) orelse return null;
            self.index += 1;
            return mime_type;
        }
    }, null);

    pub const JsApi = struct {
        pub const bridge = js.Bridge(MimeTypeArray);
        pub const Meta = struct {
            pub const name = "MimeTypeArray";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
            pub const empty_with_no_proto = true;
        };

        pub const length = bridge.constantAccessor(mime_type_names.len);
        pub const item = bridge.function(_item, .{});
        pub const namedItem = bridge.function(MimeTypeArray.getByName, .{});
        pub const @"[int]" = bridge.indexedLegacyReadOnly(MimeTypeArray.getAtIndex, mimeTypeIndexQuery, getMimeTypeIndexes, "MimeTypeArray", .{ .null_as_undefined = true });
        pub const @"[str]" = bridge.namedIndexedLegacyReadOnly(MimeTypeArray.getByName, getMimeTypeArrayNames, mimeTypeNameQuery, "MimeTypeArray", .{ .null_as_undefined = true });
        pub const symbol_iterator = bridge.iterator(MimeTypeArray.iterator, .{});

        fn _item(self: *const MimeTypeArray, index: i32) ?*MimeType {
            if (index < 0) return null;
            return self.getAtIndex(@intCast(index));
        }
    };
};

const MimeType = struct {
    _plugin_index: usize,
    _type_index: usize,

    pub fn getType(self: *const MimeType) []const u8 {
        return mime_type_names[self._type_index];
    }

    pub fn getSuffixes(_: *const MimeType) []const u8 {
        return "pdf";
    }

    pub fn getDescription(_: *const MimeType) []const u8 {
        return "Portable Document Format";
    }

    pub fn getEnabledPlugin(self: *const MimeType) *Plugin {
        return &plugins[self._plugin_index];
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(MimeType);
        pub const Meta = struct {
            pub const name = "MimeType";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const @"type" = bridge.accessor(MimeType.getType, null, .{});
        pub const suffixes = bridge.accessor(MimeType.getSuffixes, null, .{});
        pub const description = bridge.accessor(MimeType.getDescription, null, .{});
        pub const enabledPlugin = bridge.accessor(MimeType.getEnabledPlugin, null, .{});
    };
};

fn getPluginMimeIndexes(_: *Plugin, exec: *const js.Execution) !js.Array {
    var keys = exec.js.local.?.newArray(mime_type_names.len);
    for (0..mime_type_names.len) |index| {
        _ = try keys.set(@intCast(index), index, .{});
    }
    return keys;
}

fn pluginMimeIndexQuery(_: *Plugin, index: u32) ?u32 {
    if (index >= mime_type_names.len) return null;
    return @intCast(js.v8.ReadOnly);
}

fn getMimeTypeIndexes(_: *MimeTypeArray, exec: *const js.Execution) !js.Array {
    var keys = exec.js.local.?.newArray(mime_type_names.len);
    for (0..mime_type_names.len) |index| {
        _ = try keys.set(@intCast(index), index, .{});
    }
    return keys;
}

fn mimeTypeIndexQuery(_: *MimeTypeArray, index: u32) ?u32 {
    if (index >= mime_type_names.len) return null;
    return @intCast(js.v8.ReadOnly);
}

fn getPluginIndexes(_: *PluginArray, exec: *const js.Execution) !js.Array {
    var keys = exec.js.local.?.newArray(plugin_names.len);
    for (0..plugin_names.len) |index| {
        _ = try keys.set(@intCast(index), index, .{});
    }
    return keys;
}

fn pluginIndexQuery(_: *PluginArray, index: u32) ?u32 {
    if (index >= plugin_names.len) return null;
    return @intCast(js.v8.ReadOnly);
}

fn getPluginNames(_: *PluginArray, exec: *const js.Execution) !js.Array {
    return stringArray(plugin_names, exec);
}

fn pluginNameQuery(array: *const PluginArray, name: []const u8) ?u32 {
    if (array.getByName(name) == null) return null;
    return @intCast(js.v8.ReadOnly | js.v8.DontEnum);
}

fn getPluginMimeNames(_: *Plugin, exec: *const js.Execution) !js.Array {
    return stringArray(mime_type_names, exec);
}

fn pluginMimeNameQuery(plugin: *const Plugin, name: []const u8) ?u32 {
    if (plugin.getByName(name) == null) return null;
    return @intCast(js.v8.ReadOnly | js.v8.DontEnum);
}

fn getMimeTypeArrayNames(_: *MimeTypeArray, exec: *const js.Execution) !js.Array {
    return stringArray(mime_type_names, exec);
}

fn mimeTypeNameQuery(array: *const MimeTypeArray, name: []const u8) ?u32 {
    if (array.getByName(name) == null) return null;
    return @intCast(js.v8.ReadOnly | js.v8.DontEnum);
}

fn stringArray(comptime strings: anytype, exec: *const js.Execution) !js.Array {
    var keys = exec.js.local.?.newArray(strings.len);
    for (strings, 0..) |value, index| {
        _ = try keys.set(@intCast(index), value, .{});
    }
    return keys;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(PluginArray);

    pub const Meta = struct {
        pub const name = "PluginArray";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
        pub const empty_with_no_proto = true;
    };

    pub const length = bridge.constantAccessor(plugin_names.len);
    pub const refresh = bridge.function(PluginArray.refresh, .{});
    pub const @"[int]" = bridge.indexedLegacyReadOnly(PluginArray.getAtIndex, pluginIndexQuery, getPluginIndexes, "PluginArray", .{ .null_as_undefined = true });
    pub const @"[str]" = bridge.namedIndexedLegacyReadOnly(PluginArray.getByName, getPluginNames, pluginNameQuery, "PluginArray", .{ .null_as_undefined = true });
    pub const item = bridge.function(_item, .{});
    fn _item(self: *const PluginArray, index: i32) ?*Plugin {
        if (index < 0) {
            return null;
        }
        return self.getAtIndex(@intCast(index));
    }
    pub const namedItem = bridge.function(PluginArray.getByName, .{});
    pub const symbol_iterator = bridge.iterator(PluginArray.iterator, .{});
};
