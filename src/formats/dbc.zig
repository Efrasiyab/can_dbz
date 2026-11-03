const std = @import("std");
const model = @import("../model.zig");
const diagnostic = @import("../diagnostic.zig");
const validate = @import("../validate.zig");
const can_json = @import("can_json.zig");

pub const Error = error{ OutOfMemory, InvalidDbc, UnsupportedConstruct, UnknownBus };
pub const ParseOptions = struct {
    preserve_unsupported_statements: bool = false,
};
pub const TokenKind = enum { word, string, punctuation };
pub const Token = struct {
    kind: TokenKind,
    text: []const u8,
    line: u32,
    end_line: u32,
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
                if (self.input[self.offset] == '\n') {
                    self.offset += 1;
                    self.line += 1;
                    self.column = 1;
                    continue;
                }
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
            return .{ .kind = .string, .text = text, .line = token_line, .end_line = self.line, .column = token_column };
        }
        if (std.mem.indexOfScalar(u8, ":|@+-,()[];", first) != null) {
            self.offset += 1;
            self.column += 1;
            return .{ .kind = .punctuation, .text = self.input[start..self.offset], .line = token_line, .end_line = token_line, .column = token_column };
        }
        while (self.offset < self.input.len) {
            const ch = self.input[self.offset];
            const following: ?u8 = if (self.offset + 1 < self.input.len) self.input[self.offset + 1] else null;
            if (continuesExponent(self.input[start..self.offset], ch, following)) {
                self.offset += 1;
                self.column += 1;
                continue;
            }
            if (std.ascii.isWhitespace(ch) or ch == '"' or std.mem.indexOfScalar(u8, ":|@+-,()[];", ch) != null) break;
            self.offset += 1;
            self.column += 1;
        }
        return .{ .kind = .word, .text = self.input[start..self.offset], .line = token_line, .end_line = token_line, .column = token_column };
    }
};

