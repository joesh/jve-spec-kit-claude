# Tasks: Find, Sift, Find & Replace, and Timeline Search

**Input**: Design documents from `/specs/003-find-sift-find/`
**Prerequisites**: plan.md, research.md, data-model.md, contracts/commands.md, quickstart.md

## Phase 3.1: Setup

- [x] T001 Update `keymaps/default.jvekeys`: Move GoToTimecode from `Cmd+G` to `Ctrl+G`. Add `Cmd+F` = `Find @project_browser`, `Cmd+F` = `Find @timeline`, `Cmd+H` = `FindReplace @project_browser`, `Cmd+H` = `FindReplace @timeline`, `Cmd+G` = `FindNext @project_browser @timeline`, `Cmd+Shift+G` = `FindPrevious @project_browser @timeline`, `Cmd+Shift+F` = `Sift @project_browser`. Verify `make -j4` passes (keybinding parsing).

- [x] T002 Add `smart_bins` table to `src/lua/schema.sql`: `CREATE TABLE IF NOT EXISTS smart_bins (id TEXT PRIMARY KEY, project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE, name TEXT NOT NULL CHECK(length(name) > 0), scope_bin_id TEXT REFERENCES tags(id) ON DELETE SET NULL, criteria_json TEXT NOT NULL DEFAULT '[]', created_at INTEGER NOT NULL, modified_at INTEGER NOT NULL)` with index on `project_id`. Bump `SCHEMA_VERSION` comment only (no migration gate change). Run `make -j4`.

## Phase 3.2: Tests First (TDD) — MUST COMPLETE BEFORE 3.3

