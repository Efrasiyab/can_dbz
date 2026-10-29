const std = @import("std");
const can_dbz = @import("can_dbz");

const fixture = @embedFile("fixtures/minimal.can.json");

test "minimal CAN JSON fixture has the expected format header" {
    var parsed = try can_dbz.formats.can_json.parse(std.testing.allocator, fixture);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("can-db", parsed.format);
    try std.testing.expectEqual(@as(u32, 1), parsed.format_version);
    try std.testing.expectEqual(@as(usize, 0), parsed.messages.items.len);
}

test "new document passes baseline validation" {
    var document = can_dbz.model.Document.init(std.testing.allocator);
    defer document.deinit();

    var diagnostics: std.ArrayListUnmanaged(can_dbz.diagnostic.Diagnostic) = .empty;
    defer diagnostics.deinit(std.testing.allocator);

    try std.testing.expect(try can_dbz.validate.validateDocument(&document, std.testing.allocator, &diagnostics));
}

test "CAN JSON golden fixture round-trips and retains signal order" {
    var doc = try can_dbz.formats.can_json.parse(std.testing.allocator, @embedFile("fixtures/golden.can.json"));
    defer doc.deinit();
    const output = try can_dbz.formats.can_json.write(std.testing.allocator, &doc);
    defer std.testing.allocator.free(output);
    var reparsed = try can_dbz.formats.can_json.parse(std.testing.allocator, output);
    defer reparsed.deinit();
    const signals = reparsed.messages.items[0].signals.items;
    try std.testing.expectEqual(@as(usize, 5), signals.len);
    try std.testing.expectEqualStrings("LittleNineByteSpan", signals[1].name);
    try std.testing.expectEqualStrings("BranchOne", signals[4].name);
}

test "CAN JSON examples export according to the DBC support profile" {
    var minimal = try can_dbz.formats.can_json.parse(std.testing.allocator, @embedFile("fixtures/minimal.can.json"));
    defer minimal.deinit();
    const dbc_bytes = try can_dbz.formats.dbc.write(std.testing.allocator, &minimal);
    defer std.testing.allocator.free(dbc_bytes);
    var parse_diagnostics: std.ArrayListUnmanaged(can_dbz.diagnostic.Diagnostic) = .empty;
    defer parse_diagnostics.deinit(std.testing.allocator);
    var exported = try can_dbz.formats.dbc.parse(std.testing.allocator, dbc_bytes, &parse_diagnostics);
    defer exported.deinit();
    try std.testing.expectEqual(@as(usize, 0), exported.messages.items.len);
    try std.testing.expectEqual(@as(usize, 1), exported.buses.items.len);

    minimal.name = "Minimal";
    minimal.description = "CAN JSON export test";
    var name_diagnostics: std.ArrayListUnmanaged(can_dbz.diagnostic.Diagnostic) = .empty;
    defer name_diagnostics.deinit(std.testing.allocator);
    const metadata_dbc = try can_dbz.formats.dbc.writeWithDiagnostics(std.testing.allocator, &minimal, &name_diagnostics);
    defer std.testing.allocator.free(metadata_dbc);
    try std.testing.expectEqual(@as(usize, 2), name_diagnostics.items.len);
    try std.testing.expectEqual(can_dbz.diagnostic.Severity.warning, name_diagnostics.items[0].severity);
    try std.testing.expectEqualStrings("document name is omitted from DBC export", name_diagnostics.items[0].message);
    try std.testing.expectEqual(can_dbz.diagnostic.Severity.warning, name_diagnostics.items[1].severity);
    try std.testing.expectEqualStrings("document description is omitted from DBC export", name_diagnostics.items[1].message);

    var golden = try can_dbz.formats.can_json.parse(std.testing.allocator, @embedFile("fixtures/golden.can.json"));
    defer golden.deinit();
    var diagnostics: std.ArrayListUnmanaged(can_dbz.diagnostic.Diagnostic) = .empty;
    defer diagnostics.deinit(std.testing.allocator);
    const golden_dbc = try can_dbz.formats.dbc.writeWithDiagnostics(std.testing.allocator, &golden, &diagnostics);
    defer std.testing.allocator.free(golden_dbc);
    try std.testing.expectEqual(@as(usize, 1), diagnostics.items.len);
    try std.testing.expectEqual(can_dbz.diagnostic.Severity.warning, diagnostics.items[0].severity);
    var golden_exported = try can_dbz.formats.dbc.parse(std.testing.allocator, golden_dbc, &parse_diagnostics);
    defer golden_exported.deinit();
    try std.testing.expectEqual(can_dbz.model.FrameKind.fd, golden_exported.messages.items[0].frame);
    try std.testing.expectEqual(@as(u16, 64), golden_exported.messages.items[0].length);
    try std.testing.expect(golden_exported.messages.items[0].extended);
}