/// Keeps the sign of `1.5E+019` inside one number token instead of splitting it as punctuation.
fn continuesExponent(word: []const u8, sign: u8, following: ?u8) bool {
    if ((sign != '+' and sign != '-') or word.len < 2) return false;
    if (word[word.len - 1] != 'e' and word[word.len - 1] != 'E') return false;
    var has_digit = false;
    for (word[0 .. word.len - 1]) |character| {
        if (std.ascii.isDigit(character)) {
            has_digit = true;
        } else if (character != '.') return false;
    }
    return has_digit and following != null and std.ascii.isDigit(following.?);
}

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
    var statement_end: u32 = 1;
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
        if (current_line.items.len > 0 and token.line != statement_end) {
            try parseLine(
                &doc,
                &current_message,
                &last_mux,
                &frame_format_definition,
                &in_namespace_listing,
                current_line.items,
                rawStatement(bytes, line_number, statement_end),
                options,
                allocator,
                diagnostics,
            );
            current_line.clearRetainingCapacity();
        }
        if (current_line.items.len == 0) line_number = token.line;
        try current_line.append(a, token);
        statement_end = token.end_line;
    }
    if (current_line.items.len > 0) {
        try parseLine(
            &doc,
            &current_message,
            &last_mux,
            &frame_format_definition,
            &in_namespace_listing,
            current_line.items,
            rawStatement(bytes, line_number, statement_end),
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

/// Vector's container for signals not assigned to any frame; the model has no place for them.
const independent_message_id: u32 = 0xC0000000;
const independent_message: usize = std.math.maxInt(usize);

fn referencesIndependentMessage(tokens: []const Token) bool {
    if (tokens.len < 2) return false;
    const keyword = tokens[0].text;
    var id_index: usize = 0;
    if (std.mem.eql(u8, keyword, "VAL_") or std.mem.eql(u8, keyword, "SG_MUL_VAL_") or std.mem.eql(u8, keyword, "SIG_VALTYPE_")) {
        id_index = 1;
    } else if (std.mem.eql(u8, keyword, "CM_") and tokens.len > 2 and (std.mem.eql(u8, tokens[1].text, "BO_") or std.mem.eql(u8, tokens[1].text, "SG_"))) {
        id_index = 2;
    } else if (std.mem.eql(u8, keyword, "BA_") and tokens.len > 3 and (std.mem.eql(u8, tokens[2].text, "BO_") or std.mem.eql(u8, tokens[2].text, "SG_"))) {
        id_index = 3;
    } else return false;
    const raw_id = std.fmt.parseInt(u32, tokens[id_index].text, 10) catch return false;
    return raw_id == independent_message_id;
}

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
    if (referencesIndependentMessage(tokens)) return;
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
    if (std.mem.eql(u8, keyword, "CM_") and tokens.len > 1 and tokens[1].kind == .string)
        return parseGlobalComment(doc, tokens, allocator, diagnostics);
    if (std.mem.eql(u8, keyword, "CM_") and tokens.len > 1 and std.mem.eql(u8, tokens[1].text, "SG_"))
        return parseSignalComment(doc, tokens, allocator, diagnostics);
    if (std.mem.eql(u8, keyword, "CM_") and tokens.len > 1 and std.mem.eql(u8, tokens[1].text, "BU_"))
        return parseNodeComment(doc, tokens, allocator, diagnostics);
    if (std.mem.eql(u8, keyword, "CM_") and tokens.len > 1 and std.mem.eql(u8, tokens[1].text, "BO_"))
        return parseMessageComment(doc, tokens, allocator, diagnostics);
    if (std.mem.eql(u8, keyword, "CM_") and tokens.len > 1 and std.mem.eql(u8, tokens[1].text, "EV_"))
        return parseEnvironmentVariableComment(doc, tokens, allocator, diagnostics);
    if (std.mem.eql(u8, keyword, "EV_"))
        return parseEnvironmentVariable(doc, tokens, raw_line, options, allocator, diagnostics);
    if (std.mem.eql(u8, keyword, "ENVVAR_DATA_"))
        return parseEnvironmentVariableData(doc, tokens, allocator, diagnostics);
    if (std.mem.eql(u8, keyword, "VAL_TABLE_"))
        return parseValueTable(doc, tokens, allocator, diagnostics);
    if (std.mem.eql(u8, keyword, "SG_MUL_VAL_"))
        return parseSignalMultiplexerValues(doc, tokens, allocator, diagnostics);
    if (std.mem.eql(u8, keyword, "SIG_VALTYPE_"))
        return parseSignalValueType(doc, tokens, allocator, diagnostics);
    if (std.mem.eql(u8, keyword, "VAL_") and tokens.len > 1 and tokens[1].kind == .word)
        return parseSignalValues(doc, tokens, allocator, diagnostics);
    if (std.mem.eql(u8, keyword, "BA_DEF_") and tokens.len > 2 and tokens[2].kind == .string and std.mem.eql(u8, tokens[2].text, "VFrameFormat"))
        return parseFrameFormatDefinition(doc, tokens, frame_format_definition, allocator, diagnostics);
    if (std.mem.eql(u8, keyword, "BA_DEF_")) {
        return parseAttributeDefinition(doc, tokens, raw_line, options, allocator, diagnostics);
    }
    if (std.mem.eql(u8, keyword, "BA_DEF_DEF_")) {
        if (tokens.len > 1 and tokens[1].kind == .string) {
            const name = decodeDbcString(doc.allocator(), tokens[1].text) catch
                return lineError(allocator, diagnostics, tokens[1], "invalid DBC attribute name escape");
            if (findAttributeDefinition(doc, name) != null)
                return parseAttributeDefault(doc, tokens, allocator, diagnostics);
        }
        return preserveOrReject(doc, tokens[0], raw_line, options, allocator, diagnostics);
    }
    if (std.mem.eql(u8, keyword, "BA_") and tokens.len > 1 and tokens[1].kind == .string and std.mem.eql(u8, tokens[1].text, "VFrameFormat"))
        return parseFrameFormatAssignment(doc, tokens, frame_format_definition, allocator, diagnostics);
    if (std.mem.eql(u8, keyword, "BA_") and tokens.len > 1 and tokens[1].kind == .string) {
        const name = decodeDbcString(doc.allocator(), tokens[1].text) catch
            return lineError(allocator, diagnostics, tokens[1], "invalid DBC attribute name escape");
        if (findAttributeDefinition(doc, name) != null)
            return parseAttributeAssignment(doc, tokens, allocator, diagnostics);
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
        if (raw_id == independent_message_id) {
            current_message.* = independent_message;
            last_mux.* = null;
            try diagnostics.append(allocator, .{
                .severity = .warning,
                .code = .dbc_independent_signals_skipped,
                .message = "Vector independent-signal pseudo-message and its signals are skipped",
                .source = .{ .dbc = .{ .line = tokens[0].line, .column = tokens[0].column } },
            });
            return;
        }
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
    if (std.mem.eql(u8, keyword, "BO_TX_BU_"))
        return parseMessageTransmitters(doc, tokens, allocator, diagnostics);
    if (std.mem.eql(u8, keyword, "SG_")) {
        const message_index = current_message.* orelse return lineError(allocator, diagnostics, tokens[0], "SG_ signal must follow a BO_ message");
        if (message_index == independent_message) return;
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

fn parseGlobalComment(
    doc: *model.Document,
    tokens: []const Token,
    allocator: std.mem.Allocator,
    diagnostics: *std.ArrayListUnmanaged(diagnostic.Diagnostic),
) Error!void {
    if (tokens.len != 3 or !std.mem.eql(u8, tokens[2].text, ";"))
        return lineError(allocator, diagnostics, tokens[0], "malformed global comment");
    if (doc.description != null) return lineError(allocator, diagnostics, tokens[0], "duplicate global comment");
    doc.description = decodeDbcString(doc.allocator(), tokens[1].text) catch
        return lineError(allocator, diagnostics, tokens[1], "invalid DBC string escape");
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

fn parseMessageComment(
    doc: *model.Document,
    tokens: []const Token,
    allocator: std.mem.Allocator,
    diagnostics: *std.ArrayListUnmanaged(diagnostic.Diagnostic),
) Error!void {
    if (tokens.len != 5 or tokens[2].kind != .word or tokens[3].kind != .string or !std.mem.eql(u8, tokens[4].text, ";"))
        return lineError(allocator, diagnostics, tokens[0], "malformed message comment");
    const raw_id = std.fmt.parseInt(u32, tokens[2].text, 10) catch
        return lineError(allocator, diagnostics, tokens[2], "invalid message comment identifier");
    const extended = raw_id & 0x80000000 != 0;
    const id = raw_id & 0x1fffffff;
    for (doc.messages.items) |*message| {
        const message_id = std.fmt.parseInt(u32, message.id[2..], 16) catch continue;
        if (message_id != id or message.extended != extended) continue;
        if (message.description != null) return lineError(allocator, diagnostics, tokens[0], "duplicate message comment");
        message.description = decodeDbcString(doc.allocator(), tokens[3].text) catch
            return lineError(allocator, diagnostics, tokens[3], "invalid DBC string escape");
        return;
    }
    return lineError(allocator, diagnostics, tokens[2], "message comment references an unknown message");
}

fn parseEnvironmentVariable(
    doc: *model.Document,
    tokens: []const Token,
    raw_statement: []const u8,
    options: ParseOptions,
    allocator: std.mem.Allocator,
    diagnostics: *std.ArrayListUnmanaged(diagnostic.Diagnostic),
) Error!void {
    if (tokens.len < 15 or tokens[1].kind != .word or !std.mem.eql(u8, tokens[2].text, ":"))
        return lineError(allocator, diagnostics, tokens[0], "malformed environment variable declaration");
    const type_code = std.fmt.parseInt(u8, tokens[3].text, 10) catch
        return lineError(allocator, diagnostics, tokens[3], "invalid environment variable type code");
    const variable_type: model.EnvironmentVariableType = switch (type_code) {
        0 => .integer,
        1 => .float,
        2 => .string,
        3 => .data,
        else => return preserveOrReject(doc, tokens[0], raw_statement, options, allocator, diagnostics),
    };
    var index: usize = 4;
    try expectToken(tokens, &index, "[", allocator, diagnostics);
    const minimum = try readDecimal(tokens, &index, doc.allocator(), allocator, diagnostics);
    try expectToken(tokens, &index, "|", allocator, diagnostics);
    const maximum = try readDecimal(tokens, &index, doc.allocator(), allocator, diagnostics);
    try expectToken(tokens, &index, "]", allocator, diagnostics);
    if (index >= tokens.len or tokens[index].kind != .string)
        return lineError(allocator, diagnostics, tokens[0], "environment variable unit must be a quoted string");
    const unit = decodeDbcString(doc.allocator(), tokens[index].text) catch
        return lineError(allocator, diagnostics, tokens[index], "invalid DBC string escape");
    index += 1;
    const initial_value = switch (variable_type) {
        .integer, .float, .data => try readDecimal(tokens, &index, doc.allocator(), allocator, diagnostics),
        .string => blk: {
            if (index >= tokens.len or tokens[index].kind != .string)
                return lineError(allocator, diagnostics, tokens[@min(index, tokens.len - 1)], "string environment variable initial value must be quoted");
            const token = tokens[index];
            index += 1;
            break :blk decodeDbcString(doc.allocator(), token.text) catch return lineError(allocator, diagnostics, token, "invalid DBC string escape");
        },
    };
    const ev_id_value = try readUnsigned(tokens, &index, allocator, diagnostics);
    const ev_id = std.math.cast(u32, ev_id_value) orelse return lineError(allocator, diagnostics, tokens[index - 1], "environment variable ID exceeds model range");
    const access_type_value = try readUnsigned(tokens, &index, allocator, diagnostics);
    const access_type = std.math.cast(u32, access_type_value) orelse return lineError(allocator, diagnostics, tokens[index - 1], "environment variable access type exceeds model range");
    var variable = model.EnvironmentVariable{
        .name = try doc.allocator().dupe(u8, tokens[1].text),
        .variable_type = variable_type,
        .minimum = minimum,
        .maximum = maximum,
        .unit = try doc.allocator().dupe(u8, unit),
        .initial_value = initial_value,
        .ev_id = ev_id,
        .access_type = access_type,
    };
    var expect_node = true;
    var access_node_count: usize = 0;
    while (index < tokens.len - 1) : (index += 1) {
        const token = tokens[index];
        if (expect_node) {
            if (token.kind != .word) return lineError(allocator, diagnostics, token, "expected access node in environment variable declaration");
            try variable.access_nodes.append(doc.allocator(), try doc.allocator().dupe(u8, token.text));
            if (!std.mem.eql(u8, token.text, "DUMMY_NODE_VECTOR0") and !std.mem.eql(u8, token.text, "Vector__XXX") and !hasNode(doc, token.text))
                try doc.nodes.append(doc.allocator(), .{ .name = try doc.allocator().dupe(u8, token.text) });
            access_node_count += 1;
            expect_node = false;
        } else {
            if (!std.mem.eql(u8, token.text, ",")) return lineError(allocator, diagnostics, token, "expected comma between environment variable access nodes");
            expect_node = true;
        }
    }
    if (access_node_count == 0 or expect_node)
        return lineError(allocator, diagnostics, tokens[tokens.len - 1], "environment variable requires an access node list");
    try expectAttributeSemicolon(tokens, index, allocator, diagnostics);
    try doc.environment_variables.append(doc.allocator(), variable);
}

fn parseEnvironmentVariableData(
    doc: *model.Document,
    tokens: []const Token,
    allocator: std.mem.Allocator,
    diagnostics: *std.ArrayListUnmanaged(diagnostic.Diagnostic),
) Error!void {
    if (tokens.len != 5 or tokens[1].kind != .word or !std.mem.eql(u8, tokens[2].text, ":") or !std.mem.eql(u8, tokens[4].text, ";"))
        return lineError(allocator, diagnostics, tokens[0], "malformed ENVVAR_DATA_ statement");
    const size = std.fmt.parseInt(u32, tokens[3].text, 10) catch
        return lineError(allocator, diagnostics, tokens[3], "invalid environment variable data size");
    for (doc.environment_variables.items) |*variable| {
        if (!std.mem.eql(u8, variable.name, tokens[1].text)) continue;
        if (variable.data_size != null) return lineError(allocator, diagnostics, tokens[1], "duplicate ENVVAR_DATA_ declaration");
        variable.data_size = size;
        return;
    }
    return lineError(allocator, diagnostics, tokens[1], "ENVVAR_DATA_ references an unknown environment variable");
}

fn parseEnvironmentVariableComment(
    doc: *model.Document,
    tokens: []const Token,
    allocator: std.mem.Allocator,
    diagnostics: *std.ArrayListUnmanaged(diagnostic.Diagnostic),
) Error!void {
    if (tokens.len != 5 or tokens[2].kind != .word or tokens[3].kind != .string or !std.mem.eql(u8, tokens[4].text, ";"))
        return lineError(allocator, diagnostics, tokens[0], "malformed environment variable comment");
    for (doc.environment_variables.items) |*variable| {
        if (!std.mem.eql(u8, variable.name, tokens[2].text)) continue;
        if (variable.description != null) return lineError(allocator, diagnostics, tokens[0], "duplicate environment variable comment");
        variable.description = decodeDbcString(doc.allocator(), tokens[3].text) catch
            return lineError(allocator, diagnostics, tokens[3], "invalid DBC string escape");
        return;
    }
    return lineError(allocator, diagnostics, tokens[2], "environment variable comment references an unknown variable");
}

fn parseValueTable(
    doc: *model.Document,
    tokens: []const Token,
    allocator: std.mem.Allocator,
    diagnostics: *std.ArrayListUnmanaged(diagnostic.Diagnostic),
) Error!void {
    if (tokens.len < 3 or tokens[1].kind != .word or !std.mem.eql(u8, tokens[tokens.len - 1].text, ";"))
        return lineError(allocator, diagnostics, tokens[0], "malformed value table");
    const arena = doc.allocator();
    var table = model.ValueTable{ .name = try arena.dupe(u8, tokens[1].text) };
    var index: usize = 2;
    while (index < tokens.len - 1) {
        const raw = try readDecimal(tokens, &index, arena, allocator, diagnostics);
        if (index >= tokens.len - 1 or tokens[index].kind != .string)
            return lineError(allocator, diagnostics, tokens[index - 1], "value table entry requires a quoted label");
        const label = decodeDbcString(arena, tokens[index].text) catch
            return lineError(allocator, diagnostics, tokens[index], "invalid DBC string escape");
        index += 1;
        try table.choices.append(arena, .{ .raw = raw, .label = label });
    }
    try doc.value_tables.append(arena, table);
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

fn parseAttributeDefinition(
    doc: *model.Document,
    tokens: []const Token,
    raw_statement: []const u8,
    options: ParseOptions,
    allocator: std.mem.Allocator,
    diagnostics: *std.ArrayListUnmanaged(diagnostic.Diagnostic),
) Error!void {
    if (tokens.len < 4) return lineError(allocator, diagnostics, tokens[0], "malformed attribute definition");
    var index: usize = 1;
    var scope: model.AttributeScope = .document;
    if (tokens[index].kind == .word) {
        scope = if (std.mem.eql(u8, tokens[index].text, "BU_")) .node else if (std.mem.eql(u8, tokens[index].text, "BO_")) .message else if (std.mem.eql(u8, tokens[index].text, "SG_")) .signal else if (std.mem.eql(u8, tokens[index].text, "EV_")) .environment_variable else return preserveOrReject(doc, tokens[0], raw_statement, options, allocator, diagnostics);
        index += 1;
    }
    if (index + 2 >= tokens.len or tokens[index].kind != .string or tokens[index + 1].kind != .word)
        return lineError(allocator, diagnostics, tokens[0], "malformed attribute definition");
    const name_token = tokens[index];
    const type_token = tokens[index + 1];
    index += 2;
    const value_type: model.AttributeType = if (std.mem.eql(u8, type_token.text, "INT")) .integer else if (std.mem.eql(u8, type_token.text, "HEX")) .hex else if (std.mem.eql(u8, type_token.text, "FLOAT")) .float else if (std.mem.eql(u8, type_token.text, "STRING")) .string else if (std.mem.eql(u8, type_token.text, "ENUM")) .@"enum" else return preserveOrReject(doc, tokens[0], raw_statement, options, allocator, diagnostics);
    const a = doc.allocator();
    var definition = model.AttributeDefinition{
        .name = decodeDbcString(a, name_token.text) catch return lineError(allocator, diagnostics, name_token, "invalid DBC attribute name escape"),
        .scope = scope,
        .value_type = value_type,
    };
    switch (value_type) {
        .integer, .hex, .float => {
            const minimum = try readAttributeValue(doc, &definition, tokens, &index, allocator, diagnostics);
            const maximum = try readAttributeValue(doc, &definition, tokens, &index, allocator, diagnostics);
            definition.minimum = attributeValueText(minimum).?;
            definition.maximum = attributeValueText(maximum).?;
        },
        .string => {},
        .@"enum" => {
            var expect_label = true;
            while (index < tokens.len and !std.mem.eql(u8, tokens[index].text, ";")) : (index += 1) {
                const token = tokens[index];
                if (expect_label) {
                    if (token.kind != .string) return lineError(allocator, diagnostics, token, "expected quoted enum attribute label");
                    try definition.enum_labels.append(a, decodeDbcString(a, token.text) catch return lineError(allocator, diagnostics, token, "invalid DBC enum label escape"));
                    expect_label = false;
                } else {
                    if (!std.mem.eql(u8, token.text, ",")) return lineError(allocator, diagnostics, token, "expected comma between enum attribute labels");
                    expect_label = true;
                }
            }
            if (definition.enum_labels.items.len == 0 or expect_label)
                return lineError(allocator, diagnostics, tokens[index], "enum attribute definition requires comma-separated labels");
        },
    }
    try expectAttributeSemicolon(tokens, index, allocator, diagnostics);
    try doc.attribute_definitions.append(a, definition);
}

fn parseAttributeDefault(
    doc: *model.Document,
    tokens: []const Token,
    allocator: std.mem.Allocator,
    diagnostics: *std.ArrayListUnmanaged(diagnostic.Diagnostic),
) Error!void {
    if (tokens.len < 4 or tokens[1].kind != .string)
        return lineError(allocator, diagnostics, tokens[0], "malformed attribute default");
    const name = decodeDbcString(doc.allocator(), tokens[1].text) catch
        return lineError(allocator, diagnostics, tokens[1], "invalid DBC attribute name escape");
    const definition = findMutableAttributeDefinition(doc, name) orelse
        return lineError(allocator, diagnostics, tokens[1], "default references an unknown attribute definition");
    var index: usize = 2;
    const value = try readAttributeValue(doc, definition, tokens, &index, allocator, diagnostics);
    try expectAttributeSemicolon(tokens, index, allocator, diagnostics);
    definition.default = value;
}

fn parseAttributeAssignment(
    doc: *model.Document,
    tokens: []const Token,
    allocator: std.mem.Allocator,
    diagnostics: *std.ArrayListUnmanaged(diagnostic.Diagnostic),
) Error!void {
    if (tokens.len < 4 or tokens[1].kind != .string)
        return lineError(allocator, diagnostics, tokens[0], "malformed attribute assignment");
    const name = decodeDbcString(doc.allocator(), tokens[1].text) catch
        return lineError(allocator, diagnostics, tokens[1], "invalid DBC attribute name escape");
    const definition = findAttributeDefinition(doc, name) orelse
        return lineError(allocator, diagnostics, tokens[1], "assignment references an unknown attribute definition");
    var scope: model.AttributeScope = .document;
    var node_index: ?usize = null;
    var message_index: ?usize = null;
    var signal_index: ?usize = null;
    var environment_variable_index: ?usize = null;
    var value_index: usize = 2;
    if (tokens[2].kind == .word and std.mem.eql(u8, tokens[2].text, "BU_")) {
        if (tokens.len < 6 or tokens[3].kind != .word)
            return lineError(allocator, diagnostics, tokens[2], "malformed node attribute assignment");
        scope = .node;
        for (doc.nodes.items, 0..) |node, index| {
            if (std.mem.eql(u8, node.name, tokens[3].text)) {
                node_index = index;
                break;
            }
        }
        if (node_index == null) return lineError(allocator, diagnostics, tokens[3], "attribute assignment references an unknown node");
        value_index = 4;
    } else if (tokens[2].kind == .word and (std.mem.eql(u8, tokens[2].text, "BO_") or std.mem.eql(u8, tokens[2].text, "SG_"))) {
        const is_signal = std.mem.eql(u8, tokens[2].text, "SG_");
        if (tokens.len < (if (is_signal) @as(usize, 7) else 6))
            return lineError(allocator, diagnostics, tokens[2], "malformed message or signal attribute assignment");
        const id_token = tokens[3];
        const raw_id = std.fmt.parseInt(u32, id_token.text, 10) catch
            return lineError(allocator, diagnostics, id_token, "invalid attribute assignment message identifier");
        message_index = findMessageByDbcId(doc, raw_id) orelse
            return lineError(allocator, diagnostics, id_token, "attribute assignment references an unknown message");
        if (is_signal) {
            scope = .signal;
            if (tokens[4].kind != .word) return lineError(allocator, diagnostics, tokens[4], "invalid attribute assignment signal name");
            for (doc.messages.items[message_index.?].signals.items, 0..) |signal, index| {
                if (std.mem.eql(u8, signal.name, tokens[4].text)) {
                    signal_index = index;
                    break;
                }
            }
            if (signal_index == null) return lineError(allocator, diagnostics, tokens[4], "attribute assignment references an unknown signal");
            value_index = 5;
        } else {
            scope = .message;
            value_index = 4;
        }
    } else if (tokens[2].kind == .word and std.mem.eql(u8, tokens[2].text, "EV_")) {
        if (tokens.len < 6 or tokens[3].kind != .word)
            return lineError(allocator, diagnostics, tokens[2], "malformed environment-variable attribute assignment");
        scope = .environment_variable;
        for (doc.environment_variables.items, 0..) |variable, index| {
            if (std.mem.eql(u8, variable.name, tokens[3].text)) {
                environment_variable_index = index;
                break;
            }
        }
        if (environment_variable_index == null) return lineError(allocator, diagnostics, tokens[3], "attribute assignment references an unknown environment variable");
        value_index = 4;
    }
    if (definition.scope != scope)
        return lineError(allocator, diagnostics, tokens[1], "attribute assignment scope does not match its definition");
    var index = value_index;
    const value = try readAttributeValue(doc, definition, tokens, &index, allocator, diagnostics);
    try expectAttributeSemicolon(tokens, index, allocator, diagnostics);
    const assignment = model.AttributeAssignment{ .name = name, .value = value };
    const a = doc.allocator();
    switch (scope) {
        .document => try doc.attributes.append(a, assignment),
        .node => try doc.nodes.items[node_index.?].attributes.append(a, assignment),
        .message => try doc.messages.items[message_index.?].attributes.append(a, assignment),
        .signal => try doc.messages.items[message_index.?].signals.items[signal_index.?].attributes.append(a, assignment),
        .bus => return lineError(allocator, diagnostics, tokens[2], "bus attributes are not defined by this DBC profile"),
        .environment_variable => try doc.environment_variables.items[environment_variable_index.?].attributes.append(a, assignment),
    }
}

fn readAttributeValue(
    doc: *model.Document,
    definition: *const model.AttributeDefinition,
    tokens: []const Token,
    index: *usize,
    allocator: std.mem.Allocator,
    diagnostics: *std.ArrayListUnmanaged(diagnostic.Diagnostic),
) Error!model.AttributeValue {
    if (index.* >= tokens.len) return lineError(allocator, diagnostics, tokens[tokens.len - 1], "missing attribute value");
    const token = tokens[index.*];
    return switch (definition.value_type) {
        .integer => .{ .integer = try readDecimal(tokens, index, doc.allocator(), allocator, diagnostics) },
        .hex => blk: {
            if (token.kind != .word) return lineError(allocator, diagnostics, token, "invalid hexadecimal attribute value");
            index.* += 1;
            break :blk .{ .hex = try doc.allocator().dupe(u8, token.text) };
        },
        .float => .{ .float = try readDecimal(tokens, index, doc.allocator(), allocator, diagnostics) },
        .string => blk: {
            if (token.kind != .string) return lineError(allocator, diagnostics, token, "expected quoted string attribute value");
            index.* += 1;
            break :blk .{ .string = decodeDbcString(doc.allocator(), token.text) catch return lineError(allocator, diagnostics, token, "invalid DBC attribute string escape") };
        },
        .@"enum" => blk: {
            if (token.kind != .word) return lineError(allocator, diagnostics, token, "invalid enum attribute index");
            index.* += 1;
            break :blk .{ .enum_index = std.fmt.parseInt(u32, token.text, 10) catch return lineError(allocator, diagnostics, token, "invalid enum attribute index") };
        },
    };
}

fn attributeValueText(value: model.AttributeValue) ?[]const u8 {
    return switch (value) {
        .integer, .hex, .float => |text| text,
        .string, .enum_index => null,
    };
}

fn expectAttributeSemicolon(tokens: []const Token, index: usize, allocator: std.mem.Allocator, diagnostics: *std.ArrayListUnmanaged(diagnostic.Diagnostic)) Error!void {
    if (index != tokens.len - 1 or !std.mem.eql(u8, tokens[index].text, ";"))
        return lineError(allocator, diagnostics, tokens[@min(index, tokens.len - 1)], "malformed attribute statement terminator");
}

fn findMessageByDbcId(doc: *const model.Document, raw_id: u32) ?usize {
    const id = raw_id & 0x1fffffff;
    const extended = raw_id & 0x80000000 != 0;
    for (doc.messages.items, 0..) |message, index| {
        const message_id = std.fmt.parseInt(u32, message.id[2..], 16) catch continue;
        if (message_id == id and message.extended == extended) return index;
    }
    return null;
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

fn findMutableAttributeDefinition(doc: *model.Document, name: []const u8) ?*model.AttributeDefinition {
    for (doc.attribute_definitions.items) |*definition| {
        if (std.mem.eql(u8, definition.name, name)) return definition;
    }
    return null;
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

/// Exports one bus by name. DBC has no bus-name field, so non-can0 names are not retained.
pub fn writeForBus(allocator: std.mem.Allocator, doc: *const model.Document, bus_name: []const u8) Error![]u8 {
    var diagnostics: std.ArrayListUnmanaged(diagnostic.Diagnostic) = .empty;
    defer diagnostics.deinit(allocator);
    return writeForBusWithDiagnostics(allocator, doc, bus_name, &diagnostics);
}

/// Like `writeForBus`, but appends a warning when the selected bus name cannot be represented.
pub fn writeForBusWithDiagnostics(
    allocator: std.mem.Allocator,
    doc: *const model.Document,
    bus_name: []const u8,
    diagnostics: *std.ArrayListUnmanaged(diagnostic.Diagnostic),
) Error![]u8 {
    const bus = findBusByName(doc, bus_name) orelse {
        try diagnostics.append(allocator, .{
            .severity = .@"error",
            .code = .unknown_bus,
            .message = "selected DBC export bus is not defined",
            .context = .{ .bus = bus_name },
        });
        return error.UnknownBus;
    };
    if (!std.mem.eql(u8, bus.name, "can0"))
        try warn(allocator, diagnostics, "selected bus name is not represented in DBC; imported bus defaults to can0", .{ .bus = bus.name });
    if (hasOpaqueStatements(doc.dbc)) {
        try blocker(allocator, diagnostics, "opaque DBC statements cannot be safely filtered for one bus", .{ .bus = bus.name });
        return error.UnsupportedConstruct;
    }

    var selected = model.Document.init(allocator);
    defer selected.deinit();
    const a = selected.allocator();
    selected.format = doc.format;
    selected.format_version = doc.format_version;
    selected.name = doc.name;
    selected.description = doc.description;
    try selected.attributes.appendSlice(a, doc.attributes.items);
    try selected.value_tables.appendSlice(a, doc.value_tables.items);
    try selected.environment_variables.appendSlice(a, doc.environment_variables.items);
    selected.dbc = doc.dbc;
    selected.extensions = doc.extensions;
    var selected_bus = bus.*;
    selected_bus.name = "can0";
    try selected.buses.append(a, selected_bus);
    for (doc.messages.items) |message| {
        if (!std.mem.eql(u8, message.bus, bus_name)) continue;
        var selected_message = message;
        selected_message.bus = "can0";
        try selected.messages.append(a, selected_message);
    }
    for (doc.nodes.items) |node| {
        if (nodeReferencedBySelectedEntities(node.name, &selected)) try selected.nodes.append(a, node);
    }
    for (doc.attribute_definitions.items) |definition| {
        if (attributeUsedByDocument(&selected, definition.name))
            try selected.attribute_definitions.append(a, definition);
    }
    return writeWithDiagnostics(allocator, &selected, diagnostics);
}

fn nodeReferencedBySelectedEntities(node_name: []const u8, doc: *const model.Document) bool {
    for (doc.environment_variables.items) |variable| {
        for (variable.access_nodes.items) |access_node| {
            if (std.mem.eql(u8, access_node, node_name)) return true;
        }
    }
    for (doc.messages.items) |message| {
        for (message.transmitters.items) |transmitter| {
            if (std.mem.eql(u8, transmitter, node_name)) return true;
        }
        for (message.receivers.items) |receiver| {
            if (std.mem.eql(u8, receiver, node_name)) return true;
        }
        for (message.signals.items) |signal| {
            for (signal.receivers.items) |receiver| {
                if (std.mem.eql(u8, receiver, node_name)) return true;
            }
        }
    }
    return false;
}

fn attributeUsedByDocument(doc: *const model.Document, name: []const u8) bool {
    for (doc.attributes.items) |assignment| {
        if (std.mem.eql(u8, assignment.name, name)) return true;
    }
    for (doc.buses.items) |bus| {
        for (bus.attributes.items) |assignment| {
            if (std.mem.eql(u8, assignment.name, name)) return true;
        }
    }
    for (doc.nodes.items) |node| {
        for (node.attributes.items) |assignment| {
            if (std.mem.eql(u8, assignment.name, name)) return true;
        }
    }
    for (doc.environment_variables.items) |variable| {
        for (variable.attributes.items) |assignment| {
            if (std.mem.eql(u8, assignment.name, name)) return true;
        }
    }
    for (doc.messages.items) |message| {
        for (message.attributes.items) |assignment| {
            if (std.mem.eql(u8, assignment.name, name)) return true;
        }
        for (message.signals.items) |signal| {
            for (signal.attributes.items) |assignment| {
                if (std.mem.eql(u8, assignment.name, name)) return true;
            }
        }
    }
    return false;
}

fn hasOpaqueStatements(metadata: ?std.json.Value) bool {
    const object = metadata orelse return false;
    if (object != .object) return false;
    const statements = object.object.get("opaque_statements") orelse return false;
    return statements == .array and statements.array.items.len > 0;
}

fn findBusByName(doc: *const model.Document, name: []const u8) ?*const model.Bus {
    for (doc.buses.items) |*bus| {
        if (std.mem.eql(u8, bus.name, name)) return bus;
    }
    return null;
}

/// Like `write`, but appends warnings for omitted metadata and errors for export blockers.
/// Messages are static; contexts borrow from `doc`.
pub fn writeWithDiagnostics(allocator: std.mem.Allocator, doc: *const model.Document, diagnostics: *std.ArrayListUnmanaged(diagnostic.Diagnostic)) Error![]u8 {
    const start_count = diagnostics.items.len;
    var opaque_statements: ?std.json.Array = null;
    const bus_name: ?[]const u8 = if (doc.buses.items.len > 0) doc.buses.items[0].name else null;
    const bus_ctx: diagnostic.Context = .{ .bus = bus_name };
    if (doc.buses.items.len > 1) try blocker(allocator, diagnostics, "more than one bus cannot be exported", .{});
    try checkAttributeAssignments(allocator, diagnostics, &doc.attributes, .document, doc, .{});
    for (doc.value_tables.items) |table| {
        if (!isIdentifier(table.name)) try blocker(allocator, diagnostics, "value table name is not a valid DBC identifier", .{});
        for (table.choices.items) |choice| {
            if (!validDbcString(choice.label)) try blocker(allocator, diagnostics, "value table label contains unsupported control characters", .{});
        }
    }
    if (doc.name != null) try warn(allocator, diagnostics, "document name is omitted from DBC export", .{});
    if (doc.description) |description| {
        if (!validDbcString(description)) try blocker(allocator, diagnostics, "document description contains unsupported control characters", .{});
    }
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
        if (definition.scope == .bus)
            try blocker(allocator, diagnostics, "bus attribute definitions cannot be exported", .{});
        switch (definition.value_type) {
            .integer, .hex, .float => {
                if (definition.minimum == null or definition.maximum == null or
                    !validAttributeNumber(definition.value_type, definition.minimum orelse "") or
                    !validAttributeNumber(definition.value_type, definition.maximum orelse ""))
                    try blocker(allocator, diagnostics, "numeric attribute definitions require valid minimum and maximum values", .{});
            },
            .string => if (definition.minimum != null or definition.maximum != null or definition.enum_labels.items.len > 0)
                try blocker(allocator, diagnostics, "string attribute definitions cannot have bounds or enum labels", .{}),
            .@"enum" => if (definition.minimum != null or definition.maximum != null or definition.enum_labels.items.len == 0)
                try blocker(allocator, diagnostics, "enum attribute definitions require labels and cannot have numeric bounds", .{}),
        }
        if (definition.default) |default| {
            if (!validAttributeValue(&definition, default))
                try blocker(allocator, diagnostics, "attribute default does not match its definition", .{});
        }
        if (definition.dbc != null or definition.extensions != null)
            try blocker(allocator, diagnostics, "attribute definition metadata cannot be exported", .{});
        if (!validDbcString(definition.name)) try blocker(allocator, diagnostics, "attribute name contains unsupported control characters", .{});
        for (definition.enum_labels.items) |label| {
            if (!validDbcString(label)) try blocker(allocator, diagnostics, "attribute enum label contains unsupported control characters", .{});
        }
    }
    if (doc.buses.items.len == 1) {
        const bus = doc.buses.items[0];
        if (!std.mem.eql(u8, bus.name, "can0")) try blocker(allocator, diagnostics, "bus must be named can0", bus_ctx);
        if (bus.nominal_bitrate != null or bus.data_bitrate != null)
            try blocker(allocator, diagnostics, "bus bitrate fields cannot be represented by the supported DBC BS_ profile", bus_ctx);
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
        try checkAttributeAssignments(allocator, diagnostics, &node.attributes, .node, doc, .{});
        if (node.dbc != null or node.extensions != null) try blocker(allocator, diagnostics, "node dbc metadata and extensions cannot be exported", .{});
    }
    for (doc.environment_variables.items) |variable| {
        if (!isIdentifier(variable.name)) try blocker(allocator, diagnostics, "environment variable name is not a valid DBC identifier", .{});
        if (!validDbcString(variable.minimum) or !validDbcString(variable.maximum) or !validDbcString(variable.unit) or !validDbcString(variable.initial_value))
            try blocker(allocator, diagnostics, "environment variable contains unsupported control characters", .{});
        switch (variable.variable_type) {
            .integer, .data => if (!validAttributeNumber(.integer, variable.initial_value))
                try blocker(allocator, diagnostics, "environment variable initial value is not a valid integer", .{}),
            .float => if (!validAttributeNumber(.float, variable.initial_value))
                try blocker(allocator, diagnostics, "environment variable initial value is not a valid float", .{}),
            .string => {},
        }
        if (variable.variable_type == .data and variable.data_size == null)
            try blocker(allocator, diagnostics, "data environment variable requires ENVVAR_DATA_ size", .{});
        for (variable.access_nodes.items) |node_name| {
            if (!isIdentifier(node_name)) try blocker(allocator, diagnostics, "environment variable access node is not a valid DBC identifier", .{});
        }
        try checkAttributeAssignments(allocator, diagnostics, &variable.attributes, .environment_variable, doc, .{});
        if (variable.dbc != null or variable.extensions != null)
            try blocker(allocator, diagnostics, "environment variable dbc metadata and extensions cannot be exported", .{});
    }
    if (opaque_statements) |statements| {
        for (statements.items) |statement| {
            if (!validOpaqueStatement(statement)) try blocker(allocator, diagnostics, "invalid dbc.opaque_statements entry", .{});
        }
    }
    for (doc.messages.items) |message| {
        const mctx: diagnostic.Context = .{ .bus = bus_name, .message = message.name };
        if (message.receivers.items.len > 0) try blocker(allocator, diagnostics, "message receivers cannot be exported", mctx);
        if (message.description) |description| {
            if (!validDbcString(description)) try blocker(allocator, diagnostics, "message description contains unsupported control characters", mctx);
        }
        if (message.dbc != null or message.extensions != null) try blocker(allocator, diagnostics, "message dbc metadata and extensions cannot be exported", mctx);
        if (!isIdentifier(message.name)) try blocker(allocator, diagnostics, "message name is not a valid DBC identifier", mctx);
        for (message.transmitters.items, 0..) |transmitter, transmitter_index| {
            if (!isIdentifier(transmitter)) try blocker(allocator, diagnostics, "transmitter name is not a valid DBC identifier", mctx);
            for (message.transmitters.items[0..transmitter_index]) |earlier| {
                if (std.mem.eql(u8, transmitter, earlier))
                    try blocker(allocator, diagnostics, "message transmitter names must be unique", mctx);
            }
        }
        try checkAttributeAssignments(allocator, diagnostics, &message.attributes, .message, doc, mctx);
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
            try checkAttributeAssignments(allocator, diagnostics, &signal.attributes, .signal, doc, sctx);
            if (signal.value_table) |table_name| {
                if (findValueTable(doc, table_name) == null) try blocker(allocator, diagnostics, "signal references an unknown value table", sctx);
                if (findValueTable(doc, table_name) != null)
                    try warn(allocator, diagnostics, "signal value-table name is emitted as inline VAL_ values and is not preserved", sctx);
            }
            if (signal.minimum == null or signal.maximum == null)
                try warn(allocator, diagnostics, "missing signal bounds are written as [0|0]", sctx);
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
        if (message.description != null) has_comments = true;
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
    for (doc.environment_variables.items) |variable| {
        if (variable.description != null) has_comments = true;
    }
    if (doc.description != null) has_comments = true;
    if (has_comments) try appendText(allocator, &output, "\n  CM_");
    if (has_fd_frames or has_message_attributes) try appendText(allocator, &output, "\n  BA_DEF_\n  BA_");
    if (has_mux_values) try appendText(allocator, &output, "\n  SG_MUL_VAL_");
    if (has_float_signals) try appendText(allocator, &output, "\n  SIG_VALTYPE_");
    if (has_value_tables) try appendText(allocator, &output, "\n  VAL_");
    if (doc.value_tables.items.len > 0) try appendText(allocator, &output, "\n  VAL_TABLE_");
    try appendText(allocator, &output, "\n\nBS_:\n\nBU_:");
    for (doc.nodes.items) |node| try appendFmt(allocator, &output, " {s}", .{node.name});
    try appendText(allocator, &output, "\n\n");
    for (doc.value_tables.items) |table| {
        try appendFmt(allocator, &output, "VAL_TABLE_ {s}", .{table.name});
        for (table.choices.items) |choice| {
            try appendFmt(allocator, &output, " {s} ", .{choice.raw});
            try appendDbcString(allocator, &output, choice.label);
        }
        try appendText(allocator, &output, " ;\n");
    }
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
                    if (receiver_index > 0) try appendText(allocator, &output, ",");
                    try appendText(allocator, &output, receiver);
                }
                try appendText(allocator, &output, "\n");
            }
        }
    }
    for (doc.messages.items) |message| {
        if (message.transmitters.items.len < 2) continue;
        const id = std.fmt.parseInt(u32, message.id[2..], 16) catch return error.InvalidDbc;
        const raw_id = id | (if (message.extended) @as(u32, 0x80000000) else 0);
        try appendFmt(allocator, &output, "BO_TX_BU_ {d} : ", .{raw_id});
        for (message.transmitters.items[1..], 0..) |transmitter, index| {
            if (index > 0) try appendText(allocator, &output, ",");
            try appendText(allocator, &output, transmitter);
        }
        try appendText(allocator, &output, ";\n");
    }
    for (doc.environment_variables.items) |variable| {
        const type_code: u8 = switch (variable.variable_type) {
            .integer => 0,
            .float => 1,
            .string => 2,
            .data => 3,
        };
        try appendFmt(allocator, &output, "EV_ {s} : {d} [{s}|{s}] ", .{ variable.name, type_code, variable.minimum, variable.maximum });
        try appendDbcString(allocator, &output, variable.unit);
        try appendText(allocator, &output, " ");
        if (variable.variable_type == .string) {
            try appendDbcString(allocator, &output, variable.initial_value);
        } else {
            try appendText(allocator, &output, variable.initial_value);
        }
        try appendFmt(allocator, &output, " {d} {d} ", .{ variable.ev_id, variable.access_type });
        for (variable.access_nodes.items, 0..) |node_name, index| {
            if (index > 0) try appendText(allocator, &output, ",");
            try appendText(allocator, &output, node_name);
        }
        try appendText(allocator, &output, ";\n");
        if (variable.data_size) |size| try appendFmt(allocator, &output, "ENVVAR_DATA_ {s} : {d};\n", .{ variable.name, size });
    }
    if (doc.description) |description| {
        try appendText(allocator, &output, "CM_ ");
        try appendDbcString(allocator, &output, description);
        try appendText(allocator, &output, ";\n");
    }
    for (doc.messages.items) |message| {
        const id = std.fmt.parseInt(u32, message.id[2..], 16) catch return error.InvalidDbc;
        const raw_id = id | (if (message.extended) @as(u32, 0x80000000) else 0);
        if (message.description) |description| {
            try appendFmt(allocator, &output, "CM_ BO_ {d} ", .{raw_id});
            try appendDbcString(allocator, &output, description);
            try appendText(allocator, &output, ";\n");
        }
        for (message.signals.items) |signal| {
            if (signal.description) |description| {
                try appendFmt(allocator, &output, "CM_ SG_ {d} {s} ", .{ raw_id, signal.name });
                try appendDbcString(allocator, &output, description);
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
    for (doc.environment_variables.items) |variable| {
        if (variable.description) |description| {
            try appendFmt(allocator, &output, "CM_ EV_ {s} ", .{variable.name});
            try appendDbcString(allocator, &output, description);
            try appendText(allocator, &output, ";\n");
        }
    }
    if (has_fd_frames) {
        try appendText(allocator, &output, "BA_DEF_ BO_ \"VFrameFormat\" ENUM \"StandardCAN\",\"ExtendedCAN\",\"J1939PG\",\"J1939PG_21\",\"J1939PG_22\",\"J1939PG_23\",\"J1939PG_24\",\"J1939PG_25\",\"J1939PG_26\",\"J1939PG_27\",\"J1939PG_28\",\"J1939PG_29\",\"J1939PG_30\",\"J1939PG_31\",\"StandardCAN_FD\",\"ExtendedCAN_FD\",\"J1939PG_FD\";\n");
    }
    for (doc.attribute_definitions.items) |definition| {
        try appendText(allocator, &output, "BA_DEF_");
        switch (definition.scope) {
            .document => {},
            .node => try appendText(allocator, &output, " BU_"),
            .message => try appendText(allocator, &output, " BO_"),
            .signal => try appendText(allocator, &output, " SG_"),
            .environment_variable => try appendText(allocator, &output, " EV_"),
            .bus => unreachable,
        }
        try appendText(allocator, &output, " ");
        try appendDbcString(allocator, &output, definition.name);
        switch (definition.value_type) {
            .integer => try appendFmt(allocator, &output, " INT {s} {s}", .{ definition.minimum.?, definition.maximum.? }),
            .hex => try appendFmt(allocator, &output, " HEX {s} {s}", .{ definition.minimum.?, definition.maximum.? }),
            .float => try appendFmt(allocator, &output, " FLOAT {s} {s}", .{ definition.minimum.?, definition.maximum.? }),
            .string => try appendText(allocator, &output, " STRING"),
            .@"enum" => {
                try appendText(allocator, &output, " ENUM ");
                for (definition.enum_labels.items, 0..) |label, index| {
                    if (index > 0) try appendText(allocator, &output, ",");
                    try appendDbcString(allocator, &output, label);
                }
            },
        }
        try appendText(allocator, &output, ";\n");
    }
    for (doc.attribute_definitions.items) |definition| {
        if (definition.default) |default| {
            try appendText(allocator, &output, "BA_DEF_DEF_ ");
            try appendDbcString(allocator, &output, definition.name);
            try appendText(allocator, &output, " ");
            try appendAttributeValue(allocator, &output, default);
            try appendText(allocator, &output, ";\n");
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
    for (doc.attributes.items) |assignment| {
        try appendText(allocator, &output, "BA_ ");
        try appendDbcString(allocator, &output, assignment.name);
        try appendText(allocator, &output, " ");
        try appendAttributeValue(allocator, &output, assignment.value);
        try appendText(allocator, &output, ";\n");
    }
    for (doc.nodes.items) |node| {
        for (node.attributes.items) |assignment| {
            try appendText(allocator, &output, "BA_ ");
            try appendDbcString(allocator, &output, assignment.name);
            try appendFmt(allocator, &output, " BU_ {s} ", .{node.name});
            try appendAttributeValue(allocator, &output, assignment.value);
            try appendText(allocator, &output, ";\n");
        }
    }
    for (doc.messages.items) |message| {
        const id = std.fmt.parseInt(u32, message.id[2..], 16) catch return error.InvalidDbc;
        const raw_id = id | (if (message.extended) @as(u32, 0x80000000) else 0);
        for (message.attributes.items) |assignment| {
            try appendText(allocator, &output, "BA_ ");
            try appendDbcString(allocator, &output, assignment.name);
            try appendFmt(allocator, &output, " BO_ {d} ", .{raw_id});
            try appendAttributeValue(allocator, &output, assignment.value);
            try appendText(allocator, &output, ";\n");
        }
        for (message.signals.items) |signal| {
            for (signal.attributes.items) |assignment| {
                try appendText(allocator, &output, "BA_ ");
                try appendDbcString(allocator, &output, assignment.name);
                try appendFmt(allocator, &output, " SG_ {d} {s} ", .{ raw_id, signal.name });
                try appendAttributeValue(allocator, &output, assignment.value);
                try appendText(allocator, &output, ";\n");
            }
        }
    }
    for (doc.environment_variables.items) |variable| {
        for (variable.attributes.items) |assignment| {
            try appendText(allocator, &output, "BA_ ");
            try appendDbcString(allocator, &output, assignment.name);
            try appendFmt(allocator, &output, " EV_ {s} ", .{variable.name});
            try appendAttributeValue(allocator, &output, assignment.value);
            try appendText(allocator, &output, ";\n");
        }
    }
    // Section order follows the DBC grammar; Vector's CANdb++ rejects later records that appear early.
    for (doc.messages.items) |message| {
        const id = std.fmt.parseInt(u32, message.id[2..], 16) catch return error.InvalidDbc;
        const raw_id = id | (if (message.extended) @as(u32, 0x80000000) else 0);
        for (message.signals.items) |signal| {
            const choices = signalChoices(doc, signal);
            if (choices.len == 0) continue;
            try appendFmt(allocator, &output, "VAL_ {d} {s}", .{ raw_id, signal.name });
            for (choices) |choice| {
                try appendFmt(allocator, &output, " {s} ", .{choice.raw});
                try appendDbcString(allocator, &output, choice.label);
            }
            try appendText(allocator, &output, ";\n");
        }
    }
    for (doc.messages.items) |message| {
        const id = std.fmt.parseInt(u32, message.id[2..], 16) catch return error.InvalidDbc;
        const raw_id = id | (if (message.extended) @as(u32, 0x80000000) else 0);
        for (message.signals.items) |signal| {
            if (signal.signal_type != .float32 and signal.signal_type != .float64) continue;
            const value_type: u8 = if (signal.signal_type == .float32) 1 else 2;
            try appendFmt(allocator, &output, "SIG_VALTYPE_ {d} {s} : {d};\n", .{ raw_id, signal.name, value_type });
        }
    }
    for (doc.messages.items) |message| {
        const id = std.fmt.parseInt(u32, message.id[2..], 16) catch return error.InvalidDbc;
        const raw_id = id | (if (message.extended) @as(u32, 0x80000000) else 0);
        for (message.signals.items) |signal| {
            const index = parentCondition(&message, &signal) orelse continue;
            const condition = signal.when.items[index];
            try appendFmt(allocator, &output, "SG_MUL_VAL_ {d} {s} {s}", .{ raw_id, signal.name, condition.selector });
            for (condition.ranges.items, 0..) |range, range_index| {
                if (range_index > 0) try appendText(allocator, &output, ",");
                try appendFmt(allocator, &output, " {s}-{s}", .{ range.minimum, range.maximum });
            }
            try appendText(allocator, &output, ";\n");
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

fn checkAttributeAssignments(
    allocator: std.mem.Allocator,
    diagnostics: *std.ArrayListUnmanaged(diagnostic.Diagnostic),
    assignments: *const std.ArrayListUnmanaged(model.AttributeAssignment),
    scope: model.AttributeScope,
    doc: *const model.Document,
    context: diagnostic.Context,
) std.mem.Allocator.Error!void {
    for (assignments.items) |assignment| {
        const definition = findAttributeDefinition(doc, assignment.name) orelse {
            try blocker(allocator, diagnostics, "attribute assignment has no definition", context);
            continue;
        };
        if (definition.scope != scope or !validAttributeValue(definition, assignment.value))
            try blocker(allocator, diagnostics, "attribute assignment does not match its definition", context);
    }
}

fn validAttributeValue(definition: *const model.AttributeDefinition, value: model.AttributeValue) bool {
    return switch (value) {
        .integer => |text| definition.value_type == .integer and validAttributeNumber(.integer, text),
        .hex => |text| definition.value_type == .hex and validAttributeNumber(.hex, text),
        .float => |text| definition.value_type == .float and validAttributeNumber(.float, text),
        .string => |text| definition.value_type == .string and validDbcString(text),
        .enum_index => |index| definition.value_type == .@"enum" and index < definition.enum_labels.items.len,
    };
}

fn validAttributeNumber(value_type: model.AttributeType, text: []const u8) bool {
    return switch (value_type) {
        .integer => blk: {
            _ = std.fmt.parseInt(i64, text, 10) catch break :blk false;
            break :blk true;
        },
        .hex => blk: {
            if (text.len < 3 or text[0] != '0' or (text[1] != 'x' and text[1] != 'X')) break :blk false;
            _ = std.fmt.parseInt(u64, text[2..], 16) catch break :blk false;
            break :blk true;
        },
        .float => blk: {
            const value = std.fmt.parseFloat(f64, text) catch break :blk false;
            break :blk std.math.isFinite(value);
        },
        .string, .@"enum" => false,
    };
}

fn appendAttributeValue(allocator: std.mem.Allocator, output: *std.ArrayListUnmanaged(u8), value: model.AttributeValue) Error!void {
    switch (value) {
        .integer, .hex, .float => |text| try appendText(allocator, output, text),
        .string => |text| try appendDbcString(allocator, output, text),
        .enum_index => |index| try appendFmt(allocator, output, "{d}", .{index}),
    }
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
            // DBC strings carry line breaks and tabs literally; there is no \n escape.
            '\n', '\r', '\t' => try output.append(allocator, character),
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
    if (raw.string.len == 0) return false;
    return statement.object.count() == 2;
}

fn isIdentifier(text: []const u8) bool {
    if (text.len == 0) return false;
    for (text) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '_') return false;
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

fn rawStatement(input: []const u8, first_line: u32, last_line: u32) []const u8 {
    var line: u32 = 1;
    var start: usize = 0;
    while (line < first_line and start < input.len) : (start += 1) {
        if (input[start] == '\n') line += 1;
    }
    if (start >= input.len) return "";
    var end = start;
    var current = first_line;
    while (end < input.len) : (end += 1) {
        if (input[end] != '\n') continue;
        if (current >= last_line) break;
        current += 1;
    }
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

fn parseMessageTransmitters(
    doc: *model.Document,
    tokens: []const Token,
    allocator: std.mem.Allocator,
    diagnostics: *std.ArrayListUnmanaged(diagnostic.Diagnostic),
) Error!void {
    if (tokens.len < 5 or !std.mem.eql(u8, tokens[2].text, ":") or !std.mem.eql(u8, tokens[tokens.len - 1].text, ";"))
        return lineError(allocator, diagnostics, tokens[0], "malformed BO_TX_BU_ statement");
    const raw_id = std.fmt.parseInt(u32, tokens[1].text, 10) catch
        return lineError(allocator, diagnostics, tokens[1], "invalid BO_TX_BU_ message identifier");
    const id = raw_id & 0x1fffffff;
    const extended = raw_id & 0x80000000 != 0;
    var message_index: ?usize = null;
    for (doc.messages.items, 0..) |message, index| {
        const message_id = std.fmt.parseInt(u32, message.id[2..], 16) catch continue;
        if (message_id == id and message.extended == extended) {
            message_index = index;
            break;
        }
    }
    const index = message_index orelse return lineError(allocator, diagnostics, tokens[1], "BO_TX_BU_ references an unknown message");
    var message = &doc.messages.items[index];
    var expect_node = true;
    var node_count: usize = 0;
    var token_index: usize = 3;
    while (token_index < tokens.len - 1) : (token_index += 1) {
        const token = tokens[token_index];
        if (expect_node) {
            if (token.kind != .word) return lineError(allocator, diagnostics, token, "expected transmitter name in BO_TX_BU_");
            for (message.transmitters.items) |existing| {
                if (std.mem.eql(u8, existing, token.text))
                    return lineError(allocator, diagnostics, token, "duplicate BO_TX_BU_ transmitter");
            }
            node_count += 1;
            if (!std.mem.eql(u8, token.text, "Vector__XXX")) {
                const a = doc.allocator();
                if (!hasNode(doc, token.text)) try doc.nodes.append(a, .{ .name = try a.dupe(u8, token.text) });
                try message.transmitters.append(a, try a.dupe(u8, token.text));
            }
            expect_node = false;
        } else {
            if (!std.mem.eql(u8, token.text, ",")) return lineError(allocator, diagnostics, token, "expected comma between BO_TX_BU_ transmitters");
            expect_node = true;
        }
    }
    if (node_count == 0 or expect_node) return lineError(allocator, diagnostics, tokens[tokens.len - 1], "malformed BO_TX_BU_ transmitter list");
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

test "BO_TX_BU_ transmitter relationships import and export" {
    const source =
        \\BU_: ECU DASH TS
        \\BO_ 291 Engine: 1 ECU
        \\BO_TX_BU_ 291 : DASH,TS;
        \\BO_ 2147483939 Extended: 1 ECU
        \\BO_TX_BU_ 2147483939 : DASH;
    ;
    var diagnostics: std.ArrayListUnmanaged(diagnostic.Diagnostic) = .empty;
    defer diagnostics.deinit(std.testing.allocator);
    var doc = try parse(std.testing.allocator, source, &diagnostics);
    defer doc.deinit();
    try std.testing.expectEqual(@as(usize, 3), doc.messages.items[0].transmitters.items.len);
    try std.testing.expectEqualStrings("ECU", doc.messages.items[0].transmitters.items[0]);
    try std.testing.expectEqualStrings("DASH", doc.messages.items[0].transmitters.items[1]);
    try std.testing.expectEqualStrings("TS", doc.messages.items[0].transmitters.items[2]);
    try std.testing.expectEqual(@as(usize, 2), doc.messages.items[1].transmitters.items.len);

    const output = try write(std.testing.allocator, &doc);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "BO_TX_BU_ 291 : DASH,TS;\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "BO_TX_BU_ 2147483939 : DASH;\n") != null);
    var reparsed = try parse(std.testing.allocator, output, &diagnostics);
    defer reparsed.deinit();
    try std.testing.expectEqual(@as(usize, 3), reparsed.messages.items[0].transmitters.items.len);
    try std.testing.expectEqualStrings("TS", reparsed.messages.items[0].transmitters.items[2]);
    try std.testing.expectEqual(@as(usize, 2), reparsed.messages.items[1].transmitters.items.len);
    try std.testing.expectEqualStrings("DASH", reparsed.messages.items[1].transmitters.items[1]);
}

test "BO_TX_BU_ rejects unknown messages, duplicate transmitters, and malformed lists" {
    const cases = [_][]const u8{
        "BO_ 1 M: 1 ECU\nBO_TX_BU_ 2 : DASH;\n",
        "BO_ 1 M: 1 ECU\nBO_TX_BU_ 1 : ECU;\n",
        "BO_ 1 M: 1 ECU\nBO_TX_BU_ 1 : DASH,;\n",
    };
    var diagnostics: std.ArrayListUnmanaged(diagnostic.Diagnostic) = .empty;
    defer diagnostics.deinit(std.testing.allocator);
    for (cases) |source| {
        diagnostics.clearRetainingCapacity();
        try std.testing.expectError(error.InvalidDbc, parse(std.testing.allocator, source, &diagnostics));
        try std.testing.expectEqual(@as(u32, 2), diagnostics.items[0].source.dbc.line);
    }
}

test "multiple signal receivers are comma separated" {
    const source =
        \\BU_: ECU DASH TS
        \\BO_ 1 M: 1 ECU
        \\ SG_ Value : 0|8@1+ (1,0) [0|255] "" DASH,TS
    ;
    var diagnostics: std.ArrayListUnmanaged(diagnostic.Diagnostic) = .empty;
    defer diagnostics.deinit(std.testing.allocator);
    var doc = try parse(std.testing.allocator, source, &diagnostics);
    defer doc.deinit();
    try std.testing.expectEqual(@as(usize, 2), doc.messages.items[0].signals.items[0].receivers.items.len);

    const output = try write(std.testing.allocator, &doc);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"\" DASH,TS\n") != null);
    var reparsed = try parse(std.testing.allocator, output, &diagnostics);
    defer reparsed.deinit();
    try std.testing.expectEqual(@as(usize, 2), reparsed.messages.items[0].signals.items[0].receivers.items.len);
}

test "message comments and value tables import and export" {
    const source =
        \\BU_: ECU
        \\VAL_TABLE_ OnOff_e 1 "On; on, true" 0 "Off;off" ;
        \\VAL_TABLE_ Empty_e ;
        \\BO_ 291 Engine: 1 ECU
        \\ SG_ Value : 0|8@1+ (1,0) [0|255] "" ECU
        \\CM_ BO_ 291 "periodic message
        \\period: 100ms";
    ;
    var diagnostics: std.ArrayListUnmanaged(diagnostic.Diagnostic) = .empty;
    defer diagnostics.deinit(std.testing.allocator);
    var doc = try parse(std.testing.allocator, source, &diagnostics);
    defer doc.deinit();
    try std.testing.expectEqualStrings("periodic message\nperiod: 100ms", doc.messages.items[0].description.?);
    try std.testing.expectEqual(@as(usize, 2), doc.value_tables.items.len);
    try std.testing.expectEqualStrings("OnOff_e", doc.value_tables.items[0].name);
    try std.testing.expectEqualStrings("On; on, true", doc.value_tables.items[0].choices.items[0].label);
    try std.testing.expectEqual(@as(usize, 0), doc.value_tables.items[1].choices.items.len);

    const output = try write(std.testing.allocator, &doc);
    defer std.testing.allocator.free(output);
    const tables = std.mem.indexOf(u8, output, "\nVAL_TABLE_ OnOff_e").?;
    try std.testing.expect(tables < std.mem.indexOf(u8, output, "\nBO_ 291").?);
    var reparsed = try parse(std.testing.allocator, output, &diagnostics);
    defer reparsed.deinit();
    try std.testing.expectEqualStrings("periodic message\nperiod: 100ms", reparsed.messages.items[0].description.?);
    try std.testing.expectEqual(@as(usize, 2), reparsed.value_tables.items.len);
    try std.testing.expectEqualStrings("Off;off", reparsed.value_tables.items[0].choices.items[1].label);
}

test "DBC export warns about inlined value tables and synthesized signal bounds" {
    var doc = model.Document.init(std.testing.allocator);
    defer doc.deinit();
    const a = doc.allocator();
    try doc.value_tables.append(a, .{ .name = "Modes" });
    try doc.value_tables.items[0].choices.append(a, .{ .raw = "0", .label = "Off" });
    const signal = model.Signal{
        .name = "Mode",
        .start_bit = 0,
        .bit_length = 8,
        .byte_order = .little_endian,
        .signal_type = .unsigned,
        .value_table = "Modes",
    };
    var message = model.Message{
        .name = "Status",
        .bus = "can0",
        .id = "0x1",
        .extended = false,
        .frame = .classic,
        .length = 1,
    };
    try message.signals.append(a, signal);
    try doc.messages.append(a, message);

    var diagnostics: std.ArrayListUnmanaged(diagnostic.Diagnostic) = .empty;
    defer diagnostics.deinit(std.testing.allocator);
    const output = try writeWithDiagnostics(std.testing.allocator, &doc, &diagnostics);
    defer std.testing.allocator.free(output);
    try std.testing.expectEqual(@as(usize, 2), diagnostics.items.len);
    try std.testing.expectEqualStrings("signal value-table name is emitted as inline VAL_ values and is not preserved", diagnostics.items[0].message);
    try std.testing.expectEqualStrings("missing signal bounds are written as [0|0]", diagnostics.items[1].message);
    try std.testing.expect(std.mem.indexOf(u8, output, "VAL_TABLE_ Modes 0 \"Off\" ;\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "VAL_ 1 Mode 0 \"Off\";") != null);
}

test "DBC export blocks bus bitrates without a supported BS_ mapping" {
    var doc = model.Document.init(std.testing.allocator);
    defer doc.deinit();
    try doc.buses.append(doc.allocator(), .{ .name = "can0", .nominal_bitrate = 500000 });
    var diagnostics: std.ArrayListUnmanaged(diagnostic.Diagnostic) = .empty;
    defer diagnostics.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedConstruct, writeWithDiagnostics(std.testing.allocator, &doc, &diagnostics));
    try std.testing.expectEqual(@as(usize, 1), diagnostics.items.len);
    try std.testing.expectEqualStrings("bus bitrate fields cannot be represented by the supported DBC BS_ profile", diagnostics.items[0].message);
}

test "selected-bus DBC export filters messages and warns about unrepresentable names" {
    var doc = model.Document.init(std.testing.allocator);
    defer doc.deinit();
    const a = doc.allocator();
    try doc.buses.append(a, .{ .name = "can0" });
    try doc.buses.append(a, .{ .name = "can1" });
    try doc.nodes.append(a, .{ .name = "ECU0" });
    try doc.nodes.append(a, .{ .name = "ECU1" });
    try doc.nodes.append(a, .{ .name = "Receiver1" });
    try doc.nodes.append(a, .{ .name = "SharedService" });
    try doc.attribute_definitions.append(a, .{ .name = "NodeMode", .scope = .node, .value_type = .string });
    try doc.attribute_definitions.append(a, .{ .name = "UnusedNodeMode", .scope = .node, .value_type = .string });
    try doc.nodes.items[0].attributes.append(a, .{ .name = "NodeMode", .value = .{ .string = "unselected" } });
    try doc.nodes.items[1].attributes.append(a, .{ .name = "NodeMode", .value = .{ .string = "selected" } });
    var global_table = model.ValueTable{ .name = "GlobalModes" };
    try global_table.choices.append(a, .{ .raw = "0", .label = "Off" });
    try doc.value_tables.append(a, global_table);
    var global_variable = model.EnvironmentVariable{
        .name = "ServiceState",
        .variable_type = .integer,
        .minimum = "0",
        .maximum = "1",
        .unit = "",
        .initial_value = "0",
        .ev_id = 0,
        .access_type = 0,
    };
    try global_variable.access_nodes.append(a, "SharedService");
    try doc.environment_variables.append(a, global_variable);
    var first = model.Message{
        .name = "First",
        .bus = "can0",
        .id = "0x1",
        .extended = false,
        .frame = .classic,
        .length = 1,
    };
    try first.transmitters.append(a, "ECU0");
    var second = model.Message{
        .name = "Second",
        .bus = "can1",
        .id = "0x1",
        .extended = false,
        .frame = .classic,
        .length = 1,
    };
    try second.transmitters.append(a, "ECU1");
    var signal = model.Signal{
        .name = "Mode",
        .start_bit = 0,
        .bit_length = 8,
        .byte_order = .little_endian,
        .signal_type = .unsigned,
        .minimum = "0",
        .maximum = "255",
    };
    try signal.receivers.append(a, "Receiver1");
    try second.signals.append(a, signal);
    try doc.messages.append(a, first);
    try doc.messages.append(a, second);

    var diagnostics: std.ArrayListUnmanaged(diagnostic.Diagnostic) = .empty;
    defer diagnostics.deinit(std.testing.allocator);
    const output = try writeForBusWithDiagnostics(std.testing.allocator, &doc, "can1", &diagnostics);
    defer std.testing.allocator.free(output);
    try std.testing.expectEqual(@as(usize, 1), diagnostics.items.len);
    try std.testing.expectEqual(diagnostic.Severity.warning, diagnostics.items[0].severity);
    try std.testing.expectEqualStrings("can1", diagnostics.items[0].context.bus.?);
    try std.testing.expect(std.mem.indexOf(u8, output, "BO_ 1 Second: 1 ECU1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "First") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "BU_: ECU1 Receiver1 SharedService\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "ECU0") == null);
    try std.testing.expect(std.mem.indexOf(u8, output, "VAL_TABLE_ GlobalModes") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "BA_DEF_ BU_ \"NodeMode\" STRING;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "BA_ \"NodeMode\" BU_ ECU1 \"selected\";") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "UnusedNodeMode") == null);

    var reparsed = try parse(std.testing.allocator, output, &diagnostics);
    defer reparsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), reparsed.messages.items.len);
    try std.testing.expectEqualStrings("Second", reparsed.messages.items[0].name);
    try std.testing.expectEqualStrings("can0", reparsed.messages.items[0].bus);
    try std.testing.expectEqual(@as(usize, 3), reparsed.nodes.items.len);
    try std.testing.expectEqualStrings("selected", reparsed.nodes.items[0].attributes.items[0].value.string);
    try std.testing.expectEqual(@as(usize, 1), reparsed.value_tables.items.len);
    try std.testing.expectEqual(@as(usize, 1), reparsed.environment_variables.items.len);
}

test "selected-bus DBC export reports an unknown bus" {
    var doc = model.Document.init(std.testing.allocator);
    defer doc.deinit();
    try doc.buses.append(doc.allocator(), .{ .name = "can0" });
    var diagnostics: std.ArrayListUnmanaged(diagnostic.Diagnostic) = .empty;
    defer diagnostics.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnknownBus, writeForBusWithDiagnostics(std.testing.allocator, &doc, "can1", &diagnostics));
    try std.testing.expectEqual(@as(usize, 1), diagnostics.items.len);
    try std.testing.expectEqual(diagnostic.Code.unknown_bus, diagnostics.items[0].code);
}

test "selected-bus DBC export preserves selected bus blockers" {
    var doc = model.Document.init(std.testing.allocator);
    defer doc.deinit();
    const a = doc.allocator();
    try doc.buses.append(a, .{ .name = "can0" });
    try doc.buses.append(a, .{ .name = "can1", .nominal_bitrate = 500000 });
    var diagnostics: std.ArrayListUnmanaged(diagnostic.Diagnostic) = .empty;
    defer diagnostics.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedConstruct, writeForBusWithDiagnostics(std.testing.allocator, &doc, "can1", &diagnostics));
    try std.testing.expectEqual(@as(usize, 2), diagnostics.items.len);
    try std.testing.expectEqualStrings("selected bus name is not represented in DBC; imported bus defaults to can0", diagnostics.items[0].message);
    try std.testing.expectEqualStrings("bus bitrate fields cannot be represented by the supported DBC BS_ profile", diagnostics.items[1].message);
}

test "selected-bus DBC export rejects unfilterable opaque statements" {
    var diagnostics: std.ArrayListUnmanaged(diagnostic.Diagnostic) = .empty;
    defer diagnostics.deinit(std.testing.allocator);
    var doc = try parseWithOptions(std.testing.allocator, "BO_ 1 M: 1 ECU\nFOO_ opaque;\n", &diagnostics, .{ .preserve_unsupported_statements = true });
    defer doc.deinit();
    try doc.buses.append(doc.allocator(), .{ .name = "can1" });
    doc.messages.items[0].bus = "can1";
    diagnostics.clearRetainingCapacity();
    try std.testing.expectError(error.UnsupportedConstruct, writeForBusWithDiagnostics(std.testing.allocator, &doc, "can1", &diagnostics));
    try std.testing.expectEqual(@as(usize, 2), diagnostics.items.len);
    try std.testing.expectEqualStrings("opaque DBC statements cannot be safely filtered for one bus", diagnostics.items[1].message);
}

test "DBC export rejects punctuation in identifiers" {
    var doc = model.Document.init(std.testing.allocator);
    defer doc.deinit();
    try doc.nodes.append(doc.allocator(), .{ .name = "ECU$1" });
    var diagnostics: std.ArrayListUnmanaged(diagnostic.Diagnostic) = .empty;
    defer diagnostics.deinit(std.testing.allocator);
    try std.testing.expectError(error.UnsupportedConstruct, writeWithDiagnostics(std.testing.allocator, &doc, &diagnostics));
    try std.testing.expectEqual(@as(usize, 1), diagnostics.items.len);
    try std.testing.expectEqualStrings("node name is not a valid DBC identifier", diagnostics.items[0].message);
}

test "DBC string attribute values escape and round-trip quotes and backslashes" {
    const source =
        \\BA_DEF_ "Text" STRING;
        \\BA_ "Text" "quoted \"value\" and \\ path";
    ;
    var diagnostics: std.ArrayListUnmanaged(diagnostic.Diagnostic) = .empty;
    defer diagnostics.deinit(std.testing.allocator);
    var doc = try parse(std.testing.allocator, source, &diagnostics);
    defer doc.deinit();
    const expected = "quoted \"value\" and \\ path";
    try std.testing.expectEqualStrings(expected, doc.attributes.items[0].value.string);
    const output = try write(std.testing.allocator, &doc);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "BA_ \"Text\" \"quoted \\\"value\\\" and \\\\ path\";\n") != null);
    var reparsed = try parse(std.testing.allocator, output, &diagnostics);
    defer reparsed.deinit();
    try std.testing.expectEqualStrings(expected, reparsed.attributes.items[0].value.string);
}

test "global comment imports and exports as the document description" {
    const source = "BO_ 1 M: 1 ECU\n SG_ Value : 0|8@1+ (1,0) [0|255] \"\" ECU\nCM_ \"ride60 CAN matrix\";\n";
    var diagnostics: std.ArrayListUnmanaged(diagnostic.Diagnostic) = .empty;
    defer diagnostics.deinit(std.testing.allocator);
    var doc = try parse(std.testing.allocator, source, &diagnostics);
    defer doc.deinit();
    try std.testing.expectEqualStrings("ride60 CAN matrix", doc.description.?);

    const output = try write(std.testing.allocator, &doc);
    defer std.testing.allocator.free(output);
    var reparsed = try parse(std.testing.allocator, output, &diagnostics);
    defer reparsed.deinit();
    try std.testing.expectEqualStrings("ride60 CAN matrix", reparsed.description.?);
}

test "duplicate message comments are rejected" {
    const source = "BO_ 1 M: 1 ECU\nCM_ BO_ 1 \"a\";\nCM_ BO_ 1 \"b\";\n";
    var diagnostics: std.ArrayListUnmanaged(diagnostic.Diagnostic) = .empty;
    defer diagnostics.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidDbc, parse(std.testing.allocator, source, &diagnostics));
    try std.testing.expectEqual(@as(u32, 3), diagnostics.items[0].source.dbc.line);
}

test "exponent notation numbers stay one token and round-trip" {
    const source =
        \\BO_ 1 M: 8 ECU
        \\ SG_ Flags : 0|64@1+ (1,0) [0|1.84467440737096E+019] "" ECU
    ;
    var diagnostics: std.ArrayListUnmanaged(diagnostic.Diagnostic) = .empty;
    defer diagnostics.deinit(std.testing.allocator);
    var doc = try parse(std.testing.allocator, source, &diagnostics);
    defer doc.deinit();
    try std.testing.expectEqualStrings("1.84467440737096E+019", doc.messages.items[0].signals.items[0].maximum.?);

    const output = try write(std.testing.allocator, &doc);
    defer std.testing.allocator.free(output);
    var reparsed = try parse(std.testing.allocator, output, &diagnostics);
    defer reparsed.deinit();
    try std.testing.expectEqualStrings("1.84467440737096E+019", reparsed.messages.items[0].signals.items[0].maximum.?);
}

test "unmodeled multi-line comments stay one statement and are preserved verbatim" {
    const source = "BO_ 1 M: 1 ECU\r\n SG_ Value : 0|8@1+ (1,0) [0|255] \"\" ECU\r\nCM_ SGTYPE_ Env \"first line\r\nperiod: 100ms\";\r\nFOO_ after;\r\n";
    var diagnostics: std.ArrayListUnmanaged(diagnostic.Diagnostic) = .empty;
    defer diagnostics.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidDbc, parse(std.testing.allocator, source, &diagnostics));
    try std.testing.expectEqual(@as(u32, 3), diagnostics.items[0].source.dbc.line);

    var doc = try parseWithOptions(std.testing.allocator, source, &diagnostics, .{ .preserve_unsupported_statements = true });
    defer doc.deinit();
    const statements = doc.dbc.?.object.get("opaque_statements").?.array;
    try std.testing.expectEqual(@as(usize, 2), statements.items.len);
    try std.testing.expectEqualStrings("CM_ SGTYPE_ Env \"first line\r\nperiod: 100ms\";", statements.items[0].object.get("raw").?.string);
    try std.testing.expectEqual(@as(i64, 3), statements.items[0].object.get("line").?.integer);
    try std.testing.expectEqualStrings("FOO_ after;", statements.items[1].object.get("raw").?.string);
    try std.testing.expectEqual(@as(i64, 5), statements.items[1].object.get("line").?.integer);

    const output = try write(std.testing.allocator, &doc);
    defer std.testing.allocator.free(output);
    var reparsed = try parseWithOptions(std.testing.allocator, output, &diagnostics, .{ .preserve_unsupported_statements = true });
    defer reparsed.deinit();
    try std.testing.expectEqual(@as(usize, 2), reparsed.dbc.?.object.get("opaque_statements").?.array.items.len);
}

test "descriptions with line breaks are written as literal line breaks" {
    const source = "BO_ 1 M: 1 ECU\n SG_ Value : 0|8@1+ (1,0) [0|255] \"\" ECU\nCM_ SG_ 1 Value \"line one\nline two\";\n";
    var diagnostics: std.ArrayListUnmanaged(diagnostic.Diagnostic) = .empty;
    defer diagnostics.deinit(std.testing.allocator);
    var doc = try parse(std.testing.allocator, source, &diagnostics);
    defer doc.deinit();
    try std.testing.expectEqualStrings("line one\nline two", doc.messages.items[0].signals.items[0].description.?);

    const output = try write(std.testing.allocator, &doc);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"line one\nline two\";") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\\n") == null);
    var reparsed = try parse(std.testing.allocator, output, &diagnostics);
    defer reparsed.deinit();
    try std.testing.expectEqualStrings("line one\nline two", reparsed.messages.items[0].signals.items[0].description.?);
}

