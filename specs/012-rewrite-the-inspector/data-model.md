# Phase 1 Data Model: Inspector Rewrite (012)

This document defines the entities the rewritten Inspector manipulates internally, the data flowing across its boundaries, and the state transitions that define its behavior. It is implementation-agnostic about Lua module layout (that is in `plan.md`) but precise about shape and lifecycle.

---

## 1. External data flowing into the Inspector

### 1.1 Selection update (from `selection_hub`)

Shape of each item in the list passed to `update_selection(items, source_panel_id)`:

| Field | Type | Required | Notes |
|---|---|---|---|
| `item_type` | string | yes | `"timeline_clip"`, `"master_clip"`, `"timeline_sequence"`, or `"timeline"`. Anything else is ignored. |
| `clip_id` | string | when applicable | required for clip-kind `item_type` |
| `sequence_id` | string | when applicable | required for sequence-kind `item_type`; also required for `timeline_clip` for inspectable construction |
| `project_id` | string | yes | needed by the inspectable factory |
| `display_name` | string | optional | if absent, Inspector falls back to `inspectable:get_display_name()` |
| `clip` | table | optional | cached in-memory clip reference; if absent, inspectable resolves from DB |
| `sequence` | table | optional | cached in-memory sequence reference |
| `inspectable` | object | optional | if the caller already has a constructed inspectable, use it directly (skip factory) |

`source_panel_id` is a string: `"timeline"`, `"project_browser"`, `"inspector"`, or other panel identifiers. The Inspector ignores events where `source_panel_id == "inspector"` (FR-003).

### 1.2 Signals consumed

- `project_changed(new_project_id)` — clears all Inspector state (FR-017).
- `content_changed(sequence_id)` — triggers pull-on-notify for inspectables whose `.sequence_id == sequence_id` (FR-016).

---

## 2. Internal entities (module-scoped state)

### 2.1 `Inspector` (module state)

| Field | Type | Purpose |
|---|---|---|
| `root` | Qt widget | the container mounted by layout |
| `header_label` | Qt widget | top-of-panel label showing selection summary |
| `search_input` | Qt widget | search filter entry |
| `scroll_area`, `content_widget`, `content_layout` | Qt widgets | form scaffolding |
| `apply_button` | Qt widget | shown only in multi-edit mode |
| `active_schema` | `ActiveSchema?` | current schema, if any |
| `selection_state` | `SelectionState` | current selection summary |
| `suppress_updates_depth` | integer | nonzero means programmatic `set_value` calls are in progress; field widgets skip commit handlers |
| `filter_query` | string | current search text |
| `sections_by_schema` | table<schema_id → list<SectionView>> | widgets pre-built per schema, shown/hidden on activation |

### 2.2 `SelectionState`

| Field | Type | Purpose |
|---|---|---|
| `size` | integer | total number of items passed in the last update |
| `source_panel_id` | string | for mark-summary logic (FR-018) |
| `schema_counts` | table<schema_id → integer> | how many items of each schema are present |
| `active_schema_id` | string? | result of majority-schema computation |
| `active_inspectables` | list<inspectable> | items of the active schema (the subset Inspector edits) |
| `other_schema_counts` | table<schema_id → integer> | for header disclosure line (FR-005b) |
| `previous_item_ids` | set<string> | last selection's stable IDs, used for most-recently-clicked tiebreak (FR-005a) |
| `mode` | enum | `"empty"` / `"single"` / `"multi_edit"` / `"multi_read_only"` / `"heterogeneous"` / `"mixed_unsupported"` |
| `multi_edit_allowed` | boolean | `true` iff size > 1 AND every active inspectable `supports_multi_edit()` |

### 2.3 `ActiveSchema`

| Field | Type | Purpose |
|---|---|---|
| `schema_id` | string | `"clip"` or `"sequence"` |
| `sections` | list<SectionView> | ordered sections for this schema |
| `field_widgets` | table<field_key → FieldWidget> | lookup from field key to widget entry |

### 2.4 `SectionView`

| Field | Type | Purpose |
|---|---|---|
| `name` | string | section display name |
| `section_obj` | collapsible-section object | from `collapsible_section.create_section` |
| `widget` | Qt widget | section container |
| `field_names` | list<string> | labels (for search match) |
| `persisted_key` | string | `"inspector.section.<schema_id>.<section_name>.expanded"` (for PersistentWidget) |

