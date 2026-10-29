const std = @import("std");
const model = @import("../model.zig");
const diagnostic = @import("../diagnostic.zig");
const validate = @import("../validate.zig");
const can_json = @import("can_json.zig");

pub const Error = error{ OutOfMemory, InvalidDbc, UnsupportedConstruct };
pub const ParseOptions = struct {
    preserve_unsupported_statements: bool = false,
};
pub const TokenKind = enum { word, string, punctuation };
pub const Token = struct {
    kind: TokenKind,
    text: []const u8,
    line: u32,
    column: u32,
};

pub const Lexer = struct {
    input: []const u8,
    offset: usize = 0,
    line: u32 = 1,
    column: u32 = 1,

    pub fn next(self: *Lexer) Error!?Token {
        while (self.offset < self.input.len) {
            const ch = self.input[self.offset];
            if (ch == '\n') {
                self.offset += 1;
                self.line += 1;
                self.column = 1;
                continue;
            }
            if (std.ascii.isWhitespace(ch)) {
                self.offset += 1;
                self.column += 1;
                continue;
            }
            if (ch == '/' and self.offset + 1 < self.input.len and self.input[self.offset + 1] == '/') {
                while (self.offset < self.input.len and self.input[self.offset] != '\n') : (self.offset += 1) self.column += 1;
                continue;
            }
            break;
        }
        if (self.offset == self.input.len) return null;
        const start = self.offset;
        const token_line = self.line;
        const token_column = self.column;
        const first = self.input[self.offset];
        if (first == '"') {
            self.offset += 1;
            self.column += 1;
            while (self.offset < self.input.len and self.input[self.offset] != '"') {
                if (self.input[self.offset] == '\n') return error.InvalidDbc;
                if (self.input[self.offset] == '\\') {
                    if (self.offset + 1 == self.input.len or self.input[self.offset + 1] == '\n') return error.InvalidDbc;
                    self.offset += 2;
                    self.column += 2;
                    continue;
                }
                self.offset += 1;
                self.column += 1;
            }
            if (self.offset == self.input.len) return error.InvalidDbc;
            const text = self.input[start + 1 .. self.offset];
            self.offset += 1;
            self.column += 1;
            return .{ .kind = .string, .text = text, .line = token_line, .column = token_column };
        }
        if (std.mem.indexOfScalar(u8, ":|@+-,()[];", first) != null) {
            self.offset += 1;
            self.column += 1;
            return .{ .kind = .punctuation, .text = self.input[start..self.offset], .line = token_line, .column = token_column };
        }
        while (self.offset < self.input.len) {
            const ch = self.input[self.offset];
            if (std.ascii.isWhitespace(ch) or ch == '"' or std.mem.indexOfScalar(u8, ":|@+-,()[];", ch) != null) break;
            self.offset += 1;
            self.column += 1;
        }
        return .{ .kind = .word, .text = self.input[start..self.offset], .line = token_line, .column = token_column };
    }
};

pub fn parse(allocator: std.mem.Allocator, bytes: []const u8, diagnostics: *std.ArrayListUnmanaged(diagnostic.Diagnostic)) Error!model.Document {
    return parseWithOptions(allocator, bytes, diagnostics, .{});
}

pub fn parseWithOptions(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    diagnostics: *std.ArrayListUnmanaged(diagnostic.Diagnostic),
    options: ParseOptions,
) Error!model.Document {
    var doc = model.Document.init(allocator);
    errdefer doc.deinit();
    const a = doc.allocator();
    var lexer = Lexer{ .input = bytes };
    var current_message: ?usize = null;
    var last_mux: ?[]const u8 = null;
    var frame_format_definition = FrameFormatDefinition{};
    var in_namespace_listing = false;
    var current_line: std.ArrayListUnmanaged(Token) = .empty;
    defer current_line.deinit(a);
    var line_number: u32 = 1;
    while (true) {
        const maybe_token = lexer.next() catch {
            try diagnostics.append(allocator, .{
                .severity = .@"error",
                .code = .invalid_dbc,
                .message = "invalid quoted string or lexer token",
                .source = .{ .dbc = .{ .line = lexer.line, .column = lexer.column } },
            });
            return error.InvalidDbc;
        };
        const token = maybe_token orelse break;
        if (token.line != line_number) {
            try parseLine(
                &doc,
                &current_message,
                &last_mux,
                &frame_format_definition,
                &in_namespace_listing,
                current_line.items,
                rawLine(bytes, line_number),
                options,
                allocator,
                diagnostics,
            );
            current_line.clearRetainingCapacity();
            line_number = token.line;
        }
        try current_line.append(a, token);
    }
    if (current_line.items.len > 0) {
        try parseLine(
            &doc,
            &current_message,
            &last_mux,
            &frame_format_definition,
            &in_namespace_listing,
            current_line.items,
            rawLine(bytes, line_number),
            options,
            allocator,
            diagnostics,
        );
    }
    if (in_namespace_listing) {
        try diagnostics.append(allocator, .{
            .severity = .@"error",
            .code = .invalid_dbc,
            .message = "namespace declarations are not terminated by BS_",
            .source = .{ .dbc = .{ .line = lexer.line, .column = lexer.column } },
        });
        return error.InvalidDbc;
    }

    if (doc.buses.items.len == 0) try doc.buses.append(a, .{ .name = "can0" });
    try resolveMuxSelectors(&doc, allocator, diagnostics);
    try expandMuxAncestors(&doc);
    if (!try validate.validateDocument(&doc, allocator, diagnostics)) return error.InvalidDbc;
    return doc;
}

const FrameFormatDefinition = struct {
    seen: bool = false,
    fd_values: std.ArrayListUnmanaged(u16) = .empty,
};

