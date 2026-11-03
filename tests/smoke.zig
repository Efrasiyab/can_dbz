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
    try std.testing.expectEqual(@as(usize, 1), name_diagnostics.items.len);
    try std.testing.expectEqual(can_dbz.diagnostic.Severity.warning, name_diagnostics.items[0].severity);
    try std.testing.expectEqualStrings("document name is omitted from DBC export", name_diagnostics.items[0].message);
    var with_description = try can_dbz.formats.dbc.parse(std.testing.allocator, metadata_dbc, &parse_diagnostics);
    defer with_description.deinit();
    try std.testing.expectEqualStrings("CAN JSON export test", with_description.description.?);

    var golden = try can_dbz.formats.can_json.parse(std.testing.allocator, @embedFile("fixtures/golden.can.json"));
    defer golden.deinit();
    var diagnostics: std.ArrayListUnmanaged(can_dbz.diagnostic.Diagnostic) = .empty;
    defer diagnostics.deinit(std.testing.allocator);
    const golden_dbc = try can_dbz.formats.dbc.writeWithDiagnostics(std.testing.allocator, &golden, &diagnostics);
    defer std.testing.allocator.free(golden_dbc);
    try std.testing.expectEqual(@as(usize, 6), diagnostics.items.len);
    try std.testing.expectEqualStrings("document name is omitted from DBC export", diagnostics.items[0].message);
    for (diagnostics.items[1..]) |item| {
        try std.testing.expectEqualStrings("missing signal bounds are written as [0|0]", item.message);
    }
    try std.testing.expectEqual(can_dbz.diagnostic.Severity.warning, diagnostics.items[0].severity);
    var golden_exported = try can_dbz.formats.dbc.parse(std.testing.allocator, golden_dbc, &parse_diagnostics);
    defer golden_exported.deinit();
    try std.testing.expectEqual(can_dbz.model.FrameKind.fd, golden_exported.messages.items[0].frame);
    try std.testing.expectEqual(@as(u16, 64), golden_exported.messages.items[0].length);
    try std.testing.expect(golden_exported.messages.items[0].extended);
}

