const std = @import("std");
const model = @import("model.zig");
const codec = @import("codec.zig");
const validate = @import("validate.zig");
const diagnostic = @import("diagnostic.zig");

pub const Error = codec.Error || error{
    OutOfMemory,
    InvalidDocument,
    UnknownMessage,
    UnknownMuxValue,
    MissingSignal,
    InactiveSignal,
};

pub const MessageHandle = usize;

pub const FrameKey = struct {
    bus: []const u8,
    id: u32,
    extended: bool,
};

const FrameKeyContext = struct {
    pub fn hash(_: @This(), key: FrameKey) u64 {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(key.bus);
        hasher.update(&.{0});
        hasher.update(std.mem.asBytes(&key.id));
        hasher.update(&.{@intFromBool(key.extended)});
        return hasher.final();
    }

    pub fn eql(_: @This(), left: FrameKey, right: FrameKey) bool {
        return left.id == right.id and left.extended == right.extended and std.mem.eql(u8, left.bus, right.bus);
    }
};

pub const SignalPlan = struct {
    name: []const u8,
    start_bit: u16,
    bit_length: u16,
    byte_order: model.ByteOrder,
    signal_type: model.SignalType,
    factor: []const u8,
    offset: []const u8,
    minimum: ?[]const u8,
    maximum: ?[]const u8,
    is_multiplexer: bool,
    when: []const model.MuxCondition,
    choices: []const model.Choice,
    bit_positions: []const u16,
};

pub const MessagePlan = struct {
    name: []const u8,
    bus: []const u8,
    id: u32,
    extended: bool,
    frame: model.FrameKind,
    length: u16,
    signals: []const SignalPlan,
    signal_index: std.StringHashMap(usize),
};