test "all complete CAN JSON guide examples export to DBC" {
    const examples = [_][]const u8{
        @embedFile("fixtures/can-json-quick-start.can.json"),
        @embedFile("fixtures/can-json-example-1.can.json"),
        @embedFile("fixtures/can-json-example-2.can.json"),
        @embedFile("fixtures/can-json-example-3.can.json"),
        @embedFile("fixtures/can-json-example-4.can.json"),
        @embedFile("fixtures/can-json-example-5.can.json"),
        @embedFile("fixtures/can-json-example-6.can.json"),
    };
    for (examples) |example| {
        var doc = try can_dbz.formats.can_json.parse(std.testing.allocator, example);
        defer doc.deinit();
        var diagnostics: std.ArrayListUnmanaged(can_dbz.diagnostic.Diagnostic) = .empty;
        defer diagnostics.deinit(std.testing.allocator);
        const dbc_bytes = try can_dbz.formats.dbc.writeWithDiagnostics(std.testing.allocator, &doc, &diagnostics);
        defer std.testing.allocator.free(dbc_bytes);
        var imported = try can_dbz.formats.dbc.parse(std.testing.allocator, dbc_bytes, &diagnostics);
        defer imported.deinit();
        try std.testing.expectEqual(doc.messages.items.len, imported.messages.items.len);
        try std.testing.expectEqual(doc.attribute_definitions.items.len, imported.attribute_definitions.items.len);
        for (doc.attribute_definitions.items, imported.attribute_definitions.items) |expected, actual| {
            try std.testing.expectEqualStrings(expected.name, actual.name);
            try std.testing.expectEqual(expected.scope, actual.scope);
            try std.testing.expectEqual(expected.value_type, actual.value_type);
            try std.testing.expectEqualStrings(expected.minimum.?, actual.minimum.?);
            try std.testing.expectEqualStrings(expected.maximum.?, actual.maximum.?);
            try std.testing.expectEqualStrings(expected.default.?.integer, actual.default.?.integer);
        }
        for (doc.messages.items, imported.messages.items) |expected_message, actual_message| {
            try std.testing.expectEqualStrings(expected_message.name, actual_message.name);
            try std.testing.expectEqual(expected_message.extended, actual_message.extended);
            try std.testing.expectEqual(expected_message.frame, actual_message.frame);
            try std.testing.expectEqual(expected_message.length, actual_message.length);
            try std.testing.expectEqual(expected_message.signals.items.len, actual_message.signals.items.len);
            try std.testing.expectEqual(expected_message.attributes.items.len, actual_message.attributes.items.len);
            for (expected_message.attributes.items, actual_message.attributes.items) |expected, actual| {
                try std.testing.expectEqualStrings(expected.name, actual.name);
                try std.testing.expectEqualStrings(expected.value.integer, actual.value.integer);
            }
            for (expected_message.signals.items, actual_message.signals.items) |expected_signal, actual_signal| {
                try std.testing.expectEqualStrings(expected_signal.name, actual_signal.name);
                try std.testing.expectEqual(expected_signal.start_bit, actual_signal.start_bit);
                try std.testing.expectEqual(expected_signal.bit_length, actual_signal.bit_length);
                try std.testing.expectEqual(expected_signal.byte_order, actual_signal.byte_order);
                try std.testing.expectEqual(expected_signal.signal_type, actual_signal.signal_type);
                try std.testing.expectEqual(expected_signal.is_multiplexer, actual_signal.is_multiplexer);
                try std.testing.expectEqual(expected_signal.when.items.len, actual_signal.when.items.len);
                if (expected_signal.description) |description| {
                    try std.testing.expectEqualStrings(description, actual_signal.description.?);
                } else {
                    try std.testing.expect(actual_signal.description == null);
                }
                for (expected_signal.when.items, actual_signal.when.items) |expected_condition, actual_condition| {
                    try std.testing.expectEqualStrings(expected_condition.selector, actual_condition.selector);
                    try std.testing.expectEqual(expected_condition.ranges.items.len, actual_condition.ranges.items.len);
                    for (expected_condition.ranges.items, actual_condition.ranges.items) |expected_range, actual_range| {
                        try std.testing.expectEqualStrings(expected_range.minimum, actual_range.minimum);
                        try std.testing.expectEqualStrings(expected_range.maximum, actual_range.maximum);
                    }
                }
                var expected_choices: []const can_dbz.model.Choice = expected_signal.choices.items;
                if (expected_signal.value_table) |table_name| {
                    for (doc.value_tables.items) |table| {
                        if (std.mem.eql(u8, table.name, table_name)) expected_choices = table.choices.items;
                    }
                }
                try std.testing.expectEqual(expected_choices.len, actual_signal.choices.items.len);
                for (expected_choices, actual_signal.choices.items) |expected_choice, actual_choice| {
                    try std.testing.expectEqualStrings(expected_choice.raw, actual_choice.raw);
                    try std.testing.expectEqualStrings(expected_choice.label, actual_choice.label);
                }
            }
        }
    }
}

