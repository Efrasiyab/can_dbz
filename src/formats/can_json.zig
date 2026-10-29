const std = @import("std");
const model = @import("../model.zig");
const diagnostic = @import("../diagnostic.zig");
const validate = @import("../validate.zig");

pub const ParseError = error{ OutOfMemory, InvalidJson, InvalidDocument };

const JsonValue = std.json.Value;
const Diag = diagnostic.Diagnostic;

pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) ParseError!model.Document {
    var diagnostics: std.ArrayListUnmanaged(Diag) = .empty;
    defer diagnostics.deinit(allocator);
    return parseWithDiagnostics(allocator, bytes, &diagnostics);
}

pub fn parseWithDiagnostics(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    diagnostics: *std.ArrayListUnmanaged(Diag),
) ParseError!model.Document {
    var doc = model.Document.init(allocator);
    errdefer doc.deinit();
    const arena = doc.allocator();

    const root = std.json.parseFromSliceLeaky(JsonValue, arena, bytes, .{
        .duplicate_field_behavior = .@"error",
        .parse_numbers = false,
    }) catch {
        try addDiagnostic(diagnostics, allocator, .invalid_json, "input is not valid strict JSON");
        return error.InvalidJson;
    };
    if (root != .object) return invalid(diagnostics, allocator, .invalid_field_type, "top-level value must be an object");
    try checkFields(root.object, &.{
        "format",                "format_version", "name", "description", "buses", "nodes", "messages",
        "attribute_definitions", "value_tables",   "dbc",  "extensions",
    }, diagnostics, allocator);
    doc.format = try requiredString(root.object, "format", diagnostics, allocator);
    doc.format_version = try requiredU32(root.object, "format_version", diagnostics, allocator);
    doc.name = try optionalString(root.object, "name", diagnostics, allocator);
    doc.description = try optionalString(root.object, "description", diagnostics, allocator);
    doc.dbc = try optionalObject(root.object, "dbc", diagnostics, allocator);
    doc.extensions = try optionalObject(root.object, "extensions", diagnostics, allocator);

    try parseAttributeDefinitions(&doc, root.object, diagnostics, allocator);
    try parseValueTables(&doc, root.object, diagnostics, allocator);
    if (get(root.object, "buses")) |buses| try parseBuses(&doc, buses, diagnostics, allocator);
    if (get(root.object, "nodes")) |nodes| try parseNodes(&doc, nodes, diagnostics, allocator);
    const messages = get(root.object, "messages") orelse return invalid(diagnostics, allocator, .missing_field, "required field 'messages' is missing");
    try parseMessages(&doc, messages, diagnostics, allocator);

    const first_validation_diagnostic = diagnostics.items.len;
    if (!try validate.validateDocument(&doc, allocator, diagnostics)) {
        for (diagnostics.items[first_validation_diagnostic..]) |*entry| entry.context = .{};
        return error.InvalidDocument;
    }
    return doc;
}

pub fn write(allocator: std.mem.Allocator, doc: *const model.Document) std.mem.Allocator.Error![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var root = try object(a);
    try put(&root, a, "format", .{ .string = doc.format });
    try put(&root, a, "format_version", .{ .integer = doc.format_version });
    if (doc.name) |value| try put(&root, a, "name", .{ .string = value });
    if (doc.description) |value| try put(&root, a, "description", .{ .string = value });
    if (doc.buses.items.len > 0) try put(&root, a, "buses", try writeBuses(a, doc.buses.items));
    if (doc.nodes.items.len > 0) try put(&root, a, "nodes", try writeNodes(a, doc.nodes.items));
    if (doc.attribute_definitions.items.len > 0) try put(&root, a, "attribute_definitions", try writeAttributeDefinitions(a, doc.attribute_definitions.items));
    if (doc.value_tables.items.len > 0) try put(&root, a, "value_tables", try writeValueTables(a, doc.value_tables.items));
    try put(&root, a, "messages", try writeMessages(a, doc.messages.items));
    if (doc.dbc) |value| try put(&root, a, "dbc", value);
    if (doc.extensions) |value| try put(&root, a, "extensions", value);
    const serialized = try std.json.Stringify.valueAlloc(allocator, JsonValue{ .object = root }, .{ .whitespace = .indent_2 });
    defer allocator.free(serialized);
    const result = try allocator.alloc(u8, serialized.len + 1);
    @memcpy(result[0..serialized.len], serialized);
    result[serialized.len] = '\n';
    return result;
}

