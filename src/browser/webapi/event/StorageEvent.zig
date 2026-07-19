// Copyright (C) 2023-2026  Lightpanda (Selecy SAS)
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 or any later version.

const std = @import("std");
const lp = @import("darkpanda");

const js = @import("../../js/js.zig");
const Frame = @import("../../Frame.zig");

const Event = @import("../Event.zig");
const storage = @import("../storage/storage.zig");

const Allocator = std.mem.Allocator;
const String = lp.String;

// https://html.spec.whatwg.org/multipage/webstorage.html#the-storageevent-interface
const StorageEvent = @This();

_proto: *Event,
_key: ?[]const u8 = null,
_old_value: ?[]const u8 = null,
_new_value: ?[]const u8 = null,
_url: []const u8 = "",
_storage_area: ?*storage.Lookup = null,

const StorageEventInit = struct {
    key: ?[]const u8 = null,
    oldValue: ?[]const u8 = null,
    newValue: ?[]const u8 = null,
    url: []const u8 = "",
    storageArea: ?*storage.Lookup = null,
};

const Options = Event.inheritOptions(StorageEvent, StorageEventInit);

pub fn init(typ: []const u8, opts_: ?Options, frame: *Frame) !*StorageEvent {
    const arena = try frame.getArena(.tiny, "StorageEvent");
    errdefer frame.releaseArena(arena);
    const type_string = try String.init(arena, typ, .{});
    return initWithTrusted(arena, type_string, opts_, false, frame);
}

pub fn initTrusted(typ: String, opts_: ?Options, frame: *Frame) !*StorageEvent {
    const arena = try frame.getArena(.tiny, "StorageEvent.trusted");
    errdefer frame.releaseArena(arena);
    return initWithTrusted(arena, typ, opts_, true, frame);
}

fn initWithTrusted(
    arena: Allocator,
    typ: String,
    opts_: ?Options,
    trusted: bool,
    frame: *Frame,
) !*StorageEvent {
    const opts = opts_ orelse Options{};
    const event = try frame._factory.event(
        arena,
        typ,
        StorageEvent{
            ._proto = undefined,
            ._key = try copyOptional(arena, opts.key),
            ._old_value = try copyOptional(arena, opts.oldValue),
            ._new_value = try copyOptional(arena, opts.newValue),
            ._url = if (opts.url.len == 0) "" else try arena.dupe(u8, opts.url),
            ._storage_area = opts.storageArea,
        },
    );

    Event.populatePrototypes(event, opts, trusted);
    return event;
}

fn copyOptional(arena: Allocator, value: ?[]const u8) !?[]const u8 {
    const string = value orelse return null;
    return if (string.len == 0) "" else try arena.dupe(u8, string);
}

pub fn asEvent(self: *StorageEvent) *Event {
    return self._proto;
}

pub fn getKey(self: *const StorageEvent) ?[]const u8 {
    return self._key;
}

pub fn getOldValue(self: *const StorageEvent) ?[]const u8 {
    return self._old_value;
}

pub fn getNewValue(self: *const StorageEvent) ?[]const u8 {
    return self._new_value;
}

pub fn getURL(self: *const StorageEvent) []const u8 {
    return self._url;
}

pub fn getStorageArea(self: *const StorageEvent) ?*storage.Lookup {
    return self._storage_area;
}

const init_storage_operation: js.WebIDL.Operation = .{
    .interface = "StorageEvent",
    .name = "initStorageEvent",
};

fn optionalNullableString(raw: ?js.Value, exec: *js.Execution) !?[]const u8 {
    const value = raw orelse return null;
    // Web IDL applies an optional argument's default to explicit undefined.
    if (value.isNullOrUndefined()) return null;
    const converted: []const u8 = try (try js.WebIDL.toDOMStringValue(
        value,
        exec,
        init_storage_operation,
    )).toSlice();
    return @as(?[]const u8, converted);
}

fn optionalURL(raw: ?js.Value, exec: *js.Execution) ![]const u8 {
    const value = raw orelse return "";
    if (value.isUndefined()) return "";
    // V8's UTF-8 conversion replaces lone surrogates, which is the observable
    // USVString conversion required by StorageEvent.url.
    return (try js.WebIDL.toDOMStringValue(value, exec, init_storage_operation)).toSlice();
}

fn optionalStorageArea(raw: ?js.Value, exec: *js.Execution) !?*storage.Lookup {
    const value = raw orelse return null;
    if (value.isNullOrUndefined()) return null;
    return value.toZig(*storage.Lookup) catch
        return js.WebIDL.typeError(
            exec,
            init_storage_operation,
            "The optional 'storageArea' argument is not a Storage object.",
        );
}

pub fn initStorageEvent(
    self: *StorageEvent,
    event_type: js.DOMString,
    bubbles_: ?js.Value,
    cancelable_: ?js.Value,
    key_: ?js.Value,
    old_value_: ?js.Value,
    new_value_: ?js.Value,
    url_: ?js.Value,
    storage_area_: ?js.Value,
    exec: *js.Execution,
) !void {
    // Web IDL converts all supplied arguments before the implementation checks
    // whether the event is being dispatched.
    const bubbles = if (bubbles_) |value| value.toBool() else false;
    const cancelable = if (cancelable_) |value| value.toBool() else false;
    const converted_key = try optionalNullableString(key_, exec);
    const old_value = try optionalNullableString(old_value_, exec);
    const new_value = try optionalNullableString(new_value_, exec);
    const url = try optionalURL(url_, exec);
    const storage_area = try optionalStorageArea(storage_area_, exec);

    if (self._proto.isBeingDispatched()) return;

    const arena = self._proto._arena;
    const new_key = try copyOptional(arena, converted_key);
    const new_old_value = try copyOptional(arena, old_value);
    const new_new_value = try copyOptional(arena, new_value);
    const new_url = if (url.len == 0) "" else try arena.dupe(u8, url);

    try self._proto.initEvent(event_type.value, bubbles, cancelable);
    self._key = new_key;
    self._old_value = new_old_value;
    self._new_value = new_new_value;
    self._url = new_url;
    self._storage_area = storage_area;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(StorageEvent);

    pub const Meta = struct {
        pub const name = "StorageEvent";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(StorageEvent.init, .{});
    pub const key = bridge.accessor(StorageEvent.getKey, null, .{});
    pub const oldValue = bridge.accessor(StorageEvent.getOldValue, null, .{});
    pub const newValue = bridge.accessor(StorageEvent.getNewValue, null, .{});
    pub const url = bridge.accessor(StorageEvent.getURL, null, .{});
    pub const storageArea = bridge.accessor(StorageEvent.getStorageArea, null, .{});
    pub const initStorageEvent = bridge.function(StorageEvent.initStorageEvent, .{ .arity = 1 });
};

const testing = @import("../../../testing.zig");
test "WebApi: StorageEvent" {
    try testing.htmlRunner("storage_event.html", .{ .timeout_ms = 8000 });
}
