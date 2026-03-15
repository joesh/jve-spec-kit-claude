# Tasks: RelinkClips

**Input**: Design documents from `specs/002-relink-clips/`
**Prerequisites**: plan.md, research.md, data-model.md, contracts/

## Phase 3.1: Model Accessors

- [x] T001 [P] Add `Media:get_start_tc()` accessor in `src/lua/models/media.lua` — parses `metadata` JSON, returns `(value, rate)` or `(nil, nil)`. Add test in `tests/test_media_start_tc.lua`: create media with metadata containing start_tc_value/start_tc_rate, verify accessor returns correct values. Verify nil return when metadata is empty or missing start_tc fields.

- [x] T002 [P] Add `Clip.find_clips_for_media(media_id)` in `src/lua/models/clip.lua` — returns all clips (master + timeline) referencing a media_id. Add `Clip:set_source_range(source_in, source_out)` — updates both fields + saves. Add test in `tests/test_clip_for_media.lua`: create media + master clip + 2 timeline clips, verify find returns all 3. Verify set_source_range persists correctly.

## Phase 3.2: Pure Algorithm Tests (TDD) — MUST FAIL before 3.3

- [ ] T003 [P] TC offset math test in `tests/test_tc_offset.lua`. Test `compute_tc_offset(stored_value, stored_rate, candidate_value, candidate_rate)` — same TC → offset 0, different TC → correct offset, cross-rate comparison (25fps stored vs 48000Hz BWF). Test `adjust_source_range(source_in, source_out, offset, clip_rate)` — zero offset → unchanged, positive offset → shifted, negative result → returns nil (out of range).

- [ ] T004 [P] Segment filename matching test in `tests/test_segment_matching.lua`. Test basename extraction with suffix variants: `A026_C007.mov` matches `A026_C007_001.mov`, `A026_C007_002.mov`. Case-insensitive. Non-matching suffixes rejected (`A026_C007_extra.mov`). Only when `accept_filename_suffixes` enabled.

- [ ] T005 [P] Candidate filtering test in `tests/test_candidate_filtering.lua`. Test `find_candidates_for_clip(clip_info, candidates_index, matching_rules)` with various rule combinations: filename-only, TC-only, filename+TC, filename+resolution. Verify candidates that fail any enabled criterion are rejected. Verify TC containment check (clip's absolute TC range must fall within candidate's range).

## Phase 3.3: Core Algorithm Implementation

- [ ] T006 Implement `compute_tc_offset` and `adjust_source_range` in `src/lua/core/media_relinker.lua`. Pure functions, no DB access. Make T003 tests pass.

- [ ] T007 Implement `find_candidates_for_clip` in `src/lua/core/media_relinker.lua`. Takes clip info + candidate index + matching rules. Probes candidate TC via existing `probe_start_tc`. Checks containment of clip's absolute TC range. Filters by resolution/fps if enabled. Returns array of passing candidates. Make T005 tests pass.

- [ ] T008 Implement `relink_clips_batch` in `src/lua/core/media_relinker.lua`. Replaces `batch_relink`. Takes array of clip info structs + options + progress_cb. Scans search dirs → builds candidate index. For each clip: finds candidates, filters, handles TC offset if Accept Trimmed Media enabled, handles segment matching if Accept Filename Suffixes enabled. Returns `{relinked, failed, ambiguous, new_media}`. Make T004 segment tests pass. Integrate T006/T007.

## Phase 3.4: Matching Rules Dialog + Persistence

- [ ] T009 Create `src/lua/ui/matching_rules_dialog.lua` — blocking modal with checkboxes for match criteria (Filename, Timecode, Resolution, Frame Rate) and options (Accept Trimmed Media, Accept Filename Suffixes). Uses `qt_constants` API (same patterns as `new_project.lua`). Returns updated rules table or nil on cancel. Validates at least one of Filename or Timecode is checked.

- [ ] T010 [P] Test matching rules persistence in `tests/test_matching_rules.lua`. Save rules via `database.set_project_setting(pid, "relink_matching_rules", rules)`. Load and verify. Test default values when key doesn't exist. Test new project inherits from previous project's settings.

## Phase 3.5: RelinkClips Command