test "invalid CAN JSON fixtures report their expected errors" {
    const FixtureCase = struct {
        bytes: []const u8,
        code: can_dbz.diagnostic.Code,
        err: can_dbz.formats.can_json.ParseError,
    };
    const cases = [_]FixtureCase{
        .{ .bytes = @embedFile("fixtures/invalid-duplicate-key.can.json"), .code = .invalid_json, .err = error.InvalidJson },
        .{ .bytes = @embedFile("fixtures/invalid-unknown-field.can.json"), .code = .unknown_core_field, .err = error.InvalidDocument },
        .{ .bytes = @embedFile("fixtures/invalid-id.can.json"), .code = .invalid_message_id, .err = error.InvalidDocument },
        .{ .bytes = @embedFile("fixtures/invalid-bits.can.json"), .code = .signal_layout_out_of_bounds, .err = error.InvalidDocument },
    };
    for (cases) |fixture_case| {
        var diagnostics: std.ArrayListUnmanaged(can_dbz.diagnostic.Diagnostic) = .empty;
        defer diagnostics.deinit(std.testing.allocator);
        try std.testing.expectError(fixture_case.err, can_dbz.formats.can_json.parseWithDiagnostics(std.testing.allocator, fixture_case.bytes, &diagnostics));
        try std.testing.expect(diagnostics.items.len > 0);
        try std.testing.expectEqual(fixture_case.code, diagnostics.items[0].code);
    }
}

test "bounded CAN JSON parser fuzz target" {
    try std.testing.fuzz({}, fuzzCanJson, .{});
}

test "bounded DBC parser fuzz target" {
    try std.testing.fuzz({}, fuzzDbc, .{});
}

fn fuzzCanJson(_: void, smith: *std.testing.Smith) !void {
    var input: [4096]u8 = undefined;
    const length = smith.sliceWithHash(&input, 0x43414e4a);
    var diagnostics: std.ArrayListUnmanaged(can_dbz.diagnostic.Diagnostic) = .empty;
    defer diagnostics.deinit(std.testing.allocator);
    var document = can_dbz.formats.can_json.parseWithDiagnostics(std.testing.allocator, input[0..length], &diagnostics) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return,
    };
    document.deinit();
}

fn fuzzDbc(_: void, smith: *std.testing.Smith) !void {
    var input: [4096]u8 = undefined;
    const length = smith.sliceWithHash(&input, 0x44424331);
    var diagnostics: std.ArrayListUnmanaged(can_dbz.diagnostic.Diagnostic) = .empty;
    defer diagnostics.deinit(std.testing.allocator);
    var document = can_dbz.formats.dbc.parse(std.testing.allocator, input[0..length], &diagnostics) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return,
    };
    document.deinit();
}
