# can_dbz

A Zig library for converting CAN databases (DBC and an editable JSON format) and for fast, allocation-free CAN message encoding and decoding.

> **⚠️ Early stage — not recommended for use.**
> This project is a work in progress. APIs, the CAN JSON format, and DBC behavior may change without notice, DBC coverage is intentionally incomplete, and the codecs have not been validated against other CAN tooling or real-world databases. Do not use it in production or safety-relevant systems.

## Features (current)

- Semantic `Document` model with validation and structured diagnostics.
- Strict, versioned **CAN JSON v1** parser and canonical writer ([format](docs/can-json.md), [schema](schema/can-db-v1.schema.json)).
- Compiled database with message/signal indexes and raw encode/decode (Intel/Motorola, signed/unsigned, 32/64-bit floats, simple multiplexing) using caller-provided buffers.
- Physical value conversion (scale/offset, bounds, explicit rounding) and choice lookup.
- Incremental DBC import/export profile ([support matrix](docs/dbc-support.md)); unsupported statements are rejected by default or optionally preserved verbatim.

## Requirements

Zig **0.17.0** (see `minimum_zig_version` in [build.zig.zon](build.zig.zon)). Other Zig versions are not tested.

## Using as a dependency

In Zig, a reusable library is a **package** (described by `build.zig.zon`) that exposes one or more **modules** (importable with `@import`). To add can_dbz to your project:

```sh
zig fetch --save git+https://github.com/<owner>/can_dbz
```

Replace `<owner>` with the repository owner; append `#<tag-or-commit>` to pin a version. This adds a `.can_dbz` entry to the `.dependencies` of your `build.zig.zon`. Then, in your `build.zig`:

```zig
const can_dbz = b.dependency("can_dbz", .{
    .target = target,
    .optimize = optimize,
});

exe.root_module.addImport("can_dbz", can_dbz.module("can_dbz"));
```

and in your code:

```zig
const can_dbz = @import("can_dbz");
```

See the [API guide](docs/api.md) for usage.

## Documentation

- [API guide](docs/api.md)
- [CAN JSON v1 format](docs/can-json.md)
- [DBC support profile](docs/dbc-support.md)

## Development

```sh
zig fmt --check build.zig build.zig.zon bench.zig schema_test.zig src tests
zig build              # build the library
zig build test         # unit tests
zig build test-smoke   # fixture-backed smoke tests
zig build bench        # load-time vs. decode benchmark (not a performance claim)
```

A [Containerfile](Containerfile) with the pinned Zig toolchain is provided for a reproducible environment.

## Roadmap / planned work

Nothing below is implemented or promised; it records the intended direction.

- **Broader DBC coverage:** comment scopes beyond node and signal `CM_`, `VAL_TABLE_`, attribute types/scopes beyond bounded message integers, signal groups, environment variables, and relationship metadata — each with structured storage and writers before being claimed as supported.
- **Long names:** DBC long-name handling that keeps original names.
- **Safer round trips:** export reports listing anything lossy and refusal of lossy export by default; validation of DBC identifier rules, escaping and encodings; rejecting preserved opaque statements whose validity cannot be established after edits; atomic output file replacement. Semantic equivalence (not byte-identical text) is the intended guarantee for the supported profile; byte-identical regeneration would need a separate concrete-syntax-tree editor and is out of scope.
- **Multi-bus databases:** DBC export of one selected bus, rejecting ambiguous multi-bus exports.
- **Verification:** differential tests against other implementations (for example cantools and dbcppp) on a shared supported subset; more exhaustive correctness gates (all start bits and widths in Classic and FD payloads, nine-byte spans, nested multiplexing, unknown selectors, short buffers); expanded bounded-resource fuzzing.
- **Performance:** reproducible benchmarks on named hardware and build modes (frame lookup, cached-handle decode, raw vs. physical, encode, selected-signal decode, allocation counts) before adding specialized dispatch or code generation. No throughput target is promised until measured.
- **Releases:** stable API and format versioning, tagged releases.

## License

Licensed under the [Mozilla Public License 2.0](LICENSE) (MPL-2.0): modifications to MPL-covered files must be shared under the same license, while the library can still be used from projects under other licenses.
