# API guide

> The API is in an early stage and may change without notice. See the [README](../README.md).

Add the package as described in the README, then `const can_dbz = @import("can_dbz");`. The root module exposes:

| Namespace | Purpose |
|---|---|
| `can_dbz.model` | `Document` and its entities (`Bus`, `Node`, `Message`, `Signal`, value tables, attributes). |
| `can_dbz.diagnostic` | `Diagnostic`, `Code`, `Severity`, source references. |
| `can_dbz.validate` | Semantic validation of a `Document`. |
| `can_dbz.formats.can_json` | CAN JSON v1 parser and canonical writer. |
| `can_dbz.formats.dbc` | DBC parser and writer (limited profile). |
| `can_dbz.compile` | `compile` and `CompiledDatabase`. |
| `can_dbz.codec` | Raw/physical conversion primitives. |

## Workflow

```text
.can.json / .dbc  --parse-->  Document  --compile-->  CompiledDatabase  --decode/encode-->  values
                                  |
                                  +--write--> .can.json / .dbc
```

A `Document` is the editable, complete representation. A `CompiledDatabase` is an immutable, read-only index and plan set built from a validated `Document`; decode/encode calls on it do not allocate.

## Example

```zig
const std = @import("std");
const can_dbz = @import("can_dbz");

pub fn run(allocator: std.mem.Allocator, json_bytes: []const u8) !void {
    var doc = try can_dbz.formats.can_json.parse(allocator, json_bytes);
    defer doc.deinit();

    var db = try can_dbz.compile.compile(&doc, allocator);
    defer db.deinit();

    const handle = db.findMessage("can0", 0x18ff50e5, true) orelse return error.UnknownFrame;

    var payload: [64]u8 = @splat(0);
    var values: [5]can_dbz.codec.RawValue = undefined; // one per signal
    var active: [5]bool = undefined;
    var scratch: [5]u8 = undefined;
    try db.decodeRaw(handle, &payload, &values, &active, &scratch);
}
```

## Documents and ownership

`model.Document` owns an arena; every string and list inside it is freed by a single `doc.deinit()`. Slices obtained from a document are valid until then. Create one with `Document.init(allocator)` or via a parser.

## Parsing and writing

### CAN JSON

```zig
const can_json = can_dbz.formats.can_json;

pub fn parse(allocator, bytes) ParseError!model.Document
pub fn parseWithDiagnostics(allocator, bytes, diagnostics: *std.ArrayListUnmanaged(diagnostic.Diagnostic)) ParseError!model.Document
pub fn write(allocator, doc: *const model.Document) ![]u8   // caller frees
```

`ParseError` is `error{ OutOfMemory, InvalidJson, InvalidDocument }`. Parsing is strict: duplicate keys, unknown core fields and semantic errors are rejected. `parseWithDiagnostics` fills caller-owned diagnostics with codes and JSON pointers. `write` emits canonical output (stable field order, two-space indentation, sorted attribute keys). Format details: [can-json.md](./can-json.md).

### DBC

```zig
const dbc = can_dbz.formats.dbc;

pub fn parse(allocator, bytes, diagnostics: *std.ArrayListUnmanaged(diagnostic.Diagnostic)) Error!model.Document
pub fn parseWithOptions(allocator, bytes, diagnostics, options: ParseOptions) Error!model.Document
pub fn write(allocator, doc: *const model.Document) Error![]u8   // caller frees
```

`Error` is `error{ OutOfMemory, InvalidDbc, UnsupportedConstruct }`. `parse` is strict: statements outside the supported profile fail with a diagnostic carrying the source line and column. With `ParseOptions{ .preserve_unsupported_statements = true }`, unsupported single-line statements are stored in `doc.dbc.opaque_statements` (raw text and line number) and re-emitted by `write`. `write` returns `UnsupportedConstruct` for model content the DBC profile cannot express. See [dbc-support.md](./dbc-support.md).

### Diagnostics

Failed parses append `diagnostic.Diagnostic` values (`severity`, stable `code`, `message`, `source`, and `context` with bus/message/signal names) to the list you pass in. The caller owns the list and must `deinit` it. Messages are static strings; `context` and `source` slices may point into the input bytes or the document being built, so inspect diagnostics before releasing those.

## Validation

`validate.validateDocument(&doc, allocator, &diagnostics)` returns `false` when errors were reported. Parsers and `compile.compile` already validate; call it directly after building or editing a `Document` by hand.

## Compiling

```zig
pub fn compile(doc: *const model.Document, allocator: std.mem.Allocator) compile.Error!CompiledDatabase
```

`CompiledDatabase` methods (`handle` is a `MessageHandle`, `signal_index` is the signal's position in its message):

| Method | Description |
|---|---|
| `findMessage(bus, id, extended) ?MessageHandle` | Frame lookup by bus, numeric ID and extended flag. |
| `findMessageByName(temp_allocator, bus, name) !?MessageHandle` | Lookup by name (may allocate temporarily). |
| `findSignal(handle, name) !?usize` | Signal index by name. |
| `decodeRaw(handle, payload, values, active, scratch) !void` | Decode all signals into caller buffers; `active[i]` reports multiplexing activation. |
| `encodeRaw(handle, inputs, output, scratch) !usize` | Encode `?RawValue` inputs (null for inactive signals) into `output`; returns bytes written. |
| `decodeSignalRaw(handle, signal_index, payload) !RawValue` | Decode one signal. |
| `decodeSignalPhysical(handle, signal_index, payload) !f64` | Decode one signal with scale/offset and bounds checks. |
| `encodeSignalPhysical(handle, signal_index, value, rounding) !RawValue` | Convert a physical value to a raw value. |
| `choiceLabel(handle, signal_index, raw) !?[]const u8` | Label for a raw value from inline choices or a value table. |

Buffer sizes: `values`, `active`, `scratch`, and `inputs` must each hold at least one entry per signal in the message; `payload` must have exactly the message length. Runtime calls never allocate; errors leave `output` unchanged on failure.

## Raw values and conversion (`codec`)

```zig
pub const RawValue = union(enum) { unsigned: u64, signed: i64, float32: f32, float64: f64 };
pub const RoundingPolicy = enum { reject_fractional, nearest_ties_even };
```

Free functions operate on a single `model.Signal`: `decodeSignalRaw`, `encodeSignalRaw`, `decodePhysical`, `encodePhysical`, `choiceLabel`. They are the reference semantics used by the compiled paths.

Errors: `WrongLength`, `BufferTooSmall`, `UnsupportedWidth`, `WrongRawType`, `OutOfRange`, `NotRepresentable`, `ZeroFactor`, `NonFinite`, `PrecisionLoss`. Compiled-database calls additionally return `OutOfMemory`, `InvalidDocument`, `UnknownMessage`, `UnknownMuxValue`, `MissingSignal`, `InactiveSignal`.

Physical conversion rejects non-finite values and values outside the signal's physical bounds; `reject_fractional` refuses inputs that do not map exactly to an integer raw value, while `nearest_ties_even` rounds.

## Bit numbering

Signals use DBC sawtooth bit numbering for both byte orders; see [can-json.md](./can-json.md#bit-numbering-and-endianness). A signal is described by `start_bit`, `byte_order` and `bit_length` (up to 64 bits, which may span nine bytes when unaligned).
