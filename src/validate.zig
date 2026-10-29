const std = @import("std");
const model = @import("model.zig");
const diagnostic = @import("diagnostic.zig");

const Code = diagnostic.Code;
const Diag = diagnostic.Diagnostic;
const Context = diagnostic.Context;

pub fn validateDocument(
    doc: *const model.Document,
    allocator: std.mem.Allocator,
    diagnostics: *std.ArrayListUnmanaged(Diag),
) std.mem.Allocator.Error!bool {
    const initial_count = diagnostics.items.len;
    if (!std.mem.eql(u8, doc.format, "can-db")) {
        try report(diagnostics, allocator, .invalid_format, "format must be 'can-db'", .{});
    }
    if (doc.format_version != 1) {
        try report(diagnostics, allocator, .unsupported_format_version, "format_version must be 1", .{});
    }

    for (doc.buses.items, 0..) |bus, i| {
        for (doc.buses.items[0..i]) |earlier| {
            if (std.mem.eql(u8, bus.name, earlier.name))
                try report(diagnostics, allocator, .duplicate_bus_name, "bus names must be unique", .{ .bus = bus.name });
        }
        try validateAssignments(bus.attributes.items, .bus, doc, null, null, allocator, diagnostics);
    }
    for (doc.nodes.items, 0..) |node, i| {
        for (doc.nodes.items[0..i]) |earlier| {
            if (std.mem.eql(u8, node.name, earlier.name))
                try report(diagnostics, allocator, .duplicate_node_name, "node names must be unique", .{});
        }
        try validateAssignments(node.attributes.items, .node, doc, null, null, allocator, diagnostics);
    }
    for (doc.value_tables.items, 0..) |table, i| {
        for (doc.value_tables.items[0..i]) |earlier| {
            if (std.mem.eql(u8, table.name, earlier.name))
                try report(diagnostics, allocator, .duplicate_value_table_name, "value table names must be unique", .{});
        }
        try validateChoices(table.choices.items, allocator, diagnostics, .{});
    }
    for (doc.attribute_definitions.items, 0..) |definition, i| {
        for (doc.attribute_definitions.items[0..i]) |earlier| {
            if (std.mem.eql(u8, definition.name, earlier.name))
                try report(diagnostics, allocator, .duplicate_attribute_definition, "attribute definition names must be unique", .{});
        }
        if (definition.minimum) |minimum| {
            if (!validAttributeNumber(definition.value_type, minimum))
                try report(diagnostics, allocator, .invalid_attribute_value, "attribute minimum is invalid for its type", .{});
        }
        if (definition.maximum) |maximum| {
            if (!validAttributeNumber(definition.value_type, maximum))
                try report(diagnostics, allocator, .invalid_attribute_value, "attribute maximum is invalid for its type", .{});
        }
        if (definition.minimum != null and definition.maximum != null and
            compareTyped(definition.value_type, definition.minimum.?, definition.maximum.?) == .gt)
        {
            try report(diagnostics, allocator, .attribute_value_out_of_range, "attribute minimum exceeds maximum", .{});
        }
        if (definition.default) |default| {
            if (!attributeValueMatches(&definition, default)) {
                try report(diagnostics, allocator, .invalid_attribute_value, "attribute default does not match its definition", .{});
            } else if (!attributeValueInBounds(&definition, default)) {
                try report(diagnostics, allocator, .attribute_value_out_of_range, "attribute default is outside its definition bounds", .{});
            }
            for (definition.enum_labels.items, 0..) |label, label_index| {
                for (definition.enum_labels.items[0..label_index]) |earlier| {
                    if (std.mem.eql(u8, label, earlier))
                        try report(diagnostics, allocator, .duplicate_choice_label, "enum labels must be unique within an attribute definition", .{});
                }
            }
        }
    }
    try validateAssignments(doc.attributes.items, .document, doc, null, null, allocator, diagnostics);

    for (doc.messages.items, 0..) |*message, i| {
        const ctx: Context = .{ .bus = message.bus, .message = message.name };
        if (!containsBus(doc, message.bus))
            try report(diagnostics, allocator, .unknown_bus, "message references an undefined bus", ctx);
        for (doc.messages.items[0..i]) |earlier| {
            if (std.mem.eql(u8, message.bus, earlier.bus) and std.mem.eql(u8, message.name, earlier.name))
                try report(diagnostics, allocator, .duplicate_message_name, "message names must be unique within a bus", ctx);
            if (message.extended == earlier.extended and std.mem.eql(u8, message.bus, earlier.bus)) {
                const id = parseFrameId(message.id);
                const earlier_id = parseFrameId(earlier.id);
                if (id != null and earlier_id != null and id.? == earlier_id.?)
                    try report(diagnostics, allocator, .duplicate_message_id, "message identifier is already used on this bus", ctx);
            }
        }
        const frame_id = parseFrameId(message.id);
        if (frame_id == null) {
            try report(diagnostics, allocator, .invalid_message_id, "message ID must be a non-empty 0x-prefixed hexadecimal string", ctx);
        } else if ((!message.extended and frame_id.? > 0x7ff) or (message.extended and frame_id.? > 0x1fffffff)) {
            try report(diagnostics, allocator, .message_id_out_of_range, "message ID exceeds its standard or extended arbitration range", ctx);
        }
        const max_length: u16 = switch (message.frame) {
            .classic => 8,
            .fd => 64,
        };
        if (message.length > max_length)
            try report(diagnostics, allocator, .invalid_frame_length, "payload length exceeds the selected frame kind", ctx);
        try validateNodeReferences(message.transmitters.items, doc, allocator, diagnostics, ctx);
        try validateNodeReferences(message.receivers.items, doc, allocator, diagnostics, ctx);
        try validateAssignments(message.attributes.items, .message, doc, message, null, allocator, diagnostics);

        for (message.signals.items, 0..) |*signal, signal_index| {
            const signal_ctx: Context = .{ .bus = message.bus, .message = message.name, .signal = signal.name };
            for (message.signals.items[0..signal_index]) |earlier| {
                if (std.mem.eql(u8, signal.name, earlier.name))
                    try report(diagnostics, allocator, .duplicate_signal_name, "signal names must be unique within a message", signal_ctx);
            }
            if (signal.bit_length == 0)
                try report(diagnostics, allocator, .signal_width_out_of_range, "signal width must be greater than zero", signal_ctx);
            if ((signal.signal_type == .float32 and signal.bit_length != 32) or
                (signal.signal_type == .float64 and signal.bit_length != 64))
            {
                try report(diagnostics, allocator, .float_width_mismatch, "float32 and float64 signals must be exactly 32 and 64 bits", signal_ctx);
            }
            if (!isFiniteDecimal(signal.factor) or !isFiniteDecimal(signal.offset))
                try report(diagnostics, allocator, .invalid_decimal_value, "signal factor and offset must be finite decimal strings", signal_ctx);
            const minimum = if (signal.minimum) |text| parseFiniteDecimal(text) else null;
            const maximum = if (signal.maximum) |text| parseFiniteDecimal(text) else null;
            if ((signal.minimum != null and minimum == null) or (signal.maximum != null and maximum == null))
                try report(diagnostics, allocator, .invalid_decimal_value, "signal bounds must be finite decimal strings", signal_ctx);
            if (minimum != null and maximum != null and minimum.? > maximum.?)
                try report(diagnostics, allocator, .invalid_physical_bounds, "signal minimum exceeds maximum", signal_ctx);
            if (signal.bit_length > 0 and signal.bit_length <= 64 and
                !signalFitsPayload(signal, @as(u32, message.length) * 8))
            {
                try report(diagnostics, allocator, .signal_layout_out_of_bounds, "signal extends beyond the message payload", signal_ctx);
            }
            try validateNodeReferences(signal.receivers.items, doc, allocator, diagnostics, signal_ctx);
            try validateAssignments(signal.attributes.items, .signal, doc, message, signal, allocator, diagnostics);
            try validateChoices(signal.choices.items, allocator, diagnostics, signal_ctx);
            var raw_choices = signal.choices.items;
            if (signal.value_table) |table_name| {
                for (doc.value_tables.items) |table| {
                    if (std.mem.eql(u8, table.name, table_name)) raw_choices = table.choices.items;
                }
            }
            for (raw_choices) |choice| {
                const raw = parseDecimal(choice.raw);
                if (raw != null and signal.signal_type != .float32 and signal.signal_type != .float64 and
                    !inRawDomain(signal, raw.?))
                {
                    try report(diagnostics, allocator, .invalid_choice_raw, "choice value exceeds the signal's raw domain", signal_ctx);
                }
            }
            if (signal.choices.items.len > 0 and signal.value_table != null)
                try report(diagnostics, allocator, .unknown_value_table, "signal cannot define both inline choices and a value table", signal_ctx);
            if (signal.value_table) |table_name| {
                if (!containsValueTable(doc, table_name))
                    try report(diagnostics, allocator, .unknown_value_table, "signal references an undefined value table", signal_ctx);
            }
        }
        try validateMux(message, allocator, diagnostics);
        try validateOverlaps(message, allocator, diagnostics);
    }
    return diagnostics.items.len == initial_count;
}

