// Windows' UCRT does not provide a few POSIX/libquadmath entry points used by
// the shared browser sources. Keep their compatibility implementations in the
// one Windows-only shim object linked by every executable/test/DLL target.

const einval = 22;

extern "c" fn _errno() *c_int;
extern "c" fn _putenv_s(name: [*:0]const u8, value: [*:0]const u8) c_int;
extern "c" fn getenv_s(
    required_count: *usize,
    buffer: ?[*]u8,
    buffer_count: usize,
    name: [*:0]const u8,
) c_int;

fn invalidEnvironmentName(name: [*:0]const u8) bool {
    if (name[0] == 0) return true;

    var cursor = name;
    while (cursor[0] != 0) : (cursor += 1) {
        if (cursor[0] == '=') return true;
    }
    return false;
}

fn failWithErrno(err: c_int) c_int {
    _errno().* = err;
    return -1;
}

fn posixResult(ucrt_result: c_int) c_int {
    if (ucrt_result == 0) return 0;
    return failWithErrno(ucrt_result);
}

/// POSIX setenv implemented through the UCRT's process-environment API.
export fn setenv(name_arg: ?[*:0]const u8, value_arg: ?[*:0]const u8, overwrite: c_int) callconv(.c) c_int {
    const name = name_arg orelse return failWithErrno(einval);
    const value = value_arg orelse return failWithErrno(einval);
    if (invalidEnvironmentName(name)) return failWithErrno(einval);

    if (overwrite == 0) {
        // Querying through getenv_s avoids retaining a pointer into the mutable
        // environment block. UCRT provides the synchronization for both calls.
        var required_count: usize = 0;
        const query_result = getenv_s(&required_count, null, 0, name);
        if (query_result != 0) return failWithErrno(query_result);
        if (required_count != 0) return 0;
    }

    return posixResult(_putenv_s(name, value));
}

/// `_putenv_s(name, "")` removes the variable from the UCRT environment.
export fn unsetenv(name_arg: ?[*:0]const u8) callconv(.c) c_int {
    const name = name_arg orelse return failWithErrno(einval);
    if (invalidEnvironmentName(name)) return failWithErrno(einval);
    return posixResult(_putenv_s(name, ""));
}

// Zig compiler-rt provides binary128 arithmetic helpers, but does not supply
// the libquadmath-compatible truncq/roundq entry points used by the C-facing
// URL/number paths. Keep these two ABI functions bit-exact and self-contained.

const fraction_bits = 112;
const exponent_bias = 0x3fff;
const exponent_mask = 0x7fff;
const sign_mask: u128 = @as(u128, 1) << 127;
const one_bits: u128 = @as(u128, exponent_bias) << fraction_bits;

export fn truncq(value: f128) callconv(.c) f128 {
    return @bitCast(truncBits(@bitCast(value)));
}

export fn roundq(value: f128) callconv(.c) f128 {
    return @bitCast(roundBits(@bitCast(value)));
}

fn truncBits(bits: u128) u128 {
    const sign = bits & sign_mask;
    const exponent = (bits >> fraction_bits) & exponent_mask;

    // Preserve infinities, NaNs, and values whose binary representation is
    // already integral at binary128 precision.
    if (exponent == exponent_mask or exponent >= exponent_bias + fraction_bits) return bits;
    if (exponent < exponent_bias) return sign;

    const integer_exponent = exponent - exponent_bias;
    const discarded_count: u7 = @intCast(fraction_bits - integer_exponent);
    const discarded_mask = (@as(u128, 1) << discarded_count) - 1;
    return bits & ~discarded_mask;
}

fn roundBits(bits: u128) u128 {
    const sign = bits & sign_mask;
    const exponent = (bits >> fraction_bits) & exponent_mask;

    // C roundq rounds halfway cases away from zero. Preserve NaN payloads and
    // infinities exactly, including their sign bits.
    if (exponent == exponent_mask or exponent >= exponent_bias + fraction_bits) return bits;
    if (exponent < exponent_bias - 1) return sign;
    if (exponent == exponent_bias - 1) return sign | one_bits;

    const integer_exponent = exponent - exponent_bias;
    const discarded_count: u7 = @intCast(fraction_bits - integer_exponent);
    const integer_unit = @as(u128, 1) << discarded_count;
    const discarded_mask = integer_unit - 1;
    const truncated = bits & ~discarded_mask;
    const halfway = integer_unit >> 1;

    return if ((bits & discarded_mask) >= halfway)
        truncated + integer_unit
    else
        truncated;
}

test "truncq binary128 edge cases" {
    const testing = @import("std").testing;
    const negative = sign_mask;
    const half = @as(u128, exponent_bias - 1) << fraction_bits;
    const one = one_bits;
    const one_point_five = one | (@as(u128, 1) << 111);
    const infinity = @as(u128, exponent_mask) << fraction_bits;
    const nan_payload = infinity | 0x1234;

    try testing.expectEqual(@as(u128, 0), truncBits(half));
    try testing.expectEqual(negative, truncBits(negative | half));
    try testing.expectEqual(one, truncBits(one_point_five));
    try testing.expectEqual(negative | one, truncBits(negative | one_point_five));
    try testing.expectEqual(infinity, truncBits(infinity));
    try testing.expectEqual(nan_payload, truncBits(nan_payload));
}

test "roundq binary128 halfway cases are away from zero" {
    const testing = @import("std").testing;
    const negative = sign_mask;
    const half = @as(u128, exponent_bias - 1) << fraction_bits;
    const below_half = (@as(u128, exponent_bias - 2) << fraction_bits) |
        ((@as(u128, 1) << fraction_bits) - 1);
    const one = one_bits;
    const one_point_five = one | (@as(u128, 1) << 111);
    const two = @as(u128, exponent_bias + 1) << fraction_bits;

    try testing.expectEqual(@as(u128, 0), roundBits(below_half));
    try testing.expectEqual(negative, roundBits(negative | below_half));
    try testing.expectEqual(one, roundBits(half));
    try testing.expectEqual(negative | one, roundBits(negative | half));
    try testing.expectEqual(two, roundBits(one_point_five));
    try testing.expectEqual(negative | two, roundBits(negative | one_point_five));
}
