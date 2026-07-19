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

// Chromium's webpage-facing ModelContext API.  Private CDP/native MCP bridges
// deliberately live outside this implementation and are not part of the
// browser surface.
const std = @import("std");

const js = @import("../js/js.zig");

const AbortSignal = @import("AbortSignal.zig");
const Execution = js.Execution;

pub fn registerTypes() []const type {
    return &.{ModelContext};
}

const ModelContext = @This();

_tools: std.ArrayList(*Tool) = .{},

pub const init: ModelContext = .{};

pub const Annotations = struct {
    readOnlyHint: bool = false,
    untrustedContentHint: bool = false,
};

pub const Tool = struct {
    ctx: *ModelContext,
    name: []const u8,
    title: ?[]const u8,
    description: []const u8,
    input_schema: ?js.Object.Global,
    execute: js.Function.Global,
    annotations: Annotations,
    signal: ?*AbortSignal,

    pub fn markAborted(self: *Tool, exec: *const Execution) !void {
        try self.ctx.markAborted(self, exec);
    }
};

const ToolDict = struct {
    name: []const u8,
    title: ?[]const u8 = null,
    description: []const u8,
    inputSchema: ?js.Object.Global = null,
    execute: js.Function.Global,
    annotations: ?Annotations = null,
};

const RegisterToolOptions = struct {
    signal: ?*AbortSignal = null,
};

pub fn registerTool(
    self: *ModelContext,
    tool: ToolDict,
    options_: ?RegisterToolOptions,
    exec: *const Execution,
) !void {
    try validateName(tool.name);
    if (tool.description.len == 0) {
        return error.InvalidStateError;
    }

    const options = options_ orelse RegisterToolOptions{};

    // Per spec: a pre-aborted signal makes registration a silent no-op.
    if (options.signal) |signal| {
        if (signal._aborted) {
            return;
        }
    }

    // Reject duplicate names. The spec says `InvalidStateError`.
    for (self._tools.items) |existing| {
        if (std.mem.eql(u8, existing.name, tool.name)) {
            return error.InvalidStateError;
        }
    }

    const arena = exec.arena;
    const entry = try arena.create(Tool);
    entry.* = .{
        .ctx = self,
        .name = try arena.dupe(u8, tool.name),
        .title = if (tool.title) |t| try arena.dupe(u8, t) else null,
        .description = try arena.dupe(u8, tool.description),
        .input_schema = tool.inputSchema,
        .execute = tool.execute,
        .annotations = tool.annotations orelse .{},
        .signal = options.signal,
    };

    if (entry.signal) |s| {
        try s._dependents.append(arena, .{ .model_context_tool = entry });
    }
    try self._tools.append(arena, entry);
}

/// Snapshot of currently-registered tools.
pub fn tools(self: *ModelContext) []const *Tool {
    return self._tools.items;
}

/// Look up a tool by name. Returns null if not found or if its signal fired.
pub fn findTool(self: *ModelContext, name: []const u8) ?*Tool {
    for (self._tools.items) |t| {
        if (std.mem.eql(u8, t.name, name)) return t;
    }
    return null;
}

/// Remove a tool when its registration signal aborts.
fn markAborted(self: *ModelContext, tool: *Tool, _: *const Execution) !void {
    var i: usize = 0;
    while (i < self._tools.items.len) {
        const t = self._tools.items[i];
        if (t == tool) {
            _ = self._tools.swapRemove(i);
            return;
        }
        i += 1;
    }
}

fn validateName(name: []const u8) !void {
    if (name.len == 0 or name.len > 128) {
        return error.InvalidStateError;
    }
    for (name) |c| {
        const ok = (c >= 'a' and c <= 'z') or
            (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or
            c == '_' or c == '-' or c == '.';
        if (!ok) return error.InvalidStateError;
    }
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(ModelContext);

    pub const Meta = struct {
        pub const name = "ModelContext";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const registerTool = bridge.function(ModelContext.registerTool, .{});
};

const testing = @import("../../testing.zig");
test "WebApi: ModelContext" {
    try testing.htmlRunner("webmcp/model_context.html", .{});
}