fn report(
    diagnostics: *std.ArrayListUnmanaged(Diag),
    allocator: std.mem.Allocator,
    code: Code,
    message: []const u8,
    context: Context,
) std.mem.Allocator.Error!void {
    try diagnostics.append(allocator, .{
        .severity = .@"error",
        .code = code,
        .message = message,
        .context = context,
    });
}

fn parseFrameId(text: []const u8) ?u32 {
    if (text.len < 3 or text[0] != '0' or (text[1] != 'x' and text[1] != 'X')) return null;
    return std.fmt.parseInt(u32, text[2..], 16) catch null;
}

fn parseDecimal(text: []const u8) ?i128 {
    if (text.len == 0) return null;
    return std.fmt.parseInt(i128, text, 10) catch null;
}

fn parseFiniteDecimal(text: []const u8) ?f64 {
    const value = std.fmt.parseFloat(f64, text) catch return null;
    return if (std.math.isFinite(value)) value else null;
}

fn isFiniteDecimal(text: []const u8) bool {
    return parseFiniteDecimal(text) != null;
}

fn signalFitsPayload(signal: *const model.Signal, payload_bits: u32) bool {
    var bit: u32 = signal.start_bit;
    var count: u16 = 0;
    while (count < signal.bit_length) : (count += 1) {
        if (bit >= payload_bits) return false;
        if (signal.byte_order == .big_endian) {
            bit = if (bit % 8 == 0) bit + 15 else bit - 1;
        } else {
            bit += 1;
        }
    }
    return true;
}

