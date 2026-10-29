const std = @import("std");

pub const Document = struct {
    arena: std.heap.ArenaAllocator,
    format: []const u8 = "can-db",
    format_version: u32 = 1,
    name: ?[]const u8 = null,
    description: ?[]const u8 = null,
    buses: std.ArrayListUnmanaged(Bus) = .empty,
    nodes: std.ArrayListUnmanaged(Node) = .empty,
    messages: std.ArrayListUnmanaged(Message) = .empty,
    attributes: std.ArrayListUnmanaged(AttributeAssignment) = .empty,
    value_tables: std.ArrayListUnmanaged(ValueTable) = .empty,
    attribute_definitions: std.ArrayListUnmanaged(AttributeDefinition) = .empty,
    dbc: ?std.json.Value = null,
    extensions: ?std.json.Value = null,

    pub fn init(backing_allocator: std.mem.Allocator) Document {
        return .{ .arena = .init(backing_allocator) };
    }

    pub fn allocator(self: *Document) std.mem.Allocator {
        return self.arena.allocator();
    }

    pub fn deinit(self: *Document) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const Bus = struct {
    name: []const u8,
    nominal_bitrate: ?u32 = null,
    data_bitrate: ?u32 = null,
    protocol: ?[]const u8 = null,
    description: ?[]const u8 = null,
    attributes: std.ArrayListUnmanaged(AttributeAssignment) = .empty,
    dbc: ?std.json.Value = null,
    extensions: ?std.json.Value = null,
};

pub const Node = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    attributes: std.ArrayListUnmanaged(AttributeAssignment) = .empty,
    dbc: ?std.json.Value = null,
    extensions: ?std.json.Value = null,
};

pub const FrameKind = enum {
    classic,
    fd,
};

pub const ByteOrder = enum {
    little_endian,
    big_endian,
};

pub const SignalType = enum {
    unsigned,
    signed,
    float32,
    float64,
};

pub const AttributeScope = enum {
    document,
    bus,
    node,
    message,
    signal,
};

pub const AttributeType = enum {
    integer,
    hex,
    float,
    string,
    @"enum",
};

pub const AttributeValue = union(enum) {
    integer: []const u8,
    hex: []const u8,
    float: []const u8,
    string: []const u8,
    enum_index: u32,
};

pub const AttributeDefinition = struct {
    name: []const u8,
    scope: AttributeScope,
    value_type: AttributeType,
    minimum: ?[]const u8 = null,
    maximum: ?[]const u8 = null,
    enum_labels: std.ArrayListUnmanaged([]const u8) = .empty,
    default: ?AttributeValue = null,
    dbc: ?std.json.Value = null,
    extensions: ?std.json.Value = null,
};

pub const AttributeAssignment = struct {
    name: []const u8,
    value: AttributeValue,
};

pub const Choice = struct {
    raw: []const u8,
    label: []const u8,
};

pub const ValueTable = struct {
    name: []const u8,
    choices: std.ArrayListUnmanaged(Choice) = .empty,
};

pub const RawRange = struct {
    minimum: []const u8,
    maximum: []const u8,
};

pub const MuxCondition = struct {
    selector: []const u8,
    ranges: std.ArrayListUnmanaged(RawRange) = .empty,
};

pub const Message = struct {
    name: []const u8,
    bus: []const u8,
    id: []const u8,
    extended: bool,
    frame: FrameKind,
    length: u16,
    description: ?[]const u8 = null,
    transmitters: std.ArrayListUnmanaged([]const u8) = .empty,
    receivers: std.ArrayListUnmanaged([]const u8) = .empty,
    signals: std.ArrayListUnmanaged(Signal) = .empty,
    attributes: std.ArrayListUnmanaged(AttributeAssignment) = .empty,
    dbc: ?std.json.Value = null,
    extensions: ?std.json.Value = null,
};

pub const Signal = struct {
    name: []const u8,
    start_bit: u16,
    bit_length: u16,
    byte_order: ByteOrder,
    signal_type: SignalType,
    description: ?[]const u8 = null,
    unit: ?[]const u8 = null,
    factor: []const u8 = "1",
    offset: []const u8 = "0",
    minimum: ?[]const u8 = null,
    maximum: ?[]const u8 = null,
    receivers: std.ArrayListUnmanaged([]const u8) = .empty,
    is_multiplexer: bool = false,
    when: std.ArrayListUnmanaged(MuxCondition) = .empty,
    choices: std.ArrayListUnmanaged(Choice) = .empty,
    value_table: ?[]const u8 = null,
    attributes: std.ArrayListUnmanaged(AttributeAssignment) = .empty,
    dbc: ?std.json.Value = null,
    extensions: ?std.json.Value = null,
};