test "Vector independent-signal pseudo-message is skipped with a warning" {
    const source =
        \\BO_ 3221225472 VECTOR__INDEPENDENT_SIG_MSG: 0 Vector__XXX
        \\ SG_ Loose : 0|16@1+ (1,0) [0|65535] "" Vector__XXX
        \\ SG_ Loose : 0|16@1+ (1,0) [0|65535] "" Vector__XXX
        \\BO_ 1 M: 1 ECU
        \\ SG_ Value : 0|8@1+ (1,0) [0|255] "" ECU
        \\CM_ BO_ 3221225472 "unused signals";
        \\CM_ SG_ 3221225472 Loose "ignored";
        \\VAL_ 3221225472 Loose 1 "x" ;
    ;
    var diagnostics: std.ArrayListUnmanaged(diagnostic.Diagnostic) = .empty;
    defer diagnostics.deinit(std.testing.allocator);
    var doc = try parse(std.testing.allocator, source, &diagnostics);
    defer doc.deinit();
    try std.testing.expectEqual(@as(usize, 1), doc.messages.items.len);
    try std.testing.expectEqualStrings("M", doc.messages.items[0].name);
    try std.testing.expectEqual(@as(usize, 1), diagnostics.items.len);
    try std.testing.expectEqual(diagnostic.Severity.warning, diagnostics.items[0].severity);
    try std.testing.expectEqual(diagnostic.Code.dbc_independent_signals_skipped, diagnostics.items[0].code);
}

