// Copyright (C) 2023-2026 Lightpanda (Selecy SAS)
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

const js = @import("../js/js.zig");
const Execution = js.Execution;

pub fn registerTypes() []const type {
    return &.{StorageManager};
}

const StorageManager = @This();

// Give the empty dictionary a named struct type. Zig infers an untyped empty
// literal as an empty tuple and the JS bridge consequently exposes
// it as `[]`, whereas Web IDL dictionaries are ordinary objects.
const UsageDetails = struct {};

_pad: bool = false,

pub fn estimate(_: *const StorageManager, exec: *const Execution) !js.Promise {
    // StorageEstimate is a Web IDL dictionary, not an interface. Blink
    // resolves this promise with a fresh ordinary object whose dictionary
    // members are own, writable/enumerable/configurable data properties in
    // lexicographic member order. Keeping it as a Zig JsApi type would expose
    // an internal prototype and accessor descriptors that Chrome does not.
    return exec.js.local.?.resolvePromise(.{
        .quota = @as(u64, 1024 * 1024 * 1024), // 1 GiB
        .usage = @as(u64, 0),
        .usageDetails = UsageDetails{},
    });
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(StorageManager);
    pub const Meta = struct {
        pub const name = "StorageManager";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
        pub const empty_with_no_proto = true;
    };
    pub const estimate = bridge.function(StorageManager.estimate, .{});
};