test "DBC standard-gap fixture round-trips modeled environment variables" {
    const source = @embedFile("fixtures/dbc-standard-gaps.dbc");
    var diagnostics: std.ArrayListUnmanaged(can_dbz.diagnostic.Diagnostic) = .empty;
    defer diagnostics.deinit(std.testing.allocator);

    try std.testing.expectError(error.InvalidDbc, can_dbz.formats.dbc.parse(std.testing.allocator, source, &diagnostics));
    try std.testing.expectEqual(@as(u32, 3), diagnostics.items[0].source.dbc.line);

    var doc = try can_dbz.formats.dbc.parseWithOptions(std.testing.allocator, source, &diagnostics, .{ .preserve_unsupported_statements = true });
    defer doc.deinit();
    const expected = [_][]const u8{"BS_: 500000 : 1"};
    const statements = doc.dbc.?.object.get("opaque_statements").?.array.items;
    try std.testing.expectEqual(expected.len, statements.len);
    for (expected, statements) |expected_raw, statement| {
        try std.testing.expectEqualStrings(expected_raw, statement.object.get("raw").?.string);
    }
    try std.testing.expectEqual(@as(usize, 1), doc.messages.items.len);
    try std.testing.expectEqualStrings("DASH", doc.messages.items[0].signals.items[0].receivers.items[0]);
    try std.testing.expectEqual(@as(usize, 2), doc.messages.items[0].transmitters.items.len);
    try std.testing.expectEqualStrings("DASH", doc.messages.items[0].transmitters.items[1]);
    try std.testing.expectEqual(@as(usize, 7), doc.attribute_definitions.items.len);
    try std.testing.expectEqualStrings("controller", doc.attribute_definitions.items[0].default.?.string);
    try std.testing.expectEqualStrings("unnamed", doc.attribute_definitions.items[1].default.?.string);
    try std.testing.expectEqualStrings("0", doc.attribute_definitions.items[2].default.?.integer);
    try std.testing.expectEqualStrings("1.0", doc.attribute_definitions.items[3].default.?.float);
    try std.testing.expectEqualStrings("0x00", doc.attribute_definitions.items[4].default.?.hex);
    try std.testing.expectEqual(@as(u32, 0), doc.attribute_definitions.items[5].default.?.enum_index);
    try std.testing.expectEqual(@as(u32, 0), doc.attribute_definitions.items[6].default.?.enum_index);
    try std.testing.expectEqualStrings("fleet-a", doc.attributes.items[0].value.string);
    try std.testing.expectEqualStrings("controller", doc.nodes.items[0].attributes.items[0].value.string);
    try std.testing.expectEqual(@as(usize, 2), doc.messages.items[0].attributes.items.len);
    try std.testing.expectEqualStrings("100", doc.messages.items[0].attributes.items[0].value.integer);
    try std.testing.expectEqual(@as(u32, 1), doc.messages.items[0].attributes.items[1].value.enum_index);
    try std.testing.expectEqual(@as(usize, 2), doc.messages.items[0].signals.items[0].attributes.items.len);
    try std.testing.expectEqualStrings("0.75", doc.messages.items[0].signals.items[0].attributes.items[0].value.float);
    try std.testing.expectEqualStrings("0xA5", doc.messages.items[0].signals.items[0].attributes.items[1].value.hex);
    try std.testing.expectEqual(@as(usize, 4), doc.environment_variables.items.len);
    try std.testing.expectEqual(can_dbz.model.EnvironmentVariableType.integer, doc.environment_variables.items[0].variable_type);
    try std.testing.expectEqual(@as(u32, 1), doc.environment_variables.items[0].ev_id);
    try std.testing.expectEqualStrings("ambient temperature", doc.environment_variables.items[0].description.?);
    try std.testing.expectEqual(@as(u32, 1), doc.environment_variables.items[0].attributes.items[0].value.enum_index);
    try std.testing.expectEqual(can_dbz.model.EnvironmentVariableType.data, doc.environment_variables.items[1].variable_type);
    try std.testing.expectEqual(@as(?u32, 16), doc.environment_variables.items[1].data_size);
    try std.testing.expectEqualStrings("raw payload", doc.environment_variables.items[1].description.?);
    try std.testing.expectEqual(can_dbz.model.EnvironmentVariableType.float, doc.environment_variables.items[2].variable_type);
    try std.testing.expectEqualStrings("20.0", doc.environment_variables.items[2].initial_value);
    try std.testing.expectEqual(can_dbz.model.EnvironmentVariableType.string, doc.environment_variables.items[3].variable_type);
    try std.testing.expectEqualStrings("normal", doc.environment_variables.items[3].initial_value);

    const json = try can_dbz.formats.can_json.write(std.testing.allocator, &doc);
    defer std.testing.allocator.free(json);
    var json_reparsed = try can_dbz.formats.can_json.parse(std.testing.allocator, json);
    defer json_reparsed.deinit();
    try std.testing.expectEqual(@as(usize, 4), json_reparsed.environment_variables.items.len);
    try std.testing.expectEqual(@as(?u32, 16), json_reparsed.environment_variables.items[1].data_size);

    const output = try can_dbz.formats.dbc.write(std.testing.allocator, &json_reparsed);
    defer std.testing.allocator.free(output);
    var reparsed = try can_dbz.formats.dbc.parseWithOptions(std.testing.allocator, output, &diagnostics, .{ .preserve_unsupported_statements = true });
    defer reparsed.deinit();
    const reparsed_statements = reparsed.dbc.?.object.get("opaque_statements").?.array.items;
    try std.testing.expectEqual(expected.len, reparsed_statements.len);
    for (expected, reparsed_statements) |expected_raw, statement| {
        try std.testing.expectEqualStrings(expected_raw, statement.object.get("raw").?.string);
    }
    try std.testing.expectEqual(@as(usize, 2), reparsed.messages.items[0].transmitters.items.len);
    try std.testing.expectEqualStrings("DASH", reparsed.messages.items[0].transmitters.items[1]);
    try std.testing.expectEqual(@as(usize, 7), reparsed.attribute_definitions.items.len);
    try std.testing.expectEqualStrings("controller", reparsed.attribute_definitions.items[0].default.?.string);
    try std.testing.expectEqualStrings("unnamed", reparsed.attribute_definitions.items[1].default.?.string);
    try std.testing.expectEqualStrings("0", reparsed.attribute_definitions.items[2].default.?.integer);
    try std.testing.expectEqualStrings("1.0", reparsed.attribute_definitions.items[3].default.?.float);
    try std.testing.expectEqualStrings("0x00", reparsed.attribute_definitions.items[4].default.?.hex);
    try std.testing.expectEqual(@as(u32, 0), reparsed.attribute_definitions.items[5].default.?.enum_index);
    try std.testing.expectEqual(@as(u32, 0), reparsed.attribute_definitions.items[6].default.?.enum_index);
    try std.testing.expectEqualStrings("fleet-a", reparsed.attributes.items[0].value.string);
    try std.testing.expectEqualStrings("controller", reparsed.nodes.items[0].attributes.items[0].value.string);
    try std.testing.expectEqualStrings("100", reparsed.messages.items[0].attributes.items[0].value.integer);
    try std.testing.expectEqual(@as(u32, 1), reparsed.messages.items[0].attributes.items[1].value.enum_index);
    try std.testing.expectEqualStrings("0.75", reparsed.messages.items[0].signals.items[0].attributes.items[0].value.float);
    try std.testing.expectEqualStrings("0xA5", reparsed.messages.items[0].signals.items[0].attributes.items[1].value.hex);
    try std.testing.expectEqual(@as(usize, 4), reparsed.environment_variables.items.len);
    try std.testing.expectEqual(can_dbz.model.EnvironmentVariableType.integer, reparsed.environment_variables.items[0].variable_type);
    try std.testing.expectEqual(@as(u32, 1), reparsed.environment_variables.items[0].ev_id);
    try std.testing.expectEqualStrings("ambient temperature", reparsed.environment_variables.items[0].description.?);
    try std.testing.expectEqual(@as(u32, 1), reparsed.environment_variables.items[0].attributes.items[0].value.enum_index);
    try std.testing.expectEqual(can_dbz.model.EnvironmentVariableType.data, reparsed.environment_variables.items[1].variable_type);
    try std.testing.expectEqual(@as(?u32, 16), reparsed.environment_variables.items[1].data_size);
    try std.testing.expectEqualStrings("raw payload", reparsed.environment_variables.items[1].description.?);
    try std.testing.expectEqual(can_dbz.model.EnvironmentVariableType.float, reparsed.environment_variables.items[2].variable_type);
    try std.testing.expectEqualStrings("20.0", reparsed.environment_variables.items[2].initial_value);
    try std.testing.expectEqual(can_dbz.model.EnvironmentVariableType.string, reparsed.environment_variables.items[3].variable_type);
    try std.testing.expectEqualStrings("normal", reparsed.environment_variables.items[3].initial_value);
}