pub const CompiledDatabase = struct {
    arena: std.heap.ArenaAllocator,
    messages: []const MessagePlan,
    frame_index: std.HashMap(FrameKey, MessageHandle, FrameKeyContext, 80),
    name_index: std.StringHashMap(MessageHandle),

    fn allocator(self: *CompiledDatabase) std.mem.Allocator {
        return self.arena.allocator();
    }

    pub fn deinit(self: *CompiledDatabase) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn findMessage(self: *const CompiledDatabase, bus: []const u8, id: u32, extended: bool) ?MessageHandle {
        return self.frame_index.get(.{ .bus = bus, .id = id, .extended = extended });
    }

    pub fn findMessageByName(self: *const CompiledDatabase, temp_allocator: std.mem.Allocator, bus: []const u8, name: []const u8) std.mem.Allocator.Error!?MessageHandle {
        const key = try std.fmt.allocPrint(temp_allocator, "{s}\x1f{s}", .{ bus, name });
        defer temp_allocator.free(key);
        return self.name_index.get(key);
    }

    pub fn findSignal(self: *const CompiledDatabase, handle: MessageHandle, name: []const u8) Error!?usize {
        const message = try getMessage(self, handle);
        return message.signal_index.get(name);
    }

    pub fn decodeSignalRaw(self: *const CompiledDatabase, handle: MessageHandle, signal_index: usize, payload: []const u8) Error!codec.RawValue {
        const message = try getMessage(self, handle);
        if (payload.len != message.length) return error.WrongLength;
        if (signal_index >= message.signals.len) return error.UnknownMessage;
        const signal = message.signals[signal_index];
        return codec.decodeSignalRawWithPositions(&toModelSignal(signal), payload, signal.bit_positions);
    }

    pub fn decodeSignalPhysical(self: *const CompiledDatabase, handle: MessageHandle, signal_index: usize, payload: []const u8) Error!f64 {
        const signal = try getSignal(self, handle, signal_index);
        const raw = try self.decodeSignalRaw(handle, signal_index, payload);
        return codec.decodePhysical(&toModelSignal(signal), raw);
    }

    pub fn encodeSignalPhysical(self: *const CompiledDatabase, handle: MessageHandle, signal_index: usize, physical: f64, rounding: codec.RoundingPolicy) Error!codec.RawValue {
        const signal = try getSignal(self, handle, signal_index);
        return codec.encodePhysical(&toModelSignal(signal), physical, rounding);
    }

    pub fn choiceLabel(self: *const CompiledDatabase, handle: MessageHandle, signal_index: usize, raw: codec.RawValue) Error!?[]const u8 {
        const signal = try getSignal(self, handle, signal_index);
        return codec.choiceLabel(signal.choices, raw);
    }

    pub fn decodeRaw(
        self: *const CompiledDatabase,
        handle: MessageHandle,
        payload: []const u8,
        values: []codec.RawValue,
        active: []bool,
        scratch: []u8,
    ) Error!void {
        const message = try getMessage(self, handle);
        if (payload.len != message.length) return error.WrongLength;
        if (values.len < message.signals.len or active.len < message.signals.len or scratch.len < message.signals.len)
            return error.BufferTooSmall;

        for (message.signals, 0..) |signal, i|
            values[i] = try codec.decodeSignalRawWithPositions(&toModelSignal(signal), payload, signal.bit_positions);
        try ensureKnownMuxValues(message.signals, values, null);
        @memset(scratch[0..message.signals.len], 0);
        for (message.signals, 0..) |_, i| {
            active[i] = try signalIsActive(message.signals, i, values, scratch[0..message.signals.len]);
        }
    }

    pub fn encodeRaw(
        self: *const CompiledDatabase,
        handle: MessageHandle,
        inputs: []const ?codec.RawValue,
        output: []u8,
        scratch: []u8,
    ) Error!usize {
        const message = try getMessage(self, handle);
        const count = message.signals.len;
        if (inputs.len < count or output.len < message.length or scratch.len < @as(usize, message.length) + count)
            return error.BufferTooSmall;
        const raw_bytes = scratch[0..message.length];
        const active_state = scratch[message.length .. @as(usize, message.length) + count];
        @memset(active_state, 0);
        try ensureKnownMuxValues(message.signals, null, inputs);
        for (message.signals, 0..) |_, i| _ = try inputIsActive(message.signals, i, inputs, active_state);
        for (message.signals, 0..) |_, i| {
            if (active_state[i] == 2) {
                if (inputs[i] == null) return error.MissingSignal;
            } else if (inputs[i] != null) {
                return error.InactiveSignal;
            }
        }

        @memset(raw_bytes, 0);
        for (message.signals, 0..) |signal, i| {
            if (active_state[i] == 2) {
                try codec.encodeSignalRawWithPositions(&toModelSignal(signal), inputs[i].?, raw_bytes, signal.bit_positions);
            }
        }
        @memcpy(output[0..message.length], raw_bytes);
        return message.length;
    }
};

