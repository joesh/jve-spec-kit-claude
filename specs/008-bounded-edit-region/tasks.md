# Tasks: Bounded Edit Region

**Input**: Design documents from `/specs/008-bounded-edit-region/`
**Prerequisites**: plan.md, research.md, spec.md

## Status (2026-04-10)

All 14 tasks landed (T001–T014) plus FU-5 (trigger rewrite) on top
of the planned scope. Implementation status is authoritative in
[plan.md](plan.md); this file preserves the original task-breakdown
snapshot for historical reference.

## Phase 3.1: Setup

- [x] T001 Read and understand the current pipeline
  - Read `src/lua/core/commands/batch_ripple_edit.lua` — all of `build_clip_cache`, `prime_neighbor_bounds_cache`, `collect_downstream_clips`, `compute_shift_bounds`, `compute_downstream_shifts`, `inject_implicit_gap_edges`
  - Read `src/lua/ui/timeline/state/timeline_core_state.lua` — `recompute_gap_clips`
  - Read `src/lua/ui/timeline/state/clip_state.lua` — `apply_mutations`, `apply_bulk_shifts`
  - Read `src/lua/ui/timeline/timeline_state.lua` — `apply_mutations` wrapper
  - Read `src/lua/core/gap_lifecycle.lua` — `compute_gaps_for_track`
  - Read `src/lua/core/timeline_active_region.lua` — `build_snapshot_for_region`
  - Read `src/lua/models/sequence.lua` — schema, load/save
  - Catalog every `clip_kind ~= "gap"` check in the pipeline and document why each exists
  - Catalog every place `all_clips` is iterated and whether it genuinely needs all clips
  - **Output**: Written summary (comment in this task) of current flow, gap special-cases found, and downstream clip enumeration sites

## Phase 3.2: Tests First (TDD) — MUST COMPLETE BEFORE 3.3