fn parseBuses(doc: *model.Document, value: JsonValue, diagnostics: *std.ArrayListUnmanaged(Diag), allocator: std.mem.Allocator) ParseError!void {
    if (value != .array) return invalid(diagnostics, allocator, .invalid_field_type, "'buses' must be an array");
    const a = doc.allocator();
    for (value.array.items) |entry| {
        const obj = try requireObject(entry, diagnostics, allocator, "bus");
        try checkFields(obj, &.{ "name", "nominal_bitrate", "data_bitrate", "protocol", "description", "attributes", "dbc", "extensions" }, diagnostics, allocator);
        var bus = model.Bus{ .name = try requiredString(obj, "name", diagnostics, allocator) };
        bus.nominal_bitrate = try optionalU32(obj, "nominal_bitrate", diagnostics, allocator);
        bus.data_bitrate = try optionalU32(obj, "data_bitrate", diagnostics, allocator);
        bus.protocol = try optionalString(obj, "protocol", diagnostics, allocator);
        bus.description = try optionalString(obj, "description", diagnostics, allocator);
        bus.dbc = try optionalObject(obj, "dbc", diagnostics, allocator);
        bus.extensions = try optionalObject(obj, "extensions", diagnostics, allocator);
        if (get(obj, "attributes")) |attrs| try parseAssignments(a, &bus.attributes, attrs, doc, diagnostics, allocator);
        try doc.buses.append(a, bus);
    }
}

fn parseNodes(doc: *model.Document, value: JsonValue, diagnostics: *std.ArrayListUnmanaged(Diag), allocator: std.mem.Allocator) ParseError!void {
    if (value != .array) return invalid(diagnostics, allocator, .invalid_field_type, "'nodes' must be an array");
    const a = doc.allocator();
    for (value.array.items) |entry| {
        const obj = try requireObject(entry, diagnostics, allocator, "node");
        try checkFields(obj, &.{ "name", "description", "attributes", "dbc", "extensions" }, diagnostics, allocator);
        var node = model.Node{ .name = try requiredString(obj, "name", diagnostics, allocator) };
        node.description = try optionalString(obj, "description", diagnostics, allocator);
        node.dbc = try optionalObject(obj, "dbc", diagnostics, allocator);
        node.extensions = try optionalObject(obj, "extensions", diagnostics, allocator);
        if (get(obj, "attributes")) |attrs| try parseAssignments(a, &node.attributes, attrs, doc, diagnostics, allocator);
        try doc.nodes.append(a, node);
    }
}

fn parseMessages(doc: *model.Document, value: JsonValue, diagnostics: *std.ArrayListUnmanaged(Diag), allocator: std.mem.Allocator) ParseError!void {
    if (value != .array) return invalid(diagnostics, allocator, .invalid_field_type, "'messages' must be an array");
    const a = doc.allocator();
    for (value.array.items) |entry| {
        const obj = try requireObject(entry, diagnostics, allocator, "message");
        try checkFields(obj, &.{ "name", "bus", "id", "extended", "frame", "length", "description", "transmitters", "receivers", "signals", "attributes", "dbc", "extensions" }, diagnostics, allocator);
        var message = model.Message{
            .name = try requiredString(obj, "name", diagnostics, allocator),
            .bus = try requiredString(obj, "bus", diagnostics, allocator),
            .id = try requiredString(obj, "id", diagnostics, allocator),
            .extended = try requiredBool(obj, "extended", diagnostics, allocator),
            .frame = try enumValue(model.FrameKind, try requiredString(obj, "frame", diagnostics, allocator), diagnostics, allocator),
            .length = try requiredU16(obj, "length", diagnostics, allocator),
        };
        message.description = try optionalString(obj, "description", diagnostics, allocator);
        message.dbc = try optionalObject(obj, "dbc", diagnostics, allocator);
        message.extensions = try optionalObject(obj, "extensions", diagnostics, allocator);
        if (get(obj, "transmitters")) |items| try parseStringArray(a, &message.transmitters, items, diagnostics, allocator, "transmitters");
        if (get(obj, "receivers")) |items| try parseStringArray(a, &message.receivers, items, diagnostics, allocator, "receivers");
        if (get(obj, "attributes")) |attrs| try parseAssignments(a, &message.attributes, attrs, doc, diagnostics, allocator);
        const signals = get(obj, "signals") orelse return invalid(diagnostics, allocator, .missing_field, "required message field 'signals' is missing");
        try parseSignals(doc, &message, signals, diagnostics, allocator);
        try doc.messages.append(a, message);
    }
}