pub fn compile(doc: *const model.Document, allocator: std.mem.Allocator) Error!CompiledDatabase {
    var diagnostics: std.ArrayListUnmanaged(diagnostic.Diagnostic) = .empty;
    defer diagnostics.deinit(allocator);
    if (!try validate.validateDocument(doc, allocator, &diagnostics)) return error.InvalidDocument;

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    var messages: std.ArrayListUnmanaged(MessagePlan) = .empty;
    var frame_index = std.HashMap(FrameKey, MessageHandle, FrameKeyContext, 80).initContext(a, .{});
    var name_index = std.StringHashMap(MessageHandle).init(a);
    for (doc.messages.items, 0..) |message, message_index| {
        const bus = try a.dupe(u8, message.bus);
        const name = try a.dupe(u8, message.name);
        const id = std.fmt.parseInt(u32, message.id[2..], 16) catch return error.InvalidDocument;
        const signals = try a.alloc(SignalPlan, message.signals.items.len);
        var signal_index = std.StringHashMap(usize).init(a);
        for (message.signals.items, 0..) |signal, i| {
            if (signal.bit_length > 64) return error.UnsupportedWidth;
            const signal_name = try a.dupe(u8, signal.name);
            signals[i] = .{
                .name = signal_name,
                .start_bit = signal.start_bit,
                .bit_length = signal.bit_length,
                .byte_order = signal.byte_order,
                .signal_type = signal.signal_type,
                .factor = try a.dupe(u8, signal.factor),
                .offset = try a.dupe(u8, signal.offset),
                .minimum = if (signal.minimum) |v| try a.dupe(u8, v) else null,
                .maximum = if (signal.maximum) |v| try a.dupe(u8, v) else null,
                .is_multiplexer = signal.is_multiplexer,
                .when = try cloneConditions(a, signal.when.items),
                .choices = try cloneChoices(a, doc, signal),
                .bit_positions = try buildBitPositions(a, signal),
            };
            try signal_index.put(signal_name, i);
        }
        try messages.append(a, .{
            .name = name,
            .bus = bus,
            .id = id,
            .extended = message.extended,
            .frame = message.frame,
            .length = message.length,
            .signals = signals,
            .signal_index = signal_index,
        });
        try frame_index.put(.{ .bus = bus, .id = id, .extended = message.extended }, message_index);
        const key = try std.fmt.allocPrint(a, "{s}\x1f{s}", .{ bus, name });
        try name_index.put(key, message_index);
    }
    return .{
        .arena = arena,
        .messages = try messages.toOwnedSlice(a),
        .frame_index = frame_index,
        .name_index = name_index,
    };
}

fn buildBitPositions(a: std.mem.Allocator, signal: model.Signal) Error![]const u16 {
    const positions = try a.alloc(u16, signal.bit_length);
    var bit: u32 = signal.start_bit;
    for (positions) |*position| {
        if (bit > std.math.maxInt(u16)) return error.InvalidDocument;
        position.* = @intCast(bit);
        codec.advanceBit(signal.byte_order, &bit);
    }
    return positions;
}

fn cloneChoices(a: std.mem.Allocator, doc: *const model.Document, signal: model.Signal) std.mem.Allocator.Error![]const model.Choice {
    var source = signal.choices.items;
    if (signal.value_table) |name| {
        for (doc.value_tables.items) |table| {
            if (std.mem.eql(u8, table.name, name)) {
                source = table.choices.items;
                break;
            }
        }
    }
    const result = try a.alloc(model.Choice, source.len);
    for (source, 0..) |choice, i| {
        result[i] = .{
            .raw = try a.dupe(u8, choice.raw),
            .label = try a.dupe(u8, choice.label),
        };
    }
    return result;
}

fn cloneConditions(a: std.mem.Allocator, source: []const model.MuxCondition) std.mem.Allocator.Error![]const model.MuxCondition {
    const result = try a.alloc(model.MuxCondition, source.len);
    for (source, 0..) |condition, i| {
        const ranges = try a.dupe(model.RawRange, condition.ranges.items);
        result[i] = .{
            .selector = try a.dupe(u8, condition.selector),
            .ranges = .{ .items = ranges, .capacity = ranges.len, .pointer_stability = .{} },
        };
    }
    return result;
}

fn getMessage(db: *const CompiledDatabase, handle: MessageHandle) Error!MessagePlan {
    if (handle >= db.messages.len) return error.UnknownMessage;
    return db.messages[handle];
}

fn getSignal(db: *const CompiledDatabase, handle: MessageHandle, signal_index: usize) Error!SignalPlan {
    const message = try getMessage(db, handle);
    if (signal_index >= message.signals.len) return error.UnknownMessage;
    return message.signals[signal_index];
}

fn toModelSignal(plan: SignalPlan) model.Signal {
    return .{
        .name = plan.name,
        .start_bit = plan.start_bit,
        .bit_length = plan.bit_length,
        .byte_order = plan.byte_order,
        .signal_type = plan.signal_type,
        .factor = plan.factor,
        .offset = plan.offset,
        .minimum = plan.minimum,
        .maximum = plan.maximum,
    };
}