test "DBC writer emits the cantools interoperability golden fixture" {
    var doc = can_dbz.model.Document.init(std.testing.allocator);
    defer doc.deinit();
    const arena = doc.allocator();
    try doc.buses.append(arena, .{ .name = "can0" });
    try doc.nodes.append(arena, .{ .name = "ECU" });
    var message = can_dbz.model.Message{
        .name = "Status",
        .bus = "can0",
        .id = "0x1",
        .extended = false,
        .frame = .classic,
        .length = 1,
    };
    try message.transmitters.append(arena, "ECU");
    try message.signals.append(arena, .{
        .name = "Value",
        .start_bit = 0,
        .bit_length = 8,
        .byte_order = .little_endian,
        .signal_type = .unsigned,
        .minimum = "0",
        .maximum = "255",
        .receivers = .empty,
    });
    try message.signals.items[0].receivers.append(arena, "ECU");
    try doc.messages.append(arena, message);

    const output = try can_dbz.formats.dbc.write(std.testing.allocator, &doc);
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings(@embedFile("fixtures/dbc-cantools-writer.dbc"), output);

    var diagnostics: std.ArrayListUnmanaged(can_dbz.diagnostic.Diagnostic) = .empty;
    defer diagnostics.deinit(std.testing.allocator);
    var reparsed = try can_dbz.formats.dbc.parse(std.testing.allocator, output, &diagnostics);
    defer reparsed.deinit();
    try std.testing.expectEqualStrings("Status", reparsed.messages.items[0].name);
    try std.testing.expectEqualStrings("ECU", reparsed.messages.items[0].signals.items[0].receivers.items[0]);
}