- [ ] T011 Create `src/lua/core/commands/relink_clips.lua` — `RelinkClips` executor receives `clip_relink_map`, `media_path_changes`, `new_media_records`, `project_id`. Persists `old_clip_state` and `old_media_paths` for undo. Updates clips via `Clip.load` + `set_source_range` + reassign `media_id`. Updates media paths via `Media.set_file_path` in `begin_batch`/`end_batch`. Creates new media records for segments. Undoer reverses all: restores clip state, restores media paths, deletes new media records.

- [ ] T012 [P] Test RelinkClips undo in `tests/test_relink_clips_undo.lua`. Create project with media + clips. Execute RelinkClips with path change + source_in adjustment. Verify clips updated. Undo. Verify clips restored to original state. Verify media paths restored. If new media records were created, verify they're deleted on undo.

## Phase 3.6: Dialog Updates

- [ ] T013 Update `src/lua/ui/media_relink_dialog.lua` — show clip list (not media list) with status icons (check/x). Add "Matching Rules..." button → opens `matching_rules_dialog`. Load/save rules via project settings. Pass clip info structs to `relink_clips_batch`. Handle ambiguous results (prompt user to choose). Two-phase button: Relink → Apply.

- [ ] T014 Update `src/lua/core/commands/show_relink_dialog.lua` — gather offline clips (not just media). Support browser selection scope (if clips selected in browser, only those). Dispatch `RelinkClips` instead of `RelinkMedia`. Pass ambiguity resolution results.

## Phase 3.7: Integration + Cleanup

- [ ] T015 Register `relink_clips` in `src/lua/core/command_implementations.lua` (replace `relink_media`). Update `src/lua/core/command_registry.lua` to remove old aliases. Delete `src/lua/core/commands/relink_media.lua`.

- [ ] T016 Integration test in `tests/test_relink_clips_integration.lua`. Import a DRP project (using existing test fixtures). Verify media records have `start_tc` in metadata. Simulate offline by pointing media at nonexistent paths. Run `relink_clips_batch` with a search directory containing test fixtures. Verify clips reconnect with correct source_in/source_out. Verify undo restores everything.

- [ ] T017 `make -j4` — verify 0 luacheck warnings, all Lua tests pass, all C++ tests pass, all binding tests pass, all integration tests pass. Fix any regressions from RelinkMedia removal.

## Dependencies

```
T001, T002 — model accessors (independent, parallel)
T003, T004, T005 — TDD tests (independent, parallel, MUST FAIL)
T006 ← T003 (make TC offset tests pass)
T007 ← T005 (make candidate filtering tests pass)
T008 ← T004, T006, T007 (integrates all algorithm pieces)
T009 — UI (independent of algorithm)
T010 — persistence test (independent)
T011 ← T001, T002, T008 (command uses model accessors + relinker)
T012 ← T011 (tests the command)
T013 ← T009, T011 (dialog uses matching rules + command)
T014 ← T013 (show_relink_dialog dispatches through dialog)
T015 ← T011 (registration requires command to exist)
T016 ← T015 (integration test needs full system wired)
T017 ← all (final verification)
```

## Parallel Execution Examples

```
# Phase 3.1 — model accessors (2 tasks, different files):
T001: "Add Media:get_start_tc() accessor + test"
T002: "Add Clip.find_clips_for_media() + set_source_range() + test"

# Phase 3.2 — TDD tests (3 tasks, different files):
T003: "TC offset math test in tests/test_tc_offset.lua"
T004: "Segment filename matching test in tests/test_segment_matching.lua"
T005: "Candidate filtering test in tests/test_candidate_filtering.lua"

# Phase 3.5 — command + test (after T011 done):
T012: "Test RelinkClips undo in tests/test_relink_clips_undo.lua"
T010: "Test matching rules persistence in tests/test_matching_rules.lua"
```

## Validation Checklist

- [x] Contract (relink_clips_batch) has corresponding test (T005, T008)
- [x] All entities have model tasks (T001 Media accessor, T002 Clip accessor)
- [x] All tests come before implementation (T003-T005 before T006-T008)
- [x] Parallel tasks truly independent (different files, no shared state)
- [x] Each task specifies exact file path
- [x] No [P] task modifies same file as another [P] task
