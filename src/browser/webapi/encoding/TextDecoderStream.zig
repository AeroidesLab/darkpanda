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
const html5ever = @import("../../parser/html5ever.zig");

const ReadableStream = @import("../streams/ReadableStream.zig");
const WritableStream = @import("../streams/WritableStream.zig");
const TransformStream = @import("../streams/TransformStream.zig");

const Execution = js.Execution;

const TextDecoderStream = @This();

_transform: *TransformStream,
_encoding_name: []const u8,
_fatal: bool,
_ignore_bom: bool,

const InitOpts = struct {
    fatal: bool = false,
    ignoreBOM: bool = false,
};

const DecodeState = struct {
    execution: *Execution,
    encoding_handle: *anyopaque,
    input: std.ArrayList(u8) = .empty,
    emitted_len: usize = 0,
    fatal: bool,
    ignore_bom: bool,
    encoding_has_bom_removal: bool,

    fn transform(raw: *anyopaque, controller: *TransformStream.DefaultController, chunk: js.Value) !void {
        const self: *DecodeState = @ptrCast(@alignCast(raw));

        // BufferSource is (ArrayBuffer or ArrayBufferView), not just
        // Uint8Array. Reading a detached source produces the required empty
        // byte sequence because V8 reports a zero byte length.
        if (!(chunk.isArrayBuffer() or chunk.isArrayBufferView())) {
            return error.InvalidBufferSource;
        }
        // toStringSmart's BufferSource branch returns the view's raw byte
        // window, including non-u8 typed arrays and DataView, without invoking
        // JavaScript string conversion.
        const bytes = try chunk.toStringSmart();
        try self.input.appendSlice(self.execution.arena, bytes);
        try self.decodeAndEnqueue(controller, false);
    }

    fn flush(raw: *anyopaque, controller: *TransformStream.DefaultController) !void {
        const self: *DecodeState = @ptrCast(@alignCast(raw));
        try self.decodeAndEnqueue(controller, true);
    }

    /// Replay the complete byte prefix through a fresh encoding_rs decoder.
    /// This preserves every stateful encoding's exact cross-chunk state while
    /// keeping the native transform arena-owned (there is no external decoder
    /// allocation to leak if script abandons an unclosed stream). Decoded
    /// prefixes are stable, so only the newly-produced suffix is enqueued.
    fn decodeAndEnqueue(
        self: *DecodeState,
        controller: *TransformStream.DefaultController,
        is_last: bool,
    ) !void {
        if (self.input.items.len == 0) return;

        const output_capacity = html5ever.encoding_max_utf8_buffer_length(
            self.encoding_handle,
            self.input.items.len + 4,
        );
        if (output_capacity == 0) return;

        const output = try self.execution.call_arena.alloc(u8, output_capacity);
        const result = html5ever.encoding_decode(
            self.encoding_handle,
            self.input.items.ptr,
            self.input.items.len,
            output.ptr,
            output.len,
            @intFromBool(is_last),
        );

        if (self.fatal and result.hadErrors()) {
            return error.InvalidEncodedData;
        }
        if (result.bytes_read != self.input.items.len) {
            return error.DecoderOutputFull;
        }

        var decoded: []const u8 = output[0..result.bytes_written];
        if (!self.ignore_bom and self.encoding_has_bom_removal and std.mem.startsWith(u8, decoded, "\u{FEFF}")) {
            decoded = decoded[3..];
        }

        if (decoded.len < self.emitted_len) {
            return error.DecoderStateRegression;
        }
        const new_output = decoded[self.emitted_len..];
        self.emitted_len = decoded.len;
        if (new_output.len != 0) {
            try controller.enqueue(.{ .string = new_output });
        }
    }
};

pub fn init(label_: ?js.Value, opts_: ?InitOpts, exec: *Execution) !TextDecoderStream {
    const label = if (label_) |value|
        if (value.isUndefined())
            "utf-8"
        else
            try js.WebIDL.toDOMString(value, exec, null)
    else
        "utf-8";

    const encoding_info = html5ever.encoding_for_label(label.ptr, label.len);
    if (!encoding_info.isValid() or std.ascii.eqlIgnoreCase(encoding_info.name(), "replacement")) {
        const message = try std.fmt.allocPrint(
            exec.call_arena,
            "The encoding label provided ('{s}') is invalid.",
            .{label},
        );
        _ = exec.js.local.?.isolate.throwException(exec.js.local.?.isolate.createRangeError(message));
        return error.TryCatchRethrow;
    }

    var encoding_name: []const u8 = try std.ascii.allocLowerString(exec.arena, encoding_info.name());
    // Chromium normalizes the historical ASCII and Latin-1 identities to the
    // Encoding Standard's windows-1252 name.
    if (std.mem.eql(u8, encoding_name, "iso-8859-1") or std.mem.eql(u8, encoding_name, "us-ascii")) {
        encoding_name = "windows-1252";
    }

    const opts = opts_ orelse InitOpts{};
    const encoding_name_raw = encoding_info.name();
    const state = try exec.arena.create(DecodeState);
    state.* = .{
        .execution = exec,
        .encoding_handle = encoding_info.handle.?,
        .fatal = opts.fatal,
        .ignore_bom = opts.ignoreBOM,
        .encoding_has_bom_removal = std.ascii.eqlIgnoreCase(encoding_name_raw, "utf-8") or
            std.ascii.eqlIgnoreCase(encoding_name_raw, "utf-16le") or
            std.ascii.eqlIgnoreCase(encoding_name_raw, "utf-16be"),
    };

    const transform = try TransformStream.initWithZigTransformer(.{
        .context = state,
        .transform = DecodeState.transform,
        .flush = DecodeState.flush,
    }, exec);

    return .{
        ._transform = transform,
        ._encoding_name = encoding_name,
        ._fatal = opts.fatal,
        ._ignore_bom = opts.ignoreBOM,
    };
}

pub fn getReadable(self: *const TextDecoderStream) *ReadableStream {
    return self._transform.getReadable();
}

pub fn getWritable(self: *const TextDecoderStream) *WritableStream {
    return self._transform.getWritable();
}

pub fn getFatal(self: *const TextDecoderStream) bool {
    return self._fatal;
}

pub fn getIgnoreBOM(self: *const TextDecoderStream) bool {
    return self._ignore_bom;
}

pub fn getEncoding(self: *const TextDecoderStream) []const u8 {
    return self._encoding_name;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(TextDecoderStream);

    pub const Meta = struct {
        pub const name = "TextDecoderStream";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(TextDecoderStream.init, .{});
    pub const encoding = bridge.accessor(TextDecoderStream.getEncoding, null, .{});
    pub const fatal = bridge.accessor(TextDecoderStream.getFatal, null, .{});
    pub const ignoreBOM = bridge.accessor(TextDecoderStream.getIgnoreBOM, null, .{});
    pub const readable = bridge.accessor(TextDecoderStream.getReadable, null, .{});
    pub const writable = bridge.accessor(TextDecoderStream.getWritable, null, .{});
};

const testing = @import("../../../testing.zig");
test "WebApi: TextDecoderStream" {
    try testing.htmlRunner("streams/text_decoder_stream.html", .{});
}
