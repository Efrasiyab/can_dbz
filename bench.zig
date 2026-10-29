const std = @import("std");
const can_dbz = @import("src/root.zig");

const fixture = @embedFile("tests/fixtures/golden.can.json");
const iterations = 100_000;

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const io = std.Options.debug_io;

    const load_start = std.Io.Clock.awake.now(io).nanoseconds;
    for (0..100) |_| {
        var document = try can_dbz.formats.can_json.parse(allocator, fixture);
        document.deinit();
    }
    const load_elapsed = std.Io.Clock.awake.now(io).nanoseconds - load_start;

    var document = try can_dbz.formats.can_json.parse(allocator, fixture);
    defer document.deinit();
    var database = try can_dbz.compile.compile(&document, allocator);
    defer database.deinit();
    const handle = database.findMessage("can0", 0x18ff50e5, true).?;
    var payload: [64]u8 = @splat(0);
    var values: [5]can_dbz.codec.RawValue = undefined;
    var active: [5]bool = undefined;
    var scratch: [5]u8 = undefined;

    const decode_start = std.Io.Clock.awake.now(io).nanoseconds;
    for (0..iterations) |_| {
        try database.decodeRaw(handle, &payload, &values, &active, &scratch);
        std.mem.doNotOptimizeAway(values);
        std.mem.doNotOptimizeAway(active);
    }
    const decode_elapsed = std.Io.Clock.awake.now(io).nanoseconds - decode_start;

    std.debug.print(
        "CAN DB benchmark (100 loads, {d} decodes)\nload: {d} ns total; runtime decode: {d} ns total ({d:.2} ns/op)\n",
        .{ iterations, load_elapsed, decode_elapsed, @as(f64, @floatFromInt(decode_elapsed)) / iterations },
    );
}
