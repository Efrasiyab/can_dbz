# DBC support profile

The DBC adapter implements a documented subset. By default, unsupported statements fail with a diagnostic and source line/column. Call `parseWithOptions` with `preserve_unsupported_statements = true` to retain unsupported statements, including multi-line ones, in `Document.dbc.opaque_statements`; the default `parse` API remains strict. The matrix distinguishes semantic support from opaque preservation, which does not guarantee semantic round trips.

| DBC construct | Import | Export | Notes |
| --- | --- | --- | --- |
| `VERSION` | Yes | Yes | Preserved as `Document.dbc.version`. |
| `NS_` declaration list | Yes | Yes | Structural; declaration entries do not carry database values. |
| `BS_` | Empty header only | Empty header | Non-empty bus timing is rejected by default or preserved opaquely; bus bitrate fields are blocked on export because this profile has no equivalent `BS_` mapping. |
| `BU_` | Yes | Yes | Node names only. |
| `BO_` | Yes | Yes | Classic or FD frame, name, ID, length, and the transmitter named in the message declaration. Extended marker is translated to/from the DBC high bit. |
| `BO_TX_BU_` | Yes | Yes | Additional transmitters are appended to the `BO_` transmitter list and emitted in list order. |
| Tool-defined `VFrameFormat` attribute | Yes | Yes | Recognizes common enum values to identify CAN FD independently of payload length, including 8-byte FD frames; this is a tool-defined convention. |
| `SG_` integer signals | Yes | Yes | Start, width, byte order, signedness, scale, offset, physical bounds, unit, and receivers. |
| `CM_ SG_` signal comments | Yes | Yes | Signal descriptions use DBC string escaping. |
| `CM_ BU_` node comments | Yes | Yes | Node descriptions use DBC string escaping. |
| `CM_ BO_` message comments | Yes | Yes | Message descriptions, including multi-line text. |
| `CM_ "...";` global comment | Yes | Yes | Maps to the document description. |
| `CM_ EV_` environment-variable comments | Yes | Yes | Imported/exported as environment-variable descriptions with DBC string escaping. |
| Other comment scopes | Strict reject; opt-in preservation | Pass-through | Unsupported comment targets remain opaque. |
| `EV_` environment variables | Yes | Yes | Supports integer, float, string, and data type codes, scalar bounds/initial values, IDs, access types, and access nodes. |
| `ENVVAR_DATA_` | Yes | Yes | Preserves the data size associated with a data environment variable. |
| `VAL_TABLE_` value tables | Yes | Yes | Imported as document value tables and exported before messages; signal references are emitted as inline `VAL_` entries, so the reference by name is not retained. |
| `VECTOR__INDEPENDENT_SIG_MSG` (ID `3221225472`) | Skipped | N/A | Vector's container for unassigned signals and associated records is skipped with a warning. |
| `SG_MUL_VAL_` multiplexing | Yes | Yes | Supports multiple selectors and inclusive ranges. |
| `VAL_` signal values | Yes | Yes | Inline choices and referenced CAN JSON value tables are emitted as per-signal DBC values. |
| `SIG_VALTYPE_` float signals | Yes | Yes | Type `1` maps to float32 and type `2` maps to float64. |
| Standard attributes (`BA_DEF_`, `BA_DEF_DEF_`, `BA_`) | Yes | Yes | Document, node, message, signal, and environment-variable scopes; `INT`, `HEX`, `FLOAT`, `STRING`, and `ENUM` values. |
| Bus-scoped attributes | N/A | Strict export blocker | DBC has no bus attribute target in this adapter's standard scope mapping. |
| `//` lexer comments | Ignored | N/A | Comments are not retained. |
| Other unsupported statements and relationship records | Strict reject; opt-in preservation | Pass-through | Opaque statements retain raw source text and original line number. |
| Unsupported-statement preservation (`dbc.opaque_statements`) | Opt-in | Yes | Export appends opaque lines after generated supported statements. Edits and reordering can change their meaning; this is not an archival or semantic-preservation guarantee. |

## Dialect and interoperability notes

- `VFrameFormat` is a tool-defined attribute convention handled to identify CAN FD frames; do not treat it as a universally required DBC record.
- `VECTOR__INDEPENDENT_SIG_MSG` is a Vector pseudo-message handled by a dedicated skip rule, not as a general DBC message.
- `nested-mux-cantools.dbc` is a cantools-produced interoperability fixture; its declaration ordering is covered separately from the core syntax profile.
- `dbc-cantools-writer.dbc` is a golden output fixture emitted by the DBC writer and loaded by cantools 40.7.1. This is a narrow syntax check, not broad interoperability certification.
- `dbc-standard-gaps.dbc` covers the remaining unsupported bus-timing declaration and round-trips modeled attributes, transmitters, and environment variables.

## Export requirements

`dbc.write` omits the document name, extensions, and unknown `dbc` metadata because DBC has no matching fields. Use `dbc.writeWithDiagnostics` to receive warnings for omissions and normalizations, including inlined value-table references and missing bounds. For a multi-bus document, `dbc.writeForBus` exports messages for one selected bus; `dbc.writeForBusWithDiagnostics` also warns when the bus name is not `can0`, since DBC has no bus-name field and import defaults to `can0`. Exporting all buses requires one DBC file per bus; a single DBC file cannot retain multiple bus identities. Document value tables are exported as `VAL_TABLE_`, and signals that reference one also get per-signal `VAL_` values, so reuse by name is not retained on re-import. Sections are written in DBC grammar order, signals with several receivers use comma-separated names, and line breaks in descriptions are written literally. Export fails with `error.UnsupportedConstruct` for constructs the writer cannot safely encode; diagnostics identify each blocker.

- `write` rejects more than one bus; use `writeForBus` or `writeForBusWithDiagnostics` to select one bus. A selected bus not named `can0` produces a warning because the DBC output cannot retain its name.
- Bus bitrate, description, protocol, or attributes that this DBC profile cannot represent.
- Descriptions on the bus (`CM_` comments are supported for the document, nodes, messages, signals, and environment variables).
- Message receivers. Message-level receivers are not a standard DBC field.
- Bus-scoped attributes.
- Names that are not valid DBC identifiers.

Missing signal `minimum`/`maximum` do not block export; they are written as `[0|0]` with a `writeWithDiagnostics` warning.

Malformed supported declarations (such as `BO_`, `SG_`, `EV_`, `ENVVAR_DATA_`, `CM_ BU_`, `CM_ BO_`, `CM_ SG_`, `CM_ EV_`, `VAL_TABLE_`, `VFrameFormat`, `VAL_`, `SG_MUL_VAL_`, and `SIG_VALTYPE_`) remain errors even when preservation is enabled. Export also rejects metadata that the current DBC profile cannot represent (for example bus descriptions and multiple buses). The adapter is not yet a general-purpose DBC converter.