- [x] T002 [P] Test: max-shift check across multiple tracks in `tests/test_max_shift_check.lua`
  - Setup: 3 tracks (V1, A1, A2). V1 has clips at 0-100, 100-400. A1 has clip at 150-300 (gap at boundary = 50 frames). A2 has clip at 120-300 (gap at boundary = 20 frames)
  - Ripple V1 clip A out by +80. Expected: clamped to +20 (A2 is most constrained)
  - Ripple V1 clip A out by +15. Expected: allowed (15 < 20, fits all tracks)
  - Ripple V1 clip A out by +20. Expected: allowed (exactly fills A2's gap)
  - Zero-space case: A2 clip starts at 100 (no gap). Ripple by +10. Expected: clamped to 0
  - Use DSL test runner (`tests/helpers/ripple_test_runner.lua`) for setup/verification
  - Tests MUST FAIL initially (implementation doesn't exist yet — current code may pass some due to different constraint logic; verify each test exercises the new max-shift path)

- [x] T003 [P] Test: gap-as-clip in constraint computation in `tests/test_gap_as_clip_constraints.lua`
  - Setup: V1 with [A 0-100][gap 100-150][B 150-400]. Multi-edge: A out + B in (roll both edges)
  - Roll by +60. Expected: clamped to +50 (gap between A and B is only 50 frames)
  - Roll by +50. Expected: allowed (exactly fills gap)
  - Roll by -10. Expected: allowed (gap grows to 60)
  - Verify: gap participates in neighbor bounds (gap.duration constrains the roll)
  - Use DSL test runner
  - Tests MUST FAIL initially

- [x] T004 [P] Test: scoped gap recomputation in `tests/test_scoped_gap_recompute.lua`
  - Setup: timeline_state with 4 tracks, clips on each. Modify clips on 1 track only
  - Call `recompute_gap_clips({[track_id] = true})` with one track ID
  - Assert: gaps on the specified track are recomputed (correct positions)
  - Assert: gaps on the other 3 tracks are UNCHANGED (same gap clip IDs, same positions)
  - Test full recompute path too: `recompute_gap_clips(nil)` recomputes all tracks
  - Requires `timeline_core_state.recompute_gap_clips` to accept the parameter (will fail until T008 implements it)

- [x] T005 [P] Test: sequence generation counter in `tests/test_sequence_generation.lua`
  - Create a sequence. Assert `mutation_generation` is 0
  - Execute a command that mutates the sequence. Assert `mutation_generation` incremented to 1
  - Execute another. Assert incremented to 2
  - Undo. Assert generation still increments (undo is a mutation too) — or stays? (Check with Joe if undo should increment generation)
  - Verify `Sequence.load(id).mutation_generation` returns correct value
  - Requires schema change (will fail until T011 implements it)

- [x] T006 [P] Test: bounded clip access assert in `tests/test_bounded_edit_region.lua`
  - Setup: 3 tracks, 20 clips per track. Execute a roll edit on 2 clips on V1
  - Assert: `build_clip_cache` loaded <= 6 clips (2 edited + up to 4 neighbors), not 60
  - Assert: pipeline steps did NOT access any clip outside the bounded set
  - This test requires instrumentation in `build_clip_cache` to count loaded clips — will fail until T007 implements bounded loading
  - Verify that a ripple edit loads only edit region clips + uses bulk shift (no downstream enumeration)

## Phase 3.3: Core Implementation (ONLY after tests are failing)

- [x] T007 Bounded `build_clip_cache` in `src/lua/core/commands/batch_ripple_edit.lua`
  - For the execute path (not dry_run, not preloaded snapshot):
    1. From `ctx.edge_infos`, collect the clip IDs being edited
    2. Load those clips from timeline_state (use `get_track_clip_index` — already in memory, authoritative)
    3. For each edited clip, load its prev and next neighbor on the same track (including gaps)
    4. For multitrack ripple: at each boundary position, look up clips on other tracks at that position via timeline_state
    5. Register all into `ctx.all_clips`, `ctx.clip_lookup`, `ctx.track_clip_map`
  - Add a clip access counter or proxy that asserts if a pipeline step tries to access a clip not in the bounded set
  - The dry_run and preloaded_snapshot paths remain unchanged (they already have scoped data)
  - **Depends on**: T001 (understanding current code)

- [x] T008 Remove gap special-casing in `src/lua/core/commands/batch_ripple_edit.lua`
  - In `prime_neighbor_bounds_cache`: remove the `clip_kind ~= "gap"` filter at line ~498. Build neighbor bounds from ALL clips (media + gap)
  - In `build_clip_cache` DB path (line ~476-484): remove gap computation — gaps come from timeline_state as part of the bounded set
  - In any remaining pipeline steps: remove `clip_kind ~= "gap"` checks
  - Run existing ripple/roll tests to verify nothing breaks
  - **Depends on**: T007

- [x] T009 Max-shift check + bulk downstream shift in `src/lua/core/commands/batch_ripple_edit.lua`
  - Replace `collect_downstream_clips` + per-clip `compute_shift_bounds` on downstream clips:
    1. For each affected track, find the space between the last edited/non-shifting clip and the first clip after the boundary (use timeline_state's sorted track index, binary search)
    2. The minimum space across all tracks = max allowable shift
    3. Clamp `ctx.downstream_shift_frames` to this max
  - Replace per-clip shift mutations with bulk shift mutation: `{ type = "bulk_shift", track_id = track_id, shift_frames = delta, start_frame = boundary }`
  - Remove `collect_downstream_clips`, `bulk_shift_anchor_clips`, `bulk_shift_anchor_lookup`
  - `compute_shift_bounds` remains but ONLY runs on `ctx.clips_to_shift` which now contains ONLY edit-region clips (not downstream)
  - Update `finalize_execution` to emit the new bulk_shift format
  - **Depends on**: T007, T008

- [x] T010 Update `clip_state.apply_mutations` for simplified bulk_shifts in `src/lua/ui/timeline/state/clip_state.lua`
  - The new bulk_shift format is `{ track_id, shift_frames, start_frame }` (no clip_ids, no first_clip_id)
  - `apply_bulk_shifts` should handle this: for the given track, shift all clips with `timeline_start >= start_frame` by `shift_frames`
  - Keep backward compat with old format (clip_ids-based) temporarily for existing persisted commands — old commands in the undo history use the old format
  - Collect and return affected track IDs from all mutations (updates, deletes, inserts, bulk_shifts)
  - **Depends on**: T009

## Phase 3.4: Integration

- [x] T011 Scoped `recompute_gap_clips` in `src/lua/ui/timeline/state/timeline_core_state.lua`
  - Add optional `affected_track_ids` parameter (table of `{[track_id] = true}`)
  - When provided: strip gaps ONLY on affected tracks, recompute ONLY those tracks, leave others untouched
  - When nil: full recompute (existing behavior for init/load)
  - Update callers:
    - `timeline_state.apply_mutations` (line ~168): pass affected track IDs from `clip_state.apply_mutations` return value
    - `timeline_core_state.init` and `reload_clips`: continue passing nil (full recompute)
  - **Depends on**: T010

- [x] T012 Sequence generation counter in `src/lua/models/sequence.lua` and `src/lua/schema.sql`
  - Add `mutation_generation INTEGER NOT NULL DEFAULT 0` to sequences table in schema.sql
  - Add field to `Sequence.load()` return value
  - Add `Sequence.increment_generation(sequence_id)` — single SQL `UPDATE sequences SET mutation_generation = mutation_generation + 1 WHERE id = ?`
  - Call from `command_manager` after successful `apply_command_mutations` for each affected sequence
  - **Independent** — no dependencies on other tasks

## Phase 3.5: Polish

- [x] T013 Remove dead code in `src/lua/core/commands/batch_ripple_edit.lua`
  - Delete `collect_downstream_clips` function
  - Delete `bulk_shift_anchor_clips` and `bulk_shift_anchor_lookup` from context and all references
  - Delete `track_clip_positions` from `build_clip_cache` (never read)
  - Delete any remaining `clip_kind ~= "gap"` checks missed in T008
  - Run `make -j4` — zero warnings, all tests pass
  - **Depends on**: T009

- [x] T014 Integration validation — real project timing
  - Open the anamnesis project (20 tracks, hundreds of clips)
  - Perform a roll edit, measure timing in logs
  - Perform a ripple edit, measure timing in logs
  - Undo/redo both, measure timing
  - Target: all operations < 16ms (one frame at 60fps)
  - Verify shift block bounding box outline renders correctly during ripple preview
  - **Depends on**: all previous tasks

## Dependencies
- T001 before T007-T009 (must understand before modifying)
- T002-T006 parallel (tests first, different files)
- T007 → T008 → T009 sequential (core refactor chain, same file)
- T010 depends on T009 (new mutation format)
- T011 depends on T010 (needs affected track IDs)
- T012 independent (different file, no deps)
- T013 depends on T009 (removes code replaced by T009)
- T014 depends on all

## Parallel Execution Examples

```
# Phase 3.2: Launch all tests in parallel (different files)
T002: tests/test_max_shift_check.lua
T003: tests/test_gap_as_clip_constraints.lua
T004: tests/test_scoped_gap_recompute.lua
T005: tests/test_sequence_generation.lua
T006: tests/test_bounded_edit_region.lua

# Phase 3.3-3.4: T012 can run in parallel with T007-T011
T012: src/lua/models/sequence.lua + src/lua/schema.sql (independent)
T007-T011: sequential chain in batch_ripple_edit.lua → clip_state.lua → timeline_core_state.lua
```

## Notes
- All tests use `require("test_env")` and run from `tests/` directory
- Tests use the DSL test runner where possible (`tests/helpers/ripple_test_runner.lua`)
- `make -j4` must pass after each task (luacheck + all tests)
- Commit after each task with proper attribution
- Old bulk_shift format kept temporarily in clip_state for undo history compat — remove in a future cleanup pass

## Validation Checklist
- [ ] All acceptance criteria from spec.md have corresponding test assertions
- [ ] All tests written before implementation (T002-T006 before T007-T011)
- [ ] No `clip_kind ~= "gap"` checks remain in edit pipeline after T008+T013
- [ ] Parallel tasks truly independent (different files)
- [ ] Each task specifies exact file paths
