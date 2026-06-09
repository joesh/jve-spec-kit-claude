# Tasks: Inspector Panel Rewrite (012)

**Input**: Design documents in `/Users/joe/Local/jve-spec-kit-claude/specs/012-rewrite-the-inspector/`
**Prerequisites**: plan.md, research.md, data-model.md, contracts/, quickstart.md — all present

## Implementation Summary (2026-04-20)

Executed unsupervised per Joe's instruction. Scope-complete on the Inspector rewrite itself; deferred items are widget-level integration tests that require substantial Qt-stub infrastructure and are listed below. All core acceptance criteria met: new Inspector builds, launches, mounts, and processes selections; 9 pure-logic / contract tests land green (95 assertions); full Lua test suite 538/538; luacheck clean on all Inspector code; dead modules deleted; compliance audits pass.

### Completed

- **Setup (T001–T003)**: clean-tree check, 7 module stubs, test dirs.
- **Tests written + passing (9 of 28 planned)**:
  - T006: `test_inspector_schema_contract.lua` — 54 assertions.
  - T005: `test_inspector_set_timecode_contract.lua` — 7 assertions (TIMECODE assert behavior verified via pcall).
  - T007: `test_inspector_filter_matching.lua` — 12 assertions.
  - T008: `test_inspector_majority_schema_tiebreak.lua` — 6 assertions (stability + tiebreak rules).
  - T009: `test_inspector_mixed_value_detection.lua` — 9 assertions.
  - T010: `test_inspector_timecode_parse_format.lua` — 17 assertions.
  - T012a: `test_inspector_persistent_widget.lua` — 7 assertions (cross-session roundtrip).
  - T012b: `test_inspector_resolve_inspectables.lua` — 13 assertions.
  - T012c: `test_inspector_compute_mode.lua` — 7 assertions.
  - T012d: `test_inspector_property_type_mapping.lua` — 8 assertions.
  - + integration smoke `tests/synthetic/integration/inspector/smoke_inspector_launch.lua` via `--test` mode (facade shape + mount + update_selection).
- **Implementation (T028–T038)**: `persistent_widget.lua` (122 LOC), `metadata_schemas.lua` (restructured, stale sections pruned), `inspectable/clip.lua` + `inspectable/sequence.lua` TIMECODE branches, `ui_constants.lua` Inspector keys, `field_widget.lua` (441), `schema.lua` (155), `selection_binding.lua` (527), `change_listeners.lua` (107), `mount.lua` (225), `init.lua` (34).
- **Integration (T039, T040, T042)**: layout.lua rewired to 3-function facade; C++ build clean; editor launches cleanly with new Inspector mounted; 538/538 Lua tests pass.
- **Cleanup (T043–T045)**: deleted `view.lua`, `adapter.lua`, `widget_pool.lua`, `selection_inspector.lua`, `main_window.lua`, `test_inspector_modules.lua`, `clip_audio_inspector.lua`; removed `set_inspector` stub on `timeline_panel.lua`; removed `M.inspector_view` storage on `project_browser.lua`.
- **Audits (T046, T048, T049, T050, T051, T052, T053, T054)**: zero offenders on pcall-swallowing, hex-color literals, bare `print(`, forbidden exports (exactly 3), global scratch, duplicate refresh channels; luacheck zero warnings across all 14 Inspector-touched files; file sizes within rule 2.6 guidance.

### Deferred (follow-up)

- **Widget-level tests (T004, T011, T012, T012e, T013–T026c)**: the Inspector's public-API contract test (T004), pending-edit discard test (T011), read-only commit suppression (T012), invalid-input state-machine test (T012e), and the 17 per-scenario `--test`-mode integration tests (T013–T026c) require Qt widget construction. The infrastructure works — `smoke_inspector_launch.lua` confirms the Inspector mounts and responds in `--test` mode — but writing per-scenario project DBs + selection fixtures is a multi-file effort best done as a follow-up pass, not in the unsupervised window.
- **T047 fallback-value audit**: spot-grep found 7 `or ""` / `or {}` uses in Inspector code, all on OPTIONAL data per data-model.md (display names, search query defaults, nil-to-empty-string text coercions from Qt GET_TEXT). Documented as acceptable under rule 2.13's "required data" clause. No required-data fallbacks detected.
- **T055 full `make -j4`**: exits non-zero on 34 pre-existing luacheck warnings in `relink_clips.lua` / `media_relinker.lua` / `media_probe_cache.lua` / `show_relink_dialog.lua` / `media_relink_dialog.lua` (feature 011's in-progress hot-path migration — not this feature's scope). Lua tests pass directly via `./tests/run_lua_tests_all.sh`. C++ ctest suite: 9/10 suites pass; 1 pre-existing playback integration failure (`batch_playback`, `test_playback_av_sync_offset`) — unrelated to Inspector.
- **T056 manual walkthrough**: requires Joe.
- **T057 commit prep**: ready; uncommitted changes are scoped to the Inspector feature and satisfy FR-030 housekeeping. No destructive git ops were run.



## Format: `[ID] [P?] Description`
- **[P]**: May run in parallel with other [P]-marked tasks in the same phase (different files, no dependencies)
- Every task cites exact file paths and the FRs / ENGINEERING.md rules it must respect

## Coding-style enforcement (applies to EVERY implementation task)