fn signalIsActive(signals: []const SignalPlan, index: usize, values: []const codec.RawValue, state: []u8) Error!bool {
    if (state[index] == 2) return true;
    if (state[index] == 3) return false;
    if (state[index] == 1) return error.UnknownMuxValue;
    state[index] = 1;
    for (signals[index].when) |condition| {
        const selector_index = findSignal(signals, condition.selector) orelse return error.UnknownMuxValue;
        if (!try signalIsActive(signals, selector_index, values, state)) {
            state[index] = 3;
            return false;
        }
        if (!matchesRanges(values[selector_index], condition.ranges.items)) {
            state[index] = 3;
            return false;
        }
    }
    state[index] = 2;
    return true;
}

fn inputIsActive(signals: []const SignalPlan, index: usize, inputs: []const ?codec.RawValue, state: []u8) Error!bool {
    if (state[index] == 2) return true;
    if (state[index] == 3) return false;
    if (state[index] == 1) return error.UnknownMuxValue;
    state[index] = 1;
    for (signals[index].when) |condition| {
        const selector_index = findSignal(signals, condition.selector) orelse return error.UnknownMuxValue;
        if (!try inputIsActive(signals, selector_index, inputs, state)) {
            state[index] = 3;
            return false;
        }
        const selector = inputs[selector_index] orelse return error.MissingSignal;
        if (!matchesRanges(selector, condition.ranges.items)) {
            state[index] = 3;
            return false;
        }
    }
    state[index] = 2;
    return true;
}

fn findSignal(signals: []const SignalPlan, name: []const u8) ?usize {
    for (signals, 0..) |signal, i| if (std.mem.eql(u8, signal.name, name)) return i;
    return null;
}

fn ensureKnownMuxValues(signals: []const SignalPlan, values: ?[]const codec.RawValue, inputs: ?[]const ?codec.RawValue) Error!void {
    for (signals, 0..) |selector, selector_index| {
        if (!selector.is_multiplexer) continue;
        var used = false;
        var matched = false;
        const raw = if (inputs) |provided|
            provided[selector_index] orelse return error.MissingSignal
        else
            values.?[selector_index];
        for (signals) |candidate| {
            for (candidate.when) |condition| {
                if (!std.mem.eql(u8, condition.selector, selector.name)) continue;
                used = true;
                if (matchesRanges(raw, condition.ranges.items)) matched = true;
            }
        }
        if (used and !matched) return error.UnknownMuxValue;
    }
}

fn matchesRanges(value: codec.RawValue, ranges: []const model.RawRange) bool {
    const raw: i128 = switch (value) {
        .unsigned => |number| @intCast(number),
        .signed => |number| number,
        else => return false,
    };
    for (ranges) |range| {
        const minimum = std.fmt.parseInt(i128, range.minimum, 10) catch continue;
        const maximum = std.fmt.parseInt(i128, range.maximum, 10) catch continue;
        if (raw >= minimum and raw <= maximum) return true;
    }
    return false;
}

