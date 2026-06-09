# Tasks: Gap-as-Clip Refactor

**Input**: Design documents from `/specs/005-gap-as-clip-refactor/`
**Prerequisites**: plan.md, research.md, data-model.md, quickstart.md

## Phase 3.1: Setup & Foundation

- [X] T001 Create `src/lua/core/gap_lifecycle.lua` with module skeleton and header doc. Functions: `compute_gaps_for_track(track_id, sorted_media_clips, seq_fps) → gap_clips[]`, `update_gaps_after_edit(track_id, sorted_all_clips, changed_clip_ids, seq_fps) → updated_clips[]`, `create_implied_gap(track_id, position, seq_fps) → gap_clip`. No implementation yet — just the interface returning empty tables.

- [X] T002 Snapshot current test suite baseline. Run `make -j4` and record pass count. This is the regression reference — all existing tests must continue to pass after each subsequent task.

## Phase 3.2: Tests First (TDD)

- [X] T003 [P] Write `tests/test_gap_lifecycle_compute.lua`: test `compute_gaps_for_track`. Scenarios: (a) empty track → no gaps, (b) single clip not at 0 → gap before clip, (c) two clips with space → gap between them, (d) two adjacent clips → no gap between them, (e) three clips with two gaps → two gap clips returned, (f) clip at position 0 → no leading gap. Verify gap clip fields: id, track_id, timeline_start, duration, clip_kind="gap", media_id=nil. All tests must FAIL (no implementation).

- [X] T004 [P] Write `tests/test_gap_lifecycle_update.lua`: test `update_gaps_after_edit`. Scenarios: (a) clip trimmed shorter → gap grows, (b) clip trimmed longer → gap shrinks, (c) gap shrinks to zero → gap deleted, (d) clip deleted → adjacent gaps merge, (e) clip inserted in gap → gap splits into two, (f) clip inserted consuming entire gap → gap deleted. All tests must FAIL.

- [X] T005 [P] Write `tests/test_gap_lifecycle_implied.lua`: test `create_implied_gap`. Scenarios: (a) position between two adjacent clips → zero-length gap created, (b) position at start of track with clip at 0 → zero-length gap at 0, (c) position in existing gap → returns nil or existing gap (no duplicate). All tests must FAIL.

- [X] T006 Write `tests/test_gap_clip_roll.lua`: test that a clip-gap roll using BatchRippleEdit (with gap as a real clip in the track list) produces correct results. Scenarios: (a) roll right into gap → clip extends, gap shrinks, downstream stays, (b) roll left → clip shrinks, gap grows, downstream stays, (c) roll to consume entire gap → gap deleted, clips adjacent. Use ripple_layout helper with gap clips manually inserted into the track. Tests must FAIL.

- [X] T007 Write `tests/test_gap_clip_ripple.lua`: test multitrack ripple with gap clips in track list. Scenarios: (a) ripple shrink on V1 with gap on A1 → gap absorbs shift on A1, (b) ripple shrink on V1 with no gap on A1 (adjacent clips) → operation blocked, (c) ripple extend on V1 → implied zero-length gap created on A1, downstream shifts. Tests must FAIL.

## Phase 3.3: Core Implementation