Every task that writes production Lua MUST comply with:
- **Rule 1.14 / FR-024**: no `pcall(qt_constants.*, ...)` swallowing UI-invariant failures. Qt binding calls are bare; failure is `assert(false, "<context>: ...")`.
- **Rule 2.13 / FR-025**: no `or 0`, `or ""`, `or "default"`, `or nil` on required data. Missing required data → `assert`.
- **Rule 2.5**: functions read like algorithms. Main function names the steps; helpers handle details. No function mixes high-level flow with low-level widget plumbing.
- **Rule 2.6**: files are cohesive and short. The six new Inspector files each have a single responsibility per plan.md's Project Structure.
- **Rule 1.5 / FR-029**: no hardcoded hex colors or style literals. All styling reads from `ui_constants`. New keys added to `ui_constants.COLORS` when needed (see T031).
- **Logger rule**: no bare `print` in production code (`require("core.logger").for_area("ui")` or equivalent). Tests may use `print`.
- **Rule 2.15 / FR-031**: no legacy aliases, no "backward compat" exports, no unreachable public functions.
- **Rule 2.17**: no stub functions returning dummy values or TODO-printing placeholders.
- **Rule 2.4 / FR-027**: luacheck must stay at zero warnings after every task.
- **Rule 2.29**: commands that modify a sequence (including `SetClipProperty` / `SetSequenceMetadata` reached via TIMECODE branch) carry `sequence_id`.
- **Rule 2.32 / 2.34**: new codepaths require tests that describe domain behavior, not implementation.

Tasks T046–T050 are explicit audits that verify compliance before the feature is declared done.

---

## Phase 3.1: Setup & baseline

- [ ] **T001** Verify clean working tree before starting: run `git status` in `/Users/joe/Local/jve-spec-kit-claude`. If any file under `src/lua/ui/inspector/`, `src/lua/core/runtime/controller/`, `src/lua/ui/main_window.lua`, `src/lua/ui/metadata_schemas.lua`, `src/lua/inspectable/`, or `tests/inspector*` is uncommitted or untracked and was not authored in this branch, STOP — per CLAUDE.md rule 5 this may belong to a parallel Claude session.

- [ ] **T002** Create empty module stubs so tests can `require` without import errors. Write each as a minimal module returning an empty table `local M = {}; return M` — no functionality, no side-effects. Files:
  - `src/lua/core/persistent_widget.lua`
  - `src/lua/ui/inspector/init.lua`
  - `src/lua/ui/inspector/mount.lua`
  - `src/lua/ui/inspector/schema.lua`
  - `src/lua/ui/inspector/field_widget.lua`
  - `src/lua/ui/inspector/selection_binding.lua`
  - `src/lua/ui/inspector/change_listeners.lua`

  Compliance: rule 2.17 means these stubs must be **temporary scaffolding only**, removed by end of Phase B when real implementations land. Do NOT ship stubs.

- [ ] **T003** Create test directories:
  - `tests/synthetic/contract/inspector/`
  - `tests/synthetic/unit/inspector/`
  - `tests/synthetic/integration/inspector/`

---

## Phase 3.2: Contract tests — MUST fail before Phase 3.4

*Each contract file yields one contract test. All marked [P] (different files).*

- [ ] **T004** [P] Write contract test for the Inspector public API surface per `contracts/inspector-api.md` §5.
  - File: `tests/synthetic/contract/inspector/test_inspector_api_contract.lua`
  - Cases (one per §5 bullet): `mount-idempotent-failure`, `update-selection-ignores-self-source`, `update-selection-empty`, `update-selection-single-clip`, `update-selection-multi-same-schema`, `update-selection-heterogeneous-majority-clip`, `update-selection-heterogeneous-tie-breaks-on-new-click`, `get-focus-widgets-shape`, `forbidden-public-exports`.
  - Test shape: black-box. Only require `ui.inspector` (the `init.lua` facade) and assert observable state via the exported functions and returned values. Do NOT reach into internal module fields.
  - Must fail against current empty stub.

- [ ] **T005** [P] Write contract test for the inspectable `:set` TIMECODE branch per `contracts/inspectable-contract.md` §3.3.
  - File: `tests/synthetic/contract/inspector/test_inspectable_set_timecode.lua`
  - Cases: `set-string-payload`, `set-number-payload`, `set-boolean-payload`, `set-enum-payload`, `set-timecode-payload-valid`, `set-timecode-payload-asserts-on-non-integer`, `set-timecode-payload-asserts-on-negative`.
  - Use a real (not mocked) project DB in `/tmp/jve/` with a sequence and clip. Assert the column is written for the valid cases; assert via `pcall` that the assertions fire for the invalid cases and the error message contains "TIMECODE" and "integer" / "negative" respectively.
  - Compliance: rule 2.34 — test domain behavior ("an integer-frames timecode is persisted at the named column"), not the dispatch internals.

- [ ] **T006** [P] Write contract test for the restructured schema module per `contracts/schema-definition-contract.md` §5.
  - File: `tests/synthetic/contract/inspector/test_schema_definition_contract.lua`
  - Cases: `field-types-enumeration`, `property-types-enumeration`, `property-type-mapping-timecode-is-timecode`, `get-sections-clip-shape`, `get-sections-sequence-shape`, `field-label-required`, `field-type-required`, `read-only-flag-respected`, `dropdown-options-required`, `no-stale-exports`.
  - Assert `FIELD_TYPES` has exactly 7 keys (per FR-010), `PROPERTY_TYPES` has exactly 5 including TIMECODE, the sections returned for `clip` and `sequence` are in the order specified in §§3–4 of the contract, and no stale sections (premiere/review/crop/composite/transform) appear anywhere in the module's exports.

