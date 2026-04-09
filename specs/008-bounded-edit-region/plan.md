# Implementation Plan: Bounded Edit Region

**Branch**: `008-bounded-edit-region` | **Date**: 2026-04-09 | **Spec**: [spec.md](spec.md)

## Summary

Edit operations currently scan all clips on all tracks. This plan introduces a bounded edit region invariant: operations examine only the clips participating in the edit. Redo skips the executor entirely and applies persisted mutations with pre/post-condition validation. Gap recomputation is scoped to affected tracks.

## Technical Context
**Language/Version**: Lua (LuaJIT) + C++ (Qt6)  
**Primary Dependencies**: command_manager, batch_ripple_edit, timeline_state, gap_lifecycle  
**Storage**: SQLite (.jvp project files)  
**Testing**: LuaJIT test harness, `make -j4`  
**Target Platform**: macOS (Darwin)  
**Project Type**: Single (desktop video editor)  
**Performance Goals**: Roll edit redo < 1ms; execute O(affected clips)  
**Constraints**: No fallbacks, fail-fast asserts, no backward compatibility  
**Scale/Scope**: 20+ track sequences, hundreds of clips per sequence

## Constitution Check

**I. Modular Architecture**: Pass — bounded clip set is a standalone module; scoped gap recompute is a parameter addition to existing module  
**II. Command-Driven Interface**: Pass — redo fast path integrates into existing command_manager redo flow  
**III. Test-First Development**: Pass — TDD: write tests that measure clip access counts, then implement bounds  
**IV. Documentation-Driven Specifications**: Pass — this plan  
**V. Template-Based Consistency**: Pass — follows existing command/mutation patterns  
**VI. Fail-Fast Assert Policy**: Pass — bounds enforced by asserts, pre/post-condition checks are asserts  
**VII. No Fallbacks or Default Values**: Pass — no fallback to full recompute on redo failure  
**VIII. No Backward Compatibility**: Pass — old redo path replaced, not shimmed  

## Project Structure

### Source Code (affected files)
```
src/lua/
  core/
    command_manager.lua          — redo fast path, skip executor on redo
    commands/
      batch_ripple_edit.lua      — bounded build_clip_cache, bounded_clip_set proxy
    ripple/batch/
      pipeline.lua               — no change (pipeline steps already correct if cache is bounded)
      context.lua                — no change
    gap_lifecycle.lua            — no change (already per-track)
  models/
    sequence.lua                 — mutation_generation counter
  ui/timeline/
    state/
      timeline_core_state.lua    — scoped recompute_gap_clips
      clip_state.lua             — propagate affected_track_ids from mutations
    timeline_state.lua           — pass affected_track_ids to recompute_gap_clips

tests/
  test_bounded_edit_region.lua       — invariant enforcement tests
  test_scoped_gap_recompute.lua      — gap recompute scoping tests
  test_sequence_generation.lua       — generation counter tests
```

## Phase 0: Research

Complete — see [research.md](research.md).

## Phase 1: Design

### Component 1: Bounded Clip Set (batch_ripple_edit.lua)

A **BoundedClipSet** wraps the clip cache and asserts on access. Created by `build_clip_cache`, it contains only the clips the edit is permitted to examine.

```
BoundedClipSet:
  - registered_clips: {[clip_id] = clip}     -- clips the edit may access
  - affected_track_ids: {[track_id] = true}  -- tracks the edit touches
  
  - get(clip_id) → clip or ASSERT            -- access outside set = bug
  - register(clip_id, clip)                   -- add clip during cache build
  - get_track_clips(track_id) → clips or ASSERT
  - contains(clip_id) → bool                  -- for conditional checks without assert
```

**build_clip_cache bounded path** (for execute, not dry_run):
1. From `edge_infos`, collect clip IDs being edited
2. Load those clips from DB (or timeline_state cache)
3. For each, load immediate neighbors on same track (prev/next by timeline_start)
4. For multitrack ripple: at each boundary position, load clips on other tracks at that position
5. Register all into BoundedClipSet
6. Pipeline steps access clips through the set — any unregistered access asserts

