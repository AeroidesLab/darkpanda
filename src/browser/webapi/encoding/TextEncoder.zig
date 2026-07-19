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

const js = @import("../../js/js.zig");

const TextEncoder = @This();
_pad: bool = false,

pub fn init() TextEncoder {
    return .{};
}

pub fn encode(_: *const TextEncoder, value: ?js.Value, exec: *js.Execution) !js.TypedArray(u8) {
    const input = value orelse return .{ .values = "" };
    if (input.isUndefined()) return .{ .values = "" };

    return .{
        .values = try js.WebIDL.toDOMString(
            input,
            exec,
            .{ .interface = "TextEncoder", .name = "encode" },
        ),
    };
}

const EncodeIntoResult = struct {
    read: u32,
    written: u32,
};

/// UTF-8 encoding is prefix-free, so an encode-into operation can copy one
/// scalar at a time and stop before the first scalar that does not fit.  V8's
/// string-to-UTF-8 conversion replaces unpaired UTF-16 surrogates with U+FFFD,
/// which is precisely Web IDL's USVString conversion.  Four-byte UTF-8 scalars
/// consume two UTF-16 code units; every other scalar consumes one.
pub fn encodeInto(
    _: *const TextEncoder,
    source_: ?js.Value,
    destination_: ?js.Value,
    exec: *js.Execution,
) !EncodeIntoResult {
    const operation: js.WebIDL.Operation = .{ .interface = "TextEncoder", .name = "encodeInto" };
    const source_value = source_ orelse return js.WebIDL.requiredArgument(exec, operation, 2, 0);
    const destination_value = destination_ orelse return js.WebIDL.requiredArgument(exec, operation, 2, 1);

    // Generated Blink bindings convert parameters from left to right.  Keep
    // source conversion (and any user-code side effects) ahead of the typed
    // array brand check.
    const source = try js.WebIDL.toDOMString(source_value, exec, operation);
    if (!destination_value.isUint8Array()) {
        return js.WebIDL.typeError(exec, operation, "parameter 2 is not of type 'Uint8Array'.");
    }

    const destination_array = try destination_value.toZig(js.TypedArray(u8));
    const destination = @constCast(destination_array.values);

    var source_offset: usize = 0;
    var written: usize = 0;
    var read: usize = 0;
    while (source_offset < source.len) {
        const lead = source[source_offset];
        const scalar_len: usize = if (lead < 0x80)
            1
        else if (lead < 0xE0)
            2
        else if (lead < 0xF0)
            3
        else
            4;

        // toDOMString returns V8-produced, replacement-normalized UTF-8, so a
        // truncated or invalid sequence here would be an internal invariant
        // violation rather than script input.  Still guard the slice boundary.
        if (scalar_len > source.len - source_offset) return error.InvalidUtf8;
        if (scalar_len > destination.len - written) break;

        @memcpy(
            destination[written .. written + scalar_len],
            source[source_offset .. source_offset + scalar_len],
        );
        source_offset += scalar_len;
        written += scalar_len;
        read += if (scalar_len == 4) 2 else 1;
    }

    return .{ .read = @intCast(read), .written = @intCast(written) };
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(TextEncoder);

    pub const Meta = struct {
        pub const name = "TextEncoder";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
        pub const empty_with_no_proto = true;
    };

    pub const constructor = bridge.constructor(TextEncoder.init, .{});
    pub const encoding = bridge.constantAccessor("utf-8");
    pub const encode = bridge.function(TextEncoder.encode, .{ .as_typed_array = true });
    pub const encodeInto = bridge.function(TextEncoder.encodeInto, .{ .arity = 2, .required_args = 2 });
};

const testing = @import("../../../testing.zig");
test "WebApi: TextEncoder" {
    try testing.htmlRunner("encoding/text_encoder.html", .{});
}