fn containsBus(doc: *const model.Document, name: []const u8) bool {
    for (doc.buses.items) |bus| if (std.mem.eql(u8, bus.name, name)) return true;
    return false;
}

fn containsNode(doc: *const model.Document, name: []const u8) bool {
    for (doc.nodes.items) |node| if (std.mem.eql(u8, node.name, name)) return true;
    return false;
}

fn containsValueTable(doc: *const model.Document, name: []const u8) bool {
    for (doc.value_tables.items) |table| if (std.mem.eql(u8, table.name, name)) return true;
    return false;
}

fn validateNodeReferences(
    names: []const []const u8,
    doc: *const model.Document,
    allocator: std.mem.Allocator,
    diagnostics: *std.ArrayListUnmanaged(Diag),
    context: Context,
) std.mem.Allocator.Error!void {
    for (names) |name| {
        if (!containsNode(doc, name))
            try report(diagnostics, allocator, .unknown_node, "entity references an undefined node", context);
    }
}

fn validateChoices(
    choices: []const model.Choice,
    allocator: std.mem.Allocator,
    diagnostics: *std.ArrayListUnmanaged(Diag),
    context: Context,
) std.mem.Allocator.Error!void {
    for (choices, 0..) |choice, i| {
        if (parseDecimal(choice.raw) == null)
            try report(diagnostics, allocator, .invalid_choice_raw, "choice raw values must be decimal integers", context);
        for (choices[0..i]) |earlier| {
            if (std.mem.eql(u8, choice.raw, earlier.raw))
                try report(diagnostics, allocator, .duplicate_choice_raw, "choice raw values must be unique", context);
            if (std.mem.eql(u8, choice.label, earlier.label))
                try report(diagnostics, allocator, .duplicate_choice_label, "choice labels must be unique", context);
        }
    }
}

