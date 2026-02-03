# Test Coverage Results (2026-02-02)

## Session Summary

| Task | Module | Test File | Assertions |
|------|--------|-----------|------------|
| T1 | clip_mutator.lua | test_clip_mutator.lua | 104 |
| T2 | property.lua | test_property_model.lua | 50 |
| T3 | clip_link.lua | test_clip_link_model.lua | 50 |
| T4 | command_manager.lua errors | test_command_manager_error_paths.lua | 34 |
| T5 | database.lua error paths | test_database_error_paths.lua | 97 |
| T6 | command.lua error paths | test_command_error_paths.lua | 85 |
| T7 | clip_edit_helper.lua | test_clip_edit_helper.lua | 84 |
| T8 | error_system.lua + error_builder.lua | test_error_system.lua | 207 |
| T9 | snapshot_manager.lua | test_snapshot_manager.lua | 94 |
| T10 | command_schema.lua | test_command_schema.lua | 50 |
| T11 | rational.lua edge cases | test_rational_edge_cases.lua | 83 |
| T12 | clip.lua model error paths | test_clip_model_error_paths.lua | 85 |
| T13 | signals.lua | test_signals.lua | 71 |
| T14 | command_history.lua | test_command_history.lua | 75 |
| T15 | command_state.lua | test_command_state.lua | 54 |
| T16 | color_utils.lua | test_color_utils.lua | 28 |
| T17 | selection_hub.lua | test_selection_hub.lua | 35 |
| T18 | metadata_schemas.lua | test_metadata_schemas.lua | 85 |
| T19 | clip_insertion.lua | test_clip_insertion.lua | 25 |
| T20 | project_open.lua | test_project_open.lua | 12 |
| T21 | pipe.lua | test_pipe.lua | 51 |
| T22 | fs_utils.lua + path_utils.lua | test_fs_path_utils.lua | 22 |
| T23 | widget_parenting.lua | test_widget_parenting.lua | 12 |
| T24 | collapsible_section.lua | test_collapsible_section.lua | 43 |
| T25 | inspector adapter + widget_pool | test_inspector_modules.lua | 53 |
| T26 | track_state.lua | test_track_state.lua | 36 |

Full suite: **324 passed, 0 failed**

---

## T2: `property.lua` model (233 LOC → 50 assertions)

**File**: `tests/test_property_model.lua`

### Coverage

- **save_for_clip**: insert 3 props, empty list no-op, nil list no-op, upsert existing, auto-generate id
- **load_for_clip**: load all, verify fields (id, name, value, type), empty clip, nonexistent clip
- **copy_for_clip**: fresh UUIDs, name preservation, nil default encoding, empty source, round-trip save to new clip
- **delete_for_clip**: full delete, idempotent on empty, cross-clip isolation
- **delete_by_ids**: selective delete, empty/nil no-op, nonexistent id silent, empty-string skip
- **Error paths**: nil/empty clip_id asserts for load, copy, save, delete
- **JSON encoding**: nil value, boolean value, string passthrough (no double-encoding)

### Notes

- `properties` table not in schema.sql — created manually in test (matches production pattern)
- `encode_property_json` passes strings through verbatim; wraps non-strings in `{value: X}`
- `ipairs` stops at nil holes — `{nil, "", "x"}` iterates 0 elements

---

## T3: `clip_link.lua` model (332 LOC → 50 assertions)

**File**: `tests/test_clip_link_model.lua`

### Coverage

- **create_link_group**: 2-clip pair, <2 clips error, nil input, empty input
- **get_link_group**: all members returned, ORDER BY role verified (audio < video), unlinked clip → nil, nonexistent → nil
- **get_link_group_id**: linked clip returns id, unlinked → nil
- **is_linked**: true for linked, false for unlinked/nonexistent
- **disable_link / enable_link**: toggle enabled flag, verify per-clip isolation, unlinked no-op
- **unlink_clip**: 2-member group auto-dissolves, already-unlinked no-op, 3-member group keeps 2 after unlink
- **link_two_clips**: create new group, add to existing group, accepts `clip_id` field, nil/missing id asserts, cross-group assert
- **calculate_anchor_time**: confirmed bug — queries `c.start_value` (nonexistent column, should be `c.timeline_start_frame`) → returns nil

### Bugs Found

- `calculate_anchor_time` (line 311): references `c.start_value` which doesn't exist in clips table. Query silently fails, function returns nil. Should use `c.timeline_start_frame`.

---

## T4: `command_manager.lua` error paths (1934 LOC → 34 assertions)

**File**: `tests/test_command_manager_error_paths.lua`

### Coverage

**normalize_command failures (asserts disabled)**:
- Unknown command type — string path → `{success=false, is_bug=true}`
- Unknown command type — Command object path
- Unsupported argument type (number)
- No active command event during execute

**Executor failure modes**:
- Executor returns nil → treated as failure
- Executor throws error → xpcall catches, error message propagated via `last_error_message`
- Non-recording command (undoable=false) executor crash → caught by inner pcall

**Undo failure modes**:
- Missing undoer + auto-load fails → `{success=false, error_message="No undoer..."}`
- Undoer throws error → pcall catches, error message in result
- Undoer returns false → propagated as failure

