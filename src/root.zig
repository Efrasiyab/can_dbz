const std = @import("std");

pub const diagnostic = @import("diagnostic.zig");
pub const model = @import("model.zig");
pub const validate = @import("validate.zig");
pub const compile = @import("compile.zig");
pub const codec = @import("codec.zig");
pub const formats = struct {
    pub const can_json = @import("formats/can_json.zig");
    pub const dbc = @import("formats/dbc.zig");
};

test {
    _ = std.testing;
    _ = diagnostic;
    _ = model;
    _ = validate;
    _ = compile;
    _ = codec;
    _ = formats.can_json;
    _ = formats.dbc;
}