fn parseLine(
    doc: *model.Document,
    current_message: *?usize,
    last_mux: *?[]const u8,
    frame_format_definition: *FrameFormatDefinition,
    in_namespace_listing: *bool,
    tokens: []const Token,
    raw_line: []const u8,
    options: ParseOptions,
    allocator: std.mem.Allocator,
    diagnostics: *std.ArrayListUnmanaged(diagnostic.Diagnostic),
) Error!void {
    if (tokens.len == 0) return;
    const keyword = tokens[0].text;
    if (std.mem.eql(u8, keyword, "NS_")) {
        in_namespace_listing.* = true;
        return;
    }
    if (std.mem.eql(u8, keyword, "BS_")) {
        in_namespace_listing.* = false;
        if (tokens.len > 1 and !(tokens.len == 2 and std.mem.eql(u8, tokens[1].text, ":")))
            return preserveOrReject(doc, tokens[0], raw_line, options, allocator, diagnostics);
        return;
    }
    if (in_namespace_listing.*) return;
    if (std.mem.eql(u8, keyword, "VERSION")) {
        if (tokens.len != 2 or tokens[1].kind != .string)
            return lineError(allocator, diagnostics, tokens[0], "VERSION requires a quoted version string");
        var metadata = try ensureDbcObject(doc);
        const version = decodeDbcString(doc.allocator(), tokens[1].text) catch
            return lineError(allocator, diagnostics, tokens[1], "invalid DBC string escape");
        try metadata.put(doc.allocator(), "version", .{ .string = version });
        doc.dbc = .{ .object = metadata };
        return;
    }
    if (std.mem.eql(u8, keyword, "CM_") and tokens.len > 1 and std.mem.eql(u8, tokens[1].text, "SG_"))
        return parseSignalComment(doc, tokens, allocator, diagnostics);
    if (std.mem.eql(u8, keyword, "CM_") and tokens.len > 1 and std.mem.eql(u8, tokens[1].text, "BU_"))
        return parseNodeComment(doc, tokens, allocator, diagnostics);
    if (std.mem.eql(u8, keyword, "SG_MUL_VAL_"))
        return parseSignalMultiplexerValues(doc, tokens, allocator, diagnostics);
    if (std.mem.eql(u8, keyword, "SIG_VALTYPE_"))
        return parseSignalValueType(doc, tokens, allocator, diagnostics);
    if (std.mem.eql(u8, keyword, "VAL_") and tokens.len > 1 and tokens[1].kind == .word)
        return parseSignalValues(doc, tokens, allocator, diagnostics);
    if (std.mem.eql(u8, keyword, "BA_DEF_") and tokens.len > 2 and tokens[2].kind == .string and std.mem.eql(u8, tokens[2].text, "VFrameFormat"))
        return parseFrameFormatDefinition(doc, tokens, frame_format_definition, allocator, diagnostics);
    if (std.mem.eql(u8, keyword, "BA_DEF_")) {
        if (tokens.len > 3 and std.mem.eql(u8, tokens[1].text, "BO_") and tokens[2].kind == .string and std.mem.eql(u8, tokens[3].text, "INT"))
            return parseMessageAttributeDefinition(doc, tokens, allocator, diagnostics);
        return preserveOrReject(doc, tokens[0], raw_line, options, allocator, diagnostics);
    }
    if (std.mem.eql(u8, keyword, "BA_DEF_DEF_")) {
        if (tokens.len > 1 and tokens[1].kind == .string and isMessageIntegerAttribute(doc, tokens[1].text))
            return parseMessageAttributeDefault(doc, tokens, allocator, diagnostics);
        return preserveOrReject(doc, tokens[0], raw_line, options, allocator, diagnostics);
    }
    if (std.mem.eql(u8, keyword, "BA_") and tokens.len > 1 and tokens[1].kind == .string and std.mem.eql(u8, tokens[1].text, "VFrameFormat"))
        return parseFrameFormatAssignment(doc, tokens, frame_format_definition, allocator, diagnostics);
    if (std.mem.eql(u8, keyword, "BA_") and tokens.len > 1 and tokens[1].kind == .string) {
        if (tokens.len > 2 and std.mem.eql(u8, tokens[2].text, "BO_") and isMessageIntegerAttribute(doc, tokens[1].text))
            return parseMessageAttributeAssignment(doc, tokens, allocator, diagnostics);
        return preserveOrReject(doc, tokens[0], raw_line, options, allocator, diagnostics);
    }
    if (std.mem.eql(u8, keyword, "BU_")) {
        const a = doc.allocator();
        for (tokens[1..]) |token| {
            if (token.kind != .word or std.mem.eql(u8, token.text, ":")) continue;
            try doc.nodes.append(a, .{ .name = try a.dupe(u8, token.text) });
        }
        return;
    }
    if (std.mem.eql(u8, keyword, "BO_")) {
        if (tokens.len < 6 or !std.mem.eql(u8, tokens[3].text, ":"))
            return lineError(allocator, diagnostics, tokens[0], "malformed BO_ message declaration");
        const raw_id = std.fmt.parseInt(u32, tokens[1].text, 10) catch
            return lineError(allocator, diagnostics, tokens[1], "invalid DBC message identifier");
        const extended = raw_id & 0x80000000 != 0;
        const id = raw_id & 0x1fffffff;
        const length = std.fmt.parseInt(u16, tokens[4].text, 10) catch
            return lineError(allocator, diagnostics, tokens[4], "invalid DBC message length");
        const bus = if (doc.buses.items.len == 0) "can0" else doc.buses.items[0].name;
        const a = doc.allocator();
        const transmitter = if (tokens.len > 5 and !std.mem.eql(u8, tokens[5].text, "Vector__XXX")) tokens[5].text else null;
        var message = model.Message{
            .name = try a.dupe(u8, tokens[2].text),
            .bus = bus,
            .id = try std.fmt.allocPrint(a, "0x{x}", .{id}),
            .extended = extended,
            .frame = .classic,
            .length = length,
        };
        if (transmitter) |node_name| {
            if (!hasNode(doc, node_name)) try doc.nodes.append(a, .{ .name = try a.dupe(u8, node_name) });
            try message.transmitters.append(a, try a.dupe(u8, node_name));
        }
        try doc.messages.append(a, message);
        current_message.* = doc.messages.items.len - 1;
        last_mux.* = null;
        return;
    }
    if (std.mem.eql(u8, keyword, "SG_")) {
        const message_index = current_message.* orelse return lineError(allocator, diagnostics, tokens[0], "SG_ signal must follow a BO_ message");
        var i: usize = 1;
        if (i >= tokens.len) return lineError(allocator, diagnostics, tokens[0], "missing signal name");
        const name = tokens[i].text;
        i += 1;
        var mux_code: ?[]const u8 = null;
        if (i < tokens.len and tokens[i].kind == .word and !std.mem.eql(u8, tokens[i].text, ":")) {
            mux_code = tokens[i].text;
            i += 1;
        }
        try expectToken(tokens, &i, ":", allocator, diagnostics);
        const start = try readUnsigned(tokens, &i, allocator, diagnostics);
        try expectToken(tokens, &i, "|", allocator, diagnostics);
        const width = try readUnsigned(tokens, &i, allocator, diagnostics);
        try expectToken(tokens, &i, "@", allocator, diagnostics);
        const endian = try readUnsigned(tokens, &i, allocator, diagnostics);
        if (endian > 1) return lineError(allocator, diagnostics, tokens[i - 1], "byte order must be 0 or 1");
        if (i >= tokens.len or tokens[i].text.len != 1 or (tokens[i].text[0] != '+' and tokens[i].text[0] != '-'))
            return lineError(allocator, diagnostics, tokens[0], "signal sign must be + or -");
        const signed = tokens[i].text[0] == '-';
        i += 1;
        try expectToken(tokens, &i, "(", allocator, diagnostics);
        const factor = try readDecimal(tokens, &i, doc.allocator(), allocator, diagnostics);
        try expectToken(tokens, &i, ",", allocator, diagnostics);
        const offset = try readDecimal(tokens, &i, doc.allocator(), allocator, diagnostics);
        try expectToken(tokens, &i, ")", allocator, diagnostics);
        try expectToken(tokens, &i, "[", allocator, diagnostics);
        const minimum = try readDecimal(tokens, &i, doc.allocator(), allocator, diagnostics);
        try expectToken(tokens, &i, "|", allocator, diagnostics);
        const maximum = try readDecimal(tokens, &i, doc.allocator(), allocator, diagnostics);
        try expectToken(tokens, &i, "]", allocator, diagnostics);
        if (i >= tokens.len or tokens[i].kind != .string) return lineError(allocator, diagnostics, tokens[0], "signal unit must be a quoted string");
        const unit = decodeDbcString(doc.allocator(), tokens[i].text) catch
            return lineError(allocator, diagnostics, tokens[i], "invalid DBC string escape");
        i += 1;

        const a = doc.allocator();
        var signal = model.Signal{
            .name = try a.dupe(u8, name),
            .start_bit = std.math.cast(u16, start) orelse return lineError(allocator, diagnostics, tokens[0], "signal start bit exceeds model range"),
            .bit_length = std.math.cast(u16, width) orelse return lineError(allocator, diagnostics, tokens[0], "signal width exceeds model range"),
            .byte_order = if (endian == 1) .little_endian else .big_endian,
            .signal_type = if (signed) .signed else .unsigned,
            .factor = factor,
            .offset = offset,
            .minimum = minimum,
            .maximum = maximum,
            .unit = try a.dupe(u8, unit),
        };
        if (mux_code) |code| {
            if (std.mem.eql(u8, code, "M")) {
                signal.is_multiplexer = true;
                last_mux.* = signal.name;
            } else if (std.mem.startsWith(u8, code, "m")) {
                const selector = last_mux.* orelse "";
                const nested_mux = std.mem.endsWith(u8, code, "M");
                const value_text = code[1 .. code.len - @intFromBool(nested_mux)];
                const value = std.fmt.parseInt(u64, value_text, 10) catch return lineError(allocator, diagnostics, tokens[1], "invalid simple mux value");
                var ranges: std.ArrayListUnmanaged(model.RawRange) = .empty;
                try ranges.append(a, .{
                    .minimum = try std.fmt.allocPrint(a, "{d}", .{value}),
                    .maximum = try std.fmt.allocPrint(a, "{d}", .{value}),
                });
                try signal.when.append(a, .{ .selector = selector, .ranges = ranges });
                if (nested_mux) {
                    signal.is_multiplexer = true;
                    last_mux.* = signal.name;
                }
            } else return lineError(allocator, diagnostics, tokens[1], "unsupported DBC multiplexing marker");
        }
        var message = &doc.messages.items[message_index];
        try message.signals.append(a, signal);
        for (tokens[i..]) |receiver| {
            if (receiver.kind != .word or std.mem.eql(u8, receiver.text, "Vector__XXX")) continue;
            if (!hasNode(doc, receiver.text)) try doc.nodes.append(a, .{ .name = try a.dupe(u8, receiver.text) });
            try message.signals.items[message.signals.items.len - 1].receivers.append(a, try a.dupe(u8, receiver.text));
        }
        return;
    }
    return preserveOrReject(doc, tokens[0], raw_line, options, allocator, diagnostics);
}