fn validateMux(
    message: *const model.Message,
    allocator: std.mem.Allocator,
    diagnostics: *std.ArrayListUnmanaged(Diag),
) std.mem.Allocator.Error!void {
    const signals = message.signals.items;
    const message_ctx: Context = .{ .bus = message.bus, .message = message.name };
    for (signals, 0..) |*signal, i| {
        const ctx: Context = .{ .bus = message.bus, .message = message.name, .signal = signal.name };
        if (signal.is_multiplexer) {
            if (signal.signal_type != .unsigned and signal.signal_type != .signed)
                try report(diagnostics, allocator, .invalid_mux_selector, "multiplexer must be an integer raw signal", ctx);
            for (signals[0..i]) |earlier| {
                if (earlier.is_multiplexer and std.mem.eql(u8, earlier.name, signal.name))
                    try report(diagnostics, allocator, .duplicate_selector, "multiplexer names must be unique", ctx);
            }
        }
        for (signal.when.items) |condition| {
            var selector: ?*const model.Signal = null;
            for (signals) |candidate| {
                if (std.mem.eql(u8, candidate.name, condition.selector)) {
                    selector = &candidate;
                    break;
                }
            }
            if (selector == null or !selector.?.is_multiplexer) {
                try report(diagnostics, allocator, .missing_mux_selector, "mux condition must reference a multiplexer signal", ctx);
                continue;
            }
            if (selector.?.signal_type != .unsigned and selector.?.signal_type != .signed) {
                try report(diagnostics, allocator, .invalid_mux_selector, "mux selector must have an integer raw type", ctx);
                continue;
            }
            if (condition.ranges.items.len == 0)
                try report(diagnostics, allocator, .invalid_mux_range, "mux condition requires at least one range", ctx);
            for (condition.ranges.items, 0..) |range, range_index| {
                const low = parseDecimal(range.minimum);
                const high = parseDecimal(range.maximum);
                if (low == null or high == null or low.? > high.?) {
                    try report(diagnostics, allocator, .invalid_mux_range, "mux range endpoints must be ordered decimal integers", ctx);
                    continue;
                }
                if (!inRawDomain(selector.?, low.?) or !inRawDomain(selector.?, high.?))
                    try report(diagnostics, allocator, .mux_range_out_of_domain, "mux range exceeds the selector's raw domain", ctx);
                for (condition.ranges.items[0..range_index]) |earlier| {
                    const earlier_low = parseDecimal(earlier.minimum) orelse continue;
                    const earlier_high = parseDecimal(earlier.maximum) orelse continue;
                    if (low.? <= earlier_high and earlier_low <= high.?)
                        try report(diagnostics, allocator, .invalid_mux_range, "ranges in one mux condition cannot overlap", ctx);
                }
            }
        }
        for (signal.when.items, 0..) |condition, condition_index| {
            for (signal.when.items[0..condition_index]) |earlier| {
                if (std.mem.eql(u8, condition.selector, earlier.selector))
                    try report(diagnostics, allocator, .duplicate_selector, "a signal may have only one condition per selector", ctx);
            }
        }
    }
    const state = try allocator.alloc(u8, signals.len);
    defer allocator.free(state);
    @memset(state, 0);
    for (signals, 0..) |_, i| {
        if (try visitMux(i, signals, state)) {
            try report(diagnostics, allocator, .mux_dependency_cycle, "mux selector dependencies must be acyclic", message_ctx);
            break;
        }
    }
}