fn parseSignals(doc: *model.Document, message: *model.Message, value: JsonValue, diagnostics: *std.ArrayListUnmanaged(Diag), allocator: std.mem.Allocator) ParseError!void {
    if (value != .array) return invalid(diagnostics, allocator, .invalid_field_type, "message 'signals' must be an array");
    const a = doc.allocator();
    for (value.array.items) |entry| {
        const obj = try requireObject(entry, diagnostics, allocator, "signal");
        try checkFields(obj, &.{ "name", "start_bit", "bit_length", "byte_order", "type", "description", "unit", "factor", "offset", "minimum", "maximum", "receivers", "is_multiplexer", "when", "choices", "value_table", "attributes", "dbc", "extensions" }, diagnostics, allocator);
        var signal = model.Signal{
            .name = try requiredString(obj, "name", diagnostics, allocator),
            .start_bit = try requiredU16(obj, "start_bit", diagnostics, allocator),
            .bit_length = try requiredU16(obj, "bit_length", diagnostics, allocator),
            .byte_order = try enumValue(model.ByteOrder, try requiredString(obj, "byte_order", diagnostics, allocator), diagnostics, allocator),
            .signal_type = try enumValue(model.SignalType, try requiredString(obj, "type", diagnostics, allocator), diagnostics, allocator),
        };
        signal.description = try optionalString(obj, "description", diagnostics, allocator);
        signal.unit = try optionalString(obj, "unit", diagnostics, allocator);
        signal.factor = try optionalStringDefault(obj, "factor", "1", diagnostics, allocator);
        signal.offset = try optionalStringDefault(obj, "offset", "0", diagnostics, allocator);
        signal.minimum = try optionalString(obj, "minimum", diagnostics, allocator);
        signal.maximum = try optionalString(obj, "maximum", diagnostics, allocator);
        signal.is_multiplexer = try optionalBoolDefault(obj, "is_multiplexer", false, diagnostics, allocator);
        signal.value_table = try optionalString(obj, "value_table", diagnostics, allocator);
        signal.dbc = try optionalObject(obj, "dbc", diagnostics, allocator);
        signal.extensions = try optionalObject(obj, "extensions", diagnostics, allocator);
        if (get(obj, "receivers")) |items| try parseStringArray(a, &signal.receivers, items, diagnostics, allocator, "receivers");
        if (get(obj, "choices")) |choices| try parseChoices(a, &signal.choices, choices, diagnostics, allocator);
        if (get(obj, "when")) |conditions| try parseConditions(a, &signal.when, conditions, diagnostics, allocator);
        if (get(obj, "attributes")) |attrs| try parseAssignments(a, &signal.attributes, attrs, doc, diagnostics, allocator);
        try message.signals.append(a, signal);
    }
}

fn parseConditions(a: std.mem.Allocator, output: *std.ArrayListUnmanaged(model.MuxCondition), value: JsonValue, diagnostics: *std.ArrayListUnmanaged(Diag), allocator: std.mem.Allocator) ParseError!void {
    if (value != .array) return invalid(diagnostics, allocator, .invalid_field_type, "'when' must be an array");
    for (value.array.items) |entry| {
        const obj = try requireObject(entry, diagnostics, allocator, "mux condition");
        try checkFields(obj, &.{ "selector", "ranges" }, diagnostics, allocator);
        var condition = model.MuxCondition{ .selector = try requiredString(obj, "selector", diagnostics, allocator) };
        const ranges = get(obj, "ranges") orelse return invalid(diagnostics, allocator, .missing_field, "mux condition requires 'ranges'");
        if (ranges != .array) return invalid(diagnostics, allocator, .invalid_field_type, "'ranges' must be an array");
        for (ranges.array.items) |range| {
            if (range != .array or range.array.items.len != 2) return invalid(diagnostics, allocator, .invalid_field_type, "each mux range must contain two decimal strings");
            try condition.ranges.append(a, .{
                .minimum = try stringValue(range.array.items[0], diagnostics, allocator, "range minimum"),
                .maximum = try stringValue(range.array.items[1], diagnostics, allocator, "range maximum"),
            });
        }
        try output.append(a, condition);
    }
}

fn parseChoices(a: std.mem.Allocator, output: *std.ArrayListUnmanaged(model.Choice), value: JsonValue, diagnostics: *std.ArrayListUnmanaged(Diag), allocator: std.mem.Allocator) ParseError!void {
    if (value != .array) return invalid(diagnostics, allocator, .invalid_field_type, "'choices' must be an array");
    for (value.array.items) |entry| {
        const obj = try requireObject(entry, diagnostics, allocator, "choice");
        try checkFields(obj, &.{ "raw", "label" }, diagnostics, allocator);
        try output.append(a, .{
            .raw = try requiredString(obj, "raw", diagnostics, allocator),
            .label = try requiredString(obj, "label", diagnostics, allocator),
        });
    }
}

fn parseValueTables(doc: *model.Document, root: std.json.ObjectMap, diagnostics: *std.ArrayListUnmanaged(Diag), allocator: std.mem.Allocator) ParseError!void {
    const value = get(root, "value_tables") orelse return;
    if (value != .array) return invalid(diagnostics, allocator, .invalid_field_type, "'value_tables' must be an array");
    const a = doc.allocator();
    for (value.array.items) |entry| {
        const obj = try requireObject(entry, diagnostics, allocator, "value table");
        try checkFields(obj, &.{ "name", "choices" }, diagnostics, allocator);
        var table = model.ValueTable{ .name = try requiredString(obj, "name", diagnostics, allocator) };
        const choices = get(obj, "choices") orelse return invalid(diagnostics, allocator, .missing_field, "value table requires 'choices'");
        try parseChoices(a, &table.choices, choices, diagnostics, allocator);
        try doc.value_tables.append(a, table);
    }
}