fn parseSignalComment(
    doc: *model.Document,
    tokens: []const Token,
    allocator: std.mem.Allocator,
    diagnostics: *std.ArrayListUnmanaged(diagnostic.Diagnostic),
) Error!void {
    if (tokens.len != 6 or tokens[2].kind != .word or tokens[3].kind != .word or tokens[4].kind != .string or !std.mem.eql(u8, tokens[5].text, ";"))
        return lineError(allocator, diagnostics, tokens[0], "malformed signal comment");

    const raw_id = std.fmt.parseInt(u32, tokens[2].text, 10) catch
        return lineError(allocator, diagnostics, tokens[2], "invalid signal comment message identifier");
    const extended = raw_id & 0x80000000 != 0;
    const id = raw_id & 0x1fffffff;
    for (doc.messages.items) |*message| {
        const message_id = std.fmt.parseInt(u32, message.id[2..], 16) catch continue;
        if (message_id != id or message.extended != extended) continue;
        for (message.signals.items) |*signal| {
            if (!std.mem.eql(u8, signal.name, tokens[3].text)) continue;
            if (signal.description != null) return lineError(allocator, diagnostics, tokens[0], "duplicate signal comment");
            signal.description = decodeDbcString(doc.allocator(), tokens[4].text) catch
                return lineError(allocator, diagnostics, tokens[4], "invalid DBC string escape");
            return;
        }
        return lineError(allocator, diagnostics, tokens[3], "signal comment references an unknown signal");
    }
    return lineError(allocator, diagnostics, tokens[2], "signal comment references an unknown message");
}

fn parseNodeComment(
    doc: *model.Document,
    tokens: []const Token,
    allocator: std.mem.Allocator,
    diagnostics: *std.ArrayListUnmanaged(diagnostic.Diagnostic),
) Error!void {
    if (tokens.len != 5 or tokens[2].kind != .word or tokens[3].kind != .string or !std.mem.eql(u8, tokens[4].text, ";"))
        return lineError(allocator, diagnostics, tokens[0], "malformed node comment");
    for (doc.nodes.items) |*node| {
        if (!std.mem.eql(u8, node.name, tokens[2].text)) continue;
        if (node.description != null) return lineError(allocator, diagnostics, tokens[0], "duplicate node comment");
        node.description = decodeDbcString(doc.allocator(), tokens[3].text) catch
            return lineError(allocator, diagnostics, tokens[3], "invalid DBC string escape");
        return;
    }
    return lineError(allocator, diagnostics, tokens[2], "node comment references an unknown node");
}

fn parseSignalValues(
    doc: *model.Document,
    tokens: []const Token,
    allocator: std.mem.Allocator,
    diagnostics: *std.ArrayListUnmanaged(diagnostic.Diagnostic),
) Error!void {
    if (tokens.len < 6 or !std.mem.eql(u8, tokens[tokens.len - 1].text, ";"))
        return lineError(allocator, diagnostics, tokens[0], "malformed signal value table");
    const raw_id = std.fmt.parseInt(u32, tokens[1].text, 10) catch
        return lineError(allocator, diagnostics, tokens[1], "invalid signal value message identifier");
    const id = raw_id & 0x1fffffff;
    const extended = raw_id & 0x80000000 != 0;
    for (doc.messages.items) |*message| {
        const message_id = std.fmt.parseInt(u32, message.id[2..], 16) catch continue;
        if (message_id != id or message.extended != extended) continue;
        for (message.signals.items) |*signal| {
            if (!std.mem.eql(u8, signal.name, tokens[2].text)) continue;
            var index: usize = 3;
            while (index < tokens.len - 1) {
                const raw = try readDecimal(tokens, &index, doc.allocator(), allocator, diagnostics);
                if (index >= tokens.len - 1 or tokens[index].kind != .string)
                    return lineError(allocator, diagnostics, tokens[index - 1], "signal value requires a quoted label");
                const label = decodeDbcString(doc.allocator(), tokens[index].text) catch
                    return lineError(allocator, diagnostics, tokens[index], "invalid DBC string escape");
                index += 1;
                try signal.choices.append(doc.allocator(), .{ .raw = raw, .label = label });
            }
            return;
        }
        return lineError(allocator, diagnostics, tokens[2], "signal value table references an unknown signal");
    }
    return lineError(allocator, diagnostics, tokens[1], "signal value table references an unknown message");
}

fn parseSignalMultiplexerValues(
    doc: *model.Document,
    tokens: []const Token,
    allocator: std.mem.Allocator,
    diagnostics: *std.ArrayListUnmanaged(diagnostic.Diagnostic),
) Error!void {
    if (tokens.len < 8 or !std.mem.eql(u8, tokens[tokens.len - 1].text, ";"))
        return lineError(allocator, diagnostics, tokens[0], "malformed SG_MUL_VAL_ statement");
    const raw_id = std.fmt.parseInt(u32, tokens[1].text, 10) catch
        return lineError(allocator, diagnostics, tokens[1], "invalid SG_MUL_VAL_ message identifier");
    const id = raw_id & 0x1fffffff;
    const extended = raw_id & 0x80000000 != 0;
    for (doc.messages.items) |*message| {
        const message_id = std.fmt.parseInt(u32, message.id[2..], 16) catch continue;
        if (message_id != id or message.extended != extended) continue;
        for (message.signals.items) |*signal| {
            if (!std.mem.eql(u8, signal.name, tokens[2].text)) continue;
            var ranges: std.ArrayListUnmanaged(model.RawRange) = .empty;
            var index: usize = 4;
            while (index < tokens.len - 1) {
                const minimum = try readUnsigned(tokens, &index, allocator, diagnostics);
                var maximum = minimum;
                if (index < tokens.len - 1 and std.mem.eql(u8, tokens[index].text, "-")) {
                    index += 1;
                    maximum = try readUnsigned(tokens, &index, allocator, diagnostics);
                }
                try ranges.append(doc.allocator(), .{
                    .minimum = try std.fmt.allocPrint(doc.allocator(), "{d}", .{minimum}),
                    .maximum = try std.fmt.allocPrint(doc.allocator(), "{d}", .{maximum}),
                });
                if (index == tokens.len - 1) break;
                if (!std.mem.eql(u8, tokens[index].text, ","))
                    return lineError(allocator, diagnostics, tokens[index], "expected comma in SG_MUL_VAL_ ranges");
                index += 1;
            }
            if (!std.mem.eql(u8, tokens[index].text, ";"))
                return lineError(allocator, diagnostics, tokens[index], "unterminated SG_MUL_VAL_ ranges");
            signal.when.clearRetainingCapacity();
            try signal.when.append(doc.allocator(), .{ .selector = try doc.allocator().dupe(u8, tokens[3].text), .ranges = ranges });
            return;
        }
        return lineError(allocator, diagnostics, tokens[2], "SG_MUL_VAL_ references an unknown signal");
    }
    return lineError(allocator, diagnostics, tokens[1], "SG_MUL_VAL_ references an unknown message");
}

fn parseSignalValueType(
    doc: *model.Document,
    tokens: []const Token,
    allocator: std.mem.Allocator,
    diagnostics: *std.ArrayListUnmanaged(diagnostic.Diagnostic),
) Error!void {
    if (tokens.len != 6 or !std.mem.eql(u8, tokens[3].text, ":") or !std.mem.eql(u8, tokens[5].text, ";"))
        return lineError(allocator, diagnostics, tokens[0], "malformed SIG_VALTYPE_ statement");
    const raw_id = std.fmt.parseInt(u32, tokens[1].text, 10) catch
        return lineError(allocator, diagnostics, tokens[1], "invalid SIG_VALTYPE_ message identifier");
    const value_type = std.fmt.parseInt(u8, tokens[4].text, 10) catch
        return lineError(allocator, diagnostics, tokens[4], "invalid SIG_VALTYPE_ type");
    const signal_type: model.SignalType = switch (value_type) {
        1 => .float32,
        2 => .float64,
        else => return lineError(allocator, diagnostics, tokens[4], "unsupported SIG_VALTYPE_ type"),
    };
    const id = raw_id & 0x1fffffff;
    const extended = raw_id & 0x80000000 != 0;
    for (doc.messages.items) |*message| {
        const message_id = std.fmt.parseInt(u32, message.id[2..], 16) catch continue;
        if (message_id != id or message.extended != extended) continue;
        for (message.signals.items) |*signal| {
            if (std.mem.eql(u8, signal.name, tokens[2].text)) {
                signal.signal_type = signal_type;
                return;
            }
        }
        return lineError(allocator, diagnostics, tokens[2], "SIG_VALTYPE_ references an unknown signal");
    }
    return lineError(allocator, diagnostics, tokens[1], "SIG_VALTYPE_ references an unknown message");
}

