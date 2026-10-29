const std = @import("std");
const model = @import("model.zig");

pub const RawValue = union(enum) {
    unsigned: u64,
    signed: i64,
    float32: f32,
    float64: f64,
};

pub const Error = error{
    WrongLength,
    BufferTooSmall,
    UnsupportedWidth,
    WrongRawType,
    OutOfRange,
    NotRepresentable,
    ZeroFactor,
    NonFinite,
    PrecisionLoss,
};

pub const RoundingPolicy = enum {
    reject_fractional,
    nearest_ties_even,
};

pub fn decodePhysical(signal: *const model.Signal, raw: RawValue) Error!f64 {
    if (!supportedWidth(signal)) return error.UnsupportedWidth;
    if (!rawTypeMatches(signal.signal_type, raw)) return error.WrongRawType;
    const raw_number: f64 = switch (raw) {
        .unsigned => |value| blk: {
            const converted: f64 = @floatFromInt(value);
            if (converted >= @exp2(64.0)) return error.PrecisionLoss;
            if (@as(u64, @intFromFloat(converted)) != value) return error.PrecisionLoss;
            break :blk converted;
        },
        .signed => |value| blk: {
            const converted: f64 = @floatFromInt(value);
            if (converted >= @exp2(63.0) or converted < -@exp2(63.0)) return error.PrecisionLoss;
            if (@as(i64, @intFromFloat(converted)) != value) return error.PrecisionLoss;
            break :blk converted;
        },
        .float32 => |value| value,
        .float64 => |value| value,
    };
    const factor = try parseFinite(signal.factor);
    const offset = try parseFinite(signal.offset);
    const value = raw_number * factor + offset;
    if (!std.math.isFinite(value)) return error.NonFinite;
    try checkPhysicalBounds(signal, value);
    return value;
}

pub fn encodePhysical(
    signal: *const model.Signal,
    physical: f64,
    rounding: RoundingPolicy,
) Error!RawValue {
    if (!supportedWidth(signal)) return error.UnsupportedWidth;
    if (!std.math.isFinite(physical)) return error.NonFinite;
    try checkPhysicalBounds(signal, physical);
    const factor = try parseFinite(signal.factor);
    const offset = try parseFinite(signal.offset);
    if (factor == 0) return error.ZeroFactor;
    const exact_raw = (physical - offset) / factor;
    if (!std.math.isFinite(exact_raw)) return error.NonFinite;
    const raw = switch (rounding) {
        .reject_fractional => if (@trunc(exact_raw) == exact_raw) exact_raw else return error.NotRepresentable,
        .nearest_ties_even => roundTiesEven(exact_raw),
    };

    return switch (signal.signal_type) {
        .unsigned => blk: {
            if (raw < 0 or raw >= @exp2(@as(f64, @floatFromInt(signal.bit_length)))) return error.OutOfRange;
            const value: u64 = @intFromFloat(raw);
            if (@as(f64, @floatFromInt(value)) != raw) return error.PrecisionLoss;
            break :blk .{ .unsigned = value };
        },
        .signed => blk: {
            const half = @exp2(@as(f64, @floatFromInt(signal.bit_length - 1)));
            if (raw < -half or raw >= half) return error.OutOfRange;
            const value: i64 = @intFromFloat(raw);
            if (@as(f64, @floatFromInt(value)) != raw) return error.PrecisionLoss;
            break :blk .{ .signed = value };
        },
        .float32 => blk: {
            const value: f32 = @floatCast(raw);
            if (!std.math.isFinite(value) or @as(f64, value) != raw) return error.PrecisionLoss;
            break :blk .{ .float32 = value };
        },
        .float64 => .{ .float64 = raw },
    };
}

pub fn choiceLabel(choices: []const model.Choice, raw: RawValue) ?[]const u8 {
    const integer: i128 = switch (raw) {
        .unsigned => |value| @intCast(value),
        .signed => |value| value,
        else => return null,
    };
    for (choices) |choice| {
        const choice_value = std.fmt.parseInt(i128, choice.raw, 10) catch continue;
        if (choice_value == integer) return choice.label;
    }
    return null;
}

fn rawTypeMatches(signal_type: model.SignalType, raw: RawValue) bool {
    return switch (signal_type) {
        .unsigned => raw == .unsigned,
        .signed => raw == .signed,
        .float32 => raw == .float32,
        .float64 => raw == .float64,
    };
}