### 2.5 `FieldWidget` (per field, per schema)

| Field | Type | Purpose |
|---|---|---|
| `field_key` | string | stable key used with inspectable `:set` / `:get` |
| `field_type` | enum | STRING, TEXT_AREA, DROPDOWN, INTEGER, DOUBLE, BOOLEAN, TIMECODE |
| `property_type` | enum | STRING, NUMBER, BOOLEAN, ENUM, TIMECODE (for `:set` payload) |
| `read_only` | boolean | from schema definition (FR-010a) |
| `widget` | Qt widget | line edit / checkbox / combo box / text area |
| `default_value` | any? | from schema definition |
| `options` | list<string>? | for DROPDOWN |
| **Runtime flags:** | | |
| `dirty` | boolean | user typed since last pull/commit (FR-016a) |
| `error` | boolean | last commit produced invalid parse (FR-015a) |
| `mixed` | boolean | multi-edit: items disagree on this field's value (FR-014) |
| `pending_value` | any? | in-flight text converted to typed value (for multi-edit Apply) |

### 2.6 `PropertyPayload` (outgoing to inspectable `:set`)

Discriminated union on `property_type`:

```
{ value = <string>, property_type = "STRING",  default_value = <string>? }
{ value = <number>, property_type = "NUMBER",  default_value = <number>? }
{ value = <bool>,   property_type = "BOOLEAN", default_value = <bool>? }
{ value = <string>, property_type = "ENUM",    default_value = <string>? }
{ value = <int>,    property_type = "TIMECODE", default_value = <int>? }  -- NEW
```

TIMECODE values are integer frames. Frame rate is authoritative on the owning entity (sequence.frame_rate or clip.rate) and is NEVER carried in the payload.

### 2.7 `SectionPersistedState` (external — persistent_widget)

JSON record at `~/.jve/widget_state.json`:

```json
{
  "inspector.section.clip.File.expanded": true,
  "inspector.section.clip.Source Range.expanded": true,
  "inspector.section.clip.Audio.expanded": false,
  "inspector.section.sequence.Project.expanded": true,
  ...
}
```

Only boolean values. Unknown keys are ignored. Missing keys default to `true` (sections start expanded on first use).

---

## 3. State transitions

### 3.1 Inspector lifecycle

```
[created]
   │  layout.lua calls require("ui.inspector")
   ▼
[idle]
   │  layout.lua calls mount(container)
   ▼
[mounted]  ← scaffolding built; schemas pre-built; all sections hidden
   │  selection_hub delivers first update
   ▼
[selection-driven] ← see selection state machine below
```

### 3.2 Selection state machine

```
  update_selection(items, source)
           │
           ▼
  compute schema_counts, size, mode
           │
           ├── mode == "empty"          → show "No editable selection"; hide sections; clear selection label
           ├── mode == "heterogeneous"  → pick active schema (majority, tiebreak on newly-clicked item); header discloses split; load single or multi from active subset
           ├── mode == "single"         → load single; header = "Clip: X" or "Record: Y" (or "Master Clip: Y" when the master-clip schema lands); mark summary if record source or sequence schema
           ├── mode == "multi_edit"     → load multi; show Apply; header = "Clips: N selected" or "Records: N selected"
           ├── mode == "multi_read_only" → load single (first item); hide Apply; header = "... (read-only)"
           └── mode == "mixed_unsupported" → behave as multi_read_only on the active schema
```

Active-schema stability (FR-005a): the set of schemas present is derived from the new selection. If that set equals the set on the previous selection update AND there is a previous active_schema_id, **keep** the previous active_schema_id regardless of majority recount. Otherwise recompute: pick the schema with the highest count; break ties by choosing the schema of the first item in the new selection that was not in the previous selection; if no such item (full overlap), pick the schema of items[1].

### 3.3 Field widget lifecycle

