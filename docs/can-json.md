# CAN JSON v1 (`.can.json`) File Format

This document specifies **CAN JSON v1**, a strict, versioned JSON representation intended to be:

- Human-editable
- Deterministic to serialize (canonical output)
- Loss-minimizing for DBC round trips (with a dedicated `dbc` namespace)
- Easy to compile into fast, allocation-free runtime encode/decode plans

The Zig API is exposed as `formats.can_json.parse(allocator, bytes) !Document` and `formats.can_json.write(allocator, &document) ![]u8`. `parseWithDiagnostics` additionally accepts caller-owned diagnostic storage and rejects duplicate object keys, unknown core fields, and semantic errors. The shape-only JSON Schema draft is [can-db-v1.schema.json](../schema/can-db-v1.schema.json); semantic checks remain the library's responsibility.

## Quick Start

- File extension: `.can.json`
- Encoding: UTF-8
- Top-level fields:
  - `format`: must be `"can-db"`
  - `format_version`: must be `1`

Minimal example:

```json
{
  "format": "can-db",
  "format_version": 1,
  "name": "Example",
  "buses": [{ "name": "can0" }],
  "messages": []
}
```

## Strictness and Forward Compatibility

- **Duplicate JSON keys are invalid** and must be rejected.
- **Unknown core fields are errors** (to catch typos). Vendor/experimental fields must go under `extensions`.
- Arrays are used for `messages` and `signals` to preserve intentional ordering.

## Number and Identifier Encoding Rules

JSON tooling commonly treats numbers as IEEE-754 binary64, which is not safe for all raw CAN values. CAN JSON v1 therefore uses a mixed strategy:

- **Frame IDs** are strings in hexadecimal `0x` form.
  - Example: `"0x123"`, `"0x18FEEF31"`
- **Raw integers and exact bounds** are **decimal strings**.
  - Examples: `"0"`, `"255"`, `"-40"`, `"18446744073709551615"`
- **Factors/offsets and other physical floats** are **finite decimal strings** (optional exponent).
  - Examples: `"0.125"`, `"-273.15"`, `"1e-3"`
- **Bit positions and small structural counts** are JSON integers.
  - Examples: `start_bit: 7`, `bit_length: 16`, `length: 8`

Recommended implementation behavior:

- Preserve decimal strings in the in-memory `Document`.
- Convert to `i64/u64` and `f64` only during validation/compilation (with diagnostics for overflow/precision).

## Bit Numbering and Endianness

CAN JSON v1 uses **DBC sawtooth bit numbering** for both byte orders:

- Within every byte, **bit 0 is the least significant bit**.
- `start_bit` means:
  - **little_endian**: the signal's **least significant bit**.
  - **big_endian**: the signal's **most significant bit**.

Traversal rules:

- Little endian: `0, 1, 2, ...`
- Big endian: `7, 6, 5, 4, 3, 2, 1, 0, 15, 14, ..., 8, 23, ...`

Concrete examples:

- Big endian `start_bit = 7`, `bit_length = 16` occupies bytes 0 and 1.
- Big endian `start_bit = 3`, `bit_length = 12` uses bits 3–0 of byte 0, then bits 7–0 of byte 1.

## Top-Level Object

Top-level fields (not all required in v1 files, but reserved by the core schema):

- `format` (required): string, must be `"can-db"`
- `format_version` (required): integer, must be `1`
- `name` (recommended): string
- `description` (optional): string
- `buses` (recommended): array of bus objects
- `nodes` (optional): array of node objects
- `messages` (required): array of message objects
- `attribute_definitions` (optional): array of attribute definition objects
- `value_tables` (optional): array of named value table objects
- `dbc` (optional): DBC-only metadata namespace
- `extensions` (optional): object for non-core vendor data

### Bus

```json
{ "name": "can0" }
```

Suggested future fields (optional): `nominal_bitrate`, `data_bitrate`, `protocol`.

### Node

```json
{ "name": "ECU" }
```

## Message Object

Required fields:

- `name`: string
- `bus`: string (bus name)
- `id`: string, hex `0x...`
- `extended`: boolean
- `frame`: string enum: `"classic"` or `"fd"`
- `length`: integer payload length in bytes (0–8 for classic, 0–64 for FD)
- `signals`: array of signal objects