fn parseAttributeDefinitions(doc: *model.Document, root: std.json.ObjectMap, diagnostics: *std.ArrayListUnmanaged(Diag), allocator: std.mem.Allocator) ParseError!void {
    const value = get(root, "attribute_definitions") orelse return;
    if (value != .array) return invalid(diagnostics, allocator, .invalid_field_type, "'attribute_definitions' must be an array");
    const a = doc.allocator();
    for (value.array.items) |entry| {
        const obj = try requireObject(entry, diagnostics, allocator, "attribute definition");
        try checkFields(obj, &.{ "name", "scope", "type", "minimum", "maximum", "labels", "default", "dbc", "extensions" }, diagnostics, allocator);
        var definition = model.AttributeDefinition{
            .name = try requiredString(obj, "name", diagnostics, allocator),
            .scope = try enumValue(model.AttributeScope, try requiredString(obj, "scope", diagnostics, allocator), diagnostics, allocator),
            .value_type = try enumValue(model.AttributeType, try requiredString(obj, "type", diagnostics, allocator), diagnostics, allocator),
            .minimum = try optionalString(obj, "minimum", diagnostics, allocator),
            .maximum = try optionalString(obj, "maximum", diagnostics, allocator),
            .dbc = try optionalObject(obj, "dbc", diagnostics, allocator),
            .extensions = try optionalObject(obj, "extensions", diagnostics, allocator),
        };
        if (get(obj, "labels")) |labels| try parseStringArray(a, &definition.enum_labels, labels, diagnostics, allocator, "labels");
        if (get(obj, "default")) |default| definition.default = try parseAttributeValue(default, definition.value_type, diagnostics, allocator);
        try doc.attribute_definitions.append(a, definition);
    }
}

fn parseAssignments(a: std.mem.Allocator, output: *std.ArrayListUnmanaged(model.AttributeAssignment), value: JsonValue, doc: *const model.Document, diagnostics: *std.ArrayListUnmanaged(Diag), allocator: std.mem.Allocator) ParseError!void {
    if (value != .object) return invalid(diagnostics, allocator, .invalid_field_type, "'attributes' must be an object");
    var it = value.object.iterator();
    while (it.next()) |entry| {
        const raw_value = entry.value_ptr.*;
        if (raw_value != .string) return invalid(diagnostics, allocator, .invalid_field_type, "attribute assignments must be JSON strings");
        var value_type: ?model.AttributeType = null;
        for (doc.attribute_definitions.items) |definition| {
            if (std.mem.eql(u8, definition.name, entry.key_ptr.*)) value_type = definition.value_type;
        }
        const typed = if (value_type) |kind|
            try parseAttributeValue(raw_value, kind, diagnostics, allocator)
        else
            model.AttributeValue{ .string = raw_value.string };
        try output.append(a, .{ .name = entry.key_ptr.*, .value = typed });
    }
}

fn parseAttributeValue(value: JsonValue, value_type: model.AttributeType, diagnostics: *std.ArrayListUnmanaged(Diag), allocator: std.mem.Allocator) ParseError!model.AttributeValue {
    const text = try stringValue(value, diagnostics, allocator, "attribute value");
    return switch (value_type) {
        .integer => .{ .integer = text },
        .hex => .{ .hex = text },
        .float => .{ .float = text },
        .string => .{ .string = text },
        .@"enum" => .{ .enum_index = std.fmt.parseInt(u32, text, 10) catch return invalid(diagnostics, allocator, .invalid_field_type, "enum attribute value must be a non-negative decimal index") },
    };
}

fn parseStringArray(a: std.mem.Allocator, output: anytype, value: JsonValue, diagnostics: *std.ArrayListUnmanaged(Diag), allocator: std.mem.Allocator, field_name: []const u8) ParseError!void {
    if (value != .array) return invalid(diagnostics, allocator, .invalid_field_type, "array field has the wrong type");
    for (value.array.items) |entry| try output.append(a, try stringValue(entry, diagnostics, allocator, field_name));
}

fn writeBuses(a: std.mem.Allocator, buses: []const model.Bus) std.mem.Allocator.Error!JsonValue {
    var array = std.json.Array.init(a);
    for (buses) |bus| {
        var obj = try object(a);
        try put(&obj, a, "name", .{ .string = bus.name });
        if (bus.nominal_bitrate) |v| try put(&obj, a, "nominal_bitrate", .{ .integer = v });
        if (bus.data_bitrate) |v| try put(&obj, a, "data_bitrate", .{ .integer = v });
        if (bus.protocol) |v| try put(&obj, a, "protocol", .{ .string = v });
        if (bus.description) |v| try put(&obj, a, "description", .{ .string = v });
        if (bus.attributes.items.len > 0) try put(&obj, a, "attributes", try writeAssignments(a, bus.attributes.items));
        if (bus.dbc) |v| try put(&obj, a, "dbc", v);
        if (bus.extensions) |v| try put(&obj, a, "extensions", v);
        try array.append(.{ .object = obj });
    }
    return .{ .array = array };
}

