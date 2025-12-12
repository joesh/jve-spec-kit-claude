# Task List - Timebase Migration (Phase 3)

## Critical Path (Blockers)
- [x] **Refactor `CreateClip`**: Update `src/lua/core/commands/create_clip.lua` to use `Rational` objects and Sequence FPS.
- [x] **Refactor `InsertClipToTimeline`**: Update `src/lua/core/commands/insert_clip_to_timeline.lua` to use `Rational` objects.
- [x] **Refactor `SplitClip`**: Update `src/lua/core/commands/split_clip.lua`.
- [x] **Refactor `RippleDelete`**: Update `src/lua/core/commands/ripple_delete.lua`.
- [x] **Integration Test**: Create `tests/test_frame_accuracy.lua` to prove we can insert a clip without crashing.
- [x] **Fix OOM**: Resolved SQLite statement leaks in `command_manager` and `database.lua`.

## Command Refactoring Queue
- [x] Audit `command_helper.lua` for legacy property copying.
- [x] Refactor `RippleEdit`
- [x] Refactor `BatchRippleEdit`
- [x] Refactor `Nudge`
- [x] Refactor `MoveClipToTrack`
- [x] Refactor `Overwrite`
- [x] Refactor `Insert`

## Remaining Tasks from PLAN_TIMEBASE_SPEC.md

### Phase 3: Logic Refactoring
- [x] **Audio Logic:** Implement Snap vs Sample logic using `Rational` math helpers.

### Phase 4: UI & C++ Renaming
- [x] **Rename:** `ScriptableTimeline` -> `TimelineRenderer`.
- [x] **Update:** Lua View Layer (`timeline_view.lua` etc) to use `Rational` logic.

### Verification Strategy
- [x] **Legacy Coverage:** Ported `test_ripple_operations.lua` logic to `tests/integration/test_ripple_operations_rational.lua` and verified.

## Completed (Phases 1, 2, 2.5)
- [x] Replace Schema (V5)
- [x] Create Rational Library
- [x] Update `clip.lua` model
- [x] Update `sequence.lua` model
- [x] Update `track.lua` model
- [x] Explode `command_implementations.lua`

## Recent Technical Debt Cleanup
- [x] Refactored Importers (`fcp7_xml_importer.lua`, `drp_importer.lua`) to use `Rational`.
- [x] Refactored Monolithic `timeline_state.lua` into `ui/timeline/state/*`.
- [x] Refactored Monolithic `timeline_view.lua` into `ui/timeline/view/*`.
- [x] Created Full-Stack Integration Test `tests/integration/test_full_timebase_pipeline.lua`.

## Current Focus
- [x] Restore ripple handle semantics so `[`/`]` drags obey `docs/RIPPLE-ALGORITHM-RULES.md` across BatchRippleEdit and RippleEdit, covering gap clips and downstream propagation limits.

## Session Tasks (2025-???)
- [x] (done) Fix BatchRipple gap lead clamp/negation bugs and extend regression tests.
- [x] (done) Timeline gap edge selections should render handles just like clip edges; regression surfaced while restoring ripple handle semantics.
- [x] (done) Re-align per-track ripple shift signs so opposing bracket clip selections move in the correct directions while gap edges retain their bracket mapping (multi-track regression restored).
- [x] (done) Update timeline edit-zone cursors so the three zones show ], ]|[, and [ glyphs instead of generic trim arrows (custom cursors in `src/lua/qt_bindings/misc_bindings.cpp`).
- [x] (done) Timeline edge clicks must keep existing selections when re-clicked without modifiers, and Shift clicks should toggle edges like Cmd; regression in `tests/test_timeline_edge_clicks.lua`.
- [x] (done) Remove the stub `edge_utils.normalize_edge_type` and update any call sites so edge normalization only happens through the real helpers; Rule 2.17 forbids no-op stubs.
- [x] (done) BatchRippleEdit refactor/test coverage follow-up per latest review (helper split, constant extraction, new regression tests).
- [ ] Split `timeline_view_renderer.render` edge-preview block into small helpers so bracket geometry, preview clip lookup, and rectangle drawing each live in their own functions (Rule 2.26).
- [ ] Consolidate the duplicated gap-closure constraint logic in `batch_ripple_edit.lua` by routing every caller through `compute_gap_close_constraint` so changes stay in one place.
- [ ] Standardize command error returns (BatchRippleEdit/RippleEdit/etc.) so they all return `{success=false,error_message=...}` instead of sometimes `false`.
- [ ] Add docstrings for the public helpers touched in the ripple stack (`create_temp_gap_clip`, `apply_edge_ripple`, `pick_edges_for_track`, etc.) describing parameters/edge cases.
- [x] (done) Add regression coverage for rolling edits when one side of the edit is a gap (Rule 10) so gap rolls don't regress silently (`tests/test_edge_picker_gap_roll.lua`, `tests/test_edge_picker_gap_ripple.lua`, `tests/test_edge_picker_gap_zones.lua`).
- [ ] Document and/or consolidate the `timeline_state.set_edge_selection` vs `set_edge_selection_raw` APIs so callers know when raw mode is required.
- [x] Fix ripple clamp attribution so implied gap closures report the blocking gap edge and renderer color logic only highlights the actual limiter (Rule 8.5).
- [ ] Insert menu command failure: Added snapshot target seeding in `core.commands.insert` and regression `tests/test_insert_snapshot_boundary.lua`; pending user verification.
