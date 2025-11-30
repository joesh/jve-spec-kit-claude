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
- [ ] **Update:** Lua View Layer converts `Rational` -> Pixels for the renderer.

### Verification Strategy
- [ ] **Legacy Coverage:** Port the *logic* of `test_ripple_operations.lua` to a new Integration Test that uses real commands against the new schema.

## Completed (Phases 1, 2, 2.5)
- [x] Replace Schema (V5)
- [x] Create Rational Library
- [x] Update `clip.lua` model
- [x] Update `sequence.lua` model
- [x] Update `track.lua` model
- [x] Explode `command_implementations.lua`
