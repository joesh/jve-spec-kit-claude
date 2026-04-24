# Contract: Inspectable (Clip + Sequence)

**Modules**: `src/lua/inspectable/clip.lua`, `src/lua/inspectable/sequence.lua`
**Consumer**: the rewritten Inspector (`src/lua/ui/inspector/`)

The spec's non-goals forbid changing the inspectable factory's API shape. This feature only **adds** a TIMECODE branch to the `:set` payload dispatch. Everything else is validated, not modified.

---

## 1. Constructor (unchanged)

### `ClipInspectable.new(opts)`

```
opts = {
  clip_id    = <string, required>,
  project_id = <string, required>,
  sequence_id = <string, optional>,   -- present for timeline clips
  clip       = <table,  optional>,     -- cached live reference
  metadata   = <table,  optional>      -- property overrides for batch flows
}
```

### `SequenceInspectable.new(opts)`

```
opts = {
  sequence_id = <string, required>,
  project_id  = <string, required>,
  sequence    = <table,  optional>     -- cached live reference
}
```

---

## 2. Public methods (unchanged signatures)

| Method | Returns | Notes |
|---|---|---|
| `:get(field_key)` | `value` or `nil` | Reads from overrides → live ref → DB cache. Must be idempotent and side-effect-free. |
| `:set(field_key, payload)` | `ok, err` | Dispatches to a command. **Gets a new TIMECODE branch** (see §3). |
| `:refresh()` | (none) | Clears local cache so next `:get` re-reads from DB. |
| `:get_display_name()` | string | For header labels. Must never return nil. |
| `:supports_multi_edit()` | boolean | `ClipInspectable` → true; `SequenceInspectable` → false. |
| `:get_schema_id()` | `"clip"` or `"sequence"` | Decides which schema the Inspector activates. |
| `:iter_fields()` | iterator | Yields the schema fields for this inspectable. |

The Inspector also reads `inspectable.sequence_id` as a field (both `ClipInspectable` and `SequenceInspectable` carry it).

---

## 3. **NEW — TIMECODE branch at `:set`**

### 3.1 Current payload shape (recap)

```lua
inspectable:set(field_key, {
  value = <typed value>,
  property_type = "STRING" | "NUMBER" | "BOOLEAN" | "ENUM",
  default_value = <same type as value, optional>
})
```

### 3.2 Added branch

```lua
inspectable:set(field_key, {
  value = <integer frames, required, ≥ 0>,
  property_type = "TIMECODE",
  default_value = <integer frames, optional>
})
```

**Semantics**:
- `value` is integer frames. Assert `type(value) == "number" and value == math.floor(value) and value >= 0` at entry.
- Frame rate is NOT in the payload. The command side retrieves rate from the owning entity (clip.rate for clip fields; sequence.frame_rate for sequence fields).
- Internally, TIMECODE dispatches to the same `SetClipProperty` / `SetSequenceMetadata` command as NUMBER would, writing the integer frame column directly. The distinction at the payload layer lets future consumers dispatch on property_type (rule 2.21, statically verifiable).

### 3.3 `:set` contract tests

- **set-string-payload**: `:set("name", {value="X", property_type="STRING"})` dispatches `SetClipProperty` with that value.
- **set-number-payload**: `:set("volume", {value=0.5, property_type="NUMBER"})` dispatches correctly.
- **set-boolean-payload**: `:set("enabled", {value=false, property_type="BOOLEAN"})` dispatches correctly.
- **set-enum-payload**: `:set("some_enum", {value="Option A", property_type="ENUM"})` dispatches correctly.
- **set-timecode-payload-valid**: `:set("source_in", {value=120, property_type="TIMECODE"})` dispatches correctly; column written as integer 120.
- **set-timecode-payload-asserts-on-non-integer**: `:set("source_in", {value=120.5, property_type="TIMECODE"})` asserts with message containing "TIMECODE" and "integer".
- **set-timecode-payload-asserts-on-negative**: `:set("source_in", {value=-1, property_type="TIMECODE"})` asserts.
- **set-timecode-payload-asserts-on-rate-in-payload**: if a caller sneaks `rate = ...` into the payload, that key is ignored; the canonical rate on the entity is used. (Optional test — asserts only if we choose to validate strict payload shape.)

Test home: `tests/contract/inspector/test_inspectable_set_timecode.lua`.

---

## 4. Invariants (enforced, not changed)

1. `:set` always routes through `command_manager.execute_interactive` so the mutation is undoable.
2. `:refresh()` is idempotent and must not emit signals.
3. `:get_display_name()` is stable across refreshes as long as the underlying name is unchanged.
4. `:supports_multi_edit()` is pure; no state.

---

## 5. Non-goals

- Adding / removing / renaming any method on the inspectable.
- Changing `:get` / `:get_display_name` / `:supports_multi_edit` / `:get_schema_id` behavior.
- Moving rate into the payload (explicitly rejected by Q3 resolution; rate stays on the entity).
