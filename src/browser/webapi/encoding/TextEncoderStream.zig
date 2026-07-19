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
const js = @import("../../js/js.zig");

const ReadableStream = @import("../streams/ReadableStream.zig");
const WritableStream = @import("../streams/WritableStream.zig");
const TransformStream = @import("../streams/TransformStream.zig");

const Execution = js.Execution;

const TextEncoderStream = @This();

_transform: *TransformStream,

const EncodeState = struct {
    execution: *Execution,
    pending_high_surrogate: ?u16 = null,

    const Token = union(enum) {
        utf8: []const u8,
        code_unit: u16,
    };

    fn transform(raw: *anyopaque, controller: *TransformStream.DefaultController, chunk: js.Value) !void {
        const self: *EncodeState = @ptrCast(@alignCast(raw));

        // Convert exactly once. Keeping the V8 String handle (rather than a
        // UTF-8 slice) preserves lone UTF-16 surrogate code units.
        const input = try js.WebIDL.toDOMStringValue(chunk, self.execution, null);
        if (input.lenChars() == 0) return;

        // V8's native JSON stringifier emits lone surrogates as \uXXXX while
        // leaving valid Unicode scalars as UTF-8. This gives us lossless
        // UTF-16 code-unit visibility without invoking mutable JS intrinsics.
        const json = try input.toValue().toJson(self.execution.call_arena);
        if (json.len < 2 or json[0] != '"' or json[json.len - 1] != '"') {
            return error.InvalidJSONString;
        }

        var output: std.ArrayList(u8) = .empty;
        var pending = self.pending_high_surrogate;
        self.pending_high_surrogate = null;

        var cursor: usize = 1;
        const end = json.len - 1;
        while (cursor < end) {
            const token = try nextToken(json, &cursor, end);

            if (pending) |high| {
                switch (token) {
                    .code_unit => |code_unit| {
                        if (isLowSurrogate(code_unit)) {
                            try appendSurrogatePair(&output, self.execution.call_arena, high, code_unit);
                            pending = null;
                            continue;
                        }
                    },
                    .utf8 => {},
                }
                try output.appendSlice(self.execution.call_arena, "\u{FFFD}");
                pending = null;
            }

            switch (token) {
                .utf8 => |bytes| try output.appendSlice(self.execution.call_arena, bytes),
                .code_unit => |code_unit| {
                    if (isHighSurrogate(code_unit)) {
                        pending = code_unit;
                    } else if (isLowSurrogate(code_unit)) {
                        try output.appendSlice(self.execution.call_arena, "\u{FFFD}");
                    } else {
                        try appendCodePoint(&output, self.execution.call_arena, code_unit);
                    }
                },
            }
        }

        self.pending_high_surrogate = pending;
        if (output.items.len != 0) {
            try controller.enqueue(.{ .uint8array = .{ .values = output.items } });
        }
    }

    fn flush(raw: *anyopaque, controller: *TransformStream.DefaultController) !void {
        const self: *EncodeState = @ptrCast(@alignCast(raw));
        if (self.pending_high_surrogate == null) return;
        self.pending_high_surrogate = null;
        try controller.enqueue(.{ .uint8array = .{ .values = "\u{FFFD}" } });
    }

    fn nextToken(json: []const u8, cursor: *usize, end: usize) !Token {
        const start = cursor.*;
        if (json[start] != '\\') {
            var i = start + 1;
            while (i < end and json[i] != '\\') : (i += 1) {}
            cursor.* = i;
            return .{ .utf8 = json[start..i] };
        }

        if (start + 1 >= end) return error.InvalidJSONString;
        const escaped = json[start + 1];
        cursor.* = start + 2;
        return switch (escaped) {
            '"' => .{ .code_unit = '"' },
            '\\' => .{ .code_unit = '\\' },
            '/' => .{ .code_unit = '/' },
            'b' => .{ .code_unit = 0x08 },
            'f' => .{ .code_unit = 0x0c },
            'n' => .{ .code_unit = '\n' },
            'r' => .{ .code_unit = '\r' },
            't' => .{ .code_unit = '\t' },
            'u' => blk: {
                if (cursor.* + 4 > end) return error.InvalidJSONString;
                const value = std.fmt.parseInt(u16, json[cursor.* .. cursor.* + 4], 16) catch {
                    return error.InvalidJSONString;
                };
                cursor.* += 4;
                break :blk .{ .code_unit = value };
            },
            else => error.InvalidJSONString,
        };
    }

    fn appendSurrogatePair(output: *std.ArrayList(u8), allocator: std.mem.Allocator, high: u16, low: u16) !void {
        const scalar: u21 = @intCast(0x10000 +
            ((@as(u32, high) - 0xd800) << 10) +
            (@as(u32, low) - 0xdc00));
        try appendCodePoint(output, allocator, scalar);
    }

    fn appendCodePoint(output: *std.ArrayList(u8), allocator: std.mem.Allocator, scalar: u21) !void {
        var bytes: [4]u8 = undefined;
        const len = try std.unicode.utf8Encode(scalar, &bytes);
        try output.appendSlice(allocator, bytes[0..len]);
    }

    fn isHighSurrogate(value: u16) bool {
        return value >= 0xd800 and value <= 0xdbff;
    }

    fn isLowSurrogate(value: u16) bool {
        return value >= 0xdc00 and value <= 0xdfff;
    }
};

pub fn init(exec: *Execution) !TextEncoderStream {
    const state = try exec.arena.create(EncodeState);
    state.* = .{ .execution = exec };
    const transform = try TransformStream.initWithZigTransformer(.{
        .context = state,
        .transform = EncodeState.transform,
        .flush = EncodeState.flush,
    }, exec);
    return .{
        ._transform = transform,
    };
}

pub fn getReadable(self: *const TextEncoderStream) *ReadableStream {
    return self._transform.getReadable();
}

pub fn getWritable(self: *const TextEncoderStream) *WritableStream {
    return self._transform.getWritable();
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(TextEncoderStream);

    pub const Meta = struct {
        pub const name = "TextEncoderStream";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(TextEncoderStream.init, .{});
    pub const encoding = bridge.constantAccessor("utf-8");
    pub const readable = bridge.accessor(TextEncoderStream.getReadable, null, .{});
    pub const writable = bridge.accessor(TextEncoderStream.getWritable, null, .{});
};

const testing = @import("../../../testing.zig");
test "WebApi: TextEncoderStream" {
    try testing.htmlRunner("streams/transform_stream.html", .{});
}