fn parseFrameFormatDefinition(
    doc: *model.Document,
    tokens: []const Token,
    definition: *FrameFormatDefinition,
    allocator: std.mem.Allocator,
    diagnostics: *std.ArrayListUnmanaged(diagnostic.Diagnostic),
) Error!void {
    if (definition.seen) return lineError(allocator, diagnostics, tokens[0], "duplicate VFrameFormat definition");
    if (tokens.len < 7 or !std.mem.eql(u8, tokens[1].text, "BO_") or tokens[2].kind != .string or !std.mem.eql(u8, tokens[3].text, "ENUM"))
        return lineError(allocator, diagnostics, tokens[0], "malformed VFrameFormat definition");

    var index: usize = 4;
    var enum_value: u16 = 0;
    var found_terminator = false;
    while (index < tokens.len) {
        if (std.mem.eql(u8, tokens[index].text, ";")) {
            found_terminator = true;
            index += 1;
            break;
        }
        if (tokens[index].kind != .string) return lineError(allocator, diagnostics, tokens[index], "VFrameFormat enum values must be strings");
        const label = tokens[index].text;
        if (std.mem.eql(u8, label, "StandardCAN_FD") or std.mem.eql(u8, label, "ExtendedCAN_FD") or std.mem.eql(u8, label, "J1939PG_FD"))
            try definition.fd_values.append(doc.allocator(), enum_value);
        enum_value = std.math.add(u16, enum_value, 1) catch return lineError(allocator, diagnostics, tokens[index], "too many VFrameFormat enum values");
        index += 1;
        if (index < tokens.len and std.mem.eql(u8, tokens[index].text, ";")) continue;
        if (index >= tokens.len or !std.mem.eql(u8, tokens[index].text, ","))
            return lineError(allocator, diagnostics, tokens[index - 1], "expected comma in VFrameFormat definition");
        index += 1;
    }
    if (!found_terminator or index != tokens.len or enum_value == 0)
        return lineError(allocator, diagnostics, tokens[0], "incomplete VFrameFormat definition");
    definition.seen = true;
}

fn parseFrameFormatAssignment(
    doc: *model.Document,
    tokens: []const Token,
    definition: *const FrameFormatDefinition,
    allocator: std.mem.Allocator,
    diagnostics: *std.ArrayListUnmanaged(diagnostic.Diagnostic),
) Error!void {
    if (tokens.len != 6 or !std.mem.eql(u8, tokens[2].text, "BO_") or !std.mem.eql(u8, tokens[5].text, ";"))
        return lineError(allocator, diagnostics, tokens[0], "malformed VFrameFormat assignment");
    const raw_id = std.fmt.parseInt(u32, tokens[3].text, 10) catch
        return lineError(allocator, diagnostics, tokens[3], "invalid VFrameFormat message identifier");
    const enum_value = std.fmt.parseInt(u16, tokens[4].text, 10) catch
        return lineError(allocator, diagnostics, tokens[4], "invalid VFrameFormat enum value");
    const extended = raw_id & 0x80000000 != 0;
    const id = raw_id & 0x1fffffff;
    const is_fd = if (definition.seen) containsEnumValue(definition.fd_values.items, enum_value) else enum_value == 14 or enum_value == 15 or enum_value == 16;
    for (doc.messages.items) |*message| {
        const message_id = std.fmt.parseInt(u32, message.id[2..], 16) catch continue;
        if (message_id == id and message.extended == extended) {
            message.frame = if (is_fd) .fd else .classic;
            return;
        }
    }
    return lineError(allocator, diagnostics, tokens[3], "VFrameFormat assignment references an unknown message");
}

fn parseMessageAttributeDefinition(
    doc: *model.Document,
    tokens: []const Token,
    allocator: std.mem.Allocator,
    diagnostics: *std.ArrayListUnmanaged(diagnostic.Diagnostic),
) Error!void {
    if (tokens.len != 7 or !std.mem.eql(u8, tokens[1].text, "BO_") or tokens[2].kind != .string or !std.mem.eql(u8, tokens[3].text, "INT") or !std.mem.eql(u8, tokens[6].text, ";"))
        return lineError(allocator, diagnostics, tokens[0], "unsupported or malformed message attribute definition");
    var minimum_index: usize = 4;
    const minimum = try readDecimal(tokens, &minimum_index, doc.allocator(), allocator, diagnostics);
    const maximum = try readDecimal(tokens, &minimum_index, doc.allocator(), allocator, diagnostics);
    if (minimum_index != 6) return lineError(allocator, diagnostics, tokens[minimum_index], "malformed message attribute bounds");
    try doc.attribute_definitions.append(doc.allocator(), .{
        .name = try decodeDbcString(doc.allocator(), tokens[2].text),
        .scope = .message,
        .value_type = .integer,
        .minimum = minimum,
        .maximum = maximum,
    });
}

fn parseMessageAttributeDefault(
    doc: *model.Document,
    tokens: []const Token,
    allocator: std.mem.Allocator,
    diagnostics: *std.ArrayListUnmanaged(diagnostic.Diagnostic),
) Error!void {
    if (tokens.len != 4 or tokens[1].kind != .string or !std.mem.eql(u8, tokens[3].text, ";"))
        return lineError(allocator, diagnostics, tokens[0], "malformed message attribute default");
    for (doc.attribute_definitions.items) |*definition| {
        if (!std.mem.eql(u8, definition.name, tokens[1].text)) continue;
        if (definition.scope != .message or definition.value_type != .integer)
            return lineError(allocator, diagnostics, tokens[1], "unsupported message attribute default type");
        var index: usize = 2;
        definition.default = .{ .integer = try readDecimal(tokens, &index, doc.allocator(), allocator, diagnostics) };
        return;
    }
    return lineError(allocator, diagnostics, tokens[1], "default references an unknown attribute definition");
}

fn parseMessageAttributeAssignment(
    doc: *model.Document,
    tokens: []const Token,
    allocator: std.mem.Allocator,
    diagnostics: *std.ArrayListUnmanaged(diagnostic.Diagnostic),
) Error!void {
    if (tokens.len != 6 or !std.mem.eql(u8, tokens[2].text, "BO_") or !std.mem.eql(u8, tokens[5].text, ";"))
        return lineError(allocator, diagnostics, tokens[0], "unsupported or malformed message attribute assignment");
    const raw_id = std.fmt.parseInt(u32, tokens[3].text, 10) catch
        return lineError(allocator, diagnostics, tokens[3], "invalid message attribute identifier");
    const id = raw_id & 0x1fffffff;
    const extended = raw_id & 0x80000000 != 0;
    for (doc.messages.items) |*message| {
        const message_id = std.fmt.parseInt(u32, message.id[2..], 16) catch continue;
        if (message_id != id or message.extended != extended) continue;
        var index: usize = 4;
        const value = try readDecimal(tokens, &index, doc.allocator(), allocator, diagnostics);
        try message.attributes.append(doc.allocator(), .{
            .name = try decodeDbcString(doc.allocator(), tokens[1].text),
            .value = .{ .integer = value },
        });
        return;
    }
    return lineError(allocator, diagnostics, tokens[3], "attribute assignment references an unknown message");
}

fn containsEnumValue(values: []const u16, expected: u16) bool {
    for (values) |value| if (value == expected) return true;
    return false;
}

fn sameRanges(left: []const model.RawRange, right: []const model.RawRange) bool {
    if (left.len != right.len) return false;
    for (left, right) |left_range, right_range| {
        if (!std.mem.eql(u8, left_range.minimum, right_range.minimum) or
            !std.mem.eql(u8, left_range.maximum, right_range.maximum)) return false;
    }
    return true;
}

fn conditionsEqual(left: model.MuxCondition, right: model.MuxCondition) bool {
    return std.mem.eql(u8, left.selector, right.selector) and sameRanges(left.ranges.items, right.ranges.items);
}

fn findSignal(message: *const model.Message, name: []const u8) ?*const model.Signal {
    for (message.signals.items) |*signal| {
        if (std.mem.eql(u8, signal.name, name)) return signal;
    }
    return null;
}

fn hasSelector(conditions: []const model.MuxCondition, name: []const u8) bool {
    for (conditions) |condition| if (std.mem.eql(u8, condition.selector, name)) return true;
    return false;
}

/// DBC records one parent selector per signal, so the parent's own conditions are implied.
fn conditionImplied(message: *const model.Message, selector: *const model.Signal, condition: model.MuxCondition, depth: usize) bool {
    if (depth > message.signals.items.len) return false;
    for (selector.when.items) |ancestor| {
        if (conditionsEqual(ancestor, condition)) return true;
        const parent = findSignal(message, ancestor.selector) orelse continue;
        if (conditionImplied(message, parent, condition, depth + 1)) return true;
    }
    return false;
}

/// Index of the one condition DBC can carry; all others must be implied by that selector's own conditions.
fn parentCondition(message: *const model.Message, signal: *const model.Signal) ?usize {
    if (signal.when.items.len == 0) return null;
    if (signal.when.items.len == 1) return 0;
    for (signal.when.items, 0..) |candidate, index| {
        const selector = findSignal(message, candidate.selector) orelse continue;
        var covered = true;
        for (signal.when.items, 0..) |other, other_index| {
            if (index != other_index and !conditionImplied(message, selector, other, 0)) {
                covered = false;
                break;
            }
        }
        if (covered) return index;
    }
    return null;
}