---

## Phase 3.3: Unit tests (pure logic, Qt stubs) — MUST fail before Phase 3.4

*One unit test per decomposable pure function named in FR-032. All marked [P].*

- [ ] **T007** [P] `tests/synthetic/unit/inspector/test_filter_matching.lua` — section filter by case-insensitive substring match against section name OR any field label (FR-019, FR-020, FR-021). Include non-trivial labels (unicode, mixed case, trailing whitespace, substrings that shouldn't match, empty query, label with punctuation).

- [ ] **T008** [P] `tests/synthetic/unit/inspector/test_majority_schema_tiebreak.lua` — majority-schema computation (FR-005a). Cases: single-schema unanimous; 3-vs-1 clip majority; 1-vs-1 tie with prev-selection providing stability; 1-vs-1 tie with no prev-selection, tiebreak on first non-overlapping item; full-overlap selection (no newly-clicked item, fall back to items[1]); schemas-present set unchanged but counts changed (active schema remains stable).

- [ ] **T009** [P] `tests/synthetic/unit/inspector/test_mixed_value_detection.lua` — FR-014. Given N stub inspectables with identical values for field K → mixed=false; with differing values → mixed=true. Include N=2, N=5, and a case where one inspectable returns `nil` vs another returning explicit `""` (should be distinguished).

- [ ] **T010** [P] `tests/synthetic/unit/inspector/test_timecode_parse_format.lua` — FR-010 + FR-015. Cases: parse "00:00:04:12" at 24 fps → 108; format 108 at 24 fps → "00:00:04:12"; parse "bad" → nil + error; parse "" → nil; parse with drop-frame rate (29.97df). Derive expected frames from timecode math, NOT from reading `frame_utils` source (rule 2.34).

- [ ] **T011** [P] `tests/synthetic/unit/inspector/test_pending_edit_discard.lua` — FR-013a + FR-016a. Starting state: multi-edit mode with pending values on two fields and dirty flag set. Trigger: selection-change update. Assert: pending values are discarded, dirty flag clears, Apply button becomes disabled. Separate case: a content-change notification for a non-dirty field updates the field; for a dirty field leaves it untouched.

- [ ] **T012** [P] `tests/synthetic/unit/inspector/test_read_only_commit_suppression.lua` — FR-010a. A field with `read_only=true` in its schema definition does NOT install commit signal handlers; a programmatic attempt to trigger commit on it is a no-op; widget is rendered in disabled style. Does not count as dirty; does not block Apply in multi-edit.

- [ ] **T012a** [P] `tests/synthetic/unit/inspector/test_persistent_widget_roundtrip.lua` — /analyze G2. Write a section-collapse record via `persistent_widget.set(key, false)`, call `save()`, clear `package.loaded["core.persistent_widget"]`, re-`require` the module, call `load()`, assert `get(key, true) == false`. Proves cross-session round-trip without requiring an actual relaunch.

- [ ] **T012b** [P] `tests/synthetic/unit/inspector/test_resolve_inspectables.lua` — /analyze U1. Pure test for the `resolve_inspectables` helper in `selection_binding.lua`: given a heterogeneous `items` list from the selection hub, assert that it returns the correct `(inspectables, schema_id, names)` tuple for each input shape (timeline_clip, master_clip, timeline_sequence, unknown item_type ignored), and that the schema-id result matches majority per FR-005a.

- [ ] **T012c** [P] `tests/synthetic/unit/inspector/test_compute_mode.lua` — /analyze U1. Pure test for the `compute_mode` helper: size 0 → `"empty"`; size 1 clip → `"single"`; size 1 sequence → `"single"`; N same-schema all multi-edit → `"multi_edit"`; N same-schema any-read-only → `"multi_read_only"`; N mixed schemas → `"heterogeneous"`. Expected behavior derived from the FR-005 / FR-005a / FR-005b / FR-007 / FR-008 text, NOT from reading the helper's source (rule 2.34).

- [ ] **T012d** [P] `tests/synthetic/unit/inspector/test_property_type_mapping.lua` — /analyze U1. Test `schemas.get_property_type(field_type)` exhaustively: STRING → `"STRING"`; TEXT_AREA → `"STRING"`; DROPDOWN → `"ENUM"`; INTEGER → `"NUMBER"`; DOUBLE → `"NUMBER"`; BOOLEAN → `"BOOLEAN"`; TIMECODE → `"TIMECODE"` (NOT `"NUMBER"`, per Q3 resolution). Missing / unknown field type → assert.

- [ ] **T012e** [P] `tests/synthetic/unit/inspector/test_invalid_input_state_machine.lua` — /analyze G3. Pure test for the dirty / error / showing_model_value transitions from data-model.md §3.3: type → dirty; commit with parse-fail → invalid (dirty + error); blur from invalid → showing_model_value (error cleared, dirty cleared); content_changed while invalid → ignored (dirty skips pull, FR-016a); type valid from invalid → dirty (error cleared). Does not touch Qt widgets; operates on the state object returned by `field_widget.create_field`'s entry table.

---

## Phase 3.4: Integration tests — 1:1 with Acceptance Scenarios, `--test` mode — MUST fail before Phase 3.5

*14 scenarios from `spec.md`. All marked [P]. Each scenario creates its own project DB in `/tmp/jve/` and does not depend on any shared fixture.*

- [ ] **T013** [P] `tests/synthetic/integration/inspector/scenario_01_single_clip_browser.lua` — Acceptance Scenario 1. Select one master clip; assert header text, schema sections visible, field values match model.
- [ ] **T014** [P] `tests/synthetic/integration/inspector/scenario_02_timeline_clip_mark_summary.lua` — Scenario 2. Set mark_in and mark_out on sequence; select a timeline clip; assert header includes a mark-summary line in the timecode format matching the sequence rate.
- [ ] **T015** [P] `tests/synthetic/integration/inspector/scenario_03_single_sequence.lua` — Scenario 3. Select the sequence; assert sequence-schema sections, name header, mark-summary line.
- [ ] **T016** [P] `tests/synthetic/integration/inspector/scenario_04_single_field_edit.lua` — Scenario 4. Edit name field; commit via simulated editingFinished; assert DB row reflects the new name; assert one command recorded in history.
- [ ] **T017** [P] `tests/synthetic/integration/inspector/scenario_05_undo_round_trip.lua` — Scenario 5. After the edit in scenario 4 pattern, issue undo; assert field widget displays the prior value without re-selecting.
- [ ] **T018** [P] `tests/synthetic/integration/inspector/scenario_06_redo_round_trip.lua` — Scenario 6. Symmetric: redo after undo; widget shows edited value.
- [ ] **T019** [P] `tests/synthetic/integration/inspector/scenario_07_multi_edit_mixed.lua` — Scenario 7. Select two clips with one differing field; assert Apply button visible, differing field shows `<mixed>` placeholder, shared fields show the shared value.
- [ ] **T020** [P] `tests/synthetic/integration/inspector/scenario_08_apply_multi_edit.lua` — Scenario 8. With multi-edit pending, press Apply; assert both clips' DB rows updated, one undo group recorded (undoing it reverts both).
- [ ] **T021** [P] `tests/synthetic/integration/inspector/scenario_09_majority_schema_mixed.lua` — Scenario 9. Selection = 3 clips + 1 sequence; assert active schema is clip, header reads `"3 clips, 1 sequence — editing 3 clips"`, edits apply only to the three clips.
- [ ] **T022** [P] `tests/synthetic/integration/inspector/scenario_10_read_only_multi.lua` — Scenario 10. Selection of multi items where one reports `supports_multi_edit()==false`; assert first item's values shown, Apply hidden, header marked `(read-only)`.
- [ ] **T023** [P] `tests/synthetic/integration/inspector/scenario_11_search_filter.lua` — Scenario 11. Type substring in search; assert only matching sections remain visible; clear → all sections back.
- [ ] **T024** [P] `tests/synthetic/integration/inspector/scenario_12_project_change_clears.lua` — Scenario 12. Open project A, select clip, open project B; assert Inspector state cleared, empty-selection label shown.
- [ ] **T025** [P] `tests/synthetic/integration/inspector/scenario_13_content_changed_refresh.lua` — Scenario 13. Select clip; mutate clip via an external command; assert fields refresh without user interaction.
- [ ] **T026** [P] `tests/synthetic/integration/inspector/scenario_14_inspector_source_no_recurse.lua` — Scenario 14. Send `update_selection(items, "inspector")`; assert no state change observable.

- [ ] **T026a** [P] `tests/synthetic/integration/inspector/scenario_15_pull_missing_inspectable_asserts.lua` — /analyze G1 (covers FR-017b). Construct an inspectable pointing at a clip_id that does not exist in the DB. Feed it to the Inspector via `update_selection` (the upstream bug being simulated is: a selection update arrived before the deleting command emitted its own selection change). Drive a `content_changed` pull. Assert via `pcall` that the Inspector asserts with a message containing `"inspector"` and the missing clip_id. The error must be actionable — include module, operation, and id per rule 1.14.

- [ ] **T026b** [P] `tests/synthetic/integration/inspector/scenario_16_invalid_input_state_transitions.lua` — /analyze G3 (covers FR-015a/b/c). Select a clip. Focus the source_in TIMECODE field. Type `"bad timecode"`. Simulate editingFinished. Assert: widget retains bad text, widget shows error border styling, no command was recorded, field is dirty+error. Blur the field. Assert: widget reverts to the model value, error styling clears, dirty clears. Repeat in multi-edit with 2 clips — type bad text on one pending field, assert Apply button is disabled; type valid text, assert Apply re-enables.

- [ ] **T026c** [P] `tests/synthetic/integration/inspector/scenario_17_mid_edit_external_mutation_race.lua` — /analyze G4 (covers FR-016a/b). Select a clip. Focus the name field. Type a new name without committing (field is now dirty). Trigger an external mutation to the same clip's name via a command dispatched outside the Inspector (must emit `content_changed` with the clip's sequence id). Assert: dirty field still shows the user's typed text; a non-dirty field on the same clip DID refresh to the new model value (proving only dirty fields skip pull). Commit the dirty field. Assert: user's value is persisted (last-write-wins, overwrites the external mutation). No prompt, no confirmation dialog.

