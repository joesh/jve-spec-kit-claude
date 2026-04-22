# Contract: Inspector Public API

**Module**: `src/lua/ui/inspector/init.lua`
**Consumers**: `src/lua/ui/layout.lua`, `src/lua/ui/selection_hub.lua` (via `register_listener` in `layout.lua`)

This module exposes **exactly three** public functions. Every other entry point on the legacy `view.lua` is deleted (FR-027, FR-031).

---

## 1. `inspector.mount(container_widget)`

**Purpose**: Mount the Inspector into the Qt container provided by layout.lua. Must be called once, before any selection is delivered.

**Parameters**:
- `container_widget` — Qt widget handle (userdata). Required. Asserts if `nil` or wrong type.

**Returns**: nothing (or an `error_system` success payload for layout.lua consumption).

**Preconditions**:
- Called at most once during the lifetime of the process.
- `qt_constants` is loaded and its methods are callable.

**Postconditions**:
- All per-schema scaffolding is built: search input, selection-label header, scroll area, content widget, Apply button (initially hidden), collapsible sections for both `clip` and `sequence` schemas (initially hidden until a selection activates one).
- Section collapse/expand state is restored from `persistent_widget` storage.
- Two signal handlers are installed: `content_changed` (priority 60, so it runs after timeline_state and media caches) and `project_changed` (priority 45, between timeline_state at 40 and project-browser at 50).

**Failure modes**:
- Any Qt binding call failure is a fatal assertion with context `("inspector.mount", <binding name>, <error>)` — no pcall-swallowing (FR-024).

---

## 2. `inspector.update_selection(items, source_panel_id)`

**Purpose**: Receive a selection update from the selection hub. Called by the listener registered in layout.lua.

**Parameters**:
- `items` — list of selection-item tables (see `data-model.md` §1.1 for shape). May be empty.
- `source_panel_id` — string panel identifier.

**Returns**: nothing.

**Behavior**:
1. If `source_panel_id == "inspector"`: return immediately (FR-003).
2. Compute `schema_counts`, `size`, `mode` from `items`.
3. Compute `active_schema_id` with majority + stability rule (see `data-model.md` §3.2 and FR-005a).
4. Resolve inspectables for items of the active schema via the inspectable factory.
5. Build the header label per the appropriate FR (FR-006 / FR-007 / FR-008 / FR-005b).
6. Append mark summary line iff `source_panel_id == "timeline"` or `active_schema_id == "sequence"` (FR-018).
7. Activate the schema's sections; hide other schema's sections.
8. Load field values:
   - `mode == "single"` or `mode == "multi_read_only"`: `load_single(active_inspectables[1])`. In `multi_read_only`, hide Apply.
   - `mode == "multi_edit"`: `load_multi(active_inspectables)`. Show Apply (disabled until ≥1 field dirty + all valid).
9. Discard any pending un-Applied edits from a prior multi-edit mode (FR-013a).
10. Apply the current search filter to sections (FR-019/020/021).

**Invariants**:
- Active schema remains stable when `schema_counts.keys == previous_schema_counts.keys` (FR-005a stability).
- Any Qt binding failure is fatal assert.

---

## 3. `inspector.get_focus_widgets()`

**Purpose**: Return the list of Qt widgets that should participate in focus navigation via focus_manager.

**Parameters**: none.

**Returns**: list of Qt widget handles. Order matters: first = primary focus target (scroll area), then search input, then container root.

**Behavior**: pure getter; must not allocate or mutate state.

---

## 4. Private — NOT part of the public API

The following functions exist on the legacy `view.lua` but are NOT in the rewritten public API and MUST NOT be added to `init.lua`:

- `init()` — redundant; `mount` is sufficient
- `create_schema_driven_inspector()` — internal to mount
- `ensure_search_row()` — stub
- `set_header_text()`, `set_batch_enabled()` — no live caller
- `get_filter()`, `set_filter()`, `apply_search_filter()` — internal; search input widget is the source of truth
- `save_field_value()`, `save_all_fields()`, `apply_multi_edit()` — internal command dispatch
- `load_clip_data()`, `load_multi_clip_data()` — internal
- `_G.inspector_save_test` — forbidden (FR-027)

Any attempt to re-add these is a FR-027 / FR-031 violation.

---

## 5. Contract tests

Each test fails before the rewrite lands and passes after.

- **mount-idempotent-failure**: calling `mount` twice asserts (or returns an error payload — TBD per the project's pattern for this class of misuse).
- **update-selection-ignores-self-source**: `update_selection({any items}, "inspector")` does not change any observable state.
- **update-selection-empty**: `update_selection({}, "timeline")` puts Inspector in empty mode with sections hidden.
- **update-selection-single-clip**: valid clip item produces single mode, header `"Clip: <name>"`, active schema `"clip"`, sections visible.
- **update-selection-multi-same-schema**: N clips all supporting multi-edit → multi_edit mode, Apply visible-but-disabled (no dirty fields yet), header `"Clips: N selected"`.
- **update-selection-heterogeneous-majority-clip**: 3 clips + 1 sequence → active schema `"clip"`, header includes "3 clips, 1 sequence — editing 3 clips".
- **update-selection-heterogeneous-tie-breaks-on-new-click**: 1 clip + 1 sequence with previous selection = 1 clip → clip wins (stability); 1 clip + 1 sequence with previous = 0 items → the item present first in `items` that was not in previous wins.
- **get-focus-widgets-shape**: returns a non-empty list ending with the container root.
- **forbidden-public-exports**: introspection of the returned module table contains no keys other than `mount`, `update_selection`, `get_focus_widgets`.

Test home: `tests/contract/inspector/test_inspector_api_contract.lua`.