fn collectMuxAncestors(
    arena: std.mem.Allocator,
    message: *const model.Message,
    selector_name: []const u8,
    list: *std.ArrayListUnmanaged(model.MuxCondition),
    depth: usize,
) std.mem.Allocator.Error!void {
    if (depth > message.signals.items.len) return;
    const selector = findSignal(message, selector_name) orelse return;
    for (selector.when.items) |ancestor| {
        try collectMuxAncestors(arena, message, ancestor.selector, list, depth + 1);
        if (!hasSelector(list.items, ancestor.selector)) try list.append(arena, ancestor);
    }
}

/// Signals may precede their selector, so markers without one resolve to the message's only multiplexer.
fn resolveMuxSelectors(
    doc: *model.Document,
    allocator: std.mem.Allocator,
    diagnostics: *std.ArrayListUnmanaged(diagnostic.Diagnostic),
) Error!void {
    const arena = doc.allocator();
    for (doc.messages.items) |*message| {
        var root: []const u8 = "";
        var root_count: usize = 0;
        for (message.signals.items) |signal| {
            if (!signal.is_multiplexer) continue;
            root = signal.name;
            root_count += 1;
        }
        for (message.signals.items) |*signal| {
            for (signal.when.items) |*condition| {
                if (condition.selector.len != 0) continue;
                if (root_count != 1) {
                    try diagnostics.append(allocator, .{
                        .severity = .@"error",
                        .code = .invalid_dbc,
                        .message = "multiplexer selector cannot be determined without SG_MUL_VAL_",
                        .context = .{ .message = message.name, .signal = signal.name },
                    });
                    return error.InvalidDbc;
                }
                condition.selector = try arena.dupe(u8, root);
            }
        }
    }
}

fn expandMuxAncestors(doc: *model.Document) std.mem.Allocator.Error!void {
    const arena = doc.allocator();
    for (doc.messages.items) |*message| {
        for (message.signals.items) |*signal| {
            if (signal.when.items.len == 0) continue;
            var expanded: std.ArrayListUnmanaged(model.MuxCondition) = .empty;
            for (signal.when.items) |condition| try collectMuxAncestors(arena, message, condition.selector, &expanded, 0);
            if (expanded.items.len == 0) continue;
            for (signal.when.items) |condition| {
                if (!hasSelector(expanded.items, condition.selector)) try expanded.append(arena, condition);
            }
            signal.when = expanded;
        }
    }
}

fn findValueTable(doc: *const model.Document, name: []const u8) ?[]const model.Choice {
    for (doc.value_tables.items) |table| {
        if (std.mem.eql(u8, table.name, name)) return table.choices.items;
    }
    return null;
}

fn findAttributeDefinition(doc: *const model.Document, name: []const u8) ?*const model.AttributeDefinition {
    for (doc.attribute_definitions.items) |*definition| {
        if (std.mem.eql(u8, definition.name, name)) return definition;
    }
    return null;
}

fn isMessageIntegerAttribute(doc: *const model.Document, name: []const u8) bool {
    const definition = findAttributeDefinition(doc, name) orelse return false;
    return definition.scope == .message and definition.value_type == .integer;
}

fn signalChoices(doc: *const model.Document, signal: model.Signal) []const model.Choice {
    if (signal.choices.items.len > 0) return signal.choices.items;
    if (signal.value_table) |table_name| return findValueTable(doc, table_name) orelse &.{};
    return &.{};
}

pub fn write(allocator: std.mem.Allocator, doc: *const model.Document) Error![]u8 {
    var diagnostics: std.ArrayListUnmanaged(diagnostic.Diagnostic) = .empty;
    defer diagnostics.deinit(allocator);
    return writeWithDiagnostics(allocator, doc, &diagnostics);
}