fn visitMux(index: usize, signals: []const model.Signal, state: []u8) std.mem.Allocator.Error!bool {
    if (state[index] == 1) return true;
    if (state[index] == 2) return false;
    state[index] = 1;
    for (signals[index].when.items) |condition| {
        for (signals, 0..) |candidate, candidate_index| {
            if (candidate.is_multiplexer and std.mem.eql(u8, candidate.name, condition.selector)) {
                if (try visitMux(candidate_index, signals, state)) return true;
            }
        }
    }
    state[index] = 2;
    return false;
}

fn inRawDomain(signal: *const model.Signal, value: i128) bool {
    if (signal.bit_length == 0 or signal.bit_length > 64) return false;
    if (signal.signal_type == .unsigned) {
        if (value < 0) return false;
        if (signal.bit_length == 64) return @as(u128, @intCast(value)) <= std.math.maxInt(u64);
        return @as(u128, @intCast(value)) < (@as(u128, 1) << @intCast(signal.bit_length));
    }
    if (signal.signal_type == .signed) {
        const half: i128 = @as(i128, 1) << @intCast(signal.bit_length - 1);
        return value >= -half and value < half;
    }
    return false;
}

fn validateOverlaps(
    message: *const model.Message,
    allocator: std.mem.Allocator,
    diagnostics: *std.ArrayListUnmanaged(Diag),
) std.mem.Allocator.Error!void {
    const signals = message.signals.items;
    const payload_bits = @as(u32, message.length) * 8;
    for (signals, 0..) |*left, i| {
        if (left.bit_length == 0 or !signalFitsPayload(left, payload_bits)) continue;
        for (signals[i + 1 ..]) |*right| {
            if (right.bit_length == 0 or !signalFitsPayload(right, payload_bits)) continue;
            if (!conditionsAreExclusive(left, right) and signalsOverlap(left, right)) {
                try report(diagnostics, allocator, .overlapping_signals, "overlapping signal bits are not proven mutually exclusive", .{
                    .bus = message.bus,
                    .message = message.name,
                    .signal = right.name,
                });
            }
        }
    }
}

fn conditionsAreExclusive(left: *const model.Signal, right: *const model.Signal) bool {
    for (left.when.items) |left_condition| {
        for (right.when.items) |right_condition| {
            if (!std.mem.eql(u8, left_condition.selector, right_condition.selector)) continue;
            var intersects = false;
            for (left_condition.ranges.items) |a| {
                const a_low = parseDecimal(a.minimum) orelse continue;
                const a_high = parseDecimal(a.maximum) orelse continue;
                for (right_condition.ranges.items) |b| {
                    const b_low = parseDecimal(b.minimum) orelse continue;
                    const b_high = parseDecimal(b.maximum) orelse continue;
                    if (a_low <= b_high and b_low <= a_high) intersects = true;
                }
            }
            if (!intersects) return true;
        }
    }
    return false;
}

fn signalsOverlap(left: *const model.Signal, right: *const model.Signal) bool {
    var left_bit: u32 = left.start_bit;
    var left_index: u16 = 0;
    while (left_index < left.bit_length) : (left_index += 1) {
        var right_bit: u32 = right.start_bit;
        var right_index: u16 = 0;
        while (right_index < right.bit_length) : (right_index += 1) {
            if (left_bit == right_bit) return true;
            advanceBit(right.byte_order, &right_bit);
        }
        advanceBit(left.byte_order, &left_bit);
    }
    return false;
}