### Foundation: Query Engine Tests
- [x] T003 Write `tests/test_query_engine.lua`: Test `match()` for all operators (contains, begins_with, ends_with, matches_exactly for text; equals, greater_than, less_than for numeric). Test case-insensitivity. Test custom property search (Scene, Take). Test `match_all()` AND logic. Test `filter()` returns {matching, non_matching}. Test `get_searchable_fields()` returns correct registry. Use non-trivial data: mixed codecs, varied fps (24/25/30), clip names with substrings that could false-match. See quickstart.md tests 1.1-1.10. All tests must FAIL (module doesn't exist yet). Run with `cd tests && luajit test_harness.lua test_query_engine.lua` — expect failures.

### State Management Tests
- [x] T004 [P] Write `tests/test_sift_state.lua`: Test sift_state module — `apply_sift()` computes hidden_ids from criteria + clips. `expand_sift()` adds OR criterion (shows more). `narrow_sift()` adds AND criterion (shows fewer). `clear_sift()` resets all. Test persistence: `to_json()` / `from_json()` round-trip. Test re-evaluation when clips change (new clip added matches/doesn't match). Test empty sift (no clips match), full sift (all match). Use 10+ clips with varied attributes. Must FAIL.

- [x] T005 [P] Write `tests/test_smart_bin.lua`: Test smart_bin model — `create()` inserts into smart_bins table. `find_by_project()` returns all smart bins for a project. `update()` modifies criteria/name/scope. `delete()` removes. `evaluate()` applies criteria via query_engine and returns matching clip IDs. Test scope: project-wide (scope_bin_id=NULL) vs scoped to specific bin. Test dynamic update: after clip property change, re-evaluate shows updated membership. Must FAIL.

### Command Tests
- [x] T006 [P] Write `tests/test_find_commands.lua`: Test FindClips command — creates 10 clips with varied names, executes FindClips with column="name", operator="contains", value="INT". Assert correct clip_ids returned. Test scope="visible" with sift active (should only search non-hidden clips). Test scope="all" searches everything. Test FindNext direction="forward" cycles through matches, wraps at end. Test FindPrevious wraps at beginning. Test no-match returns empty. Must FAIL.

- [x] T007 [P] Write `tests/test_sift_commands.lua`: Test Sift command with mode="fresh" — hides non-matching clips. Test ExpandSift (mode="expand") — shows additional matches. Test NarrowSift (mode="narrow") — hides within visible set. Test ClearSift — restores all. Test that sift criteria persist to project settings and survive save/load cycle. Must FAIL.

- [x] T008 [P] Write `tests/test_replace_commands.lua`: Test ReplaceClipProperty — single clip replacement + undo restores previous value. Test ReplaceAllClipProperties — batch replace 5 clips, all changed. Undo restores all 5. Test with custom property (Scene). Test Replace on read-only-excluded field is rejected. Test no-match returns 0 affected. Must FAIL.

- [x] T009 Write `tests/test_timeline_find.lua`: Test FindClips with context="timeline" — creates timeline with 15 clips across 3 tracks. FindClips returns matches sorted by timeline_start (cross-track). FindNext advances in timeline order. Test no active sequence returns error. Must FAIL.

## Phase 3.3: Core Implementation (ONLY after tests are failing)

### Foundation Layer
- [x] T010 Implement `src/lua/core/query_engine.lua`: Pure-function module, zero dependencies beyond Lua stdlib. Functions: `match(clip_data, query)`, `match_all(clip_data, queries)`, `filter(clips, queries)`, `get_searchable_fields()`. Searchable fields registry per data-model.md (name, enabled, codec, fps, duration, resolution, volume, audio_channels, audio_sample_rate, date_modified, plus custom properties). Text matching: case-insensitive via `string.lower()`. Numeric matching: `tonumber()` conversion. Custom property lookup: `clip_data.properties[column]`. Run `cd tests && luajit test_harness.lua test_query_engine.lua` — all tests must PASS. Then `make -j4` for luacheck.

### State Management Layer
- [x] T011 [P] Implement `src/lua/core/sift_state.lua`: Module managing sift filter state. Functions: `apply_sift(clips, query)` — set fresh criteria, compute hidden_ids. `expand_sift(clips, query)` — add OR criterion. `narrow_sift(clips, query)` — add AND criterion. `clear_sift()` — reset. `is_active()` — boolean. `get_criteria()` — return criteria array. `to_json()` / `from_json()` — serialize for project settings persistence. `evaluate(clips)` — re-evaluate current criteria against clip set, return {visible_ids, hidden_ids}. Uses query_engine internally. Run test_sift_state.lua — PASS. `make -j4`.

- [x] T012 [P] Implement `src/lua/core/smart_bin.lua`: Model for smart_bins table CRUD. Functions: `create(db, project_id, name, criteria_json, scope_bin_id)`, `find_by_project(db, project_id)`, `find_by_id(db, id)`, `update(db, id, fields)`, `delete(db, id)`, `evaluate(db, smart_bin, clips)` — apply criteria via query_engine. Table is in schema.sql — assert it exists, no fallback creation. Run test_smart_bin.lua — PASS. `make -j4`.

### Command Layer
- [x] T013 [P] Implement `src/lua/core/find_state.lua` (find session state management): Register FindClips and FindNext commands. FindClips: gather clips from context (browser: project_browser.get_all_items() or sifted subset; timeline: timeline_state.get_clips()). Apply query_engine.filter(). Store matches + current_index in module-level find_state. Select matching clips (browser: select_browser_items; timeline: set_selection + move playhead). FindNext: increment/decrement current_index (wrap), update selection + scroll. FindPrevious: same with direction="backward". Non-undoable. Run test_find_commands.lua — PASS. `make -j4`.

- [x] T014 [P] Implement `src/lua/core/sift_commands.lua` (sift operations + persistence): Register Sift, ExpandSift, NarrowSift, ClearSift commands. Sift: use sift_state.apply_sift() with mode param. Persist criteria to project settings via `db.set_project_settings()`. Trigger project_browser refresh (signal or direct call). ExpandSift/NarrowSift: convenience wrappers calling Sift with mode="expand"/"narrow". ClearSift: call sift_state.clear_sift(), persist, refresh. Non-undoable. Run test_sift_commands.lua — PASS. `make -j4`.

- [x] T015 [P] Implement `src/lua/core/commands/replace_clip_property.lua`: Register ReplaceClipProperty (undoable, single clip) and ReplaceAllClipProperties (undoable, batch). ReplaceClipProperty: read current value (from clip.name or properties table depending on column), capture in `previous_value`, apply string.gsub replacement, write via existing SetClipProperty pattern or direct DB update. Undo: restore previous_value. ReplaceAll: loop over clip_ids, capture all previous values in `previous_values` array, apply replacements. Undo: restore all. Run test_replace_commands.lua — PASS. `make -j4`.

- [x] T016 [P] Implement `src/lua/core/commands/smart_bin_commands.lua`: Register CreateSmartBin (undoable), UpdateSmartBin (undoable), DeleteSmartBin (undoable). Create: call smart_bin.create(), capture smart_bin_id for undo (DELETE). Update: capture previous state for undo. Delete: capture full record for undo (re-INSERT). Emit signal for browser refresh. Run test_smart_bin.lua smart bin command tests — PASS. `make -j4`.

- [x] T017 Implement timeline find support (find_state handles timeline ordering) in `src/lua/core/commands/find_clips.lua` (extend existing): Add timeline context handling — when context="timeline", get clips from timeline_state.get_clips(), sort matches by timeline_start_frame, move playhead via timeline_state viewport, select clip. Ensure FindNext in timeline also moves playhead. Run test_timeline_find.lua — PASS. `make -j4`.

## Phase 3.4: UI Integration

- [x] T018 Implement `src/lua/ui/find_dialog.lua`: Modal dialog launched by Find command. Widgets: attribute dropdown (searchable via regex per spec scenario 1.5), operator dropdown, search text field, scope selector ("Visible (Sifted)" / "All Clips"), Find/Find Next/Find Previous/Close buttons, "Find & Replace" expand button (FR-011b). On search: execute FindClips command. On Find Next/Prev: execute FindNext. On Escape: restore previous selection (FR-016). Persist dialog settings to `~/.jve/` (FR-025b). Works in both browser and timeline contexts (check focus_manager for current panel). `make -j4`.

- [x] T019 [P] Implement `src/lua/ui/sift_dialog.lua`: Modal dialog launched by Sift command. Same attribute/operator/value widgets as find_dialog. When sift is active, show three action buttons: "Sift" (fresh), "Expand Sift", "Narrow Sift", plus "Clear Sift". When no sift active, show only "Sift" button. Execute corresponding Sift command on button click. Persist dialog settings. `make -j4`.

- [x] T020 [P] Implement `src/lua/ui/find_replace_dialog.lua`: Dialog with find field + replace field + column selector (editable columns only per FR-052) + scope selector ("Selected Clips" / "All Visible") + Replace / Replace All / Skip / Close buttons. Replace: execute ReplaceClipProperty, advance to next match. Replace All: execute ReplaceAllClipProperties. Skip: advance FindNext without replacing. Works in browser and timeline contexts. Persist settings. `make -j4`.

- [x] T021 [P] Implement `src/lua/ui/smart_bin_dialog.lua`: Dialog for creating/editing Smart Bins. Widgets: name field, scope selector ("Entire Project" / specific bin dropdown), criteria rows (add/remove rows, each with column + operator + value). On OK: execute CreateSmartBin or UpdateSmartBin command. `make -j4`.

- [x] T022 [P] Implement `src/lua/ui/timeline_index.lua`: Floating dialog (FR-040) with sortable table widget. Columns: #, Clip Name, Track, Source In, Source Out, Record In, Record Out, Duration (customizable via right-click, scenario 17). Filter bar at top with column + operator selectors (scenario 18). Click row → move playhead + select clip (FR-043). Keyboard: arrows move rows, Shift+arrow extends selection, Cmd+click toggles (scenario 20). Column header click sorts asc/desc (FR-044). Subscribe to timeline change signals to keep list updated (FR-045). `make -j4`.

## Phase 3.5: Browser & Menu Integration

- [ ] T023 Implement sift indicator in project browser: When sift_state.is_active(), display "(Sifted)" in browser header (FR-022). On project_browser.populate(), filter items through sift_state — hide items whose clip_id is in hidden_ids. On new media import, re-evaluate sift and show/hide accordingly (FR-027). Load sift criteria from project settings on project open. File: `src/lua/ui/project_browser.lua` (modify existing). `make -j4`.

- [ ] T024 Integrate Smart Bins into project browser tree: When populating browser, query smart_bin.find_by_project() and add Smart Bin nodes with distinct icon (FR-062). Clicking a Smart Bin evaluates its criteria and shows matching clips. Double-click on a clip in Smart Bin behaves normally (FR-063). Right-click on Smart Bin: Edit..., Delete. File: `src/lua/ui/project_browser.lua` (modify existing). `make -j4`.

- [ ] T025 Add menu items: Edit menu: Find... (Cmd+F), Find Next (Cmd+G), Find Previous (Cmd+Shift+G), Find and Replace... (Cmd+H), separator, Sift... (Cmd+Shift+F), Expand Sift..., Narrow Sift..., Clear Sift, separator, Timeline Index... View menu or context menu: New Smart Bin... Enable/disable menu items based on context (e.g., Expand/Narrow/Clear only when sift active, Find Next only when find active). File: modify `menus.xml` and `src/lua/core/menu_system.lua` as needed. `make -j4`.

- [ ] T026 Wire keyboard shortcuts: Ensure command_registry auto-loads the new command files. Verify Cmd+F dispatches to Find in correct context (browser vs timeline based on focus). Verify Cmd+G/Cmd+Shift+G work for Find Next/Previous. Verify Cmd+Shift+F opens Sift dialog. Verify Ctrl+G still works for GoToTimecode. End-to-end smoke test via `--test` mode. `make -j4`.

## Phase 3.6: Polish & Validation

- [ ] T027 [P] Run full quickstart validation: Execute all 35 scenarios from `quickstart.md` via `--test` mode scripts. Document any failures, fix, re-run. Ensure all 7 categories pass (query engine, bin find, bin sift, timeline find, timeline index, find & replace, smart bins).

- [ ] T028 [P] Run `make -j4` full validation: All existing tests pass (no regressions). Zero luacheck warnings on new files. All new test files pass.

- [ ] T029 Performance validation: Create test project with 1000+ clips (generate via test script). Measure query_engine.filter() time — must be <100ms. Measure sift apply time. Measure Smart Bin evaluate time. If any exceed target, optimize (index-based lookup, precomputed values).

## Dependencies
```
T001 (keybindings) ─── no deps, can start immediately
T002 (schema) ─────── no deps, can start immediately
T003 (query tests) ── no deps
T004-T009 (tests) ─── no deps (TDD: tests written before code)
T010 (query engine) ── depends on T003
T011, T012 ────────── depend on T010 [P with each other]
T013-T016 ─────────── depend on T010, T011/T012 as needed [P with each other]
T017 ──────────────── depends on T013
T018-T022 ─────────── depend on T013-T016 [P with each other]
T023, T024 ────────── depend on T011, T012, T014, T016
T025 ──────────────── depends on T013-T016
T026 ──────────────── depends on T001, T025
T027-T029 ─────────── depend on all above
```

## Parallel Execution Examples

```
# Phase 3.2 — All test files are independent, launch together:
T003: test_query_engine.lua
T004: test_sift_state.lua
T005: test_smart_bin.lua
T006: test_find_commands.lua
T007: test_sift_commands.lua
T008: test_replace_commands.lua
T009: test_timeline_find.lua

# Phase 3.3 — After T010, state + command layers are independent:
T011: sift_state.lua
T012: smart_bin.lua
T013: find_clips.lua
T014: sift.lua
T015: replace_clip_property.lua
T016: smart_bin_commands.lua

# Phase 3.4 — All dialogs are independent files:
T018: find_dialog.lua
T019: sift_dialog.lua
T020: find_replace_dialog.lua
T021: smart_bin_dialog.lua
T022: timeline_index.lua
```

## Validation Checklist
- [x] All commands have corresponding tests (T003-T009 cover all commands)
- [x] All entities have model tasks (query_engine T010, sift_state T011, smart_bin T012)
- [x] All tests come before implementation (Phase 3.2 before 3.3)
- [x] Parallel tasks truly independent (different files, no shared state)
- [x] Each task specifies exact file path
- [x] No task modifies same file as another [P] task