fn writeNodes(a: std.mem.Allocator, nodes: []const model.Node) std.mem.Allocator.Error!JsonValue {
    var array = std.json.Array.init(a);
    for (nodes) |node| {
        var obj = try object(a);
        try put(&obj, a, "name", .{ .string = node.name });
        if (node.description) |v| try put(&obj, a, "description", .{ .string = v });
        if (node.attributes.items.len > 0) try put(&obj, a, "attributes", try writeAssignments(a, node.attributes.items));
        if (node.dbc) |v| try put(&obj, a, "dbc", v);
        if (node.extensions) |v| try put(&obj, a, "extensions", v);
        try array.append(.{ .object = obj });
    }
    return .{ .array = array };
}

fn writeMessages(a: std.mem.Allocator, messages: []const model.Message) std.mem.Allocator.Error!JsonValue {
    var array = std.json.Array.init(a);
    for (messages) |message| {
        var obj = try object(a);
        try put(&obj, a, "name", .{ .string = message.name });
        try put(&obj, a, "bus", .{ .string = message.bus });
        try put(&obj, a, "id", .{ .string = message.id });
        try put(&obj, a, "extended", .{ .bool = message.extended });
        try put(&obj, a, "frame", .{ .string = @tagName(message.frame) });
        try put(&obj, a, "length", .{ .integer = message.length });
        if (message.description) |v| try put(&obj, a, "description", .{ .string = v });
        if (message.transmitters.items.len > 0) try put(&obj, a, "transmitters", try stringArray(a, message.transmitters.items));
        if (message.receivers.items.len > 0) try put(&obj, a, "receivers", try stringArray(a, message.receivers.items));
        if (message.attributes.items.len > 0) try put(&obj, a, "attributes", try writeAssignments(a, message.attributes.items));
        try put(&obj, a, "signals", try writeSignals(a, message.signals.items));
        if (message.dbc) |v| try put(&obj, a, "dbc", v);
        if (message.extensions) |v| try put(&obj, a, "extensions", v);
        try array.append(.{ .object = obj });
    }
    return .{ .array = array };
}

fn writeSignals(a: std.mem.Allocator, signals: []const model.Signal) std.mem.Allocator.Error!JsonValue {
    var array = std.json.Array.init(a);
    for (signals) |signal| {
        var obj = try object(a);
        try put(&obj, a, "name", .{ .string = signal.name });
        try put(&obj, a, "start_bit", .{ .integer = signal.start_bit });
        try put(&obj, a, "bit_length", .{ .integer = signal.bit_length });
        try put(&obj, a, "byte_order", .{ .string = @tagName(signal.byte_order) });
        try put(&obj, a, "type", .{ .string = @tagName(signal.signal_type) });
        if (signal.description) |v| try put(&obj, a, "description", .{ .string = v });
        if (signal.unit) |v| try put(&obj, a, "unit", .{ .string = v });
        if (!std.mem.eql(u8, signal.factor, "1")) try put(&obj, a, "factor", .{ .string = signal.factor });
        if (!std.mem.eql(u8, signal.offset, "0")) try put(&obj, a, "offset", .{ .string = signal.offset });
        if (signal.minimum) |v| try put(&obj, a, "minimum", .{ .string = v });
        if (signal.maximum) |v| try put(&obj, a, "maximum", .{ .string = v });
        if (signal.receivers.items.len > 0) try put(&obj, a, "receivers", try stringArray(a, signal.receivers.items));
        if (signal.is_multiplexer) try put(&obj, a, "is_multiplexer", .{ .bool = true });
        if (signal.when.items.len > 0) try put(&obj, a, "when", try writeConditions(a, signal.when.items));
        if (signal.choices.items.len > 0) try put(&obj, a, "choices", try writeChoices(a, signal.choices.items));
        if (signal.value_table) |v| try put(&obj, a, "value_table", .{ .string = v });
        if (signal.attributes.items.len > 0) try put(&obj, a, "attributes", try writeAssignments(a, signal.attributes.items));
        if (signal.dbc) |v| try put(&obj, a, "dbc", v);
        if (signal.extensions) |v| try put(&obj, a, "extensions", v);
        try array.append(.{ .object = obj });
    }
    return .{ .array = array };
}