pub fn decodeSignalRaw(signal: *const model.Signal, payload: []const u8) Error!RawValue {
    try validateLayout(signal, payload.len);
    const bits = extractBits(signal, payload);
    return switch (signal.signal_type) {
        .unsigned => .{ .unsigned = bits },
        .signed => .{ .signed = signExtend(bits, signal.bit_length) },
        .float32 => .{ .float32 = @bitCast(@as(u32, @truncate(bits))) },
        .float64 => .{ .float64 = @bitCast(bits) },
    };
}

pub fn decodeSignalRawWithPositions(signal: *const model.Signal, payload: []const u8, positions: []const u16) Error!RawValue {
    if (!supportedWidth(signal) or positions.len != signal.bit_length)
        return error.UnsupportedWidth;
    var bits: u64 = 0;
    for (positions, 0..) |position, i| {
        if (@as(usize, position) / 8 >= payload.len) return error.BufferTooSmall;
        const bit: u1 = @truncate(payload[position / 8] >> @as(u3, @truncate(position % 8)));
        if (signal.byte_order == .little_endian) {
            bits |= @as(u64, bit) << @intCast(i);
        } else {
            bits = (bits << 1) | bit;
        }
    }
    return rawValue(signal, bits);
}

pub fn encodeSignalRaw(signal: *const model.Signal, value: RawValue, payload: []u8) Error!void {
    try validateLayout(signal, payload.len);
    const bits = try rawBits(signal, value);
    insertBits(signal, bits, payload);
}

pub fn encodeSignalRawWithPositions(signal: *const model.Signal, value: RawValue, payload: []u8, positions: []const u16) Error!void {
    if (!supportedWidth(signal) or positions.len != signal.bit_length)
        return error.UnsupportedWidth;
    for (positions) |position| if (@as(usize, position) / 8 >= payload.len) return error.BufferTooSmall;
    const bits = try rawBits(signal, value);
    for (positions, 0..) |position, i| {
        const source_index: u6 = if (signal.byte_order == .little_endian)
            @intCast(i)
        else
            @intCast(signal.bit_length - i - 1);
        const mask: u8 = @as(u8, 1) << @as(u3, @truncate(position % 8));
        if ((bits >> source_index) & 1 == 1) {
            payload[position / 8] |= mask;
        } else {
            payload[position / 8] &= ~mask;
        }
    }
}

fn rawBits(signal: *const model.Signal, value: RawValue) Error!u64 {
    const bits: u64 = switch (signal.signal_type) {
        .unsigned => switch (value) {
            .unsigned => |raw| raw,
            else => return error.WrongRawType,
        },
        .signed => switch (value) {
            .signed => |raw| @bitCast(raw),
            else => return error.WrongRawType,
        },
        .float32 => switch (value) {
            .float32 => |raw| @as(u64, @as(u32, @bitCast(raw))),
            else => return error.WrongRawType,
        },
        .float64 => switch (value) {
            .float64 => |raw| @bitCast(raw),
            else => return error.WrongRawType,
        },
    };
    if (signal.signal_type == .unsigned and signal.bit_length < 64 and bits >= (@as(u64, 1) << @intCast(signal.bit_length)))
        return error.OutOfRange;
    if (signal.signal_type == .signed and signal.bit_length < 64) {
        const signed_value: i64 = @bitCast(bits);
        const half: i64 = @as(i64, 1) << @intCast(signal.bit_length - 1);
        if (signed_value < -half or signed_value >= half) return error.OutOfRange;
    }
    return bits;
}

fn rawValue(signal: *const model.Signal, bits: u64) RawValue {
    return switch (signal.signal_type) {
        .unsigned => .{ .unsigned = bits },
        .signed => .{ .signed = signExtend(bits, signal.bit_length) },
        .float32 => .{ .float32 = @bitCast(@as(u32, @truncate(bits))) },
        .float64 => .{ .float64 = @bitCast(bits) },
    };
}

fn supportedWidth(signal: *const model.Signal) bool {
    if (signal.bit_length == 0 or signal.bit_length > 64) return false;
    return switch (signal.signal_type) {
        .float32 => signal.bit_length == 32,
        .float64 => signal.bit_length == 64,
        .unsigned, .signed => true,
    };
}