```
  [initial]
     │  load_single / load_multi / refresh
     ▼
  [showing_model_value]  (dirty=false, error=false, mixed=per-context)
     │  user types (textChanged)
     ▼
  [dirty]                (dirty=true, pending_value=parsed-or-nil)
     │
     ├── commit (editingFinished / toggle)
     │     ├── parse succeeds, single-edit → route to inspectable:set → showing_model_value
     │     ├── parse succeeds, multi-edit  → stays dirty, pending_value set, Apply enabled-iff-all-valid
     │     └── parse fails                 → [invalid]
     │
     └── blur without commit             → showing_model_value (discard pending)
                                            if error was set, clear it

  [invalid]   (dirty=true, error=true, bad text visible with red border)
     │
     ├── blur                 → revert to showing_model_value, clear error, clear dirty
     ├── user types valid     → dirty (error=false)
     └── content_changed      → ignored (dirty fields skip pull; FR-016a)
```

### 3.4 Apply (multi-edit) flow

```
  Apply button clicked
     │
     │  (precondition: enabled iff all dirty fields valid)
     ▼
  command_manager.begin_command_event("ui")
     │
     ▼
  for each active_inspectable:
     for each dirty field with pending_value:
        inspectable:set(field_key, payload)
     │
     ▼
  command_manager.end_command_event()   (all N*M writes = one undo group)
     │
     ▼
  for each field:
     set_value(pending_value); clear dirty; clear pending_value
     │
     ▼
  (content_changed signal fires; Inspector's own listener sees it and re-pulls, idempotently)
```

### 3.5 Change-notification flow

```
  project_changed(new_project_id)
     │
     ▼
  active_schema := nil
  selection_state := reset
  all field widgets cleared
  header := "No editable selection"
  sections hidden

  content_changed(sequence_id)
     │
     ▼
  if sequence_id matches any active_inspectable.sequence_id:
     for each active_inspectable:
        inspectable:refresh()  (invalidates its cache)
     if mode == "single":          load_single(active_inspectables[1])
     else if mode in multi:        load_multi(active_inspectables)
```

`load_single` / `load_multi` iterate fields and call `set_value` on non-dirty ones. Dirty fields are skipped (FR-016a).

### 3.6 Section collapse persistence

```
  on section create:
     expanded = persistent_widget.get(persisted_key, true)   -- default true
     section:setExpanded(expanded)

  on section toggle (user clicks header):
     persistent_widget.set(persisted_key, new_expanded)
     (persistent_widget autosaves opportunistically)
```

---

## 4. Invariants

1. **Single refresh channel.** Only `Signals.connect("content_changed", ...)` drives refresh. No second listener via `timeline_state.add_listener` or any other path (FR-016, enforces the fix for the dual-path bug in the current code).

2. **Pull-on-notify is idempotent.** Re-entering a pull produced by the Inspector's own commit is allowed and must not diverge state. `suppress_updates_depth` prevents commit handlers firing during programmatic `set_value`.

3. **Dirty fields are sacrosanct.** A content_changed notification must not overwrite dirty content. `load_single` / `load_multi` iterate fields and skip dirty ones.

4. **No fallback values on required data.** Frame rate, schema id, field type, field label, property type: missing = assert. Optional fields in the schema are explicitly marked optional.

5. **Command-system exclusivity.** Every field write goes through `inspectable:set` → command_manager. No direct DB writes. No private undo stack.

6. **Public API is three functions.** `mount`, `update_selection`, `get_focus_widgets`. Nothing else is exported.

7. **Deletion responsibility is upstream.** Inspector never checks "is this inspectable still alive" before pulling. If a pull returns no value for a field key on an inspectable the Inspector currently holds, assert with context identifying the missing inspectable and the operation — this indicates the deleting command failed to emit the selection change (FR-017b).

---

## 5. Validation rules

| Field type | Parse validation |
|---|---|
| STRING | no parse; any text accepted |
| TEXT_AREA | no parse; any text accepted |
| DROPDOWN | must be one of `options`; enforced by the combo box widget, no parse needed |
| INTEGER | `tonumber(text) and text matches integer regex`; else invalid |
| DOUBLE | `tonumber(text)`; else invalid |
| BOOLEAN | widget-level (checkbox); no parse |
| TIMECODE | `frame_utils.parse_timecode(text, rate)` must return non-nil integer frames ≥ 0; else invalid |

Invalid parse → field enters `invalid` state (bad text visible, red border, Apply disabled in multi-edit). Blur reverts (FR-015b).