test "typed attributes preserve scope-like strings and reject mismatched scopes" {
    const source =
        \\BA_DEF_ "Label" STRING;
        \\BA_ "Label" "BO_";
    ;
    var diagnostics: std.ArrayListUnmanaged(diagnostic.Diagnostic) = .empty;
    defer diagnostics.deinit(std.testing.allocator);
    var doc = try parse(std.testing.allocator, source, &diagnostics);
    defer doc.deinit();
    try std.testing.expectEqualStrings("BO_", doc.attributes.items[0].value.string);

    const output = try write(std.testing.allocator, &doc);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "BA_ \"Label\" \"BO_\";\n") != null);
    var reparsed = try parse(std.testing.allocator, output, &diagnostics);
    defer reparsed.deinit();
    try std.testing.expectEqualStrings("BO_", reparsed.attributes.items[0].value.string);

    const mismatch =
        \\BU_: ECU
        \\BO_ 1 M: 1 ECU
        \\BA_DEF_ BU_ "Role" STRING;
        \\BA_ "Role" BO_ 1 "controller";
    ;
    diagnostics.clearRetainingCapacity();
    try std.testing.expectError(error.InvalidDbc, parse(std.testing.allocator, mismatch, &diagnostics));
    try std.testing.expectEqual(@as(u32, 4), diagnostics.items[0].source.dbc.line);
}

