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

const js = @import("js.zig");
const v8 = js.v8;

const PromiseRejection = @This();

local: *const js.Local,
promise_handle: *const v8.Promise,
reason_handle: ?*const v8.Value,

pub fn init(local: *const js.Local, handle: *const v8.PromiseRejectMessage) PromiseRejection {
    return .{
        .local = local,
        .promise_handle = v8.v8__PromiseRejectMessage__GetPromise(handle).?,
        .reason_handle = v8.v8__PromiseRejectMessage__GetValue(handle),
    };
}

pub fn promise(self: PromiseRejection) js.Promise {
    return .{
        .local = self.local,
        .handle = self.promise_handle,
    };
}

pub fn reason(self: PromiseRejection) ?js.Value {
    const value_handle = self.reason_handle orelse return null;

    return .{
        .local = self.local,
        .handle = value_handle,
    };
}

pub fn persist(self: PromiseRejection) !Global {
    const promise_global = try self.promise().persist();
    errdefer promise_global.deinit();
    return .{
        .promise = promise_global,
        .reason = if (self.reason()) |reason_value| try reason_value.persist() else null,
    };
}

pub const Global = struct {
    promise: js.Promise.Global,
    reason: ?js.Value.Global,

    pub fn deinit(self: Global) void {
        if (self.reason) |reason_global| reason_global.deinit();
        self.promise.deinit();
    }

    pub fn local(self: Global, local_: *const js.Local) ?PromiseRejection {
        const promise_handle: *const v8.Promise = @ptrCast(
            v8.v8__Global__Get(&self.promise.slot.handle, local_.isolate.handle) orelse return null,
        );
        const reason_handle: ?*const v8.Value = if (self.reason) |reason_global|
            @ptrCast(v8.v8__Global__Get(&reason_global.slot.handle, local_.isolate.handle) orelse return null)
        else
            null;
        return .{
            .local = local_,
            .promise_handle = promise_handle,
            .reason_handle = reason_handle,
        };
    }

    pub fn isPromise(self: Global, promise_handle: *const v8.Promise) bool {
        return v8.v8__Global__IsEqual(&self.promise.slot.handle, @ptrCast(promise_handle));
    }

    pub fn isCollected(self: Global, isolate: js.Isolate) bool {
        return v8.v8__Global__Get(&self.promise.slot.handle, isolate.handle) == null;
    }

    pub fn hasHandler(self: Global, isolate: js.Isolate) bool {
        const promise_handle: *const v8.Promise = @ptrCast(
            v8.v8__Global__Get(&self.promise.slot.handle, isolate.handle) orelse return true,
        );
        return v8.v8__Promise__HasHandler(promise_handle);
    }

    pub fn makeWeak(self: Global) void {
        v8.v8__Global__SetWeak(&self.promise.slot.handle);
        if (self.reason) |reason_global| v8.v8__Global__SetWeak(&reason_global.slot.handle);
    }

    pub fn makeStrong(self: Global) void {
        v8.v8__Global__ClearWeak(&self.promise.slot.handle);
        if (self.reason) |reason_global| v8.v8__Global__ClearWeak(&reason_global.slot.handle);
    }
};