fn validateLayout(signal: *const model.Signal, payload_length: usize) Error!void {
    if (!supportedWidth(signal)) return error.UnsupportedWidth;
    var bit: u32 = signal.start_bit;
    var count: u16 = 0;
    while (count < signal.bit_length) : (count += 1) {
        if (bit / 8 >= payload_length) return error.BufferTooSmall;
        advanceBit(signal.byte_order, &bit);
    }
}

fn extractBits(signal: *const model.Signal, payload: []const u8) u64 {
    var result: u64 = 0;
    var bit: u32 = signal.start_bit;
    var i: u16 = 0;
    while (i < signal.bit_length) : (i += 1) {
        const payload_bit: u1 = @truncate(payload[bit / 8] >> @as(u3, @truncate(bit % 8)));
        if (signal.byte_order == .little_endian) {
            result |= @as(u64, payload_bit) << @intCast(i);
        } else {
            result = (result << 1) | payload_bit;
        }
        advanceBit(signal.byte_order, &bit);
    }
    return result;
}

fn insertBits(signal: *const model.Signal, bits: u64, payload: []u8) void {
    var bit: u32 = signal.start_bit;
    var i: u16 = 0;
    while (i < signal.bit_length) : (i += 1) {
        const source_index: u6 = if (signal.byte_order == .little_endian)
            @intCast(i)
        else
            @intCast(signal.bit_length - i - 1);
        const mask: u8 = @as(u8, 1) << @as(u3, @truncate(bit % 8));
        if ((bits >> source_index) & 1 == 1) {
            payload[bit / 8] |= mask;
        } else {
            payload[bit / 8] &= ~mask;
        }
        advanceBit(signal.byte_order, &bit);
    }
}

fn signExtend(value: u64, width: u16) i64 {
    if (width == 64) return @bitCast(value);
    const sign_bit = @as(u64, 1) << @intCast(width - 1);
    const extended = if (value & sign_bit == 0) value else value | (~@as(u64, 0) << @intCast(width));
    return @bitCast(extended);
}

fn parseFinite(text: []const u8) Error!f64 {
    const value = std.fmt.parseFloat(f64, text) catch return error.NotRepresentable;
    if (!std.math.isFinite(value)) return error.NonFinite;
    return value;
}

fn checkPhysicalBounds(signal: *const model.Signal, value: f64) Error!void {
    if (signal.minimum) |text| {
        const minimum = try parseFinite(text);
        if (value < minimum) return error.OutOfRange;
    }
    if (signal.maximum) |text| {
        const maximum = try parseFinite(text);
        if (value > maximum) return error.OutOfRange;
    }
}

fn roundTiesEven(value: f64) f64 {
    const lower = @floor(value);
    const fraction = value - lower;
    if (fraction < 0.5) return lower;
    if (fraction > 0.5) return lower + 1;
    return if (@mod(lower, 2) == 0) lower else lower + 1;
}

pub fn advanceBit(order: model.ByteOrder, bit: *u32) void {
    if (order == .big_endian) {
        bit.* = if (bit.* % 8 == 0) bit.* + 15 else bit.* - 1;
    } else {
        bit.* += 1;
    }
}

test "reference codec round-trips integer signals in both byte orders" {
    const widths = [_]u16{ 1, 2, 7, 8, 12, 31, 32, 63, 64 };
    for ([_]model.ByteOrder{ .little_endian, .big_endian }) |order| {
        for (widths) |width| {
            const start_bit: u16 = if (order == .big_endian) 7 else 3;
            var signal = model.Signal{
                .name = "S",
                .start_bit = start_bit,
                .bit_length = width,
                .byte_order = order,
                .signal_type = .unsigned,
            };
            var payload: [16]u8 = @splat(0xa5);
            const value: u64 = if (width == 64) 0xfedcba9876543210 else (@as(u64, 1) << @intCast(width)) - 1;
            try encodeSignalRaw(&signal, .{ .unsigned = value }, &payload);
            const actual = try decodeSignalRaw(&signal, &payload);
            try std.testing.expectEqual(value, actual.unsigned);
        }
    }
}