test "node description DBC fixture imports and exports with escaping" {
    var diagnostics: std.ArrayListUnmanaged(can_dbz.diagnostic.Diagnostic) = .empty;
    defer diagnostics.deinit(std.testing.allocator);
    var doc = try can_dbz.formats.dbc.parse(std.testing.allocator, @embedFile("fixtures/node-description.dbc"), &diagnostics);
    defer doc.deinit();
    const description = "quoted \"node\" and \\ path";
    try std.testing.expectEqualStrings(description, doc.nodes.items[0].description.?);

    const output = try can_dbz.formats.dbc.write(std.testing.allocator, &doc);
    defer std.testing.allocator.free(output);
    var reparsed = try can_dbz.formats.dbc.parse(std.testing.allocator, output, &diagnostics);
    defer reparsed.deinit();
    try std.testing.expectEqualStrings(description, reparsed.nodes.items[0].description.?);
}

test "DBC with selectors declared after their signals (cantools ordering) imports nested multiplexing" {
    var diagnostics: std.ArrayListUnmanaged(can_dbz.diagnostic.Diagnostic) = .empty;
    defer diagnostics.deinit(std.testing.allocator);
    var doc = try can_dbz.formats.dbc.parse(std.testing.allocator, @embedFile("fixtures/nested-mux-cantools.dbc"), &diagnostics);
    defer doc.deinit();
    const signals = doc.messages.items[0].signals.items;
    try std.testing.expectEqualStrings("WriteStatus", signals[0].name);
    try std.testing.expectEqual(@as(usize, 1), signals[0].when.items.len);
    try std.testing.expectEqualStrings("Service", signals[0].when.items[0].selector);
    // ReadValue depends on SubId, whose own Service=1 condition is re-expanded.
    try std.testing.expectEqual(@as(usize, 2), signals[1].when.items.len);
    try std.testing.expectEqualStrings("Service", signals[1].when.items[0].selector);
    try std.testing.expectEqualStrings("SubId", signals[1].when.items[1].selector);
    try std.testing.expectEqualStrings("10", signals[1].when.items[1].ranges.items[0].minimum);
    try std.testing.expectEqualStrings("11", signals[1].when.items[1].ranges.items[0].maximum);
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
        if (doc.name != null and std.mem.eql(u8, doc.name.?, "FdDemo")) {
            const comment = std.mem.indexOf(u8, dbc_bytes, "\nCM_ SG_ ").?;
            const frame_format = std.mem.indexOf(u8, dbc_bytes, "\nBA_ \"VFrameFormat\"").?;
            const value_type = std.mem.indexOf(u8, dbc_bytes, "\nSIG_VALTYPE_ ").?;
            try std.testing.expect(comment < frame_format and frame_format < value_type);
        }
        if (doc.name != null and std.mem.eql(u8, doc.name.?, "NestedMux")) {
            try std.testing.expect(std.mem.indexOf(u8, dbc_bytes, "\n  VAL_\n") != null);
            try std.testing.expect(std.mem.indexOf(u8, dbc_bytes, "SG_ SubId m1M :") != null);
            try std.testing.expect(std.mem.indexOf(u8, dbc_bytes, "SG_ WriteStatus m2 :") != null);
            try std.testing.expect(std.mem.indexOf(u8, dbc_bytes, "SG_ ReadValue m10 :") != null);
            try std.testing.expect(std.mem.indexOf(u8, dbc_bytes, "SG_MUL_VAL_ 1024 SubId Service 1-1;") != null);
            try std.testing.expect(std.mem.indexOf(u8, dbc_bytes, "SG_MUL_VAL_ 1024 ReadValue SubId 10-10, 11-11;") != null);
            try std.testing.expect(std.mem.indexOf(u8, dbc_bytes, "SG_MUL_VAL_ 1024 WriteStatus Service 2-2;") != null);
        }
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
                if (expected_signal.when.items.len != actual_signal.when.items.len) {
                    std.debug.print("{s}.{s}: expected {d} mux conditions, imported {d}\n", .{
                        expected_message.name,
                        expected_signal.name,
                        expected_signal.when.items.len,
                        actual_signal.when.items.len,
                    });
                    for (actual_signal.when.items) |condition| std.debug.print("  selector {s}\n", .{condition.selector});
                }
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