fn advanceBit(order: model.ByteOrder, bit: *u32) void {
    if (order == .big_endian) {
        bit.* = if (bit.* % 8 == 0) bit.* + 15 else bit.* - 1;
    } else {
        bit.* += 1;
    }
}

fn validateAssignments(
    assignments: []const model.AttributeAssignment,
    scope: model.AttributeScope,
    doc: *const model.Document,
    _: ?*const model.Message,
    _: ?*const model.Signal,
    allocator: std.mem.Allocator,
    diagnostics: *std.ArrayListUnmanaged(Diag),
) std.mem.Allocator.Error!void {
    for (assignments, 0..) |assignment, i| {
        for (assignments[0..i]) |earlier| {
            if (std.mem.eql(u8, assignment.name, earlier.name))
                try report(diagnostics, allocator, .duplicate_attribute_assignment, "attribute assignments must be unique per target", .{});
        }
        var definition: ?*const model.AttributeDefinition = null;
        for (doc.attribute_definitions.items) |candidate| {
            if (std.mem.eql(u8, candidate.name, assignment.name)) {
                definition = &candidate;
                break;
            }
        }
        if (definition == null) {
            try report(diagnostics, allocator, .missing_attribute_definition, "attribute assignment has no definition", .{});
            continue;
        }
        if (definition.?.scope != scope)
            try report(diagnostics, allocator, .attribute_scope_mismatch, "attribute definition scope does not match its target", .{});
        if (!attributeValueMatches(definition.?, assignment.value)) {
            try report(diagnostics, allocator, .invalid_attribute_value, "attribute value does not match its definition", .{});
        } else if (!attributeValueInBounds(definition.?, assignment.value)) {
            try report(diagnostics, allocator, .attribute_value_out_of_range, "attribute assignment is outside its definition bounds", .{});
        }
    }
}

fn attributeValueMatches(definition: *const model.AttributeDefinition, value: model.AttributeValue) bool {
    return switch (value) {
        .integer => |text| definition.value_type == .integer and validAttributeNumber(.integer, text),
        .hex => |text| definition.value_type == .hex and validAttributeNumber(.hex, text),
        .float => |text| definition.value_type == .float and validAttributeNumber(.float, text),
        .string => definition.value_type == .string,
        .enum_index => |index| definition.value_type == .@"enum" and index < definition.enum_labels.items.len,
    };
}

fn validAttributeNumber(value_type: model.AttributeType, text: []const u8) bool {
    return switch (value_type) {
        .integer => parseDecimal(text) != null,
        .hex => parseHex(text) != null,
        .float => blk: {
            const value = std.fmt.parseFloat(f64, text) catch break :blk false;
            break :blk std.math.isFinite(value);
        },
        .string, .@"enum" => false,
    };
}

fn parseHex(text: []const u8) ?u64 {
    if (text.len < 3 or text[0] != '0' or (text[1] != 'x' and text[1] != 'X')) return null;
    return std.fmt.parseInt(u64, text[2..], 16) catch null;
}

fn compareTyped(value_type: model.AttributeType, left: []const u8, right: []const u8) ?std.math.Order {
    return switch (value_type) {
        .integer => if (parseDecimal(left)) |a| if (parseDecimal(right)) |b| std.math.order(a, b) else null else null,
        .hex => if (parseHex(left)) |a| if (parseHex(right)) |b| std.math.order(a, b) else null else null,
        .float => if (parseFiniteDecimal(left)) |a| if (parseFiniteDecimal(right)) |b| std.math.order(a, b) else null else null,
        .string, .@"enum" => null,
    };
}