- [X] T008 Implement `compute_gaps_for_track` in `src/lua/core/gap_lifecycle.lua`. Scan sorted media clips, create gap clips for each empty space (including before first clip if it doesn't start at 0). Return sorted list of gap clips. Verify T003 passes.

- [X] T009 Implement `update_gaps_after_edit` in `src/lua/core/gap_lifecycle.lua`. Given sorted clip list (media + existing gaps) and set of changed clip IDs, recompute gaps locally: find the changed clips' neighbors, recompute gap geometry for those positions only. Handle merge (two gaps adjacent after clip delete), split (clip inserted in gap), resize (clip trimmed), and delete (gap at zero). Verify T004 passes.

- [X] T010 Implement `create_implied_gap` in `src/lua/core/gap_lifecycle.lua`. Create a zero-length gap clip at the given position on the given track. Used by multitrack ripple when clips are adjacent and no gap exists. Verify T005 passes.

- [X] T011 Wire gap computation into timeline_state sequence open. When a sequence is loaded (`timeline_state.init` or `reload_clips`), call `compute_gaps_for_track` for each track and merge gap clips into the track's clip list. Gaps must be visible to `get_clip_by_id`, track clip iteration, and neighbor bounds. Run `make -j4` — existing tests may need minor adjustments for gap clips appearing in clip lists.

- [X] T012 Modify `edge_picker.lua`: remove `gap_before`/`gap_after` edge type creation. At a clip-gap boundary, the edge picker now finds the gap clip in the track list and selects `{clip:out, gap:in}`. At a gap-clip boundary, selects `{gap:out, clip:in}`. Remove the "Gap after this clip" / "Gap before this clip" fallback paths in `select_boundary_edges` and `build_boundaries`. The gap is a real clip — find it by position.

- [X] T013 Modify `edge_utils.lua`: remove `to_bracket` mappings for `gap_before`→`"out"` and `gap_after`→`"in"`. These edge types no longer exist. Gaps use `in`/`out` like any clip.

- [X] T014 Modify `batch_ripple_edit.lua` — remove `materialize_gap_edges` function and its call in the pipeline. Edge infos now reference gap clips directly (from edge_picker). The gap clip is already in `ctx.clip_lookup` (from build_clip_cache, which loads from timeline_state including gaps). Remove from `pipeline.lua` as well.

- [X] T015 Modify `batch_ripple_edit.lua` — remove `propagate_gap_offsets`, `move_gap_right_clip`, `compute_gap_shift_value`, `snapshot_clip_for_gap` (gap propagation). Gap clips are processed by `apply_edge_ripple` like any clip. Roll mechanics handle the gap's neighbor naturally. Remove the call to `propagate_gap_offsets` from `process_edge_trims`.

- [X] T016 Modify `batch_ripple_edit.lua` — remove gap-roll special path in `apply_edge_ripple`. The `if is_gap and trim_type == "roll"` branch is deleted. Gaps use the same `"in"` and `"out"` paths as media clips. For "in" roll: `timeline_start += delta, duration -= delta`. For "out": `duration += delta`. Same as clips.

- [X] T017 Modify `batch_ripple_edit.lua` — remove `apply_gap_limits`, `compute_gap_close_constraint`, `clamp_gap_to_origin`. Gap constraints are handled by existing clip constraint functions (`apply_min_duration_limits` for min=0, `apply_roll_constraints` for neighbor bounds). Remove `is_gap_edge()` checks from `compute_constraints`, `analyze_selection`, `compute_applied_delta`, and `build_planned_mutations`.

- [X] T018 Replace `inject_implicit_gap_edges` with `create_implied_gap` call. When multitrack ripple needs an edge on a track where clips are adjacent (no gap), call `gap_lifecycle.create_implied_gap` to create a real zero-length gap clip at that boundary. Insert it into the track's clip list and ctx. The rest of the pipeline treats it as a normal clip. Remove the old `inject_implicit_gap_edges` function.

- [X] T019 Modify `build_planned_mutations` in `batch_ripple_edit.lua`: remove `is_temp_gap` filtering. Gap clips are in `modified_clips` but not persisted — filter by `clip_kind == "gap"` (or absence of media_id) when building DB mutations. Gap changes are reflected in-memory only.

- [X] T020 Verify T006 (clip-gap roll) and T007 (multitrack ripple with gaps) pass. Run full `make -j4`. Fix any regressions.

## Phase 3.4: Integration & Cleanup

- [X] T021 Wire gap update into command post-execution. After any command that modifies clips (BatchRippleEdit, Insert, Overwrite, Delete, RippleDelete, SplitClip, etc.), call `update_gaps_after_edit` on affected tracks. This must happen after mutations are applied but before UI refresh. Verify gaps stay in sync after edits and undos.

- [X] T022 [P] Update `tests/synthetic/helpers/ripple_layout.lua` and `tests/synthetic/helpers/ripple_test_runner.lua`: when creating test layouts, compute gaps for each track and include them in the clip list. This ensures all tests that use these helpers work with the new gap-as-clip model.

- [X] T023 [P] Update existing gap tests (`test_batch_ripple_gap_*.lua`, `test_gap_*.lua`, `test_timeline_*gap*.lua`) to use new gap model. Replace `gap_before`/`gap_after` edge types with `in`/`out` on gap clips. Replace `is_temp_gap` checks with `clip_kind == "gap"` checks. Remove references to `materialize_gap_edges`, `create_temp_gap_clip`.

- [X] T024 Remove dead code: delete `create_temp_gap_clip`, `register_temp_gap`, `is_gap_edge`, `gap_right_has_independent_in_edge`, `clip_has_selected_edge` (move_gap_right_clip guard), and any remaining `gap_before`/`gap_after` references. Search codebase-wide with `grep -r "gap_before\|gap_after\|is_gap_edge\|is_temp_gap\|create_temp_gap\|register_temp_gap"`.

## Phase 3.5: Polish & Validation

- [X] T025 Run full `make -j4`. All tests must pass. Zero luacheck warnings.

- [X] T026 Manual validation per `quickstart.md`: clip-gap roll, ExtendEdit, multitrack ripple (with gap, blocked by zero-gap), gap split, gap merge, gap delete, preview/commit consistency.

- [X] T027 Update memory/handoff notes: mark gap-as-clip refactor complete, update `project_gap_as_clip_refactor.md`, update `MEMORY.md` ripple trim status.

## Dependencies

```
T001 (skeleton) → T003-T005 (tests) → T008-T010 (implement lifecycle)
T002 (baseline) — reference throughout

T008-T010 (lifecycle) → T011 (wire into timeline_state)
T011 → T012 (edge_picker) → T013 (edge_utils)
T013 → T014-T018 (batch_ripple_edit changes) — sequential, same file
T018 → T019 (mutation filtering)
T019 → T020 (verify roll/ripple tests)
T020 → T021 (wire into commands)
T021 → T022-T023 (test updates, parallel)
T023 → T024 (dead code removal)
T024 → T025-T027 (validation, sequential)
```

## Parallel Execution Examples

```
# Phase 3.2: All test files are independent
T003: tests/test_gap_lifecycle_compute.lua
T004: tests/test_gap_lifecycle_update.lua
T005: tests/test_gap_lifecycle_implied.lua

# Phase 3.4: Test helper and test updates are independent files
T022: tests/synthetic/helpers/ripple_layout.lua + ripple_test_runner.lua
T023: tests/test_batch_ripple_gap_*.lua + test_gap_*.lua + test_timeline_*gap*.lua
```

## Validation Checklist

- [ ] All gap lifecycle functions have tests (T003-T005)
- [ ] Clip-gap roll tested (T006)
- [ ] Multitrack ripple with gaps tested (T007)
- [ ] All tests come before implementation
- [ ] Parallel tasks are truly independent (different files)
- [ ] Each task specifies exact file paths
- [ ] No task modifies same file as another [P] task
- [ ] 27 multitrack ripple tests pass unchanged (FR-013)