/// Like `write`, but appends warnings for omitted metadata and errors for export blockers.
/// Messages are static; contexts borrow from `doc`.
pub fn writeWithDiagnostics(allocator: std.mem.Allocator, doc: *const model.Document, diagnostics: *std.ArrayListUnmanaged(diagnostic.Diagnostic)) Error![]u8 {
    const start_count = diagnostics.items.len;
    var opaque_statements: ?std.json.Array = null;
    const bus_name: ?[]const u8 = if (doc.buses.items.len > 0) doc.buses.items[0].name else null;
    const bus_ctx: diagnostic.Context = .{ .bus = bus_name };
    if (doc.buses.items.len > 1) try blocker(allocator, diagnostics, "more than one bus cannot be exported", .{});
    if (doc.value_tables.items.len > 0) try warn(allocator, diagnostics, "document value tables are expanded into DBC signal values", .{});
    if (doc.attributes.items.len > 0) try blocker(allocator, diagnostics, "document-level attribute assignments cannot be exported", .{});
    if (doc.name != null) try warn(allocator, diagnostics, "document name is omitted from DBC export", .{});
    if (doc.description != null) try warn(allocator, diagnostics, "document description is omitted from DBC export", .{});
    if (doc.extensions != null) try warn(allocator, diagnostics, "document extensions are omitted from DBC export", .{});
    if (doc.dbc) |metadata| {
        if (metadata != .object) {
            try blocker(allocator, diagnostics, "dbc metadata must be an object", .{});
        } else {
            var it = metadata.object.iterator();
            while (it.next()) |entry| {
                if (std.mem.eql(u8, entry.key_ptr.*, "version")) {
                    if (entry.value_ptr.* != .string) {
                        try blocker(allocator, diagnostics, "dbc.version must be a string", .{});
                    } else if (!validDbcString(entry.value_ptr.string)) {
                        try blocker(allocator, diagnostics, "dbc.version contains unsupported control characters", .{});
                    }
                } else if (std.mem.eql(u8, entry.key_ptr.*, "opaque_statements")) {
                    if (entry.value_ptr.* != .array) {
                        try blocker(allocator, diagnostics, "dbc.opaque_statements must be an array", .{});
                    } else opaque_statements = entry.value_ptr.array;
                } else try warn(allocator, diagnostics, "unknown dbc metadata is omitted from DBC export", .{});
            }
        }
    }
    for (doc.attribute_definitions.items) |definition| {
        if (definition.scope != .message or definition.value_type != .integer or definition.minimum == null or definition.maximum == null)
            try blocker(allocator, diagnostics, "only bounded message integer attribute definitions can be exported", .{});
        if (definition.default) |default| {
            if (default != .integer) try blocker(allocator, diagnostics, "only integer attribute defaults can be exported", .{});
        }
        if (definition.dbc != null or definition.extensions != null)
            try blocker(allocator, diagnostics, "attribute definition metadata cannot be exported", .{});
        if (!validDbcString(definition.name)) try blocker(allocator, diagnostics, "attribute name contains unsupported control characters", .{});
    }
    if (doc.buses.items.len == 1) {
        const bus = doc.buses.items[0];
        if (!std.mem.eql(u8, bus.name, "can0")) try blocker(allocator, diagnostics, "bus must be named can0", bus_ctx);
        if (bus.description != null) try blocker(allocator, diagnostics, "bus description cannot be exported", bus_ctx);
        if (bus.protocol != null) try blocker(allocator, diagnostics, "bus protocol cannot be exported", bus_ctx);
        if (bus.attributes.items.len > 0) try blocker(allocator, diagnostics, "bus attributes cannot be exported", bus_ctx);
        if (bus.dbc != null or bus.extensions != null) try blocker(allocator, diagnostics, "bus dbc metadata and extensions cannot be exported", bus_ctx);
    }
    for (doc.nodes.items) |node| {
        if (!isIdentifier(node.name)) try blocker(allocator, diagnostics, "node name is not a valid DBC identifier", .{});
        if (node.description) |description| {
            if (!validDbcString(description)) try blocker(allocator, diagnostics, "node description contains unsupported control characters", .{});
        }
        if (node.attributes.items.len > 0) try blocker(allocator, diagnostics, "node attributes cannot be exported", .{});
        if (node.dbc != null or node.extensions != null) try blocker(allocator, diagnostics, "node dbc metadata and extensions cannot be exported", .{});
    }
    if (opaque_statements) |statements| {
        for (statements.items) |statement| {
            if (!validOpaqueStatement(statement)) try blocker(allocator, diagnostics, "invalid dbc.opaque_statements entry", .{});
        }
    }
    for (doc.messages.items) |message| {
        const mctx: diagnostic.Context = .{ .bus = bus_name, .message = message.name };
        if (message.receivers.items.len > 0) try blocker(allocator, diagnostics, "message receivers cannot be exported", mctx);
        if (message.description != null) try blocker(allocator, diagnostics, "message description cannot be exported", mctx);
        if (message.dbc != null or message.extensions != null) try blocker(allocator, diagnostics, "message dbc metadata and extensions cannot be exported", mctx);
        if (message.transmitters.items.len > 1) try blocker(allocator, diagnostics, "more than one transmitter cannot be exported", mctx);
        if (!isIdentifier(message.name)) try blocker(allocator, diagnostics, "message name is not a valid DBC identifier", mctx);
        if (message.transmitters.items.len == 1 and !isIdentifier(message.transmitters.items[0])) try blocker(allocator, diagnostics, "transmitter name is not a valid DBC identifier", mctx);
        for (message.attributes.items) |assignment| {
            const definition = findAttributeDefinition(doc, assignment.name) orelse {
                try blocker(allocator, diagnostics, "message attribute assignment has no definition", mctx);
                continue;
            };
            if (definition.scope != .message or definition.value_type != .integer or assignment.value != .integer)
                try blocker(allocator, diagnostics, "only message integer attribute assignments can be exported", mctx);
        }
        for (message.signals.items) |signal| {
            const sctx: diagnostic.Context = .{ .bus = bus_name, .message = message.name, .signal = signal.name };
            if (signal.when.items.len > 0) {
                if (parentCondition(&message, &signal) == null)
                    try blocker(allocator, diagnostics, "multiplexer conditions cannot be reduced to one DBC parent selector", sctx);
                for (signal.when.items) |condition| {
                    if (condition.ranges.items.len == 0)
                        try blocker(allocator, diagnostics, "multiplexer condition requires at least one range", sctx);
                }
            }
            if (signal.unit) |unit| {
                if (!validDbcString(unit)) try blocker(allocator, diagnostics, "signal unit contains unsupported control characters", sctx);
            }
            if (signal.description) |description| {
                if (!validDbcString(description)) try blocker(allocator, diagnostics, "signal description contains unsupported control characters", sctx);
            }
            if (signal.attributes.items.len > 0) try blocker(allocator, diagnostics, "signal attributes cannot be exported", sctx);
            if (signal.value_table) |table_name| {
                if (findValueTable(doc, table_name) == null) try blocker(allocator, diagnostics, "signal references an unknown value table", sctx);
            }
            if (signal.dbc != null or signal.extensions != null) try blocker(allocator, diagnostics, "signal dbc metadata and extensions cannot be exported", sctx);
            if (!isIdentifier(signal.name)) try blocker(allocator, diagnostics, "signal name is not a valid DBC identifier", sctx);
            for (signal.receivers.items) |receiver| if (!isIdentifier(receiver)) try blocker(allocator, diagnostics, "receiver name is not a valid DBC identifier", sctx);
        }
    }
    for (diagnostics.items[start_count..]) |item| {
        if (item.severity == .@"error") return error.UnsupportedConstruct;
    }
    var output: std.ArrayListUnmanaged(u8) = .empty;
    errdefer output.deinit(allocator);
    const version = if (doc.dbc) |metadata| if (metadata.object.get("version")) |v| v.string else "" else "";
    try appendText(allocator, &output, "VERSION ");
    try appendDbcString(allocator, &output, version);
    try appendText(allocator, &output, "\n\nNS_ :");
    var has_comments = false;
    var has_fd_frames = false;
    var has_mux_values = false;
    var has_float_signals = false;
    var has_message_attributes = doc.attribute_definitions.items.len > 0;
    var has_value_tables = false;
    for (doc.messages.items) |message| {
        if (message.frame == .fd) has_fd_frames = true;
        if (message.attributes.items.len > 0) has_message_attributes = true;
        for (message.signals.items) |signal| {
            if (signal.description != null) has_comments = true;
            if (signal.when.items.len > 0) has_mux_values = true;
            if (signal.signal_type == .float32 or signal.signal_type == .float64) has_float_signals = true;
            if (signalChoices(doc, signal).len > 0) has_value_tables = true;
        }
    }
    for (doc.nodes.items) |node| {
        if (node.description != null) has_comments = true;
    }
    if (has_comments) try appendText(allocator, &output, "\n  CM_");
    if (has_fd_frames or has_message_attributes) try appendText(allocator, &output, "\n  BA_DEF_\n  BA_");
    if (has_mux_values) try appendText(allocator, &output, "\n  SG_MUL_VAL_");
    if (has_float_signals) try appendText(allocator, &output, "\n  SIG_VALTYPE_");
    if (has_value_tables) try appendText(allocator, &output, "\n  VAL_");
    try appendText(allocator, &output, "\n\nBS_:\n\nBU_:");
    for (doc.nodes.items) |node| try appendFmt(allocator, &output, " {s}", .{node.name});
    try appendText(allocator, &output, "\n\n");
    for (doc.messages.items) |message| {
        const id = std.fmt.parseInt(u32, message.id[2..], 16) catch return error.InvalidDbc;
        const raw_id = id | (if (message.extended) @as(u32, 0x80000000) else 0);
        const transmitter = if (message.transmitters.items.len == 0) "Vector__XXX" else message.transmitters.items[0];
        try appendFmt(allocator, &output, "\nBO_ {d} {s}: {d} {s}\n", .{ raw_id, message.name, message.length, transmitter });
        for (message.signals.items) |signal| {
            // External parsers only honour SG_MUL_VAL_ for signals that carry an mN marker.
            const parent_index = parentCondition(&message, &signal);
            const mux_marker: []const u8 = if (parent_index) |index| blk: {
                const first = signal.when.items[index].ranges.items[0].minimum;
                break :blk if (signal.is_multiplexer)
                    try std.fmt.allocPrint(allocator, " m{s}M", .{first})
                else
                    try std.fmt.allocPrint(allocator, " m{s}", .{first});
            } else if (signal.is_multiplexer) " M" else "";
            defer if (parent_index != null) allocator.free(mux_marker);
            const sign: u8 = if (signal.signal_type == .signed) '-' else '+';
            const endian: u8 = if (signal.byte_order == .little_endian) '1' else '0';
            try appendFmt(allocator, &output, " SG_ {s}{s} : {d}|{d}@{c}{c} ({s},{s}) [{s}|{s}] ", .{
                signal.name,
                mux_marker,
                signal.start_bit,
                signal.bit_length,
                endian,
                sign,
                signal.factor,
                signal.offset,
                signal.minimum orelse "0",
                signal.maximum orelse "0",
            });
            try appendDbcString(allocator, &output, signal.unit orelse "");
            try appendText(allocator, &output, " ");
            if (signal.receivers.items.len == 0) {
                try appendText(allocator, &output, " Vector__XXX\n");
            } else {
                for (signal.receivers.items, 0..) |receiver, receiver_index| {
                    if (receiver_index > 0) try appendText(allocator, &output, " ");
                    try appendText(allocator, &output, receiver);
                }
                try appendText(allocator, &output, "\n");
            }
        }
    }
    for (doc.messages.items) |message| {
        const id = std.fmt.parseInt(u32, message.id[2..], 16) catch return error.InvalidDbc;
        const raw_id = id | (if (message.extended) @as(u32, 0x80000000) else 0);
        for (message.signals.items) |signal| {
            if (parentCondition(&message, &signal)) |index| {
                const condition = signal.when.items[index];
                try appendFmt(allocator, &output, "SG_MUL_VAL_ {d} {s} {s}", .{ raw_id, signal.name, condition.selector });
                for (condition.ranges.items, 0..) |range, range_index| {
                    if (range_index > 0) try appendText(allocator, &output, ",");
                    try appendFmt(allocator, &output, " {s}-{s}", .{ range.minimum, range.maximum });
                }
                try appendText(allocator, &output, ";\n");
            }
            if (signal.description) |description| {
                try appendFmt(allocator, &output, "CM_ SG_ {d} {s} ", .{ raw_id, signal.name });
                try appendDbcString(allocator, &output, description);
                try appendText(allocator, &output, ";\n");
            }
            if (signal.signal_type == .float32 or signal.signal_type == .float64) {
                const value_type: u8 = if (signal.signal_type == .float32) 1 else 2;
                try appendFmt(allocator, &output, "SIG_VALTYPE_ {d} {s} : {d};\n", .{ raw_id, signal.name, value_type });
            }
            const choices = signalChoices(doc, signal);
            if (choices.len > 0) {
                try appendFmt(allocator, &output, "VAL_ {d} {s}", .{ raw_id, signal.name });
                for (choices) |choice| {
                    try appendFmt(allocator, &output, " {s} ", .{choice.raw});
                    try appendDbcString(allocator, &output, choice.label);
                }
                try appendText(allocator, &output, ";\n");
            }
        }
    }
    for (doc.nodes.items) |node| {
        if (node.description) |description| {
            try appendFmt(allocator, &output, "CM_ BU_ {s} ", .{node.name});
            try appendDbcString(allocator, &output, description);
            try appendText(allocator, &output, ";\n");
        }
    }
    if (has_fd_frames) {
        try appendText(allocator, &output, "BA_DEF_ BO_ \"VFrameFormat\" ENUM \"StandardCAN\",\"ExtendedCAN\",\"J1939PG\",\"J1939PG_21\",\"J1939PG_22\",\"J1939PG_23\",\"J1939PG_24\",\"J1939PG_25\",\"J1939PG_26\",\"J1939PG_27\",\"J1939PG_28\",\"J1939PG_29\",\"J1939PG_30\",\"J1939PG_31\",\"StandardCAN_FD\",\"ExtendedCAN_FD\",\"J1939PG_FD\";\n");
    }
    for (doc.attribute_definitions.items) |definition| {
        try appendText(allocator, &output, "BA_DEF_ BO_ ");
        try appendDbcString(allocator, &output, definition.name);
        try appendFmt(allocator, &output, " INT {s} {s};\n", .{ definition.minimum.?, definition.maximum.? });
        if (definition.default) |default| {
            try appendText(allocator, &output, "BA_DEF_DEF_ ");
            try appendDbcString(allocator, &output, definition.name);
            try appendFmt(allocator, &output, " {s};\n", .{default.integer});
        }
    }
    if (has_fd_frames) {
        for (doc.messages.items) |message| {
            if (message.frame != .fd) continue;
            const id = std.fmt.parseInt(u32, message.id[2..], 16) catch return error.InvalidDbc;
            const raw_id = id | (if (message.extended) @as(u32, 0x80000000) else 0);
            const format: u8 = if (message.extended) 15 else 14;
            try appendFmt(allocator, &output, "BA_ \"VFrameFormat\" BO_ {d} {d};\n", .{ raw_id, format });
        }
    }
    for (doc.messages.items) |message| {
        const id = std.fmt.parseInt(u32, message.id[2..], 16) catch return error.InvalidDbc;
        const raw_id = id | (if (message.extended) @as(u32, 0x80000000) else 0);
        for (message.attributes.items) |assignment| {
            try appendText(allocator, &output, "BA_ ");
            try appendDbcString(allocator, &output, assignment.name);
            try appendFmt(allocator, &output, " BO_ {d} {s};\n", .{ raw_id, assignment.value.integer });
        }
    }
    if (opaque_statements) |statements| {
        for (statements.items) |statement| {
            const raw = statement.object.get("raw").?.string;
            try appendText(allocator, &output, raw);
            if (raw.len == 0 or raw[raw.len - 1] != '\n') try appendText(allocator, &output, "\n");
        }
    }
    return output.toOwnedSlice(allocator);
}