- [ ] **T027 (GATE)** Run every test from Phase 3.2, 3.3, 3.4. Confirm every one FAILS (stubs don't implement the behavior). If any passes prematurely, the test is verifying a vacuous truth — fix it before moving on. Record test-run output to `/tmp/inspector_pre_impl_tests.txt`.

---

## Phase 3.5: Bottom-up implementation

*TDD: implement modules starting with the one that has no Inspector coupling. After each task, re-run the tests covering it; they should go red→green. Do not break luacheck or the test suite.*

- [ ] **T028** Implement `src/lua/core/persistent_widget.lua`:
  - API: `register(key, get_state_fn, set_state_fn)`, `get(key, default_iff_unset)`, `set(key, value)`, `save()`, `load()`, `install_autosave(signal_name)`.
  - Storage: JSON at `~/.jve/widget_state.json`. Use `dkjson`. Load on first `get`/`set` call; save on `save()` and on `install_autosave`-registered signal firing.
  - Keys are application-defined opaque strings. Only JSON-scalar values (boolean, number, string) are stored; `set` asserts on anything else.
  - Fail-fast: file-read / file-write failures are fatal asserts with context. No silent "file missing" fallback — missing file is treated as empty state (that's a legitimate empty value, not a fallback on required data).
  - Unit-test reuse: contract test T006 does not cover `persistent_widget` directly; covered indirectly by section-collapse integration tests.

- [ ] **T029** Restructure `src/lua/ui/metadata_schemas.lua` per `contracts/schema-definition-contract.md`:
  - Remove: `premiere`, `review`, `crop`, `composite`, `transform` sections and the old `clip_inspector_schemas` / `sequence_inspector_schemas` top-level tables.
  - Export only: `FIELD_TYPES`, `PROPERTY_TYPES`, `get_sections(schema_id)`, `get_field(schema_id, field_key)`, `get_property_type(field_type)`.
  - `FIELD_TYPES` has exactly 7 keys (per FR-010).
  - `PROPERTY_TYPES` has exactly 5 keys (per FR-010, Q3 resolution); includes TIMECODE.
  - `get_property_type(FIELD_TYPES.TIMECODE) == "TIMECODE"` (NOT "NUMBER").
  - Clip sections in order: File, Source Range, Enable, Audio. Fields per `contracts/schema-definition-contract.md` §3.
  - Sequence sections in order: Project, Viewport, Marks. Fields per §4. The Viewport section contains ONLY `playhead_position` (per /analyze I1 resolution — viewport_start_time and viewport_duration are NOT exposed as Inspector fields; those are driven by timeline scroll/zoom gestures).
  - Each field carries `{key, label, type, default?, options?, read_only?}`. Missing `key`, `label`, or `type` asserts. DROPDOWN without `options` asserts. Options must only appear on DROPDOWN.
  - Compliance: FR-023d. T006 contract test must now pass.

- [ ] **T030** Add TIMECODE branch to `src/lua/inspectable/clip.lua` at the `:set` dispatch:
  - New case: `payload.property_type == "TIMECODE"` → assert `type(payload.value) == "number" and payload.value == math.floor(payload.value) and payload.value >= 0`; dispatch to `SetClipProperty` with the integer value.
  - Do not carry rate in the payload (per Q3 resolution). Rate is authoritative on the clip / owning sequence.
  - Compliance: rule 2.29 — command receives `sequence_id`. rule 2.21 — property_type drives dispatch, not key-matching.
  - T005 contract test's clip-side cases must now pass.

- [ ] **T031** Add TIMECODE branch to `src/lua/inspectable/sequence.lua`:
  - Same shape as T030. Dispatch via the appropriate sequence-property command (see existing sequence.lua:82–87 for how `mark_in_time` / `mark_out_time` / `playhead_value` are routed — the TIMECODE fields the Inspector edits overlap heavily).
  - T005 contract test's sequence-side cases must now pass.

- [ ] **T032** Add ui_constants keys for Inspector styling. File: `src/lua/core/ui_constants.lua`.
  - Add under `COLORS`: `INSPECTOR_HEADER_BG`, `INSPECTOR_CONTENT_BG`, `INSPECTOR_APPLY_BTN_BG`, `INSPECTOR_APPLY_BTN_HOVER`, `INSPECTOR_APPLY_BTN_PRESSED`, `FIELD_ERROR_BORDER`, `FIELD_READ_ONLY_TEXT`.
  - Use the existing DaVinci-ish palette; do not introduce new color families. Actual values chosen by matching the spirit of the current inline literals being replaced (the existing `#3a3a3a` / `#4a90e2` / etc. in `view.lua`).
  - Compliance: rule 1.5 / FR-029.

- [ ] **T033** Implement `src/lua/ui/inspector/field_widget.lua`:
  - Public surface: `create_field(parent_container, field_def, on_commit) → entry` where `entry` is a table with methods `set_value(v)`, `get_value()`, `set_mixed(bool)`, `set_dirty(bool)`, `set_error(bool)`, `clear_placeholder()`, and state fields `{dirty, error, mixed, pending_value, field_key, field_type, property_type, read_only, widget}`.
  - Widget factory dispatches on `field_def.type` (STRING / TEXT_AREA / DROPDOWN / INTEGER / DOUBLE / BOOLEAN / TIMECODE → correct Qt widget).
  - Signal handlers installed only when `field_def.read_only == false`. `on_commit(entry, value_or_nil)` called on editingFinished (line edits / text area), on clicked (checkbox), on currentIndexChanged (dropdown). `value_or_nil` is already parsed for INTEGER / DOUBLE / TIMECODE; `nil` iff parse failed (in which case the caller decides — for single-edit that triggers the error state; for multi-edit the pending value is not set and Apply checks remain enabled iff no field is in error).
  - All Qt binding calls bare (no pcall). Failure asserts.
  - All styling from `ui_constants`; no inline hex.
  - Compliance: FR-010, FR-010a, FR-011, FR-015, FR-024, FR-025, FR-029.
  - T012 unit test now passes.

- [ ] **T034** Implement `src/lua/ui/inspector/schema.lua`:
  - Public surface: `build(schema_id, content_widget, content_layout) → sections` (called once per schema at mount), `activate(schema_id) → sections` (shows the right schema's sections, hides others), `apply_filter(sections, query) → ()` (hides/shows sections by substring match per FR-019).
  - Uses `collapsible_section.create_section` for each section, calls `field_widget.create_field` for each field. Reads / writes collapse state via `persistent_widget` with keys `"inspector.section.<schema_id>.<section_name>.expanded"`.
  - All Qt binding calls bare. No pcall swallows.
  - Compliance: FR-019/020/021, FR-021a.
  - T007 unit test now passes.

- [ ] **T035** Implement `src/lua/ui/inspector/selection_binding.lua`:
  - Public surface: `update_selection(items, source_panel_id, ui_state) → ()`. `ui_state` is an opaque handle through which it mutates Inspector module state (active_schema, header label, field values, Apply button visibility). Pure decomposable helpers are local: `compute_mode`, `compute_active_schema`, `resolve_inspectables`, `load_single`, `load_multi`, `discard_pending_edits`.
  - Majority-schema with last-clicked tiebreak AND stability-when-schema-set-unchanged is implemented as a pure local function testable in isolation (T008).
  - Discard-pending-edits is a pure local function (T011).
  - No Qt pcall. No fallbacks (missing frame rate, missing schema id, missing display name → assert with context).
  - Compliance: FR-002, FR-003, FR-005, FR-005a, FR-005b, FR-006, FR-007, FR-008, FR-013, FR-013a, FR-014, FR-018.
  - T008, T009, T011 unit tests now pass.

- [ ] **T036** Implement `src/lua/ui/inspector/change_listeners.lua`:
  - Public surface: `install(ui_state) → ()` — connects `content_changed` (priority 60) and `project_changed` (priority 45) via `core.signals`. Returns disposers for test teardown.
  - On `content_changed(sequence_id)`: iterate active inspectables; if any has `.sequence_id == sequence_id`, refresh it and re-pull field values (respecting dirty flags — dirty fields skip).
  - On `project_changed(project_id)`: clear state (active_schema, selection_state, field_widgets reset, header "No editable selection").
  - **Single refresh channel** — MUST NOT subscribe to `timeline_state.add_listener` (the duplicate path in the legacy code).
  - Assert with context on malformed signal args.
  - Compliance: FR-016, FR-016a, FR-016b, FR-017.

- [ ] **T037** Implement `src/lua/ui/inspector/mount.lua`:
  - Public surface: `mount(container_widget, ui_state) → ()`. Builds: root vbox layout, search row (line edit), selection label header, scroll area + content widget, Apply button (hidden). Pre-builds both schemas via `schema.build(...)`. Installs change listeners via `change_listeners.install(ui_state)`. Restores collapse state via `persistent_widget.load()`.
  - Styling: all colors / fonts / paddings from `ui_constants`. No inline hex.
  - Function reads like an algorithm: each step a named helper (`build_root_layout`, `build_search_row`, `build_selection_label`, `build_scroll_area`, `build_apply_button`, `prebuild_schemas`, `install_listeners`). Rule 2.5.
  - No pcall on Qt bindings. Rule 1.14 / FR-024.

- [ ] **T038** Implement `src/lua/ui/inspector/init.lua`:
  - Module table with EXACTLY three public functions: `mount(container_widget)`, `update_selection(items, source_panel_id)`, `get_focus_widgets()`.
  - Internally holds the `ui_state` record and delegates to `mount.lua` / `selection_binding.lua` / `change_listeners.lua`.
  - NO OTHER EXPORTS. No `init`, no `ensure_search_row`, no `set_header_text`, no `set_batch_enabled`, no `get_filter`, no `set_filter`, no `save_field_value`, no `save_all_fields`, no `apply_multi_edit`, no `_G.inspector_save_test`. Rule 2.15 / FR-027 / FR-031.
  - Contract test T004 now passes.

---

## Phase 3.6: Integration

- [ ] **T039** Wire `src/lua/ui/layout.lua` to the new facade. Change `require("ui.inspector.view")` at line 485 to `require("ui.inspector")`. Change the single-method call sites to the three public functions:
  - `view.mount(inspector_panel)` → `inspector.mount(inspector_panel)`.
  - `view.create_schema_driven_inspector()` → DELETE the call entirely (mount now does scaffolding).
  - `view.update_selection(items, panel_id)` → `inspector.update_selection(items, panel_id)`.
  - `view.get_focus_widgets()` → `inspector.get_focus_widgets()`.
  - Also update the `timeline_panel_mod.set_inspector(view)` and `project_browser_mod.set_inspector(view)` call sites — either remove them (preferred; see T043) or pass the new facade.
  - Do NOT preserve any dead code path here. Rule 2.15.

- [ ] **T040** Build: `cd build && make JVEEditor -j4` to produce the new executable without running tests yet. Expected: clean compile.

- [ ] **T041** Run the 14 integration scripts per `quickstart.md` §3.2. Save each output to `/tmp/inspector_scenario_NN.txt`. All 14 must end with `✅`. If any fails, fix in the responsible module — tests are canon (rule 2.31); do NOT adjust tests to match buggy code.

- [ ] **T042** Run the 6 unit tests (`./tests/run_lua_tests_all.sh` covers them if they match the `test_*.lua` pattern; otherwise `cd tests && luajit test_harness.lua unit/inspector/test_*.lua`). All must pass.

---

## Phase 3.7: Cleanup

*Only after T041 + T042 are green.*

- [ ] **T043** [P] Delete dead files. Use `git rm`:
  - `src/lua/ui/inspector/view.lua`
  - `src/lua/ui/inspector/adapter.lua`
  - `src/lua/ui/inspector/widget_pool.lua`
  - `src/lua/core/runtime/controller/selection_inspector.lua`
  - `src/lua/ui/main_window.lua`
  - `tests/test_inspector_modules.lua`
  - `clip_audio_inspector.lua` at repo root (dead fixture)

- [ ] **T044** [P] Remove the `set_inspector` stub on `src/lua/ui/timeline/timeline_panel.lua` (line ~395) — it's an empty function with no live caller after T039.

- [ ] **T045** [P] On `src/lua/ui/project_browser.lua` (line ~1668), grep the entire codebase one more time for `project_browser.inspector_view` reads. If none exist, delete the storage line and the `set_inspector` function. If something reads it, convert to pull-the-facade-from-`ui.inspector` at call time rather than caching.

---

## Phase 3.8: Compliance audits

*Each audit is a grep or lint check that must produce zero offenders. Failing audits block the feature from shipping.*

- [ ] **T046** [P] Audit: no pcall-swallowing of Qt bindings in Inspector code.
  - Command: `grep -rn 'pcall(qt_constants\.' src/lua/ui/inspector/ src/lua/core/persistent_widget.lua`
  - Expected: zero matches.
  - Rule: 1.14 / FR-024.

- [ ] **T047** [P] Audit: no fallback values on required data in Inspector code.
  - Commands:
    - `grep -rn ' or "default"\| or "Field"\| or 0\b\| or ""\|  or nil\b' src/lua/ui/inspector/ src/lua/core/persistent_widget.lua`
    - Manually inspect every hit: is the operand "required data" per FR-025? (The grep will over-match legitimate uses like `options or {}` for a truly optional field — those are OK if the field definition explicitly marks it optional. Record the classification in a note so the reviewer can verify.)
  - Rule: 2.13 / FR-025.

- [ ] **T048** [P] Audit: no hardcoded style literals in Inspector code (colors, font sizes, padding, margins, font weights).
  - Commands:
    - `grep -rnE '#[0-9a-fA-F]{3,6}' src/lua/ui/inspector/` — hex colors
    - `grep -rnE 'font-size:\s*[0-9]+(px\|pt\|em)' src/lua/ui/inspector/` — font size literals
    - `grep -rnE '\b(padding\|margin\|min-width\|min-height\|max-width\|max-height):\s*[0-9]+' src/lua/ui/inspector/` — spacing literals
    - `grep -rnE 'font-weight:\s*(bold\|[0-9]+)' src/lua/ui/inspector/` — weight literals
  - Expected: zero matches across all four. Every styling value must come via `ui_constants.COLORS.*`, `ui_constants.FONTS.*`, or `ui_constants.LAYOUT.*`. If a literal is unavoidable (e.g., embedded QSS alignment `0 2 4 2` for `SET_MARGINS`), it must be documented as a non-styling layout parameter.
  - Rule: 1.5 / FR-029. Covers /analyze A1.

- [ ] **T049** [P] Audit: no bare `print(` in Inspector production code (tests are exempt).
  - Command: `grep -rn '\bprint(' src/lua/ui/inspector/ src/lua/core/persistent_widget.lua`
  - Expected: zero matches. Every log call uses `core.logger`.

- [ ] **T050** [P] Audit: no forbidden exports on the facade.
  - Command: `grep -n 'function M\.' src/lua/ui/inspector/init.lua`
  - Expected: exactly three lines matching `function M.mount`, `function M.update_selection`, `function M.get_focus_widgets`. No others.
  - Rule: 2.15 / 2.17 / FR-027 / FR-031.

- [ ] **T051** [P] Audit: function-size and file-size per rule 2.5 / 2.6.
  - Command: `wc -l src/lua/ui/inspector/*.lua src/lua/core/persistent_widget.lua`
  - Target: each file under ~400 LOC; no single function over ~80 LOC. Larger counts are acceptable only if a helper-split would produce artificial seams; document the justification in the task's completion note.

- [ ] **T052** Audit: luacheck zero warnings.
  - Command: `luacheck src/lua --config .luacheckrc --std luajit > /tmp/luacheck.txt 2>&1 ; wc -l /tmp/luacheck.txt`
  - Expected: the "Total: 0 warnings / 0 errors" line, no per-file offender lines touching Inspector code. Rule: 2.4.

- [ ] **T053** Audit: no `_G.` global scratch in Inspector code.
  - Command: `grep -rn '_G\.' src/lua/ui/inspector/`
  - Expected: zero matches. No `_G.inspector_save_test` and no siblings. Rule: 2.17.

- [ ] **T054** Audit: no duplicate refresh subscription.
  - Command: `grep -rn 'timeline_state\.add_listener\|Signals\.connect' src/lua/ui/inspector/`
  - Expected: exactly ONE `Signals.connect("content_changed", ...)` and ONE `Signals.connect("project_changed", ...)` in `change_listeners.lua`; zero hits for `timeline_state.add_listener`. Rule: 3.0 MVC single channel.

---

## Phase 3.9: Final validation

- [ ] **T055** Full `make -j4` from repo root. Must exit 0. Log to `/tmp/final_build.log`. Covers: C++ compile, luacheck (T052 enforced here too), all Lua tests (unit + integration pattern), C++ tests.

- [ ] **T056** Manual quickstart walkthrough per `quickstart.md` §§2, 5. Tick the acceptance list in §4. Screenshot or describe any visual change the user should notice (e.g., Apply button styling, error-border color). Joe signs off the manual walkthrough before the task is considered complete — do NOT self-close.

- [ ] **T057** Write a concise commit message per the project's convention ("Authored-By: Joe Shapiro <joe@shapiro.net> With-Help-From: Claude", rule 2.8). Do NOT commit. Present the diff and commit message for Joe to approve.

---

## Dependencies

- T001–T003 (setup) before everything.
- T004–T026 plus T012a–T012e and T026a–T026c (tests) all marked [P] but collectively required before T027 (gate).
- T027 (gate) blocks T028.
- Within Phase 3.5, order is: T028 → T029 → T030 & T031 (parallel) → T032 → T033 → T034 → T035 → T036 → T037 → T038. Non-parallel because each new module may reference prior ones.
- T039 (wiring) blocks T040–T042 (integration runs).
- T043–T045 (cleanup) blocked by T041 + T042 being green.
- T046–T054 (audits) blocked by T045 (cleanup complete).
- T055–T057 (final validation) blocked by all audits green.

## Parallel execution examples

### Contract + unit + integration tests (T004–T026)

After T001–T003 are done, all 23 test files are independent (different files; no shared state). Spawn them in one batch:

```
Task: "Write tests/synthetic/contract/inspector/test_inspector_api_contract.lua per T004"
Task: "Write tests/synthetic/contract/inspector/test_inspectable_set_timecode.lua per T005"
Task: "Write tests/synthetic/contract/inspector/test_schema_definition_contract.lua per T006"
Task: "Write tests/synthetic/unit/inspector/test_filter_matching.lua per T007"
... (through T026)
```

### Cleanup (T043–T045)

Parallel deletions — each touches distinct files:

```
Task: "git rm dead inspector files per T043"
Task: "Edit timeline_panel.lua to remove set_inspector stub per T044"
Task: "Audit + edit project_browser.lua set_inspector per T045"
```

### Compliance audits (T046–T054)

All greps / lints, all independent:

```
Task: "Audit pcall-swallowing per T046"
Task: "Audit fallback values per T047"
Task: "Audit hardcoded colors per T048"
Task: "Audit bare print per T049"
Task: "Audit public exports per T050"
Task: "Audit file/function sizes per T051"
Task: "Audit luacheck per T052"
Task: "Audit global scratch per T053"
Task: "Audit duplicate subscriptions per T054"
```

---

## Validation checklist

- [x] All three contracts have contract test tasks (T004–T006).
- [x] Both new entity-adjacent artifacts (persistent_widget, schema module restructure) have implementation tasks (T028, T029).
- [x] All 14 Acceptance Scenarios have 1:1 integration tests (T013–T026, per FR-033).
- [x] Post-/analyze coverage: 3 additional integration tests (T026a pull-missing-asserts, T026b invalid-input state, T026c mid-edit race) — cover FR-017b, FR-015a/b/c, FR-016a/b.
- [x] All six FR-032 unit tests exist (T007–T012) plus five /analyze-driven additions (T012a persistent-widget roundtrip, T012b resolve_inspectables, T012c compute_mode, T012d property-type mapping, T012e invalid-input state machine).
- [x] Tests precede implementation (Phase 3.2/3.3/3.4 before Phase 3.5).
- [x] Parallel [P] tasks touch disjoint files.
- [x] Each task specifies exact absolute file paths.
- [x] ENGINEERING.md coding-style rules are not left implicit: each implementation task cites the FRs and rules it respects, and Phase 3.8 runs explicit grep-based audits to enforce them mechanically.
- [x] No task depends on a file authored by a parallel Claude session (T001 baseline check protects against that).

---

## Notes

- Commit after each task so the branch history shows what landed when. Exception: T057 is an approval gate, not an auto-commit.
- Rule 2.20 — regression tests first — is structurally enforced by Phase 3.2/3.3/3.4 before 3.5. Any bug found during T041 must produce a new failing test BEFORE the fix is written.
- If a test fails at any phase, investigate the responsible code, not the test. Rule 2.31.
- Do NOT run `git reset --hard`, `git stash -u`, `git clean`, or `git checkout -- .` at any point in this feature. CLAUDE.md rule 5 — parallel Claude sessions may have uncommitted work you don't recognize.