Common optional fields:

- `description`: string
- `transmitters`: array of node names
- `receivers`: array of node names (message-level receivers)
- `attributes`: object mapping attribute name -> value string
- `dbc`: object (message-local DBC metadata)
- `extensions`: object

Example (classic 8-byte):

```json
{
  "name": "EngineStatus",
  "bus": "can0",
  "id": "0x123",
  "extended": false,
  "frame": "classic",
  "length": 8,
  "transmitters": ["ECU"],
  "signals": []
}
```

## Signal Object

Required fields:

- `name`: string
- `start_bit`: integer
- `bit_length`: integer
- `byte_order`: string enum: `"little_endian"` or `"big_endian"`
- `type`: string enum: `"unsigned"`, `"signed"`, `"float32"`, `"float64"`

Optional fields (common):

- `description`: string
- `unit`: string
- `factor`: decimal string (default `"1"`)
- `offset`: decimal string (default `"0"`)
- `minimum`: decimal string
- `maximum`: decimal string
- `receivers`: array of node names
- `is_multiplexer`: boolean (default false)
- `when`: multiplexing condition array
- `choices`: array of `{ raw, label }`
- `value_table`: string (name of a document-level value table)
- `attributes`: object mapping attribute name -> value string
- `dbc`: object (signal-local DBC metadata)
- `extensions`: object

### Choices

Choice raw values are **decimal strings** (raw domain):

```json
"choices": [
  { "raw": "0", "label": "Stopped" },
  { "raw": "1", "label": "Running" }
]
```

Exactly one of the following should be used:

- `choices` (inline)
- `value_table` (reference)

Using both at once is an error.

## Multiplexing

Multiplexing is expressed with a `when` array on signals.

- A multiplexer (selector) signal sets `is_multiplexer: true`.
- Signals that depend on the selector include `when` conditions.
- Conditions are in the **raw** selector domain (before scaling/choices).

Condition structure:

```json
"when": [
  {
    "selector": "Page",
    "ranges": [["1", "3"], ["7", "7"]]
  }
]
```

Semantics:

- Missing `when` => unconditional signal.
- Multiple `when` entries are **AND**.
- Multiple `ranges` within an entry are **OR**.

## Attributes

Attributes are typed by `attribute_definitions`. Assignments are strings, interpreted by the attribute type.

An attribute definition example:

```json
{
  "name": "GenMsgCycleTime",
  "scope": "message",
  "type": "integer",
  "minimum": "0",
  "maximum": "65535",
  "default": "0"
}
```

Assignment example:

```json
"attributes": {
  "GenMsgCycleTime": "10"
}
```

Recommended attribute types:

- `integer` (decimal string)
- `float` (finite decimal string)
- `string` (literal JSON string)
- `enum` (decimal string index into the definition's label list)

## DBC Metadata Namespace (`dbc`)

Fields under `dbc` are for data that has no stable, format-neutral meaning yet but must survive round trips.

Examples of candidates:

- DBC version/header
- legacy bit timing blocks
- environment variables
- signal types and relationship metadata
- preservation of unsupported statements (`dbc.opaque_statements`)

The `dbc` object is allowed at:

- document level
- message level
- signal level

Consumers must ignore unknown `dbc` fields unless they explicitly implement them.

## Extensions (`extensions`)

Non-core vendor fields must be placed under `extensions` to avoid future core-field collisions.

Example:

```json
"extensions": {
  "acme": {
    "review_status": "draft",
    "ticket": "ACME-1234"
  }
}
```

## Canonical Serialization (Recommended)

Canonical writing is recommended to make diffs stable and to support golden tests:

- UTF-8
- 2-space indentation
- stable field order (documented by the writer)
- preserve message/signal array order
- sort `attributes` keys
- omit optional defaults consistently

Canonical serialization preserves **meaning**, not original whitespace or number spelling.

---

# Extensive Examples

These examples are intended to be copy/paste-able and to cover the tricky parts: endianness, muxing, FD payloads, attributes, and value tables.

## Example 1: Small Classic Frame (two signals + choices)

```json
{
  "format": "can-db",
  "format_version": 1,
  "name": "Powertrain",
  "description": "Small example edited by humans.",
  "buses": [{ "name": "can0" }],
  "nodes": [{ "name": "ECU" }, { "name": "Dashboard" }],
  "messages": [
    {
      "name": "EngineStatus",
      "bus": "can0",
      "id": "0x123",
      "extended": false,
      "frame": "classic",
      "length": 8,
      "transmitters": ["ECU"],
      "signals": [
        {
          "name": "EngineSpeed",
          "description": "Crankshaft speed",
          "start_bit": 0,
          "bit_length": 16,
          "byte_order": "little_endian",
          "type": "unsigned",
          "factor": "0.125",
          "offset": "0",
          "minimum": "0",
          "maximum": "8000",
          "unit": "rpm",
          "receivers": ["Dashboard"]
        },
        {
          "name": "State",
          "start_bit": 16,
          "bit_length": 2,
          "byte_order": "little_endian",
          "type": "unsigned",
          "choices": [
            { "raw": "0", "label": "Stopped" },
            { "raw": "1", "label": "Running" },
            { "raw": "2", "label": "Cranking" }
          ]
        }
      ]
    }
  ]
}
```

## Example 2: Big-Endian (Motorola) Layout Demonstrator

This example is purely to make `start_bit` and `bit_length` expectations explicit. The endian variants are separate messages because they occupy the same payload bits.

```json
{
  "format": "can-db",
  "format_version": 1,
  "name": "EndianDemo",
  "buses": [{ "name": "can0" }],
  "messages": [
    {
      "name": "MotorolaExample",
      "bus": "can0",
      "id": "0x200",
      "extended": false,
      "frame": "classic",
      "length": 2,
      "signals": [
        {
          "name": "BE_u16",
          "description": "Big endian 16-bit value starting at bit 7 (occupies byte0+byte1).",
          "start_bit": 7,
          "bit_length": 16,
          "byte_order": "big_endian",
          "type": "unsigned"
        }
      ]
    },
    {
      "name": "IntelExample",
      "bus": "can0",
      "id": "0x201",
      "extended": false,
      "frame": "classic",
      "length": 2,
      "signals": [
        {
          "name": "LE_u16",
          "description": "Little endian 16-bit value starting at bit 0 (also occupies byte0+byte1).",
          "start_bit": 0,
          "bit_length": 16,
          "byte_order": "little_endian",
          "type": "unsigned"
        }
      ]
    }
  ]
}
```

## Example 3: Multiplexing (Page selector)

```json
{
  "format": "can-db",
  "format_version": 1,
  "name": "MuxDemo",
  "buses": [{ "name": "can0" }],
  "messages": [
    {
      "name": "PagedData",
      "bus": "can0",
      "id": "0x300",
      "extended": false,
      "frame": "classic",
      "length": 8,
      "signals": [
        {
          "name": "Page",
          "start_bit": 0,
          "bit_length": 8,
          "byte_order": "little_endian",
          "type": "unsigned",
          "is_multiplexer": true
        },
        {
          "name": "Temperature",
          "start_bit": 8,
          "bit_length": 16,
          "byte_order": "little_endian",
          "type": "signed",
          "factor": "0.1",
          "offset": "-40",
          "unit": "C",
          "when": [
            { "selector": "Page", "ranges": [["1", "1"], ["3", "3"]] }
          ]
        },
        {
          "name": "Pressure",
          "start_bit": 8,
          "bit_length": 16,
          "byte_order": "little_endian",
          "type": "unsigned",
          "factor": "0.5",
          "offset": "0",
          "unit": "kPa",
          "when": [
            { "selector": "Page", "ranges": [["2", "2"]] }
          ]
        }
      ]
    }
  ]
}
```

## Example 4: Nested Multiplexing (two selectors)

Multiple `when` entries are ANDed: a signal can depend on more than one selector.

```json
{
  "format": "can-db",
  "format_version": 1,
  "name": "NestedMux",
  "buses": [{ "name": "can0" }],
  "messages": [
    {
      "name": "ServiceResponse",
      "bus": "can0",
      "id": "0x400",
      "extended": false,
      "frame": "classic",
      "length": 8,
      "signals": [
        {
          "name": "Service",
          "start_bit": 0,
          "bit_length": 8,
          "byte_order": "little_endian",
          "type": "unsigned",
          "is_multiplexer": true,
          "choices": [
            { "raw": "1", "label": "Read" },
            { "raw": "2", "label": "Write" }
          ]
        },
        {
          "name": "SubId",
          "start_bit": 8,
          "bit_length": 8,
          "byte_order": "little_endian",
          "type": "unsigned",
          "is_multiplexer": true
        },
        {
          "name": "ReadValue",
          "start_bit": 16,
          "bit_length": 16,
          "byte_order": "little_endian",
          "type": "unsigned",
          "when": [
            { "selector": "Service", "ranges": [["1", "1"]] },
            { "selector": "SubId", "ranges": [["10", "10"], ["11", "11"]] }
          ]
        },
        {
          "name": "WriteStatus",
          "start_bit": 16,
          "bit_length": 8,
          "byte_order": "little_endian",
          "type": "unsigned",
          "when": [
            { "selector": "Service", "ranges": [["2", "2"]] }
          ],
          "choices": [
            { "raw": "0", "label": "OK" },
            { "raw": "1", "label": "Denied" },
            { "raw": "2", "label": "Busy" }
          ]
        }
      ]
    }
  ]
}
```

## Example 5: CAN FD 64-byte Payload + Float Signal

```json
{
  "format": "can-db",
  "format_version": 1,
  "name": "FdDemo",
  "buses": [{ "name": "can0" }],
  "messages": [
    {
      "name": "SensorSnapshot",
      "bus": "can0",
      "id": "0x18FF50E5",
      "extended": true,
      "frame": "fd",
      "length": 64,
      "signals": [
        {
          "name": "TimestampMs",
          "start_bit": 0,
          "bit_length": 32,
          "byte_order": "little_endian",
          "type": "unsigned",
          "minimum": "0",
          "maximum": "4294967295",
          "unit": "ms"
        },
        {
          "name": "AccelX",
          "start_bit": 32,
          "bit_length": 32,
          "byte_order": "little_endian",
          "type": "float32",
          "unit": "m/s^2"
        },
        {
          "name": "BlobCounter",
          "description": "Demonstrates a 64-bit unsigned raw value.",
          "start_bit": 256,
          "bit_length": 64,
          "byte_order": "little_endian",
          "type": "unsigned",
          "minimum": "0",
          "maximum": "18446744073709551615"
        }
      ]
    }
  ]
}
```

## Example 6: Attributes + Value Tables (document-level)

```json
{
  "format": "can-db",
  "format_version": 1,
  "name": "AttrsAndTables",
  "buses": [{ "name": "can0" }],
  "attribute_definitions": [
    {
      "name": "GenMsgCycleTime",
      "scope": "message",
      "type": "integer",
      "minimum": "0",
      "maximum": "65535",
      "default": "0"
    }
  ],
  "value_tables": [
    {
      "name": "OnOff",
      "choices": [
        { "raw": "0", "label": "Off" },
        { "raw": "1", "label": "On" }
      ]
    }
  ],
  "messages": [
    {
      "name": "Lights",
      "bus": "can0",
      "id": "0x500",
      "extended": false,
      "frame": "classic",
      "length": 1,
      "attributes": { "GenMsgCycleTime": "100" },
      "signals": [
        {
          "name": "Headlights",
          "start_bit": 0,
          "bit_length": 1,
          "byte_order": "little_endian",
          "type": "unsigned",
          "value_table": "OnOff"
        },
        {
          "name": "Hazards",
          "start_bit": 1,
          "bit_length": 1,
          "byte_order": "little_endian",
          "type": "unsigned",
          "value_table": "OnOff"
        }
      ]
    }
  ],
  "dbc": {
    "version": "1.0",
    "notes": "Example of a DBC-only metadata namespace; fields are not yet standardized."
  },
  "extensions": {
    "example": {
      "source": "handwritten",
      "last_reviewed": "2026-10-27"
    }
  }
}
```