fn writeChoices(a: std.mem.Allocator, choices: []const model.Choice) std.mem.Allocator.Error!JsonValue {
    var array = std.json.Array.init(a);
    for (choices) |choice| {
        var obj = try object(a);
        try put(&obj, a, "raw", .{ .string = choice.raw });
        try put(&obj, a, "label", .{ .string = choice.label });
        try array.append(.{ .object = obj });
    }
    return .{ .array = array };
}

fn writeConditions(a: std.mem.Allocator, conditions: []const model.MuxCondition) std.mem.Allocator.Error!JsonValue {
    var array = std.json.Array.init(a);
    for (conditions) |condition| {
        var obj = try object(a);
        try put(&obj, a, "selector", .{ .string = condition.selector });
        var ranges = std.json.Array.init(a);
        for (condition.ranges.items) |range| {
            var pair = std.json.Array.init(a);
            try pair.append(.{ .string = range.minimum });
            try pair.append(.{ .string = range.maximum });
            try ranges.append(.{ .array = pair });
        }
        try put(&obj, a, "ranges", .{ .array = ranges });
        try array.append(.{ .object = obj });
    }
    return .{ .array = array };
}

fn writeValueTables(a: std.mem.Allocator, tables: []const model.ValueTable) std.mem.Allocator.Error!JsonValue {
    var array = std.json.Array.init(a);
    for (tables) |table| {
        var obj = try object(a);
        try put(&obj, a, "name", .{ .string = table.name });
        try put(&obj, a, "choices", try writeChoices(a, table.choices.items));
        try array.append(.{ .object = obj });
    }
    return .{ .array = array };
}

fn writeAttributeDefinitions(a: std.mem.Allocator, definitions: []const model.AttributeDefinition) std.mem.Allocator.Error!JsonValue {
    var array = std.json.Array.init(a);
    for (definitions) |definition| {
        var obj = try object(a);
        try put(&obj, a, "name", .{ .string = definition.name });
        try put(&obj, a, "scope", .{ .string = @tagName(definition.scope) });
        try put(&obj, a, "type", .{ .string = @tagName(definition.value_type) });
        if (definition.minimum) |v| try put(&obj, a, "minimum", .{ .string = v });
        if (definition.maximum) |v| try put(&obj, a, "maximum", .{ .string = v });
        if (definition.enum_labels.items.len > 0) try put(&obj, a, "labels", try stringArray(a, definition.enum_labels.items));
        if (definition.default) |v| try put(&obj, a, "default", try attributeValueJson(a, v));
        if (definition.dbc) |v| try put(&obj, a, "dbc", v);
        if (definition.extensions) |v| try put(&obj, a, "extensions", v);
        try array.append(.{ .object = obj });
    }
    return .{ .array = array };
}

fn writeAssignments(a: std.mem.Allocator, assignments: []const model.AttributeAssignment) std.mem.Allocator.Error!JsonValue {
    const sorted = try a.dupe(model.AttributeAssignment, assignments);
    std.mem.sort(model.AttributeAssignment, sorted, {}, struct {
        fn less(_: void, left: model.AttributeAssignment, right: model.AttributeAssignment) bool {
            return std.mem.lessThan(u8, left.name, right.name);
        }
    }.less);
    var obj = try object(a);
    for (sorted) |assignment| try put(&obj, a, assignment.name, try attributeValueJson(a, assignment.value));
    return .{ .object = obj };
}

fn attributeValueJson(a: std.mem.Allocator, value: model.AttributeValue) std.mem.Allocator.Error!JsonValue {
    return switch (value) {
        .integer, .hex, .float, .string => |text| .{ .string = text },
        .enum_index => |index| .{ .string = try std.fmt.allocPrint(a, "{d}", .{index}) },
    };
}

fn stringArray(a: std.mem.Allocator, values: []const []const u8) std.mem.Allocator.Error!JsonValue {
    var array = std.json.Array.init(a);
    for (values) |value| try array.append(.{ .string = value });
    return .{ .array = array };
}

fn object(a: std.mem.Allocator) std.mem.Allocator.Error!std.json.ObjectMap {
    _ = a;
    return std.json.ObjectMap.empty;
}

fn put(map: *std.json.ObjectMap, a: std.mem.Allocator, key: []const u8, value: JsonValue) std.mem.Allocator.Error!void {
    try map.put(a, key, value);
}

fn get(map: std.json.ObjectMap, key: []const u8) ?JsonValue {
    return map.get(key);
}

fn requireObject(value: JsonValue, diagnostics: *std.ArrayListUnmanaged(Diag), allocator: std.mem.Allocator, label: []const u8) ParseError!std.json.ObjectMap {
    _ = label;
    if (value != .object) return invalid(diagnostics, allocator, .invalid_field_type, "expected an object");
    return value.object;
}