test "reference codec sign-extends integers and preserves float bit patterns" {
    var signed = model.Signal{
        .name = "Signed",
        .start_bit = 0,
        .bit_length = 12,
        .byte_order = .little_endian,
        .signal_type = .signed,
    };
    var payload: [2]u8 = @splat(0);
    try encodeSignalRaw(&signed, .{ .signed = -17 }, &payload);
    const decoded_signed = try decodeSignalRaw(&signed, &payload);
    try std.testing.expectEqual(@as(i64, -17), decoded_signed.signed);

    var floating = model.Signal{
        .name = "Float",
        .start_bit = 1,
        .bit_length = 32,
        .byte_order = .big_endian,
        .signal_type = .float32,
    };
    var float_payload: [5]u8 = @splat(0);
    const float_value: f32 = -123.5;
    try encodeSignalRaw(&floating, .{ .float32 = float_value }, &float_payload);
    const decoded_float = try decodeSignalRaw(&floating, &float_payload);
    try std.testing.expectEqual(@as(u32, @bitCast(float_value)), @as(u32, @bitCast(decoded_float.float32)));
}

test "reference codec reports buffer and raw-type errors" {
    const signal = model.Signal{
        .name = "TooWide",
        .start_bit = 0,
        .bit_length = 16,
        .byte_order = .little_endian,
        .signal_type = .unsigned,
    };
    try std.testing.expectError(error.BufferTooSmall, decodeSignalRaw(&signal, &.{0}));
    var payload: [2]u8 = @splat(0);
    try std.testing.expectError(error.WrongRawType, encodeSignalRaw(&signal, .{ .signed = 1 }, &payload));
}

test "physical conversion checks scaling, bounds, precision, and rounding" {
    const signal = model.Signal{
        .name = "Scaled",
        .start_bit = 0,
        .bit_length = 8,
        .byte_order = .little_endian,
        .signal_type = .unsigned,
        .factor = "0.5",
        .offset = "-1",
        .minimum = "0",
        .maximum = "126.5",
    };
    const physical = try decodePhysical(&signal, .{ .unsigned = 5 });
    try std.testing.expectEqual(@as(f64, 1.5), physical);
    try std.testing.expectError(error.WrongRawType, decodePhysical(&signal, .{ .signed = 5 }));
    try std.testing.expectError(error.NotRepresentable, encodePhysical(&signal, 1.25, .reject_fractional));
    try std.testing.expectEqual(@as(u64, 4), (try encodePhysical(&signal, 1, .reject_fractional)).unsigned);
    try std.testing.expectEqual(@as(u64, 4), (try encodePhysical(&signal, 1.25, .nearest_ties_even)).unsigned);
    try std.testing.expectError(error.OutOfRange, encodePhysical(&signal, 200, .nearest_ties_even));
    try std.testing.expectError(error.PrecisionLoss, decodePhysical(&signal, .{ .unsigned = 9007199254740993 }));
}

test "choice lookup uses exact signed and unsigned raw values" {
    const choices = [_]model.Choice{
        .{ .raw = "-1", .label = "negative" },
        .{ .raw = "18446744073709551615", .label = "maximum" },
    };
    try std.testing.expectEqualStrings("negative", choiceLabel(&choices, .{ .signed = -1 }).?);
    try std.testing.expectEqualStrings("maximum", choiceLabel(&choices, .{ .unsigned = std.math.maxInt(u64) }).?);
}

test "physical conversion handles zero factors and signed extrema explicitly" {
    const zero_factor = model.Signal{
        .name = "Constant",
        .start_bit = 0,
        .bit_length = 8,
        .byte_order = .little_endian,
        .signal_type = .unsigned,
        .factor = "0",
        .offset = "4.5",
    };
    try std.testing.expectEqual(@as(f64, 4.5), try decodePhysical(&zero_factor, .{ .unsigned = 200 }));
    try std.testing.expectError(error.ZeroFactor, encodePhysical(&zero_factor, 4.5, .reject_fractional));

    const signed_extreme = model.Signal{
        .name = "Signed64",
        .start_bit = 0,
        .bit_length = 64,
        .byte_order = .little_endian,
        .signal_type = .signed,
    };
    const minimum: i64 = std.math.minInt(i64);
    try std.testing.expectEqual(@as(f64, @floatFromInt(minimum)), try decodePhysical(&signed_extreme, .{ .signed = minimum }));
    try std.testing.expectEqual(minimum, (try encodePhysical(&signed_extreme, @floatFromInt(minimum), .reject_fractional)).signed);
    try std.testing.expectError(error.OutOfRange, encodePhysical(&.{
        .name = "Unsigned64",
        .start_bit = 0,
        .bit_length = 64,
        .byte_order = .little_endian,
        .signal_type = .unsigned,
    }, @exp2(64.0), .reject_fractional));
}