fn blocker(allocator: std.mem.Allocator, diagnostics: *std.ArrayListUnmanaged(diagnostic.Diagnostic), message: []const u8, context: diagnostic.Context) std.mem.Allocator.Error!void {
    try diagnostics.append(allocator, .{ .severity = .@"error", .code = .unsupported_dbc_export, .message = message, .context = context });
}

fn warn(allocator: std.mem.Allocator, diagnostics: *std.ArrayListUnmanaged(diagnostic.Diagnostic), message: []const u8, context: diagnostic.Context) std.mem.Allocator.Error!void {
    try diagnostics.append(allocator, .{ .severity = .warning, .code = .unsupported_dbc_export, .message = message, .context = context });
}

fn decodeDbcString(allocator: std.mem.Allocator, text: []const u8) Error![]const u8 {
    var output: std.ArrayListUnmanaged(u8) = .empty;
    errdefer output.deinit(allocator);
    var index: usize = 0;
    while (index < text.len) : (index += 1) {
        if (text[index] != '\\') {
            try output.append(allocator, text[index]);
            continue;
        }
        index += 1;
        if (index == text.len) return error.InvalidDbc;
        const character: u8 = switch (text[index]) {
            '"' => '"',
            '\\' => '\\',
            'n' => '\n',
            'r' => '\r',
            't' => '\t',
            else => return error.InvalidDbc,
        };
        try output.append(allocator, character);
    }
    return output.toOwnedSlice(allocator);
}

fn validDbcString(text: []const u8) bool {
    for (text) |character| {
        if (character < 0x20 and character != '\n' and character != '\r' and character != '\t') return false;
    }
    return true;
}

fn appendDbcString(allocator: std.mem.Allocator, output: *std.ArrayListUnmanaged(u8), text: []const u8) Error!void {
    try appendText(allocator, output, "\"");
    for (text) |character| {
        switch (character) {
            '"' => try appendText(allocator, output, "\\\""),
            '\\' => try appendText(allocator, output, "\\\\"),
            '\n' => try appendText(allocator, output, "\\n"),
            '\r' => try appendText(allocator, output, "\\r"),
            '\t' => try appendText(allocator, output, "\\t"),
            else => {
                if (character < 0x20) return error.InvalidDbc;
                try output.append(allocator, character);
            },
        }
    }
    try appendText(allocator, output, "\"");
}

fn validOpaqueStatement(statement: std.json.Value) bool {
    if (statement != .object) return false;
    const raw = statement.object.get("raw") orelse return false;
    const line = statement.object.get("line") orelse return false;
    if (raw != .string or !isPositiveInteger(line)) return false;
    if (std.mem.indexOfAny(u8, raw.string, "\r\n") != null or raw.string.len == 0) return false;
    return statement.object.count() == 2;
}

fn isIdentifier(text: []const u8) bool {
    if (text.len == 0) return false;
    for (text) |ch| {
        if (std.ascii.isWhitespace(ch) or std.mem.indexOfScalar(u8, ":|@+-,()[];\"", ch) != null) return false;
    }
    return true;
}

fn isPositiveInteger(value: std.json.Value) bool {
    return switch (value) {
        .integer => |number| number > 0,
        .number_string => |text| (std.fmt.parseInt(u32, text, 10) catch return false) > 0,
        else => false,
    };
}

fn rawLine(input: []const u8, line_number: u32) []const u8 {
    var line: u32 = 1;
    var start: usize = 0;
    while (line < line_number and start < input.len) : (start += 1) {
        if (input[start] == '\n') line += 1;
    }
    if (start >= input.len) return "";
    var end = start;
    while (end < input.len and input[end] != '\n') : (end += 1) {}
    if (end > start and input[end - 1] == '\r') end -= 1;
    return input[start..end];
}

fn preserveOrReject(
    doc: *model.Document,
    token: Token,
    raw_statement: []const u8,
    options: ParseOptions,
    allocator: std.mem.Allocator,
    diagnostics: *std.ArrayListUnmanaged(diagnostic.Diagnostic),
) Error!void {
    if (!options.preserve_unsupported_statements)
        return lineError(allocator, diagnostics, token, "unsupported DBC statement in this import profile");

    const a = doc.allocator();
    var metadata = try ensureDbcObject(doc);
    var statements: std.json.Array = if (metadata.get("opaque_statements")) |existing| blk: {
        if (existing != .array) return error.InvalidDbc;
        break :blk existing.array;
    } else std.json.Array.init(a);
    var statement = std.json.ObjectMap.empty;
    try statement.put(a, "raw", .{ .string = try a.dupe(u8, raw_statement) });
    try statement.put(a, "line", .{ .integer = token.line });
    try statements.append(.{ .object = statement });
    try metadata.put(a, "opaque_statements", .{ .array = statements });
    doc.dbc = .{ .object = metadata };
}

fn ensureDbcObject(doc: *model.Document) Error!std.json.ObjectMap {
    if (doc.dbc) |metadata| {
        if (metadata == .object) return metadata.object;
        return error.InvalidDbc;
    }
    return std.json.ObjectMap.empty;
}

fn hasNode(doc: *const model.Document, name: []const u8) bool {
    for (doc.nodes.items) |node| if (std.mem.eql(u8, node.name, name)) return true;
    return false;
}

fn lineError(allocator: std.mem.Allocator, diagnostics: *std.ArrayListUnmanaged(diagnostic.Diagnostic), token: Token, message: []const u8) Error {
    diagnostics.append(allocator, .{
        .severity = .@"error",
        .code = .invalid_dbc,
        .message = message,
        .source = .{ .dbc = .{ .line = token.line, .column = token.column } },
    }) catch return error.OutOfMemory;
    return error.InvalidDbc;
}

fn expectToken(tokens: []const Token, index: *usize, expected: []const u8, allocator: std.mem.Allocator, diagnostics: *std.ArrayListUnmanaged(diagnostic.Diagnostic)) Error!void {
    if (index.* >= tokens.len or !std.mem.eql(u8, tokens[index.*].text, expected)) {
        const token = if (index.* < tokens.len) tokens[index.*] else tokens[tokens.len - 1];
        return lineError(allocator, diagnostics, token, "unexpected token in DBC statement");
    }
    index.* += 1;
}

fn readUnsigned(tokens: []const Token, index: *usize, allocator: std.mem.Allocator, diagnostics: *std.ArrayListUnmanaged(diagnostic.Diagnostic)) Error!u64 {
    if (index.* >= tokens.len) return lineError(allocator, diagnostics, tokens[tokens.len - 1], "missing integer value");
    const result = std.fmt.parseInt(u64, tokens[index.*].text, 10) catch return lineError(allocator, diagnostics, tokens[index.*], "invalid integer value");
    index.* += 1;
    return result;
}