**Downstream shifts** (ripple): The bulk_shift mutation already carries `clip_ids` or `first_clip_id + anchor_start_frame`. On execute, `compute_downstream_shifts` collects these IDs. On redo, the persisted `bulk_shifts` mutation carries them. No need to scan all_clips.

### Component 2: Scoped Gap Recomputation (timeline_core_state.lua)

`recompute_gap_clips` gains an optional `affected_track_ids` parameter:

```
recompute_gap_clips(affected_track_ids)
  if not affected_track_ids:
    -- FULL recompute (init/load only)
    strip all gaps, recompute all tracks
  else:
    -- SCOPED recompute
    strip gaps ONLY on affected tracks
    recompute gaps ONLY on affected tracks
    leave other tracks' gaps untouched
```

**Propagation**: `__timeline_mutations` already contains `track_id` per update and `track_id` per bulk_shift. `clip_state.apply_mutations` collects affected track IDs and returns them. `timeline_state.apply_mutations` passes them to `recompute_gap_clips`.

### Component 3: Sequence Generation Counter (sequence.lua)

```sql
ALTER TABLE sequences ADD COLUMN mutation_generation INTEGER NOT NULL DEFAULT 0;
```

Incremented by `command_manager` after any successful mutation on a sequence. Readable via `Sequence.load(id).mutation_generation`. Used by future nested sequence pre-condition checks: "is the nested sequence still at the generation I expect?"

### Data Model Changes

**sequences table**: Add `mutation_generation INTEGER NOT NULL DEFAULT 0`

**__timeline_mutations format** (no change to structure, document existing):
```lua
{
  sequence_id = "...",
  updates = { { clip_id, start_value, duration_value, source_in_value, source_out_value, track_id } },
  deletes = { clip_id, ... },
  inserts = { { full clip record }, ... },
  bulk_shifts = { { track_id, shift_frames, clip_ids = {...} }, ... },
  -- NEW: affected_track_ids (derived, not persisted — computed from above)
}
```

## Phase 2: Task Planning Approach

**Strategy**: TDD order. Tests first, then implementation.

1. **Tests for invariants** — bounded clip set access assert, scoped gap recompute, generation counter
2. **BoundedClipSet** module — the clip access proxy with assert enforcement
3. **Bounded build_clip_cache** — execute/redo path loads only participating clips
4. **Scoped recompute_gap_clips** — accept affected_track_ids parameter
5. **Mutation track propagation** — clip_state returns affected tracks, timeline_state forwards to gap recompute
6. **Sequence generation counter** — schema + model + increment logic
7. **Remove dead code** — `track_clip_positions` (never read)
8. **Integration validation** — verify with real project, measure redo timing

**Ordering**: Tasks 1-2 are parallel. 3 depends on 2. 4-5 are parallel. 6-7 are independent. 8 depends on all.

**Estimated**: ~12 tasks

## Unresolved Questions

- `inject_implicit_gap_edges` scans all tracks at a boundary position for multitrack ripple — should we load just the clips at that position (SQL WHERE track_id IN (...) AND timeline_start <= pos AND timeline_start + duration > pos), or is it acceptable to load the full track at that position? The former is more correct but requires a new DB query pattern.
- `compute_downstream_shifts` on execute currently scans all_clips. With bounded set, it needs the downstream clip IDs. On first execute these aren't known yet — should we do a targeted DB query (clips on track X with timeline_start >= boundary)?

## Progress Tracking

**Phase Status**:
- [x] Phase 0: Research complete
- [x] Phase 1: Design complete
- [ ] Phase 2: Task planning (describe approach only — /tasks generates)
- [ ] Phase 3: Tasks generated
- [ ] Phase 4: Implementation complete
- [ ] Phase 5: Validation passed

**Gate Status**:
- [x] Initial Constitution Check: PASS
- [x] Post-Design Constitution Check: PASS
- [x] All NEEDS CLARIFICATION resolved
- [x] Complexity deviations documented (none)
