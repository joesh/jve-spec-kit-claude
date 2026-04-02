
# Implementation Plan: Gap-as-Clip Refactor

**Branch**: `005-gap-as-clip-refactor` | **Date**: 2026-04-01 | **Spec**: [spec.md](spec.md)
**Input**: Feature specification from `/specs/005-gap-as-clip-refactor/spec.md`

## Summary

Replace gap-as-edge-modifier architecture with gap-as-clip. Gaps become normal in-memory clip entities (not persisted to DB) that live in the track's clip list. All gap-specific branching in the ripple/roll/constraint/preview pipeline is eliminated. The only gap-aware code is gap lifecycle management (creation, deletion, merge, split when clips change). Clip manipulation code does not distinguish gaps from media clips (FR-001a).

## Technical Context
**Language/Version**: Lua (LuaJIT) + C++ (Qt6)
**Primary Dependencies**: SQLite (persistence), command_manager (undo/redo), timeline_state (in-memory model)
**Storage**: SQLite for media clips (unchanged). Gaps are in-memory only — not persisted.
**Testing**: LuaJIT tests via `make -j4`. Black-box, no mocks. 27 existing multitrack ripple tests must pass unchanged (FR-013).
**Target Platform**: macOS (desktop)
**Project Type**: Single project — Lua scripts + C++ core
**Performance Goals**: Local gap recomputation only (FR-017). O(1) per edit, not O(n) over all clips. Must not regress 60fps preview rendering.
**Constraints**: Feature-length timelines with thousands of clips. Gap recompute must touch only affected clips and immediate neighbors.
**Scale/Scope**: ~15 functions to remove, ~20 `is_gap_edge()` branch points to eliminate, ~30 test files reference gap edge types.

## Constitution Check

**I. Modular Architecture**: ✅ Gap lifecycle is a standalone module. Clip manipulation code has no gap awareness (FR-001a). MVC: gap state is model-level; views pull from track clip list.
**II. Command-Driven Interface**: ✅ No new commands. Existing commands (BatchRippleEdit, Insert, Delete, etc.) work unchanged because gaps are normal clips.
**III. Test-First Development**: ✅ Existing 27 multitrack ripple tests serve as the regression suite. New tests for gap lifecycle (create, delete, merge, split). TDD: write gap lifecycle tests first, then implement.
**IV. Documentation-Driven Specifications**: ✅ Spec complete with clarifications.
**V. Template-Based Consistency**: ✅ Following spec→plan→tasks workflow.
**VI. Fail-Fast Assert Policy**: ✅ Gap clips assert on invariant violations (zero-length gap with no adjacent clips, gap with media_id, etc.).
**VII. No Fallbacks or Default Values**: ✅ No fallback gap creation. Gaps computed from clip positions or asserted missing.
**VIII. No Backward Compatibility**: ✅ `gap_before`/`gap_after` edge types deleted entirely. No shims. Existing tests updated to new model.

## Project Structure

### Documentation (this feature)
```
specs/005-gap-as-clip-refactor/
├── plan.md              # This file
├── research.md          # Phase 0: existing code inventory
├── data-model.md        # Phase 1: gap clip entity model
├── quickstart.md        # Phase 1: verification steps
└── tasks.md             # Phase 2: ordered implementation tasks
```

### Source Code (affected areas)
```
src/lua/
├── core/
│   ├── commands/
│   │   └── batch_ripple_edit.lua    # Remove gap-specific pipeline steps
│   ├── ripple/
│   │   └── batch/
│   │       └── pipeline.lua         # Remove materialize/inject steps
│   ├── gap_lifecycle.lua            # NEW: create/delete/merge/split gaps
│   ├── clip_mutator.lua             # No gap awareness needed
│   ├── edge_utils.lua               # Remove gap_before/gap_after
│   └── timeline_constraints.lua     # Remove is_gap checks
├── ui/
│   └── timeline/
│       ├── edge_picker.lua          # Select gap:in/gap:out directly
│       ├── roll_detector.lua        # Finds clip-gap pairs naturally
│       └── view/
│           └── timeline_view_renderer.lua  # Remove temp_gap rendering
└── models/
    └── clip.lua                     # No changes (gaps use same interface)

tests/
├── test_gap_lifecycle.lua           # NEW: create/delete/merge/split
├── test_ripple_in_multitrack_upstream_stable.lua  # Must pass unchanged
└── test_batch_ripple_gap_*.lua      # Update to new gap model
```

