const std = @import("std");

pub const Severity = enum {
    info,
    warning,
    @"error",
};

pub const Code = enum {
    invalid_json,
    invalid_dbc,
    unknown_core_field,
    missing_field,
    invalid_field_type,
    invalid_enum_value,
    invalid_format,
    unsupported_format_version,
    duplicate_bus_name,
    duplicate_node_name,
    duplicate_message_name,
    duplicate_message_id,
    duplicate_signal_name,
    duplicate_value_table_name,
    duplicate_attribute_definition,
    invalid_message_id,
    message_id_out_of_range,
    invalid_frame_length,
    unknown_bus,
    unknown_node,
    signal_width_out_of_range,
    signal_layout_out_of_bounds,
    float_width_mismatch,
    unknown_value_table,
    duplicate_choice_raw,
    duplicate_choice_label,
    invalid_choice_raw,
    duplicate_selector,
    missing_mux_selector,
    invalid_mux_selector,
    invalid_mux_range,
    mux_range_out_of_domain,
    mux_dependency_cycle,
    overlapping_signals,
    missing_attribute_definition,
    attribute_scope_mismatch,
    invalid_attribute_value,
    attribute_value_out_of_range,
    duplicate_attribute_assignment,
    invalid_decimal_value,
    invalid_physical_bounds,
    unsupported_dbc_export,
};

pub const SourceRef = union(enum) {
    none,
    json_pointer: []const u8,
    dbc: DbcLocation,
};

pub const DbcLocation = struct {
    line: u32,
    column: u32,
};

pub const Context = struct {
    bus: ?[]const u8 = null,
    message: ?[]const u8 = null,
    signal: ?[]const u8 = null,
};

pub const Diagnostic = struct {
    severity: Severity,
    code: Code,
    message: []const u8,
    source: SourceRef = .none,
    context: Context = .{},

    pub fn format(
        self: Diagnostic,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;

        try writer.print("{s}: {s}", .{ @tagName(self.severity), @tagName(self.code) });
        if (self.context.bus) |bus| try writer.print(" [{s}]", .{bus});
        if (self.context.message) |msg| try writer.print(" {s}", .{msg});
        if (self.context.signal) |sig| try writer.print("/{s}", .{sig});
        try writer.print(" - {s}", .{self.message});

        switch (self.source) {
            .none => {},
            .json_pointer => |ptr| try writer.print(" ({s})", .{ptr}),
            .dbc => |loc| try writer.print(" (dbc {d}:{d})", .{ loc.line, loc.column }),
        }
    }
};
