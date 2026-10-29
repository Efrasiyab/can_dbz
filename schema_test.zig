const std = @import("std");

test "CAN JSON schema is valid JSON Schema-shaped data" {
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        @embedFile("schema/can-db-v1.schema.json"),
        .{},
    );
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
    try std.testing.expectEqualStrings("https://json-schema.org/draft/2020-12/schema", parsed.value.object.get("$schema").?.string);
    try std.testing.expect(parsed.value.object.get("$defs") != null);
}