**Structure Decision**: Single project. New file `gap_lifecycle.lua` for gap creation/deletion logic. All other changes are modifications to existing files — removing gap-specific code paths.

## Phase 0: Outline & Research

No external unknowns to research. This is an internal refactor of known code. Research phase inventories the existing gap-specific code to remove.

### Code Inventory

**Functions to remove** (batch_ripple_edit.lua):
- `create_temp_gap_clip()` — replaced by gap_lifecycle
- `register_temp_gap()` — no temp gaps
- `materialize_gap_edges()` — edge picker selects gap:in/out directly
- `move_gap_right_clip()` — roll mechanics handle it
- `compute_gap_shift_value()` — gap duration change IS the shift
- `propagate_gap_offsets()` — no temp gaps to propagate
- `inject_implicit_gap_edges()` — replaced by on-the-fly zero-length gap creation (FR-010e)
- `compute_gap_close_constraint()` — same as min_duration_limits
- `clamp_gap_to_origin()` — same as any clip
- `apply_gap_limits()` — unified with clip constraints
- `gap_right_has_independent_in_edge()` — no gap propagation
- `clip_has_selected_edge()` guard in move_gap_right_clip — no propagation

**Branch points to remove** (~20 occurrences):
- `is_gap_edge()` checks in constraint, preview, mutation, rendering code
- `gap_before`/`gap_after` edge type handling in edge_utils, edge_picker, edge_info
- `is_temp_gap` checks in build_clip_cache, build_planned_mutations, edge preview builder
- Gap-roll special path in `apply_edge_ripple`

**Edge types to remove**:
- `gap_before`, `gap_after` from edge_utils.to_bracket
- `gap_before`, `gap_after` from edge_picker.select_boundary_edges
- `gap_before`, `gap_after` from edge_info.build_edge_key

**Pipeline steps to remove** (pipeline.lua):
- `ops.materialize_gap_edges(ctx)`
- `ops.inject_implicit_gap_edges(ctx)`
- `propagate_gap_offsets(ctx)` call in process_edge_trims

**New module**: `gap_lifecycle.lua`
- `compute_gaps_for_track(track_clips)` — initial gap computation on sequence open
- `update_gaps_locally(track_clips, changed_clip_ids)` — local recompute after edit
- `create_zero_length_gap(track_id, position)` — for implied edge selection (FR-010e)

### Research Decision Log

| Decision | Rationale | Alternatives Rejected |
|----------|-----------|----------------------|
| In-memory gaps, not DB rows | Undo is free (recompute from clip positions). No schema change. | DB rows: simpler but inflates clip count, needs migration |
| Persistent for timeline session | Edge picker/roll detector need gaps in the clip list at all times | Transient per-edit: edge picker can't find gaps between edits |
| Local recompute only | O(n) unacceptable for feature-length edits | Full recompute: too slow |
| On-the-fly zero-length gaps for adjacent clips | Avoids polluting track with zero-length objects between every pair | Always-present zero-length gaps: creates 3 edges at every boundary |

## Phase 1: Design & Contracts

### Data Model

**Gap Clip Entity** (in-memory only):
- `id`: synthetic string (e.g., `"gap_<track_id>_<start>"`)
- `track_id`: same as adjacent clips
- `timeline_start`: integer frames
- `duration`: integer frames (≥ 0)
- `clip_kind`: `"gap"`
- `media_id`: nil
- `source_in`: nil
- `source_out`: nil
- `fps_numerator`, `fps_denominator`: inherited from sequence
- `is_gap`: true (convenience flag for lifecycle code only — NOT checked by clip manipulation)