fn checkFields(obj: std.json.ObjectMap, allowed: []const []const u8, diagnostics: *std.ArrayListUnmanaged(Diag), allocator: std.mem.Allocator) ParseError!void {
    var it = obj.iterator();
    while (it.next()) |entry| {
        if (!contains(allowed, entry.key_ptr.*))
            return invalid(diagnostics, allocator, .unknown_core_field, "unknown core field; use 'extensions' for vendor data");
    }
}

fn contains(values: []const []const u8, key: []const u8) bool {
    for (values) |value| if (std.mem.eql(u8, value, key)) return true;
    return false;
}

fn requiredString(obj: std.json.ObjectMap, key: []const u8, diagnostics: *std.ArrayListUnmanaged(Diag), allocator: std.mem.Allocator) ParseError![]const u8 {
    const value = get(obj, key) orelse return invalid(diagnostics, allocator, .missing_field, "required string field is missing");
    return stringValue(value, diagnostics, allocator, key);
}

fn optionalString(obj: std.json.ObjectMap, key: []const u8, diagnostics: *std.ArrayListUnmanaged(Diag), allocator: std.mem.Allocator) ParseError!?[]const u8 {
    const value = get(obj, key) orelse return null;
    return try stringValue(value, diagnostics, allocator, key);
}

fn optionalStringDefault(obj: std.json.ObjectMap, key: []const u8, default: []const u8, diagnostics: *std.ArrayListUnmanaged(Diag), allocator: std.mem.Allocator) ParseError![]const u8 {
    return (try optionalString(obj, key, diagnostics, allocator)) orelse default;
}

fn stringValue(value: JsonValue, diagnostics: *std.ArrayListUnmanaged(Diag), allocator: std.mem.Allocator, label: []const u8) ParseError![]const u8 {
    _ = label;
    if (value != .string) return invalid(diagnostics, allocator, .invalid_field_type, "field must be a JSON string");
    return value.string;
}

fn requiredBool(obj: std.json.ObjectMap, key: []const u8, diagnostics: *std.ArrayListUnmanaged(Diag), allocator: std.mem.Allocator) ParseError!bool {
    const value = get(obj, key) orelse return invalid(diagnostics, allocator, .missing_field, "required boolean field is missing");
    if (value != .bool) return invalid(diagnostics, allocator, .invalid_field_type, "field must be a JSON boolean");
    return value.bool;
}

fn optionalBoolDefault(obj: std.json.ObjectMap, key: []const u8, default: bool, diagnostics: *std.ArrayListUnmanaged(Diag), allocator: std.mem.Allocator) ParseError!bool {
    const value = get(obj, key) orelse return default;
    if (value != .bool) return invalid(diagnostics, allocator, .invalid_field_type, "field must be a JSON boolean");
    return value.bool;
}

fn requiredU16(obj: std.json.ObjectMap, key: []const u8, diagnostics: *std.ArrayListUnmanaged(Diag), allocator: std.mem.Allocator) ParseError!u16 {
    const value = get(obj, key) orelse return invalid(diagnostics, allocator, .missing_field, "required integer field is missing");
    const integer = jsonInteger(value) orelse return invalid(diagnostics, allocator, .invalid_field_type, "field must be a non-negative JSON integer");
    return std.math.cast(u16, integer) orelse invalid(diagnostics, allocator, .invalid_field_type, "integer is outside the supported range");
}

fn requiredU32(obj: std.json.ObjectMap, key: []const u8, diagnostics: *std.ArrayListUnmanaged(Diag), allocator: std.mem.Allocator) ParseError!u32 {
    const value = get(obj, key) orelse return invalid(diagnostics, allocator, .missing_field, "required integer field is missing");
    const integer = jsonInteger(value) orelse return invalid(diagnostics, allocator, .invalid_field_type, "field must be a non-negative JSON integer");
    return std.math.cast(u32, integer) orelse invalid(diagnostics, allocator, .invalid_field_type, "integer is outside the supported range");
}

fn optionalU32(obj: std.json.ObjectMap, key: []const u8, diagnostics: *std.ArrayListUnmanaged(Diag), allocator: std.mem.Allocator) ParseError!?u32 {
    const value = get(obj, key) orelse return null;
    const integer = jsonInteger(value) orelse return invalid(diagnostics, allocator, .invalid_field_type, "field must be a non-negative JSON integer");
    return std.math.cast(u32, integer) orelse invalid(diagnostics, allocator, .invalid_field_type, "integer is outside the supported range");
}

fn jsonInteger(value: JsonValue) ?i64 {
    return switch (value) {
        .integer => |n| n,
        .number_string => |text| std.fmt.parseInt(i64, text, 10) catch null,
        else => null,
    };
}

fn optionalObject(obj: std.json.ObjectMap, key: []const u8, diagnostics: *std.ArrayListUnmanaged(Diag), allocator: std.mem.Allocator) ParseError!?JsonValue {
    const value = get(obj, key) orelse return null;
    if (value != .object) return invalid(diagnostics, allocator, .invalid_field_type, "metadata field must be a JSON object");
    return value;
}