test "compiled plans index messages and execute only active mux branches" {
    var doc = model.Document.init(std.testing.allocator);
    const a = doc.allocator();
    try doc.buses.append(a, .{ .name = "can0" });
    var message = model.Message{
        .name = "MuxMessage",
        .bus = "can0",
        .id = "0x123",
        .extended = false,
        .frame = .classic,
        .length = 2,
    };
    try message.signals.append(a, .{
        .name = "Page",
        .start_bit = 0,
        .bit_length = 2,
        .byte_order = .little_endian,
        .signal_type = .unsigned,
        .is_multiplexer = true,
    });
    var ranges_one: std.ArrayListUnmanaged(model.RawRange) = .empty;
    try ranges_one.append(a, .{ .minimum = "1", .maximum = "1" });
    var when_one: std.ArrayListUnmanaged(model.MuxCondition) = .empty;
    try when_one.append(a, .{ .selector = "Page", .ranges = ranges_one });
    try message.signals.append(a, .{
        .name = "BranchOne",
        .start_bit = 8,
        .bit_length = 8,
        .byte_order = .little_endian,
        .signal_type = .signed,
        .when = when_one,
        .value_table = "SignedValues",
    });
    var ranges_two: std.ArrayListUnmanaged(model.RawRange) = .empty;
    try ranges_two.append(a, .{ .minimum = "2", .maximum = "2" });
    var when_two: std.ArrayListUnmanaged(model.MuxCondition) = .empty;
    try when_two.append(a, .{ .selector = "Page", .ranges = ranges_two });
    try message.signals.append(a, .{
        .name = "BranchTwo",
        .start_bit = 8,
        .bit_length = 8,
        .byte_order = .little_endian,
        .signal_type = .signed,
        .when = when_two,
    });
    try doc.messages.append(a, message);
    var value_table = model.ValueTable{ .name = "SignedValues" };
    try value_table.choices.append(a, .{ .raw = "-12", .label = "Negative twelve" });
    try doc.value_tables.append(a, value_table);

    var db = try compile(&doc, std.testing.allocator);
    defer db.deinit();
    doc.deinit();
    const handle = db.findMessage("can0", 0x123, false).?;
    try std.testing.expectEqual(handle, (try db.findMessageByName(std.testing.allocator, "can0", "MuxMessage")).?);
    try std.testing.expectEqualStrings("Negative twelve", (try db.choiceLabel(handle, 1, .{ .signed = -12 })).?);

    const inputs = [_]?codec.RawValue{
        .{ .unsigned = 1 },
        .{ .signed = -12 },
        null,
    };
    var output: [2]u8 = @splat(0xaa);
    var scratch: [5]u8 = @splat(0);
    try std.testing.expectEqual(@as(usize, 2), try db.encodeRaw(handle, &inputs, &output, &scratch));
    var decoded: [3]codec.RawValue = undefined;
    var active: [3]bool = undefined;
    var state: [3]u8 = undefined;
    try db.decodeRaw(handle, &output, &decoded, &active, &state);
    try std.testing.expectEqual(@as(i64, -12), decoded[1].signed);
    try std.testing.expectEqualSlices(bool, &.{ true, true, false }, &active);
    const reference = model.Signal{
        .name = "BranchOne",
        .start_bit = 8,
        .bit_length = 8,
        .byte_order = .little_endian,
        .signal_type = .signed,
    };
    try std.testing.expectEqual((try codec.decodeSignalRaw(&reference, &output)).signed, decoded[1].signed);
    const unknown_inputs = [_]?codec.RawValue{ .{ .unsigned = 3 }, null, null };
    const before_unknown = output;
    try std.testing.expectError(error.UnknownMuxValue, db.encodeRaw(handle, &unknown_inputs, &output, &scratch));
    try std.testing.expectEqualSlices(u8, &before_unknown, &output);
}

test "compiled encoding leaves output unchanged when inputs are invalid" {
    var doc = model.Document.init(std.testing.allocator);
    defer doc.deinit();
    const a = doc.allocator();
    try doc.buses.append(a, .{ .name = "can0" });
    var message = model.Message{
        .name = "Simple",
        .bus = "can0",
        .id = "0x321",
        .extended = false,
        .frame = .classic,
        .length = 1,
    };
    try message.signals.append(a, .{
        .name = "Byte",
        .start_bit = 0,
        .bit_length = 8,
        .byte_order = .little_endian,
        .signal_type = .unsigned,
    });
    try doc.messages.append(a, message);
    var db = try compile(&doc, std.testing.allocator);
    defer db.deinit();
    var output = [_]u8{0x5a};
    var scratch: [2]u8 = @splat(0);
    try std.testing.expectError(error.MissingSignal, db.encodeRaw(0, &.{null}, &output, &scratch));
    try std.testing.expectEqual(@as(u8, 0x5a), output[0]);
}