test "environment variable records reject malformed declarations and unknown targets" {
    const cases = [_][]const u8{
        "EV_ Ambient: 0 [0|255] \"degC\" 0 1 0 ;\n",
        "EV_ Payload: 3 [0|0] \"\" 0 2 0 ECU;\nENVVAR_DATA_ Missing : 16;\n",
        "CM_ EV_ Missing \"comment\";\n",
    };
    var diagnostics: std.ArrayListUnmanaged(diagnostic.Diagnostic) = .empty;
    defer diagnostics.deinit(std.testing.allocator);
    for (cases, 0..) |source, index| {
        diagnostics.clearRetainingCapacity();
        try std.testing.expectError(error.InvalidDbc, parse(std.testing.allocator, source, &diagnostics));
        try std.testing.expectEqual(@as(u32, if (index == 1) 2 else 1), diagnostics.items[0].source.dbc.line);
    }
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
    const source = "BO_ 1 M: 1 ECU\nCM_ SGTYPE_ Env \"comment\";\n";
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
        \\CM_ SGTYPE_ Env "comment";
        \\FOO_ arbitrary;
    ;
    var diagnostics: std.ArrayListUnmanaged(diagnostic.Diagnostic) = .empty;
    defer diagnostics.deinit(std.testing.allocator);
    var doc = try parseWithOptions(std.testing.allocator, source, &diagnostics, .{ .preserve_unsupported_statements = true });
    defer doc.deinit();

    const statements = doc.dbc.?.object.get("opaque_statements").?.array;
    try std.testing.expectEqual(@as(usize, 2), statements.items.len);
    try std.testing.expectEqualStrings("CM_ SGTYPE_ Env \"comment\";", statements.items[0].object.get("raw").?.string);
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
    try std.testing.expect(std.mem.endsWith(u8, output, "CM_ SGTYPE_ Env \"comment\";\nFOO_ arbitrary;\n"));

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
