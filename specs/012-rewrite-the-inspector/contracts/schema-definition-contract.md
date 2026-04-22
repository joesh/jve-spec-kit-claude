# Contract: Schema Definition Module

**Module**: `src/lua/ui/metadata_schemas.lua` (restructured under FR-023d)
**Consumers**: `src/lua/ui/inspector/schema.lua`, `src/lua/ui/inspector/field_widget.lua`, `src/lua/inspectable/{clip,sequence}.lua`

The restructured module is the single source of truth for the Inspector's section / field layout. Stale sections (premiere, review, crop, composite, transform) are pruned; the remaining sections correspond to properties enumerated in `research.md` §1.

---

## 1. Exports

```lua
local schemas = require("ui.metadata_schemas")

schemas.FIELD_TYPES            -- table of field-type enum values
schemas.PROPERTY_TYPES          -- table of property-type enum values (incl. TIMECODE)
schemas.get_sections(schema_id) -- ordered list of section definitions for a schema
schemas.get_field(schema_id, field_key) -- single field definition or nil
schemas.get_property_type(field_type)  -- maps FIELD_TYPE → property_type for the payload
```

Nothing else is exported. Legacy entries like `clip_inspector_schemas` (the old table) MUST NOT be re-exported (FR-027, rule 2.15).

### 1.1 `FIELD_TYPES`

```lua
schemas.FIELD_TYPES = {
  STRING    = "STRING",
  TEXT_AREA = "TEXT_AREA",
  DROPDOWN  = "DROPDOWN",
  INTEGER   = "INTEGER",
  DOUBLE    = "DOUBLE",
  BOOLEAN   = "BOOLEAN",
  TIMECODE  = "TIMECODE",
}
```

No other field types are supported (FR-010).

### 1.2 `PROPERTY_TYPES`

```lua
schemas.PROPERTY_TYPES = {
  STRING   = "STRING",
  NUMBER   = "NUMBER",
  BOOLEAN  = "BOOLEAN",
  ENUM     = "ENUM",
  TIMECODE = "TIMECODE",  -- distinct per Q3 resolution
}
```

### 1.3 `get_property_type(field_type)`

```
STRING     → STRING
TEXT_AREA  → STRING
DROPDOWN   → ENUM
INTEGER    → NUMBER
DOUBLE     → NUMBER
BOOLEAN    → BOOLEAN
TIMECODE   → TIMECODE   -- NOT NUMBER anymore (Q3)
```

---

## 2. Section / field definition shape

```lua
-- Ordered list returned by get_sections(schema_id):
{
  { name = <string>, schema = { fields = { <field>, <field>, ... } } },
  { name = <string>, schema = { fields = { <field>, ... } } },
  ...
}

-- A field:
{
  key        = <string, required, unique within schema>,
  label      = <string, required>,
  type       = <FIELD_TYPE, required>,
  default    = <value, optional>,
  options    = <list<string>, required for DROPDOWN>,
  read_only  = <boolean, default false>,       -- NEW for this feature (FR-010a)
}
```

- `key` is the stable identifier passed to `inspectable:get` / `:set`. Asserts if missing or empty.
- `label` is the display label. Asserts if missing or empty (rule 2.13: no `or "Field"` fallbacks).
- `type` is required. Missing → assert.
- `options` is required iff type == DROPDOWN; otherwise forbidden.
- `read_only = true` causes the Inspector to render the widget disabled and skip commit handlers.

---

## 3. Clip schema (target layout per Phase 0 research)

```
SCHEMA: clip

Section: File
  - name           STRING                          editable
  - media_id       STRING   read_only              (display, not editable here)
  - offline        BOOLEAN  read_only              (transient)
  - rate           STRING   read_only              (display only; formatted "24 fps" or "23.976 fps")

Section: Source Range
  - timeline_start  TIMECODE                       editable
  - duration        TIMECODE                       editable
  - source_in       TIMECODE                       editable
  - source_out      TIMECODE                       editable
  - mark_in         TIMECODE                       editable (nullable — treat empty as clear)
  - mark_out        TIMECODE                       editable (nullable)
  - playhead_frame  TIMECODE  read_only            (display)

Section: Enable
  - enabled         BOOLEAN                        editable

Section: Audio
  - volume          DOUBLE                         editable
```

**Note on `rate`**: although stored as a RATIONAL, the Inspector renders it as a pre-formatted read-only STRING produced by the inspectable's `:get("rate_display")` (or equivalent). We do not expose numerator/denominator separately — this is a display surface only, not an editor for frame rate.

---

## 4. Sequence schema (target layout per Phase 0 research)

```
SCHEMA: sequence

Section: Project
  - name                 STRING                     editable
  - frame_rate           STRING   read_only         (formatted)
  - width                INTEGER  read_only
  - height               INTEGER  read_only
  - audio_sample_rate    INTEGER  read_only
  - start_timecode_frame TIMECODE                   editable

Section: Viewport
  - playhead_position    TIMECODE                   editable (may also be driven externally)

Section: Marks
  - mark_in              TIMECODE                   editable (nullable)
  - mark_out             TIMECODE                   editable (nullable)
```

---

## 5. Contract tests

- **field-types-enumeration**: `FIELD_TYPES` has exactly 7 keys, values match the enumeration in this doc. No PREMIERE / REVIEW / CROP etc.
- **property-types-enumeration**: `PROPERTY_TYPES` has exactly 5 keys, includes TIMECODE.
- **property-type-mapping-timecode-is-timecode**: `get_property_type(FIELD_TYPES.TIMECODE) == "TIMECODE"` (NOT "NUMBER").
- **get-sections-clip-shape**: `get_sections("clip")` returns the target layout in the order specified in §3.
- **get-sections-sequence-shape**: `get_sections("sequence")` returns the target layout in §4.
- **field-label-required**: a field without a `label` key causes an assert during `get_sections`.
- **field-type-required**: a field without a `type` key causes an assert.
- **read-only-flag-respected**: fields with `read_only = true` round-trip through `get_field` with that flag.
- **dropdown-options-required**: a DROPDOWN field without `options` asserts.
- **no-stale-exports**: the returned module table has no `clip_inspector_schemas` key, no `sequence_inspector_schemas` key, no premiere/review/crop/composite/transform sections anywhere.

Test home: `tests/contract/inspector/test_schema_definition_contract.lua`.

---

## 6. Migration guidance

The old `metadata_schemas.lua` shape:
```lua
metadata_schemas.clip_inspector_schemas = {
  camera_info = { schema = { fields = { ... } } },
  production = { schema = { fields = { ... } } },
  ...
}
metadata_schemas.get_sections = function(schema_id) ... end  -- returns array derived from the above table
```

The new shape returns an **explicitly ordered** list per schema (sections are order-sensitive — Resolve's File before Source Range before Audio, not alphabetical). The internal storage format is a free choice; consumers only see `get_sections` and `get_field`.

---

## 7. Non-goals

- Supporting per-sequence or per-project schema overrides. Schemas are global and defined by this module.
- Runtime schema mutation (adding / removing fields at runtime). Schemas are effectively static.
- Persistence of schema-editor changes. The schema is code-owned, not user-owned.