fn readDecimal(tokens: []const Token, index: *usize, arena: std.mem.Allocator, diagnostic_allocator: std.mem.Allocator, diagnostics: *std.ArrayListUnmanaged(diagnostic.Diagnostic)) Error![]const u8 {
    if (index.* >= tokens.len) return lineError(diagnostic_allocator, diagnostics, tokens[tokens.len - 1], "missing decimal value");
    var negative = false;
    if (std.mem.eql(u8, tokens[index.*].text, "-")) {
        negative = true;
        index.* += 1;
    } else if (std.mem.eql(u8, tokens[index.*].text, "+")) {
        index.* += 1;
    }
    if (index.* >= tokens.len) return lineError(diagnostic_allocator, diagnostics, tokens[tokens.len - 1], "missing decimal digits");
    const number = tokens[index.*].text;
    index.* += 1;
    return if (negative) try std.fmt.allocPrint(arena, "-{s}", .{number}) else try arena.dupe(u8, number);
}

fn appendText(allocator: std.mem.Allocator, output: *std.ArrayListUnmanaged(u8), text: []const u8) std.mem.Allocator.Error!void {
    try output.appendSlice(allocator, text);
}

fn appendFmt(allocator: std.mem.Allocator, output: *std.ArrayListUnmanaged(u8), comptime fmt: []const u8, args: anytype) std.mem.Allocator.Error!void {
    const text = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(text);
    try output.appendSlice(allocator, text);
}

test "DBC lexer reports line and column and parses baseline message profile" {
    const source =
        \\VERSION "1"
        \\NS_ :
        \\  NS_DESC_
        \\  CM_
        \\BS_:
        \\BU_: ECU DASH
        \\BO_ 291 Engine: 2 ECU
        \\ SG_ Page M : 0|2@1+ (1,0) [0|3] "" DASH
        \\ SG_ State m1 : 8|8@1- (0.5,-1) [-40|40] "" DASH
    ;
    var diagnostics: std.ArrayListUnmanaged(diagnostic.Diagnostic) = .empty;
    defer diagnostics.deinit(std.testing.allocator);
    var doc = try parse(std.testing.allocator, source, &diagnostics);
    defer doc.deinit();
    try std.testing.expectEqual(@as(usize, 1), doc.messages.items.len);
    try std.testing.expectEqualStrings("Engine", doc.messages.items[0].name);
    try std.testing.expect(doc.messages.items[0].signals.items[0].is_multiplexer);
    try std.testing.expectEqualStrings("Page", doc.messages.items[0].signals.items[1].when.items[0].selector);
    try std.testing.expectEqualStrings("-1", doc.messages.items[0].signals.items[1].offset);
    try std.testing.expectEqualStrings("1", doc.dbc.?.object.get("version").?.string);

    const output = try write(std.testing.allocator, &doc);
    defer std.testing.allocator.free(output);
    var reparsed = try parse(std.testing.allocator, output, &diagnostics);
    defer reparsed.deinit();
    try std.testing.expectEqualStrings("State", reparsed.messages.items[0].signals.items[1].name);
}

test "signal comments import and export with DBC string escaping" {
    const source =
        \\BO_ 291 Engine: 1 ECU
        \\ SG_ Value : 0|8@1+ (1,0) [0|255] "" ECU
        \\CM_ SG_ 291 Value "quoted \"text\" and \\ path";
    ;
    var diagnostics: std.ArrayListUnmanaged(diagnostic.Diagnostic) = .empty;
    defer diagnostics.deinit(std.testing.allocator);
    var doc = try parse(std.testing.allocator, source, &diagnostics);
    defer doc.deinit();
    const description = "quoted \"text\" and \\ path";
    try std.testing.expectEqualStrings(description, doc.messages.items[0].signals.items[0].description.?);

    const output = try write(std.testing.allocator, &doc);
    defer std.testing.allocator.free(output);
    var reparsed = try parse(std.testing.allocator, output, &diagnostics);
    defer reparsed.deinit();
    try std.testing.expectEqualStrings(description, reparsed.messages.items[0].signals.items[0].description.?);
}

test "VFrameFormat imports and exports CAN FD frames with CRLF lines" {
    const source = "VERSION \"1\"\r\nNS_ :\r\nBS_:\r\nBU_: ECU\r\nBO_ 291 Engine: 8 ECU\r\n SG_ Value : 0|8@1+ (1,0) [0|255] \"\" ECU\r\nBA_DEF_ BO_ \"VFrameFormat\" ENUM \"StandardCAN\",\"ExtendedCAN\",\"StandardCAN_FD\",\"ExtendedCAN_FD\";\r\nBA_ \"VFrameFormat\" BO_ 291 2;\r\n";
    var diagnostics: std.ArrayListUnmanaged(diagnostic.Diagnostic) = .empty;
    defer diagnostics.deinit(std.testing.allocator);
    var doc = try parse(std.testing.allocator, source, &diagnostics);
    defer doc.deinit();
    try std.testing.expectEqual(model.FrameKind.fd, doc.messages.items[0].frame);
    try std.testing.expectEqual(@as(u16, 8), doc.messages.items[0].length);

    const output = try write(std.testing.allocator, &doc);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "BA_ \"VFrameFormat\" BO_ 291 14;") != null);
    var reparsed = try parse(std.testing.allocator, output, &diagnostics);
    defer reparsed.deinit();
    try std.testing.expectEqual(model.FrameKind.fd, reparsed.messages.items[0].frame);
    try std.testing.expectEqual(@as(u16, 8), reparsed.messages.items[0].length);
}

test "unimplemented DBC statements are rejected with source locations" {
    const source = "BO_ 1 M: 1 ECU\nCM_ BO_ 1 \"comment\";\n";
    var diagnostics: std.ArrayListUnmanaged(diagnostic.Diagnostic) = .empty;
    defer diagnostics.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidDbc, parse(std.testing.allocator, source, &diagnostics));
    try std.testing.expectEqual(diagnostic.Code.invalid_dbc, diagnostics.items[0].code);
    try std.testing.expectEqual(@as(u32, 2), diagnostics.items[0].source.dbc.line);
}

test "unsupported DBC statements can be preserved and exported on request" {
    const source =
        \\VERSION "1"
        \\BO_ 1 M: 1 ECU
        \\ SG_ Value : 0|8@1+ (1,0) [0|255] "" ECU
        \\CM_ BO_ 1 "comment";
        \\FOO_ arbitrary;
    ;
    var diagnostics: std.ArrayListUnmanaged(diagnostic.Diagnostic) = .empty;
    defer diagnostics.deinit(std.testing.allocator);
    var doc = try parseWithOptions(std.testing.allocator, source, &diagnostics, .{ .preserve_unsupported_statements = true });
    defer doc.deinit();

    const statements = doc.dbc.?.object.get("opaque_statements").?.array;
    try std.testing.expectEqual(@as(usize, 2), statements.items.len);
    try std.testing.expectEqualStrings("CM_ BO_ 1 \"comment\";", statements.items[0].object.get("raw").?.string);
    try std.testing.expectEqual(@as(i64, 4), statements.items[0].object.get("line").?.integer);
    try std.testing.expectEqualStrings("FOO_ arbitrary;", statements.items[1].object.get("raw").?.string);
    try std.testing.expectEqual(@as(i64, 5), statements.items[1].object.get("line").?.integer);

    const json = try can_json.write(std.testing.allocator, &doc);
    defer std.testing.allocator.free(json);
    var json_doc = try can_json.parse(std.testing.allocator, json);
    defer json_doc.deinit();
    try std.testing.expectEqual(@as(usize, 2), json_doc.dbc.?.object.get("opaque_statements").?.array.items.len);

    const output = try write(std.testing.allocator, &json_doc);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.endsWith(u8, output, "CM_ BO_ 1 \"comment\";\nFOO_ arbitrary;\n"));

    var reparsed = try parseWithOptions(std.testing.allocator, output, &diagnostics, .{ .preserve_unsupported_statements = true });
    defer reparsed.deinit();
    try std.testing.expectEqual(@as(usize, 2), reparsed.dbc.?.object.get("opaque_statements").?.array.items.len);
}

test "preservation mode does not hide malformed supported declarations" {
    var diagnostics: std.ArrayListUnmanaged(diagnostic.Diagnostic) = .empty;
    defer diagnostics.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.InvalidDbc,
        parseWithOptions(std.testing.allocator, "BO_ bad M: 1 ECU\n", &diagnostics, .{ .preserve_unsupported_statements = true }),
    );
    try std.testing.expectEqual(@as(u32, 1), diagnostics.items[0].source.dbc.line);
}