**Other paths**:
- `replay_events` returns boolean (graceful with stubbed timeline_state)
- Nested command failure propagation (parent executor calls child that crashes)
- Listener error isolation (crashing listener doesn't prevent execution or other listeners)
- Command event nesting depth (begin/end tracking, end-without-begin assert)
- Malformed executor result (table with non-boolean `.success`) → assert

### Design Issues Found

- **`execution_depth` leak**: When `bug_result` asserts inside `execute()`, the Lua error throws past the `::cleanup::` label. `execution_depth` is incremented at entry but never decremented. `shutdown()` doesn't reset it (module-local). All subsequent `execute()` calls enter the nested path.
  - **Workaround**: Tests disable asserts via `asserts_module._set_enabled_for_tests(false)` for bug_result paths, and place the `normalize_executor_result` assert test last.
  - **Affected paths**: Any pcall-wrapped `execute()` with invalid commands leaks depth.
- **Nested error messages empty**: When a nested command fails, `result.error_message` stays as `""` because the nested path (lines 745-793) doesn't read `last_error_message` like the top-level path does (line 1099).

---

## T5: `database.lua` error paths (2273 LOC → 97 assertions)

**File**: `tests/test_database_error_paths.lua`

### Coverage

**load_clips / build_clip_from_query_row**:
- nil sequence_id → FATAL assert
- Normal clip → correct Rational fields (timeline_start, duration, source_in, source_out, rate)
- Clip with empty name → default "Clip <id>" generated
- Clip with no media (NULL media_id) → nil media fields, label falls back to clip id
- Empty sequence → empty array
- Nonexistent sequence → empty array (no error)

**load_sequences**:
- nil/empty project_id → FATAL error
- Valid project with clips → correct duration via max(clip_end) Rational comparison
- Empty sequence → duration = Rational(0)
- Nonexistent project → empty array

**load_sequence_track_heights**:
- nil/empty sequence_id → {} (graceful)
- Nonexistent sequence → {} (no record)
- Valid JSON object → correctly decoded payload
- Malformed JSON (`{bad json###`) → FATAL (dkjson returns nil, caught by type check)
- JSON array (`[1,2,3]`) → passes as Lua table (arrays are tables)
- JSON string (`"hello"`) → FATAL (string is not table)
- Empty string in DB → {} (no decode attempted)

**save_bins**:
- nil/empty project_id → `(false, reason)`
- Empty bins list → success
- Single root bin → success, verified via load_bins
- Parent-child-grandchild hierarchy → success, parent_ids verified
- Re-save with subset → stale bins removed
- Bin with empty/whitespace name → silently dropped by build_bin_lookup
- Tag assignment preservation across re-save

**assign_master_clips_to_bin**:
- nil/empty project_id → `(false, reason)`
- Empty/non-table clip_ids → `(true)` no-op
- Nonexistent bin_id → `(false, reason)` with "invalid bin" message
- Empty-string bin_id → `(false, reason)`
- Valid assignment → success, verified via load_master_clip_bin_map
- Reassignment to different bin → moves
- Unassign via nil bin_id → deletes assignment
- Multi-clip assignment

**load_clip_marks / save_clip_marks**:
- nil/empty clip_id → assert
- nil playhead → assert
- Nonexistent clip → nil
- Default values (nil marks, 0 playhead)
- Round-trip save/load with marks set
- Mark clearing via nil (nullable columns)

### Design Observations

- **build_clip_from_query_row FATAL paths mostly unreachable**: The 5 FATAL checks (missing project_id, owner_sequence_id, media metadata, sequence fps, clip fps) are defensive guards against schema corruption. Schema NOT NULL and CHECK constraints prevent these states through normal SQL operations. Testing requires disabling constraints (not feasible with CHECK) or mock query objects (function is local).
- **load_sequence_track_heights JSON validation gap**: The `pcall(json.decode, raw)` branch for "invalid JSON" never fires because dkjson doesn't throw — it returns `(nil, error_string)`. Malformed JSON falls through to the `type(decoded) ~= "table"` check instead. Both invalid JSON and non-object JSON produce the same "expected JSON object" error.
- **JSON array/object conflation**: Lua tables don't distinguish arrays from objects. `[1,2,3]` passes the `type(decoded) ~= "table"` guard. If track_heights_json contained a JSON array, it would be returned as payload without error.
- **save_bins cycle handling**: `resolve_bin_path` detects cycles via a stack set and silently breaks them by clearing parent_id. This means the "invalid hierarchy" error return in save_bins is unreachable for cycle cases — cycles are auto-repaired, not rejected.

---

## T6: `command.lua` error paths (639 LOC → 85 assertions)

**File**: `tests/test_command_error_paths.lua`

### Coverage

**deserialize()**:
- nil → `(nil, "JSON string is empty")`
- empty string → `(nil, "JSON string is empty")`
- Invalid JSON → `(nil, "Decoded JSON is not a table")` (dkjson returns nil, not throw)
- JSON string/null/number → `(nil, "Decoded JSON is not a table")`
- Valid JSON → full command with type, project_id, sequence_number, parameters, playhead fields

**serialize()**:
- Numeric playhead_rate → preserved in JSON
- Table playhead_rate `{fps_numerator, fps_denominator}` → divided to numeric
- Zero denominator → error "playhead_rate missing fps_denominator"
- Nil denominator → error "playhead_rate missing fps_denominator"
- Table playhead_value `{frames=N}` → extracts `.frames`
- Ephemeral (`__` prefix) parameters excluded from output

**parse_from_query()**:
- nil query → nil
- Layout 2 (<17 cols) with valid JSON → correct command fields
- Layout 2 with invalid JSON → graceful empty params (no error)
- Layout 2 with empty JSON string → empty params
- Layout 1 (17+ cols) → correct fields including parent_id, selection state
- project_id fallback: nil arg → uses `args_table.project_id`
- Metatable set on result (methods available)

**create_undo()**:
- Type = "Undo" + original type
- Non-ephemeral params copied
- Ephemeral (`__` prefix) params excluded
- Fresh UUID generated

**save()** (with real SQLite database):
- Missing playhead_value → FATAL assert
- playhead_rate = 0 → FATAL assert (≤0 check)
- Missing executed_at → FATAL assert
- Valid INSERT path → success, verified in DB
- Valid UPDATE path (same id) → success, fields updated
- Table playhead_rate → converted to numeric in DB
- Ephemeral params excluded from persisted command_args JSON
- Rational playhead_value `{frames=42}` → stores integer 42

**Parameter management**:
- set_parameter / get_parameter round-trip
- get nonexistent → nil
- set_parameters bulk
- set_parameters(nil) → no-op
- clear_parameter
- get_all_parameters
- get_persistable_parameters filters `__` prefix keys

**label()**:
- Custom `display_label` parameter takes priority
- Fallback to `command_labels.label_for_type()`

### Design Observations

- **deserialize JSON error conflation**: Same issue as T5's track heights — `pcall(json.decode, malformed)` succeeds with `decoded=nil` because dkjson doesn't throw. The "Failed to decode JSON" branch is unreachable. All malformed JSON falls through to "Decoded JSON is not a table".
- **save() playhead_rate inconsistency**: In `serialize()` (line 408), zero/nil denominator is explicitly checked and errors. In `save()` (line 516), nil denominator silently falls back to `or 1`. Different behavior for the same edge case in two code paths.
- **save() playhead assertion conflates two checks**: Line 526 checks `db_playhead_value == nil or playhead_rate_val <= 0` in a single condition with a single error message. Missing playhead_value and zero playhead_rate produce identical error strings.

---

## T7: `clip_edit_helper.lua` (327 LOC → 84 assertions)

**File**: `tests/test_clip_edit_helper.lua`

### Coverage

**resolve_media_id_from_ui**:
- Non-empty media_id → pass through
- nil/empty → attempts UI resolution via `ui.ui_state`
- Mocked UI state → resolves from project browser, sets command parameter
- No UI module → returns nil

**resolve_sequence_id**:
- From args.sequence_id → pass through, sets command + snapshot params
- From track_id → resolves via `command_helper.resolve_sequence_for_track()`
- From timeline_state fallback
- All nil → returns nil
- `__snapshot_sequence_ids` not overwritten if already set

**resolve_track_id**:
- Non-empty track_id → pass through
- nil → resolves first VIDEO track from DB via `Track.find_by_sequence()`
- Empty sequence (no VIDEO tracks) → `(nil, error_message)`
- Empty string → treated as nil, resolves

**resolve_edit_time**:
- edit_time=0 → valid, NOT treated as nil (start of timeline)
- Numeric/Rational values → pass through
- nil → falls back to timeline_state playhead, sets command parameter
- nil + no timeline_state → nil

**resolve_clip_name**:
- Full priority chain: args.clip_name > master_clip.name > media.name > fallback
- Each level tested in isolation and in combination

**resolve_timing**:
- Explicit duration + source_in → computes source_out
- Explicit source_in + source_out → computes duration
- No timing data at all → `(nil, "invalid duration_frames")`
- Master clip fallback (duration + source_in)
- Media fallback (duration only)
- Default source_in = Rational(0) when absent
- Zero duration → error

**create_selected_clip**:
- Video-only (0 audio channels): has_video=true, has_audio=false, payload fields correct
- With audio channels: has_audio=true, audio_channel_count correct
- audio(ch): correct role="audio", channel index, clip_name with " (Audio)" suffix
- Out-of-bounds audio channel index → assert
- nil audio_channels → defaults to 0

**get_media_fps**:
- From master_clip.rate → extracts fps_numerator/denominator
- From media_id → DB lookup via `rational_helpers.require_media_rate()`
- No master_clip, no media_id → sequence fps fallback
- Empty media_id → sequence fps fallback
- Master clip without .rate field → assert

**create_audio_track_resolver**:
- Existing audio track (index 0) → returns from initial list
- Beyond existing → creates new AUDIO track with auto-name "A2"
- Negative index → assert
- timeline_state mock → uses provided tracks instead of DB

---

## T8: `error_system.lua` + `error_builder.lua` (847 LOC → 207 assertions)

**File**: `tests/test_error_system.lua`

### error_system.lua Coverage

**create_error()**:
- Non-table param → error with "params must be a table"
- nil/empty/numeric message → error with "params.message must be a non-empty string"
- Minimal params → correct defaults (code="UNKNOWN_ERROR", category="system", severity="error", operation/component="unknown_*")
- All optional fields → preserved (code, category, severity, operation, component, context_stack, technical_details, parameters, user_message, remediation)
- success=false always set, timestamp and lua_stack captured
- user_message defaults to message when not provided

**create_success()**:
- Default message "Operation completed successfully", empty return_values
- Custom message and return_values preserved
- success=true, timestamp present

**is_error() / is_success()**:
- Correct on error/success objects
- nil → falsy (Lua `and` short-circuit returns nil, not false)
- string/number/empty table → falsy

**add_context()**:
- Pushes context to front of context_stack (prepend via insert at 1)
- Updates top-level operation/component
- Merges technical_details (key-value pairs)
- Appends remediation suggestions
- Overrides user_message when provided
- Second context: stack has 2 entries, newest at index 1
- Success result → passthrough (no mutation)
- nil → passthrough

**safe_call()**:
- Success path: returns function's success result unchanged
- Error return: propagates error with context added, code preserved
- Lua throw: catches via pcall, wraps in LUA_RUNTIME_ERROR with original message
- nil return: passthrough (no validation)
- Non-table return: FATAL error "returned string but safe_call requires ErrorContext"
- Table without .success: FATAL error "returned table without .success field"

**format_user_error()**:
- nil error_obj → error "error_obj cannot be nil"
- Success result → "No error to format"
- Basic error → contains user_message, error code, category
- With context/details/remediation → sections present ("What was happening", technical details, "How to fix this")

**format_debug_error()**:
- nil/success → "No error to format"
- Full error → contains DEBUG ERROR REPORT header/footer, code, severity, message, Context Stack, Parameters, Technical Details, Lua Stack Trace

**assert_type()**:
- Correct type (string/number/table) → no error, returns nothing
- Wrong type → throws with "Invalid <param_name> type" message

**qt_widget_error()**:
- create/style/connect/layout → correct code mapping, category=qt_widget, targeted remediation per operation
- Unknown operation → code fallback "QT_WIDGET_ERROR", generic remediation

**inspector_error()**:
- Code = "INSPECTOR_<UPPER(operation)>_FAILED"
- Category = inspector, standard 4-item remediation

**log_detailed_error()**:
- Error object → delegates to format_debug_error
- Non-error values (string/number/nil) → tostring()

**Exports**:
- CATEGORIES: QT_WIDGET="qt_widget", COMMAND="command", etc.
- SEVERITY: CRITICAL="critical", INFO="info", etc.
- CODES: LUA_RUNTIME_ERROR, WIDGET_CREATION_FAILED, etc.

### error_builder.lua Coverage

**ErrorBuilder.new()**:
- Sets severity/code/message, defaults category="general", operation/component="unknown"
- user_message defaults to message

**Method chaining**:
- All 13 builder methods return self: addContext, addContextTable, addSuggestion, addSuggestions, addAutoFix, withAttemptedAction, withOperation, withComponent, withCategory, withUserMessage, withTechnicalDetails, escalate, withTiming

**addContext / addContextTable**:
- addContext converts values to string
- addContextTable merges key-value pairs (stringified)
- Non-table arg to addContextTable → no-op

**addSuggestion / addSuggestions**:
- Single and bulk append
- Non-table arg to addSuggestions → no-op

**addAutoFix**:
- Stores description, code_hint, confidence
- Default confidence = 50 when omitted

**withAttemptedAction**:
- Appends to attempted_actions array

**escalate()**:
- Upgrades severity: info → warning → error → critical
- Lower or same severity → no change (only escalates up)

**withTiming()**:
- Computes duration from start_value, stores as context
- nil start_value → no-op

**withTechnicalDetails()**:
- Merges table into technical_details (preserves non-string values)
- Non-table arg → no-op

**build()**:
- Produces error_system-compatible object (success=false, timestamp, lua_stack)
- Maps internal suggestions → remediation
- Maps internal context → technical_details
- All builder-set fields (severity, code, message, operation, component, category, user_message) preserved

**Automatic suggestions (_addAutomaticSuggestions)**:
- "widget creation" message → Qt bindings suggestion + autofix
- "layout" message → parent widget suggestion + autofix
- "signal" message → signal name suggestion + autofix
- "attempt to call nil" → modules loaded suggestion + autofix
- Unrelated message → zero auto-suggestions

**Convenience constructors**:
- createWidgetError: category=qt_widget, component=widget_system, code=WIDGET_ERROR
- createLayoutError: category=qt_layout, component=layout_system
- createSignalError: category=signals, component=signal_system
- createValidationError: category=validation, component=input_validation
- All produce builders that build() into valid error objects

### Design Observations

- **is_error/is_success nil semantics**: Both use `result and type(result) == "table" and ...` which returns `nil` (not `false`) for nil input due to Lua's `and` short-circuit. Callers must use truthiness checks, not `== false`.
- **build() overwrites technical_details**: `self.error_data.technical_details = self.error_data.context` on line 196 replaces any details added via `withTechnicalDetails()` with the context table. If both `addContext` and `withTechnicalDetails` are used, the technical details are lost at build time.
- **safe_call JSON branch untestable without C++**: The `rich_error` JSON parsing branch (lines 408-436) handles C++ ErrorContext objects serialized as JSON. Requires actual Qt/C++ runtime to trigger.
- **format_user_error type-check ordering**: The nil check (line 281) runs before the type check (line 290). If a non-nil non-table is passed (e.g., a string), the `.success` access on line 285 would error before reaching the type guard. In practice, only tables and nil are passed.

---

## T9: `snapshot_manager.lua` (522 LOC → 94 assertions)

**File**: `tests/test_snapshot_manager.lua`

### Coverage

**should_snapshot()**:
- Boundary: 50 → true, 100 → true
- Non-boundary: 0 (must be >0), 1, 49, 51 → false
- Negative → false
- SNAPSHOT_INTERVAL = 50 exposed

**create_snapshot + load_snapshot round-trip**:
- Full clip with Rational fields (timeline_start, duration, source_in, source_out)
- Sequence record preserved (id, project_id, name, fps_numerator, playhead_frame)
- Tracks preserved (id, track_type, name)
- Clips with Rational reconstruction (frames extracted on create, Rational.new on load)
- Rate preserved (fps_numerator, fps_denominator)
- Boolean enabled/offline (stored as 1/0, restored as true/false)
- Media preserved (id, name, file_path, Rational duration, frame_rate, width, audio_channels)

**Overwrite semantics**:
- Second create_snapshot for same sequence replaces first
- load_snapshot returns latest (sequence_number updated, new clip set)

**Empty clips**:
- create_snapshot with {} → success
- Loaded snapshot has 0 clips but sequence + tracks preserved

**Nonexistent sequence**:
- load_snapshot → nil

**Missing parameters (asserts disabled)**:
- nil db/sequence_id/sequence_number/clips → false (create) or nil (load)

**Missing parameters (asserts enabled)**:
- nil db/sequence_id → assert "missing required parameters"

**Clip validation**:
- Missing id → assert "missing required field 'id'"
- Missing clip_kind → assert "missing required field 'clip_kind'"

**Rational reconstruction accuracy**:
- 30fps clip: frame values (120, 300, 10, 310) preserved across JSON serialize/deserialize
- Rate fields preserved (30/1)
- enabled=false, offline=true correctly round-tripped

**Media deduplication**:
- 2 clips referencing same media → snapshot contains 1 media entry

**Clip with no media**:
- nil media_id → 0 media in snapshot, clip still loaded

**load_project_snapshots()**:
- Multi-sequence: both seq1 and seq2 returned, keyed by sequence_id
- target_sequence_number filtering: 60 → only seq1 (at 50), not seq2 (at 75)
- exclude_sequence_id: excludes seq1, keeps seq2
- nil db/project_id → {}
- Nonexistent project → {}

### Design Observations

- **One snapshot per sequence**: `create_snapshot` DELETEs existing snapshot before INSERT. No history of snapshots — only latest retained.
- **Fail-soft vs fail-fast split**: With asserts enabled, missing params crash. With asserts disabled, they return false/nil silently. Production behavior depends on asserts configuration.
- **Rational storage as integers**: Clip Rational fields are decomposed to `.frames` integers for JSON storage, then reconstructed via `Rational.new(frames, num, den)` on load. This means the Rational's internal ticks/rate are recalculated, not preserved verbatim.
- **Media loaded globally**: `build_snapshot_payload` calls `database.load_media()` (all media in DB), then filters by clip references. For large media libraries this loads more than necessary.
- **delete_query not finalized**: Line 394 — the DELETE prepared statement is executed but never finalized. SQLite handles this via garbage collection but it's inconsistent with other query patterns in the module.

---

## T10: `command_schema.lua` (400 LOC → 50 assertions)

**File**: `tests/test_command_schema.lua`

### Coverage

**validate_and_normalize() — top-level validation**:
- nil spec → `(false, nil, "No schema registered")`
- Non-table params (string, nil) → `(false, nil, "params must be a table")`
- Unknown param → `(false, nil, "unknown param 'bogus'")`
- Ephemeral `__keys` always allowed (not rejected as unknown)
- Global `sequence_id` always allowed

**Alias normalization**:
- Single alias → normalizes to canonical, removes original key
- Multiple aliases → second alias also normalizes
- Canonical + alias both present → `(false, nil, "both ... and alias")`

**Spec normalization**:
- Bare spec (no `.args` wrapper) → auto-wrapped into `{ args = spec }`

**apply_defaults**:
- Missing keys filled from rule.default
- Caller-provided values NOT overwritten
- Multiple defaults applied simultaneously

**empty_as_nil**:
- Empty string → nil when rule.empty_as_nil=true

**requires_any cross-field constraints**:
- At least one present → passes
- None present → `(false, nil, "requires at least one of")`
- Empty string not considered present (is_present returns false)

**Persisted fields**:
- Keys in spec.persisted accepted (not rejected as unknown)
- Args + persisted combined in same params table

**Nested table: accept_legacy_keys**:
- Legacy key copied to canonical when canonical absent
- Canonical NOT overwritten when already present

**Nested table: fields**:
- Defaults applied to nested fields when apply_defaults=true
- empty_as_nil works on nested fields

**required_outside_ui_context**:
- UI context → not required (passes)
- Non-UI context → required (but see bug below)

**asserts_enabled**:
- `opts.asserts_enabled = true` → nil spec and unknown param trigger Lua assert

### Bug Found: apply_rules Return Value Discarded

**Location**: `command_schema.lua:374-375`

```lua
apply_rules(args, true)
apply_rules(persisted, opts.require_persisted == true)
```

The return values `(false, error_msg)` from `apply_rules()` are **never checked**. This means all validation performed inside `apply_rules` is silently ignored:

- **required=true** → missing param passes
- **kind mismatch** → wrong type passes
- **one_of violation** → invalid enum passes
- **nested fields.required** → missing nested field passes
- **requires_fields** → missing field passes
- **requires_methods** → missing method passes
- **required_outside_ui_context** → missing non-UI param passes

Only these validations work correctly (handled before/after apply_rules):
- nil spec, non-table params, unknown keys, alias conflicts, requires_any

The fix would be:
```lua
local ok, err = apply_rules(args, true)
if not ok then return fail(err) end
local ok2, err2 = apply_rules(persisted, opts.require_persisted == true)
if not ok2 then return fail(err2) end
```

This bug means command parameter validation is effectively no-op for type/required/enum checks, relying entirely on executors to validate their own inputs.

---

## T11: `rational.lua` edge cases (395 LOC → 83 assertions)

**File**: `tests/test_rational_edge_cases.lua`

### Coverage (supplements existing test_rational.lua)

**Division by number**:
- Exact: 100/2 = 50 frames, rate preserved
- Rounding (half-up): 7/2 → 4, 5/3 → 2
- Division by zero → error "division by zero"

**Division by Rational (duration ratio)**:
- Same rate: 100/50 = 2.0 scalar
- Cross-rate: 48@24fps / 60@30fps = 1.0 (both 2s)
- Zero dividend (0@24 / 50@24) → 0
- Zero-duration divisor → error "division by zero duration"
- Non-Rational lhs → error
- Non-number/Rational rhs → error

**Hydrate edge cases**:
- nil → nil; false → nil
- Already Rational → same object reference (identity)
- Table with full fps → correct Rational
- Table with partial fps (only numerator) → denominator defaults to 1
- Table with no fps → defaults to 30/1; caller-provided defaults used when passed
- Empty table (no .frames) → nil
- Number → treated as frames; number with no fps → default 30
- String → nil; true → nil
- Zero frames → valid; negative frames → valid

**Negative frame arithmetic**:
- neg + pos, pos - neg, neg + neg, subtraction going negative

**Unary negation**:
- Positive → negative, double negation restores, negate zero = zero

**Multiply**:
- Rational * number, number * Rational (commutative)
- Fractional with rounding (7 * 1.5 → 11 via half-up)
- Multiply by zero → 0 frames
- Two Rationals → error (only scalar multiplication supported)

**Cross-rate comparison**:
- Equal durations at different rates (24@24 == 30@30, both 1s)
- Unequal durations correctly detected
- Less-than across rates
- NTSC (30000@30000/1001) vs film (24024@24) equality (both 1001s)

**Dead code found**: `__eq` and `__lt` number coercion paths (rational.lua lines 251-254, 278-281) are **unreachable in LuaJIT**. Lua 5.1 only invokes comparison metamethods when both operands share the same metatable. Mixed number/table comparisons bypass the metamethod entirely.

**max()**:
- Same rate: returns larger
- Cross-rate: rescales r2 to r1's rate, compares frames, returns rescaled
- Equal → returns r1
- Non-Rational → error

**from_seconds()**:
- Exact (1s@24 → 24 frames, 0.5s@30 → 15, 0s → 0)
- Rounding (1/30s@24 → 0.8 frames → rounds to 1)
- NTSC (1s@30000/1001 → 30 frames)
- Non-number → error

**to_seconds() / to_milliseconds()**:
- 1s identity, zero, NTSC precision, negative frames

**tostring**:
- Denominator=1 format, NTSC format, negative frames, zero

**rescale_floor / rescale_ceil**:
- 1@30fps→24fps: floor→0, ceil→1, round→1
- Exact rescale: floor=ceil=round
- Identity rescale returns new object (verified via rawequal)

**metatable**:
- Rational.metatable exposed and matches getmetatable(instance)

---

## T12: `clip.lua` model error paths (560 LOC → 85 assertions)

**File**: `tests/test_clip_model_error_paths.lua`

### Coverage

**create() — missing required fields**:
- Missing fps_numerator → assert
- Missing fps_denominator → assert
- Missing timeline_start → error "timeline_start is required"
- Missing duration → error "duration is required"

**create() — non-Rational fields**:
- timeline_start as number → error "must be a Rational object"
- duration as string → error "must be a Rational object"

**create() — legacy field name rejection**:
- start_value → error "Legacy field names...NOT allowed"
- duration_value → error
- source_in_value → error

**create() — valid with defaults**:
- Returns clip with auto-generated id, clip_kind="timeline", enabled=true, offline=false
- source_in defaults to Rational(0, fps)
- source_out defaults to duration
- rate table populated

**create() — empty/nil name**:
- Empty string → auto-generated "Clip <first 8 chars of id>"
- nil → same auto-generation

**create() — all optional fields**:
- Custom id, project_id, clip_kind, track_id, owner_sequence_id, parent_clip_id, source_sequence_id, source_in, source_out, enabled=false, offline=true

**save() + load() round-trip**:
- INSERT path: save returns true, load returns clip with correct fields
- Rational fields preserved (timeline_start, duration, source_in, source_out)
- Rate, enabled, offline correctly persisted and loaded
- Loaded clip has metatable (methods available)

**save() — UPDATE path**:
- Modify loaded clip fields, save, reload → values updated

**save() — non-Rational fields**:
- timeline_start set to number → error "timeline_start is not Rational"
- duration set to string → error "duration is not Rational"

**save() — invalid clip ID**:
- Empty string → returns false (no crash)
- nil → returns false

**load() — error paths**:
- nil clip_id → error "Invalid clip_id"
- Empty clip_id → error "Invalid clip_id"
- Nonexistent clip → error "Clip not found"

**load_optional() — graceful nil**:
- nil/empty/nonexistent → returns nil (no error)
- Existing clip → returns full clip object

**load() — master clip**:
- Master clip without track (NULL track_id) loads successfully
- Uses clip's own fps for timeline fields (no sequence fps required)

**delete()**:
- Save then delete → returns true
- Subsequent load_optional → nil (clip gone)

**get_sequence_id()**:
- Valid clip → returns correct sequence_id via track→sequence join
- nil/empty → error "clip_id is required"
- Nonexistent → error "not found or has no track"

**find_at_time()**:
- Time within clip → returns clip
- At exact start boundary → found (inclusive)
- At frame before end → found
- At exact end → nil (exclusive: start+duration boundary)
- Before clip / empty region → nil
- nil track_id → assert "track_id is required"
- nil time → assert "time_rat must be a Rational"

**restore_without_occlusion()**:
- Equivalent to save({skip_occlusion=true}), returns true, persists changes

**get_property() / set_property()**:
- get_property returns self[name]
- get_property nonexistent → nil
- set_property updates field, subsequent get_property returns new value

**generate_id()**:
- Returns non-empty string
- Two calls return different IDs

### Design Observations

- **NULL frame data / zero fps untestable**: Schema enforces `timeline_start_frame INTEGER NOT NULL`, `CHECK(fps_numerator > 0)`, `CHECK(fps_denominator > 0)`. The Lua assert guards (lines 113-120, 149-152) are defensive against schema corruption but cannot be triggered through normal SQL paths.
- **Timeline vs source fps split**: Timeline fields (timeline_start, duration) use the owning sequence's fps on load, while source fields (source_in, source_out) use the clip's own fps. This is a deliberate design for cross-rate editing.
- **Master clip special case**: Master clips (clip_kind="master") bypass sequence fps lookup and use their own fps for all fields, since they're not placed on a timeline.
- **find_at_time uses logger**: Line 522 references `logger` module which is not imported — would error if db connection is nil in a non-test context.

---

## T13: `signals.lua` (213 LOC → 71 assertions)

**File**: `tests/test_signals.lua`

### Coverage

**connect() — validation**:
- nil signal_name → error (INVALID_SIGNAL_NAME)
- number signal_name → error
- empty string → error (EMPTY_SIGNAL_NAME)
- string handler → error (INVALID_HANDLER)
- nil handler → error
- non-number priority → error (INVALID_PRIORITY)

**connect() — valid**:
- Returns incrementing connection IDs
- Default priority = 100
- Handler, signal_name, creation_trace stored in connection record

**Priority ordering**:
- Lower priority numbers execute first (10 < 100 < 300)
- Same priority preserves insertion order (FIFO)

**disconnect()**:
- Non-number ID → error (INVALID_CONNECTION_ID)
- Nonexistent ID → error (CONNECTION_NOT_FOUND)
- Valid disconnect → handler no longer called on emit
- Double disconnect → CONNECTION_NOT_FOUND
- Empty signal list cleaned from registry after last disconnect

**emit()**:
- Non-string signal → error (INVALID_SIGNAL_NAME)
- No handlers → empty table (not error)
- Arguments passed through to handlers via unpack
- Handler error isolation: crashing handler doesn't prevent others (pcall wraps each)
- Each result includes connection_id, success, result/error fields
- Return values captured in result.result

**list_signals()**:
- Empty registry → empty list
- Returns name + handler_count per signal

**clear_all()**:
- Returns success, empties all registries
- Emit after clear → empty results

**hooks facade**:
- hooks.add = Signals.connect, hooks.remove = Signals.disconnect
- hooks.run filters failed handlers, returns only successful results

**Signal isolation**:
- Emitting signal A does not trigger signal B handlers

### Design Observations

- **error_system return values, not throws**: All validation errors return error objects instead of throwing. Callers must check `error_system.is_error()` on the return value.
- **connection_id_counter never resets between clear_all calls**: `clear_all()` resets to 0, so IDs restart. In production, `clear_all` is only used for testing/cleanup.
- **Handler nil check at emit time**: Line 215 checks `handler_record.handler == nil` and throws with creation_trace. This guards against corruption between connect and emit (e.g., handler GC'd from weak table — but connections table uses strong refs, so this is purely defensive).

---

## T14: `command_history.lua` (280 LOC → 75 assertions)

**File**: `tests/test_command_history.lua`

### Coverage

**init()**:
- nil/empty sequence_id → error "sequence_id is required"
- nil/empty project_id → error "project_id is required"
- Valid init → reads MAX(sequence_number) from commands table, sets active_sequence_id

**reset()**:
- Clears current_sequence_number to nil, last_sequence_number to 0
- Resets active_stack_id to "global"

**Sequence number management**:
- increment → returns next value, updates last_sequence_number
- decrement → decreases last_sequence_number
- set_current_sequence_number → updates both local var and stack state
- Stack state's position_initialized set to true after set

**ensure_stack_state()**:
- Creates new state with nil current, empty branch_path, not initialized
- Returns same object reference on second call
- nil → defaults to global stack

**apply_stack_state()**:
- Restores current_sequence_number from stack state
- nil → defaults to global

**set_active_stack()**:
- Accepts opts.sequence_id, stores on stack state
- Triggers initialize_stack_position_from_db if not yet initialized

**get_current_stack_sequence_id()**:
- Returns stack's sequence_id when set
- nil stack sequence + fallback=false → nil
- nil stack sequence + fallback=true → active_sequence_id from init

**stack_id_for_sequence() (multi_stack disabled)**:
- Always returns "global" when JVE_ENABLE_MULTI_STACK_UNDO is not set
- nil/empty sequence_id → "global"

**resolve_stack_for_command() (multi_stack disabled)**:
- Always returns "global", nil

**Undo groups (Emacs-style)**:
- begin_undo_group with explicit ID → stored, current returns that ID
- cursor_on_entry captures current_sequence_number at outermost begin
- Nested group → get_current_undo_group_id returns outermost (undo_group_stack[1])
- get_undo_group_cursor_on_entry returns outermost entry's cursor
- end_undo_group pops and returns group_id
- end with no active group → warns + nil
- Auto-generated IDs: "explicit_group_<counter>", unique across calls

**save/load_undo_position()**:
- save writes current_sequence_number to sequences table
- nil current → saves 0
- load returns (value, has_row) tuple
- Nonexistent sequence → (nil, false)
- nil/empty sequence_id → (nil, false)

**initialize_stack_position_from_db()**:
- saved > 0 → set_current_sequence_number(saved)
- saved == 0 → set_current_sequence_number(nil)
- NULL + has_row + last > 0 → set_current_sequence_number(last)

**find_latest_child_command()**:
- Returns latest child by sequence_number for given parent
- Decodes command_args JSON
- Top-level commands found via parent=0 (NULL parent_sequence_number)
- Nonexistent parent → nil

### Design Observations

- **Module-local state**: `db`, `last_sequence_number`, `active_sequence_id`, `undo_group_stack` are all module-local. No way to inspect them directly; tests must use public getters.
- **Multi-stack gated by env var**: `JVE_ENABLE_MULTI_STACK_UNDO=1` enables per-sequence undo stacks. Without it, all 4 multi-stack code paths (stack_id_for_sequence, resolve_stack_for_command) short-circuit to "global".
- **Emacs undo group semantics**: Nested groups collapse into outermost. `get_current_undo_group_id()` returns `undo_group_stack[1].id` (first/outermost), not the last/innermost. This matches Emacs where nested `undo-boundary` calls are no-ops.
- **find_latest_child_command SQL trick**: `WHERE parent_sequence_number IS ? OR (parent_sequence_number IS NULL AND ? = 0)` — the IS handles NULL comparison (unlike =), and the OR clause lets parent=0 match top-level commands (NULL parent).

---

## T15: `command_state.lua` (294 LOC → 54 assertions)

**File**: `tests/test_command_state.lua`

### Coverage

**init()**:
- Sets module-local db, resets state_hash_cache and current_state_hash

**calculate_state_hash()**:
- No db → error "No database connection"
- Valid project → 8-char hex string (djb2 hash)
- Deterministic: same project → same hash
- Sensitive to data changes: clip insert, clip modify, media insert, track insert, sequence playhead modify all change hash
- Nonexistent project → deterministic empty hash (djb2 of empty string)
- Covers all 5 tables: projects, sequences, tracks, clips, media

**update_command_hashes()**:
- Sets command.pre_hash field

**capture_selection_snapshot()**:
- Clips: extracts clip IDs from timeline_state.get_selected_clips()
- Edges: extracts clip_id, edge_type, trim_type descriptors
- Gaps: extracts track_id, start_value, duration descriptors
- nil/missing get_selected_gaps → "[]"
- nil returns from getters → "[]" (graceful)
- Filters entries with missing required fields (ipairs stops at nil holes; entries with nil id/clip_id/edge_type/track_id skipped)
- temp_gap_* clip IDs resolved via DB query (gap_after finds clip by end position)

**restore_selection_from_serialized()**:
- Clip IDs loaded from DB via Clip.load_optional
- Edges take priority over clips (if edges present, clips not processed)
- bypass_persist when get_sequence_id returns nil/empty (uses selection_state directly)
- Empty JSON → clears selection and gaps
- nil/empty string JSON → clears selection
- Nonexistent clips skipped gracefully (logged warning, not error)

### Design Observations

- **djb2 hash**: Uses `hash = (hash * 33 + byte) % 0x100000000` — standard djb2. Not cryptographic, just for change detection. 32-bit range formatted as 8 hex chars.
- **parse_temp_gap_identifier format**: `"temp_gap_<track_id>_<start_frames>_<end_frames>"`. The track_id itself may contain underscores, so parsing extracts the trailing `_<num>_<num>` pattern and treats everything before as track_id.
- **resolve_gap_clip_id SQL**: For gap_after, finds clip whose `(timeline_start_frame + duration_frames) = start_frames`. For gap_before, finds clip whose `timeline_start_frame = end_frames`. This maps gap boundaries to adjacent real clips.
- **bypass_persist logic**: When `timeline_state.get_sequence_id()` returns nil, the module calls `selection_state` directly instead of going through `timeline_state` (which would try to persist to a non-existent sequence). This handles the startup/test case where no sequence is loaded.
- **VIDEO_OVERLAP trigger**: The clips table has a trigger preventing overlapping clips on video tracks. Test clip inserts must use non-overlapping positions.

---

## T16: `color_utils.lua` (18 LOC → 28 assertions)

**File**: `tests/test_color_utils.lua`

### Coverage

**dim_hex() — valid operations**:
- Factor 1.0 → identity (white, black, red unchanged)
- Factor 0.0 → black for any input
- Factor 0.5 → correct half-brightness (#ffffff→#808080, #ff8000→#804000)
- Rounding: half-up (255*0.3=76.5→77=0x4d)
- Black stays black at any factor

**Output format**:
- Always lowercase hex (#AABBCC at 1.0 → #aabbcc)
- Starts with #, length 7

**Validation errors**:
- nil/number color → "expected hex string color"
- Missing #, short (#fff), long (#ffffffff), invalid chars (#gggggg), empty → "expected '#RRGGBB'"
- nil/string factor → "expected numeric factor"
- Negative/over-1 factor → "factor must be in [0, 1]"

**Boundary factors**:
- Exact 0 and 1, tiny factor 0.01 (255*0.01=2.55→3=#030303)

### Design Observations

- **Pure function, no state**: Single exported function `dim_hex`. No module state, no dependencies beyond Lua stdlib.
- **Rounding behavior**: Uses `math.floor(x * factor + 0.5)` — standard round-half-up. This means 127.5→128 and 2.55→3.

---

## T17: `selection_hub.lua` (70 LOC → 35 assertions)

**File**: `tests/test_selection_hub.lua`

### Coverage

**Initial state**:
- Empty items, nil panel

**update_selection()**:
- Per-panel storage, cross-panel isolation
- nil panel → no-op
- nil items → stored as empty table

**clear_selection()**:
- Empties panel's selection
- nil panel → no-op

**set_active_panel()**:
- Switches active panel, triggers notification
- get_active_selection returns correct panel's items

**Listeners**:
- register_listener returns numeric token
- Immediate callback on registration with current active selection
- Notified when active panel's selection updated
- NOT notified when inactive panel updated/cleared
- Error isolation: crashing listener doesn't prevent others (pcall)
- unregister_listener stops notifications
- Non-function callback → error

**Multiple listeners**: Both called on notification

**set_active_panel(nil)**: nil panel → empty items from get_active_selection

### Design Observations

- **register_listener calls callback immediately** (line 90): `callback(items, active_panel_id)` is NOT wrapped in pcall. If the callback throws during registration, it propagates up. Only subsequent notifications (via `notify()`) are pcall-protected.
- **Listener ordering**: Listeners are stored in a table keyed by token (number). `pairs()` iteration order is not guaranteed, so listener execution order is non-deterministic.
- **_reset_for_tests()**: Exposed explicitly for test cleanup. Resets all module-local state.

---

## T18: `metadata_schemas.lua` (277 LOC → 85 assertions)

**File**: `tests/test_metadata_schemas.lua`

### Coverage

**FIELD_TYPES exports**: All 7 types verified (STRING, INTEGER, DOUBLE, BOOLEAN, TIMECODE, DROPDOWN, TEXT_AREA)

**clip_inspector_schemas**: 12 categories exist (Camera, Production, Transform Properties, Review, Audio, IPTC Core, Dublin Core, Dynamic Media, EXIF, Cropping Properties, Composite Properties, Premiere Project)

**Field structure**: key, label, type, default fields present on all fields

**Field type variations**:
- Dropdown: options array, default value (Review.status)
- Numeric with min/max: constraints from options parameter (Composite.opacity)
- Boolean: default false (Composite.drop_shadow)
- Integer: default 100 (Camera.iso)
- Timecode: default "00:00:00:00" (Dynamic Media.timecode_in)

**sequence_inspector_schemas**: 2 categories (Timeline Settings, Timeline Viewport)

**get_sections()**:
- "clip" → 12 sections, alphabetically sorted (verified pairwise)
- "sequence" → 2 sections
- Unknown/nil → empty table

**iter_fields_for_schema()**:
- Clip: >50 fields iterated, specific keys verified
- Sequence: ≥10 fields
- Unknown: 0 iterations (iterator immediately exhausted)

**Extensibility API**:
- add_custom_schema: adds new category to clip schemas
- add_custom_field: appends field to existing schema (returns true), nonexistent → false

**Default handling**: nil default in create_field → "" (empty string), explicit values preserved

### Design Observations

- **Static data module**: No runtime state beyond the schema tables themselves. All data is defined at require-time.
- **create_field is local**: Not exported. Users can't call it directly — must construct field tables manually or use add_custom_field.
- **get_sections sorts by name**: Uses `table.sort(names)` for deterministic alphabetical ordering. Schema insertion order doesn't matter.
- **iter_fields_for_schema**: Returns a stateful iterator (closure over index). Flattens all sections' fields into a single sequence. Useful for bulk operations like property migration.

---

## T19: `clip_insertion.lua` (46 LOC → 25 assertions)

**File**: `tests/test_clip_insertion.lua`

### Coverage

**Video-only clip**:
- 1 insert call on sequence, correct video track (index 0), correct insert_pos
- No link_two_clips calls (single clip needs no linking)

**Audio-only clip (2 channels)**:
- 2 insert calls, correct audio tracks (index 0, 1), correct channel data
- 1 link call (2 clips → star link from first)

**Video + stereo audio (3 clips)**:
- 3 inserts: video first, then audio ch0, ch1
- 2 link calls: (clip1, clip2) and (clip1, clip3) — star topology anchored on first clip

**Video + mono audio (2 clips)**:
- 2 inserts, 1 link call

**Missing state fields**:
- nil selected_clip → assert (line 19)
- nil sequence → assert (line 20)
- nil insert_pos → assert (line 21)

### Testing Approach

Mock-based: `clip_link.link_two_clips` is stubbed before `require` to record calls. Mock sequence records `insert_clip` calls with track/position/data. Mock selected_clip provides configurable `has_video`/`has_audio`/`audio_channel_count` methods.

### Design Observations

- **Star linking topology**: All clips are linked to `new_clips[1]` (the video clip when present, or first audio clip). This means the first clip is the "anchor" in the link group, consistent with `clip_link.link_two_clips` which adds clip_b to clip_a's group.
- **No error handling on insert_clip**: The function `assert()`s on each `seq:insert_clip()` return. If insertion fails (returns nil/false), the entire operation aborts mid-way — some clips may be inserted without their linked counterparts.
- **Channel iteration is 0-indexed**: `for ch = 0, clip:audio_channel_count()-1` matches the 0-based channel convention used in `clip_edit_helper.create_selected_clip`.

---

## T20: `project_open.lua` (67 LOC → 12 assertions)

**File**: `tests/test_project_open.lua`

### Coverage

**Validation**:
- nil db_module → assert "db_module.set_path is required"
- db_module without set_path → assert
- nil project_path → assert "project_path is required"
- Empty project_path → assert

**Successful open**:
- db_module.set_path called with correct path, returns true → function returns true

**Failed open**:
- set_path returns false → function returns false
- set_path returns nil → function returns false (Lua truthiness: nil is falsy)

**Stale SHM cleanup**:
- Creates fake SHM file at `<path>-shm`, no process holds it → file removed before set_path called
- Verifies SHM file is gone post-call

**No SHM file**:
- No SHM exists → opens normally without attempting removal

### Testing Approach

Mock-based: Stubs `db_module.set_path`, `core.logger`, `core.time_utils`. The `is_file_locked` function shells out to `lsof` — in test, the SHM file is not held by any process, so `lsof` returns count ≤ 1 → "not locked" → stale → removed.

### Design Observations

- **SHM vs WAL semantics**: The function deliberately removes only the SHM file (shared memory index), never the WAL (write-ahead log). WAL contains actual transaction data that SQLite will replay on next open; SHM is just a memory-mapped cache that SQLite recreates.
- **lsof race condition**: Between the `is_file_locked` check and `os.remove`, another process could lock the SHM. This is a TOCTOU race but acceptable for development use.
- **No Qt dialog path tested**: The `parent_window` and `qt_constants` parameters are accepted but unused in the current implementation — no error dialog is shown on failure.

---

## T21: `pipe.lua` (125 LOC → 51 assertions)

**File**: `tests/test_pipe.lua`

### Coverage

**pipe()**:
- Identity (no transforms) → value unchanged
- Single, chained (2), triple (3) transforms → correct composition
- nil value flows through
- Table value processed correctly

**map()**:
- Basic: doubles list, preserves length and order
- Index passed as 2nd arg, list as 3rd arg
- Empty list → empty; nil list → empty (defensive guard)
- Non-function arg → error "requires a function"

**filter()**:
- Basic: keeps even numbers
- All filtered out → empty; none filtered → full copy
- Empty/nil list → empty
- Non-function → error

**flat_map()**:
- Table return → flattened into output
- Scalar return → collected directly
- nil return → skipped (element dropped)
- Mixed returns (table, nil, scalar) in same call
- Empty/nil list → empty
- Index+list args passed to mapper
- Non-function → error

**each()**:
- Visits all elements with side effects
- Returns original list reference (identity for chaining)
- Index+list args passed
- nil list → returns nil (no iteration, no crash)
- Empty list → returns empty
- Non-function → error

**reduce()**:
- Sum and string concatenation
- Index+list args passed to reducer
- Empty list → returns initial value
- nil list → returns initial value
- Non-function → error

**Integration (pipe + combinators)**:
- filter→map→reduce pipeline: `[1..6] → evens → double → sum = 24`
- flat_map in pipeline with subsequent filter
- each passthrough in pipeline (side-effect doesn't alter data flow)

### Design Observations

- **Pure functional combinators**: Each combinator returns a closure, enabling composition via `pipe()`. No module state, no side effects (except `each`).
- **nil-safe lists**: All combinators handle nil input by returning an empty table (or nil for `each`). This prevents nil propagation errors in pipelines.
- **No lazy evaluation**: All transforms are eager — each combinator materializes a full intermediate table. For small lists this is fine; for large datasets this could be memory-intensive.
- **each returns original reference**: Unlike map/filter which create new tables, `each` returns the same table object. This means mutations inside the `each` callback affect the original list.

---

## T22: `fs_utils.lua` (34 LOC) + `path_utils.lua` (49 LOC) → 22 assertions

**File**: `tests/test_fs_path_utils.lua`

### Coverage

**fs_utils.file_exists()**:
- Existing file (test uses own source path via `debug.getinfo`) → true
- Nonexistent file → false
- nil → false; empty string → false
- Directory path → no crash (result varies by OS)
- Custom mode parameter ("r" instead of default "rb")
- Removed file → false

**path_utils.resolve_repo_root()**:
- Returns non-empty string
- No trailing slash
- Points to actual project (verified by checking core/database.lua exists)

**path_utils.resolve_repo_path() — absolute paths**:
- Unix `/usr/bin/lua` → passthrough
- Windows `C:/Users/test` → passthrough
- Windows backslash `C:\Users\test` → passthrough

**path_utils.resolve_repo_path() — relative paths**:
- Simple relative → repo_root + "/" + path
- Leading slash is absolute (passthrough, not stripped)
- Filename only → repo_root + "/" + filename

**path_utils.resolve_repo_path() — edge cases**:
- nil → nil
- Empty string → empty string

**is_absolute_path (indirect)**:
- Relative path detected and resolved
- Drive letters: `D:/`, `d:\` both detected as absolute

### Design Observations

- **resolve_repo_root is fragile**: It finds the project root by locating `core.database` in `package.path` and stripping the suffix. If package.path doesn't include the project's src/lua directory, the assert fires.
- **Leading slash ambiguity**: `resolve_repo_path("/foo")` passes through as absolute (Unix absolute path). This is correct but means you can't use leading-slash relative paths — they're always treated as absolute.
- **gsub on relative paths**: `path:gsub("^/+", "")` strips leading slashes from the relative portion before concatenation. But this branch is only reached for non-absolute paths, which by definition don't start with `/`. The gsub is a no-op safety measure.
- **file_exists mode parameter**: Default "rb" (read binary) works for both text and binary files. The mode parameter allows callers to check write-accessibility via "w", though this would create/truncate the file as a side effect.

---

## T23: `widget_parenting.lua` (38 LOC → 12 assertions)

**File**: `tests/test_widget_parenting.lua`

### Coverage

**debug_widget_info()**:
- String widget + name → no crash
- Table widget + name → no crash
- nil widget + nil name → uses "unknown" fallback, no crash
- Number widget, no name → no crash

**smart_add_child()**:
- Returns success table (success=true)
- error_system.is_success → true; is_error → false
- nil args → success (stub doesn't validate)
- Table args → success

**Module exports**:
- debug_widget_info and smart_add_child are both functions

### Design Observations

- **Stub implementation**: Both functions are placeholders for future Qt integration. `smart_add_child` always returns success regardless of inputs. `debug_widget_info` uses `print` (not logger) for debug output.
- **Dependencies pulled but unused**: Requires `error_system`, `logger`, and `ui_constants`. Only `error_system` is actually used (for `create_success`). `logger` and `ui_constants` are loaded but never called.
- **Minimal test value**: Since this is a stub, tests verify the API contract (return types, no crashes) rather than meaningful behavior. Tests will need expansion when real Qt parenting logic is implemented.

---

## T24: `collapsible_section.lua` (716 LOC → 43 assertions)

**File**: `tests/test_collapsible_section.lua`

### Coverage

**create_section() factory**:
- Returns success table with section, section_widget, content_layout in return_values
- Section object accessible via result.section

**CollapsibleSection.new() state**:
- title stored correctly
- parent_widget stored
- connections initialized as empty table
- section_enabled defaults to true
- bypassed defaults to false
- expanded set to false after create() (which calls setExpanded(false))

**setExpanded()**:
- Expand (false→true): success, expanded=true
- Collapse (true→false): success, expanded=false
- Same state (false→false): success with "already in desired state" message (early return)

**addContentWidget()**:
- With content_layout: success
- With nil content_layout: SECTION_NOT_INITIALIZED error with correct code

**cleanup()**:
- All 7 widget refs (main_widget, header_widget, enabled_dot, title_label, content_frame, content_layout, disclosure_triangle) set to nil
- connections array emptied
- Returns success

**onToggle()**:
- Delegates to signals.connect("section:toggled", handler)
- Returns connection ID

**Title variations**:
- Normal single word, spaced multi-word, empty string — all succeed

**Qt failure paths**:
- WIDGET.CREATE throws → QT_WIDGET_CREATION_FAILED error propagated
- LAYOUT.CREATE_VBOX throws → error propagated (LAYOUT_CREATION_FAILED)

### Testing Approach

Full Qt stub layer: qt_constants (WIDGET, LAYOUT, GEOMETRY, PROPERTIES, DISPLAY, CONTROL), qt_signals, ui_constants, logger, and globals (qt_set_widget_attribute, qt_update_widget). Stubs return mock widget tables with incrementing IDs.

### Design Observations

- **90% error handling boilerplate**: Of the 716 LOC, roughly 600 lines are pcall-wrapped Qt calls with error_system.create_error fallbacks. The actual state logic is ~50 lines.
- **Global callback pattern**: Header click handlers are registered as `_G[callback_name]` where the name includes the section title with spaces replaced by underscores. This is a fragile pattern that could collide if two sections share a title.
- **createEnabledDot is disabled**: The method exists (lines 476-550) but the call in createHeader is commented out. The orange dot feature is dormant.
- **setExpanded early return**: If `self.expanded == expanded`, returns immediately without touching Qt. This prevents unnecessary Qt calls when the state hasn't changed.

---

## T25: Inspector adapter (134 LOC) + widget_pool (299 LOC) → 53 assertions

**File**: `tests/test_inspector_modules.lua`

### Adapter Coverage

**bind()**:
- nil panel_handle → error (INVALID_PANEL_HANDLE)
- Non-table fns → assert_type throws
- Missing applySearchFilter or setSelectedClips → error (MISSING_REQUIRED_FUNCTIONS)
- Valid bind → success, stores panel and fns

**filterClipMetadata (via applySearchFilter)**:
- Empty/nil query → all clips pass (no filter)
- Name match (case-insensitive substring)
- ID match
- Source path match
- Metadata value match (iterates clip.metadata pairs)
- Metadata key match
- No matches → empty filtered list
- Multiple matches (e.g., ".mov" suffix)

**setSelectedClips()**:
- Stores clips and reapplies current filter
- nil clips → empty array stored

**Legacy aliases**:
- apply_filter → applySearchFilter
- set_selected_clips → setSelectedClips

### Widget Pool Coverage

**rent()**:
- All 5 widget types: line_edit, checkbox, label, slider, combobox
- Unknown type → nil (with error log)
- Default config (no options) → works
- Configures widget (text, placeholder, checked, range, options)

**return_widget()**:
- Returns to pool, decrements active count
- Subsequent rent reuses pooled widget
- nil → no-op
- Non-rented widget → logged warning, no crash

**get_stats()**:
- Reports pool sizes per type and active_count
- Accurate after rent/return operations

**clear()**:
- Resets all pools to empty, clears active widgets and signal connections

**connect_signal()**:
- Known signals: editingFinished, clicked, textChanged, valueChanged → returns connection
- Unknown signal → false
- Wraps handler in pcall for error isolation

**Signal cleanup on return**:
- Connections tracked per widget in _signal_connections
- return_widget disconnects and clears connections

### Design Observations

- **Adapter filtering is pure Lua**: `filterClipMetadata` does case-insensitive substring matching against name, id, src, and metadata key/value pairs. No Qt dependency — this is the most testable part.
- **Widget pool reuse pattern**: `rent()` checks the pool first (`table.remove(pool)` pops from the end), then creates new if empty. `return_widget()` clears state and pushes back. Classic object pool pattern.
- **view.lua not tested**: At 1135 LOC, view.lua has 10+ transitive require dependencies (command_manager, frame_utils, timeline_state, inspectable_factory, metadata_schemas, collapsible_section, profile_scope, widget_pool, qt_constants, qt_signals). Stubbing all of these reliably would be fragile. The pure helpers (normalize_default_value, get_field_key, field suppression depth) could be extracted and tested independently.
- **Double C++ call**: adapter.applySearchFilter does Lua-based filtering AND calls the C++ function if bound. This dual path means filtering works even without the C++ backend.

---

## T26: `track_state.lua` (60 LOC → 36 assertions)

**File**: `tests/test_track_state.lua`

### Coverage

**get_all()**:
- Returns data.state.tracks reference
- Empty tracks → empty table

**get_video_tracks() / get_audio_tracks()**:
- Correctly filters by track_type == "VIDEO" / "AUDIO"
- Mixed tracks → correct counts
- No tracks of requested type → empty
- Empty tracks → empty

**get_height()**:
- Explicit height on track → returns that height
- No height field → returns data.dimensions.default_track_height (50)
- Nonexistent track_id → returns default height

**set_height()**:
- Updates track.height field
- Sets track_layout_dirty = true
- Calls data.notify_listeners()
- Same height → no-op (dirty flag stays false, listener not called)
- Nonexistent track_id → no crash, no side effects
- persist_callback called with true when height changes

**is_layout_dirty() / clear_layout_dirty()**:
- Flag set by set_height, cleared by clear_layout_dirty
- Full lifecycle: clean → set_height → dirty → clear → clean

**get_primary_id()**:
- Returns first track matching type (order matters)
- Accepts lowercase ("video") → uppercased internally
- Nonexistent type ("SUBTITLE") → nil
- Empty tracks → nil

**get_by_id()**:
- Found → returns track table
- Nonexistent → nil
- nil → nil (early return guard)

### Testing Approach

Stubs ui_constants with TIMELINE constants before requiring timeline_state_data. Uses `data.reset()` + `data.state.tracks = [...]` to set up each test scenario. No Qt stubs needed — track_state is pure Lua operating on in-memory state.

### Design Observations

- **Module-local dirty flag**: `track_layout_dirty` is module-local, not on `data.state`. Only `set_height` sets it, only `clear_layout_dirty` clears it. No way to set it externally.
- **Linear scan for all lookups**: `get_height`, `set_height`, `get_primary_id`, `get_by_id` all iterate `data.state.tracks` with `ipairs`. Fine for typical timeline track counts (< 20), but O(n) per call.
- **notify_listeners debouncing**: `data.notify_listeners()` uses a timer-based debounce. In tests without `qt_create_single_shot_timer`, the fallback path calls listeners synchronously (line 33: `callback()`), making test assertions deterministic.
- **get_primary_id uppercases**: `track_type:upper()` means callers can pass "video" or "VIDEO" — the function normalizes. But track data in `data.state.tracks` must use uppercase "VIDEO"/"AUDIO" for the comparison to work.