fn attributeValueInBounds(definition: *const model.AttributeDefinition, value: model.AttributeValue) bool {
    const text: ?[]const u8 = switch (value) {
        .integer => |v| v,
        .hex => |v| v,
        .float => |v| v,
        .string, .enum_index => null,
    };
    if (text) |numeric_text| {
        if (definition.minimum) |minimum| {
            const order = compareTyped(definition.value_type, numeric_text, minimum) orelse return false;
            if (order == .lt) return false;
        }
        if (definition.maximum) |maximum| {
            const order = compareTyped(definition.value_type, numeric_text, maximum) orelse return false;
            if (order == .gt) return false;
        }
    }
    if (value == .enum_index) return value.enum_index < definition.enum_labels.items.len;
    return true;
}
test "validates identifiers, frame limits, and signal bounds" {
    var doc = model.Document.init(std.testing.allocator);
    defer doc.deinit();
    const arena = doc.allocator();

    try doc.buses.append(arena, .{ .name = "can0" });
    var message = model.Message{
        .name = "M",
        .bus = "can0",
        .id = "0x800",
        .extended = false,
        .frame = .classic,
        .length = 1,
    };
    try message.signals.append(arena, .{
        .name = "PastEnd",
        .start_bit = 7,
        .bit_length = 2,
        .byte_order = .little_endian,
        .signal_type = .unsigned,
    });
    try doc.messages.append(arena, message);

    var diagnostics: std.ArrayListUnmanaged(Diag) = .empty;
    defer diagnostics.deinit(std.testing.allocator);
    try std.testing.expect(!try validateDocument(&doc, std.testing.allocator, &diagnostics));
    try std.testing.expect(hasCode(&diagnostics, .message_id_out_of_range));
    try std.testing.expect(hasCode(&diagnostics, .signal_layout_out_of_bounds));
}

test "allows overlapping branches only when their mux ranges are disjoint" {
    var doc = model.Document.init(std.testing.allocator);
    defer doc.deinit();
    const arena = doc.allocator();
    var message = model.Message{
        .name = "Mux",
        .bus = "can0",
        .id = "0x100",
        .extended = false,
        .frame = .classic,
        .length = 1,
    };
    try message.signals.append(arena, .{
        .name = "Page",
        .start_bit = 0,
        .bit_length = 2,
        .byte_order = .little_endian,
        .signal_type = .unsigned,
        .is_multiplexer = true,
    });
    var one_ranges: std.ArrayListUnmanaged(model.RawRange) = .empty;
    try one_ranges.append(arena, .{ .minimum = "0", .maximum = "0" });
    var one_conditions: std.ArrayListUnmanaged(model.MuxCondition) = .empty;
    try one_conditions.append(arena, .{ .selector = "Page", .ranges = one_ranges });
    try message.signals.append(arena, .{
        .name = "One",
        .start_bit = 2,
        .bit_length = 3,
        .byte_order = .little_endian,
        .signal_type = .unsigned,
        .when = one_conditions,
    });
    var two_ranges: std.ArrayListUnmanaged(model.RawRange) = .empty;
    try two_ranges.append(arena, .{ .minimum = "1", .maximum = "1" });
    var two_conditions: std.ArrayListUnmanaged(model.MuxCondition) = .empty;
    try two_conditions.append(arena, .{ .selector = "Page", .ranges = two_ranges });
    try message.signals.append(arena, .{
        .name = "Two",
        .start_bit = 2,
        .bit_length = 3,
        .byte_order = .little_endian,
        .signal_type = .unsigned,
        .when = two_conditions,
    });
    try doc.buses.append(arena, .{ .name = "can0" });
    try doc.messages.append(arena, message);

    var diagnostics: std.ArrayListUnmanaged(Diag) = .empty;
    defer diagnostics.deinit(std.testing.allocator);
    try std.testing.expect(try validateDocument(&doc, std.testing.allocator, &diagnostics));
    try std.testing.expect(!hasCode(&diagnostics, .overlapping_signals));
}

fn hasCode(diagnostics: *const std.ArrayListUnmanaged(Diag), code: Code) bool {
    for (diagnostics.items) |entry| if (entry.code == code) return true;
    return false;
}