**Invariants**:
- A gap's `timeline_start + duration` = next clip's `timeline_start` (or sequence end)
- A gap's `timeline_start` = previous clip's `timeline_start + duration` (or 0 for first gap)
- No two gaps are adjacent (merge invariant)
- Gap duration ≥ 0 (zero-length gaps are valid, deleted when trimmed to zero)

**Lifecycle Events**:
- Sequence open → compute all gaps from clip positions
- Clip insert/overwrite → shrink or split affected gap
- Clip delete → merge adjacent gaps
- Clip trim/roll/ripple → resize affected gap
- Undo/redo → recompute gaps locally from restored clip positions
- Sequence close → discard all gaps

### Contracts (Internal Module Interfaces)

No REST/GraphQL APIs — this is an internal refactor. Contracts are module interfaces:

**gap_lifecycle.lua**:
```
compute_gaps_for_track(track_id, sorted_clips, seq_fps) → gap_clips[]
update_gaps_after_edit(track_id, sorted_clips, changed_region, seq_fps) → gap_clips[]
create_implied_gap(track_id, position, seq_fps) → gap_clip
```

**edge_picker.lua** (modified interface):
```
-- Before: select_boundary_edges returns {clip1:out, clip1:gap_after}
-- After:  select_boundary_edges returns {clip1:out, gap:in} (gap found in track clip list)
-- No interface change — same function, different internal behavior
```

**batch_ripple_edit.lua** (simplified pipeline):
```
-- Before: 10 steps, 4 gap-specific
-- After: 7 steps, 0 gap-specific
-- build_clip_cache → prime_neighbor_bounds → assign_edge_tracks →
-- determine_lead_edge → analyze_selection → compute_constraints →
-- process_edge_trims → compute_downstream_shifts
```

### Test Scenarios (from spec acceptance criteria)

1. Clip-gap roll: clip extends into gap, gap shrinks, downstream stays
2. Clip-gap ripple: gap grows/shrinks, downstream shifts
3. Multitrack ripple with zero-gap blocking
4. Multitrack ripple with implied zero-length gap creation
5. Gap split on insert/overwrite
6. Gap merge on clip delete
7. Gap delete when trimmed to zero
8. Undo restores gap state
9. ExtendEdit (E key) on clip-gap boundary
10. Preview matches commit for clip-gap roll

### Quickstart Verification

See [quickstart.md](quickstart.md) for step-by-step verification.

## Phase 2: Task Planning Approach
*This section describes what the /tasks command will do — DO NOT execute during /plan*

**Task Generation Strategy**:
- Gap lifecycle module first (create/delete/merge/split) with tests
- Then modify edge_picker to find gap clips in track list
- Then strip gap-specific code from batch_ripple_edit pipeline
- Then remove gap_before/gap_after edge types
- Then update existing tests to new model
- Final: run full suite, manual validation

**Ordering Strategy**:
- TDD: gap lifecycle tests before implementation
- Bottom-up: gap_lifecycle → edge_picker → batch_ripple_edit → cleanup
- Existing tests run after each step to catch regressions early

**Estimated Output**: 15-20 ordered tasks

**IMPORTANT**: This phase is executed by the /tasks command, NOT by /plan

## Phase 3+: Future Implementation
*Beyond /plan scope*

## Complexity Tracking

No constitution violations. The refactor reduces complexity — no justifications needed.

## Progress Tracking

**Phase Status**:
- [x] Phase 0: Research complete (/plan command)
- [x] Phase 1: Design complete (/plan command)
- [x] Phase 2: Task planning complete (/plan command - describe approach only)
- [ ] Phase 3: Tasks generated (/tasks command)
- [ ] Phase 4: Implementation complete
- [ ] Phase 5: Validation passed

**Gate Status**:
- [x] Initial Constitution Check: PASS
- [x] Post-Design Constitution Check: PASS
- [x] All NEEDS CLARIFICATION resolved
- [x] Complexity deviations documented (none needed)

---
*Based on Constitution v2.0.0 - See `.specify/memory/constitution.md`*