fn enumValue(comptime T: type, text: []const u8, diagnostics: *std.ArrayListUnmanaged(Diag), allocator: std.mem.Allocator) ParseError!T {
    return std.meta.stringToEnum(T, text) orelse invalid(diagnostics, allocator, .invalid_enum_value, "string is not a supported enum value");
}

fn invalid(diagnostics: *std.ArrayListUnmanaged(Diag), allocator: std.mem.Allocator, code: diagnostic.Code, message: []const u8) ParseError {
    addDiagnostic(diagnostics, allocator, code, message) catch return error.OutOfMemory;
    return error.InvalidDocument;
}

fn addDiagnostic(diagnostics: *std.ArrayListUnmanaged(Diag), allocator: std.mem.Allocator, code: diagnostic.Code, message: []const u8) std.mem.Allocator.Error!void {
    try diagnostics.append(allocator, .{ .severity = .@"error", .code = code, .message = message });
}

test "CAN JSON fixture parses and writes canonically" {
    const bytes =
        \\{"format":"can-db","format_version":1,"name":"Minimal","buses":[{"name":"can0"}],"messages":[]}
    ;
    var doc = try parse(std.testing.allocator, bytes);
    defer doc.deinit();
    const output = try write(std.testing.allocator, &doc);
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings(
        \\{
        \\  "format": "can-db",
        \\  "format_version": 1,
        \\  "name": "Minimal",
        \\  "buses": [
        \\    {
        \\      "name": "can0"
        \\    }
        \\  ],
        \\  "messages": []
        \\}
        \\
    , output);
}

test "CAN JSON rejects duplicate keys and unknown core fields" {
    const duplicate = "{\"format\":\"can-db\",\"format\":\"can-db\",\"format_version\":1,\"messages\":[]}";
    var diagnostics: std.ArrayListUnmanaged(Diag) = .empty;
    defer diagnostics.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidJson, parseWithDiagnostics(std.testing.allocator, duplicate, &diagnostics));
    try std.testing.expectEqual(diagnostic.Code.invalid_json, diagnostics.items[0].code);

    diagnostics.clearRetainingCapacity();
    const unknown = "{\"format\":\"can-db\",\"format_version\":1,\"messages\":[],\"formt\":\"typo\"}";
    try std.testing.expectError(error.InvalidDocument, parseWithDiagnostics(std.testing.allocator, unknown, &diagnostics));
    try std.testing.expectEqual(diagnostic.Code.unknown_core_field, diagnostics.items[0].code);
}

test "CAN JSON round-trips signal semantics without changing declared order" {
    const bytes =
        \\{
        \\  "format": "can-db",
        \\  "format_version": 1,
        \\  "buses": [{"name": "can0"}],
        \\  "nodes": [{"name": "ECU"}],
        \\  "attribute_definitions": [{"name": "Cycle", "scope": "message", "type": "integer", "minimum": "0", "default": "10"}],
        \\  "value_tables": [{"name": "States", "choices": [{"raw": "0", "label": "Off"}]}],
        \\  "messages": [{
        \\    "name": "M", "bus": "can0", "id": "0x123", "extended": false, "frame": "classic", "length": 8,
        \\    "transmitters": ["ECU"], "attributes": {"Cycle": "10"},
        \\    "signals": [
        \\      {"name": "Page", "start_bit": 0, "bit_length": 2, "byte_order": "little_endian", "type": "unsigned", "is_multiplexer": true},
        \\      {"name": "Value", "start_bit": 8, "bit_length": 16, "byte_order": "big_endian", "type": "signed", "factor": "1e-3", "value_table": "States", "when": [{"selector": "Page", "ranges": [["0", "1"]]}]}
        \\    ]
        \\  }]
        \\}
    ;
    var doc = try parse(std.testing.allocator, bytes);
    defer doc.deinit();
    try std.testing.expectEqual(@as(usize, 2), doc.messages.items[0].signals.items.len);
    try std.testing.expectEqualStrings("Page", doc.messages.items[0].signals.items[0].name);
    try std.testing.expectEqualStrings("1e-3", doc.messages.items[0].signals.items[1].factor);

    const canonical = try write(std.testing.allocator, &doc);
    defer std.testing.allocator.free(canonical);
    var reparsed = try parse(std.testing.allocator, canonical);
    defer reparsed.deinit();
    try std.testing.expectEqual(doc.messages.items[0].frame, reparsed.messages.items[0].frame);
    try std.testing.expectEqual(doc.messages.items[0].signals.items.len, reparsed.messages.items[0].signals.items.len);
    try std.testing.expectEqualStrings("Value", reparsed.messages.items[0].signals.items[1].name);
    try std.testing.expectEqualStrings("10", reparsed.messages.items[0].attributes.items[0].value.integer);
}
