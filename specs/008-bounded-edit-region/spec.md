# Feature Specification: Bounded Edit Region

**Feature Branch**: `008-bounded-edit-region`  
**Created**: 2026-04-09  
**Status**: Draft

## Problem Statement

Edit operations (execute, undo, redo) load ALL clips from the database and recompute gaps for ALL tracks, even when the edit touches only 2 edges on 1 track. In a 20-track sequence with hundreds of clips, a simple roll edit redo takes ~2 seconds — 596 gap computations for an operation that affects 2 clips.

The cost chain on redo:
1. `build_clip_cache` loads ALL clips from SQLite + computes gaps for ALL 20 tracks
2. `apply_command_mutations` applies changes (cheap, O(affected clips))
3. `recompute_gap_clips` strips ALL gaps and recomputes for ALL 20 tracks again
4. If mutations fail, `reload_clips` does the full load + gap recompute a third time

## Architectural Invariant

**An edit operation may only examine the clips directly participating in the edit.** Everything beyond those clips is either untouched (roll) or shifts as an opaque block (ripple). No global scan.

Specifically:
- **Roll edit**: only the two clips whose edges abut need to be examined
- **Ripple edit**: only the clips whose edges are being modified; everything downstream shifts as one opaque block without per-clip examination
- **Implicit gap edges** (multitrack ripple): the constraint grows to include clips at the boundary position on other tracks, but only at that position
- These bounds are **asserted**, not just optimized — future code that tries to access clips outside the bounded region must hit an assert

## User Stories

### US-1: Fast Edit Operations
As an editor, when I execute, undo, or redo a roll/ripple edit, the operation completes in under 16ms (one frame at 60fps) regardless of sequence size.

### US-2: Bounded Clip Access
As an editor, when I perform a trim/roll/ripple, the system loads only the participating clips, not the entire sequence.

## Functional Requirements

### FR-1: Bounded build_clip_cache
For the execute path, `build_clip_cache` loads only:
1. Clips whose edges are being edited (from `edge_infos`)
2. Their immediate neighbors on the same track (for constraint computation)
3. For multitrack ripple: clips at the boundary position on other tracks

An assert enforces that no pipeline step accesses clips outside this set.

### FR-2: Scoped Gap Recomputation
`recompute_gap_clips` in `timeline_core_state` must accept a set of affected track IDs and only recompute gaps on those tracks. The mutation system propagates affected track IDs. An all-tracks recompute is only permitted on sequence init/load.

### FR-3: Multi-Sequence Future-Proofing
Mutation data structures must support multiple sequence IDs from the start. Pre/post-condition checks iterate per-sequence. A sequence generation counter (incremented on any mutation) enables O(1) staleness detection for nested sequence references. This is infrastructure only — cross-sequence cascade logic is deferred to the nested sequences feature.

## Non-Functional Requirements

### NFR-1: Performance
- Roll edit redo: < 1ms for the mutation application (excluding rendering)
- Ripple edit redo: < 1ms + O(downstream clips for bulk shift)  
- Execute path: O(affected clips + neighbors), not O(all clips)

### NFR-2: Safety
- Pre-condition failure on redo = hard assert (state corruption detected)
- Post-condition failure = hard assert (incomplete mutations detected)
- No fallback to full recomputation — that masks bugs

## Acceptance Criteria

1. Roll edit on a 20-track sequence loads exactly the abutting pair + neighbors, not all clips
2. `build_clip_cache` loads only participating clips + neighbors; assert fires if pipeline accesses anything outside the bounded set
3. `recompute_gap_clips` after mutation touches only affected tracks
4. Redo of a roll edit on 20-track sequence has the same bounded behavior as execute
5. Mutation data structure supports multi-sequence keys (verified by unit test, not exercised in production yet)
6. Sequence generation counter increments on mutation and is readable

## Clarifications

### Session 2026-04-09

**Q: For ripple edits, does the affected region extend to end-of-track?**  
A: No. Everything beyond the edited edges shifts as one opaque block. You don't examine any clips beyond the affected edges. The downstream shift is a bulk operation on a set of clip IDs already known from the original execution.

**Q: Should recompute_gap_clips also be scoped?**  
A: Yes, to affected tracks only. The mutation system already knows which tracks were touched.

**Q: How to validate persisted mutation data on redo without spending the same time as a full query?**  
A: Pre-condition checks: load only the named clips, assert current state matches expected pre-state. Post-condition checks: on affected tracks only, verify no overlaps and gap contiguity. Both are O(affected clips), not O(all clips).

**Q: What are the holes in the pre/post-condition validation?**  
A: (1) Closed-world assumption — won't detect phantom clips appearing on affected tracks. (2) Incomplete mutation capture — won't catch missing side effects. (3) Gap state is unvalidatable directly. Post-condition overlap/contiguity check on affected tracks mitigates all three.

**Q: Cross-sequence effects from nested sequences?**  
A: An edit in nested sequence A that changes its duration must cascade to parent sequence B. The command group captures mutations in both sequences atomically. Pre/post checks validate both. Sequence generation counter enables O(1) staleness detection. This is future-proofed in data structures but not implemented until nested sequences land.

**Q: Should the redo path skip build_clip_cache entirely?**  
A: Yes. Redo uses persisted mutations directly. The executor does not re-run the pipeline.

## Technical Dependencies

- `src/lua/core/commands/batch_ripple_edit.lua` — `build_clip_cache`, executor, undoer
- `src/lua/core/ripple/batch/pipeline.lua` — pipeline step orchestration
- `src/lua/core/ripple/batch/context.lua` — ctx construction
- `src/lua/ui/timeline/state/timeline_core_state.lua` — `recompute_gap_clips`
- `src/lua/ui/timeline/state/clip_state.lua` — `apply_mutations`
- `src/lua/ui/timeline/timeline_state.lua` — `apply_mutations` wrapper
- `src/lua/core/command_manager.lua` — `run_redo_executor`, `apply_command_mutations`
- `src/lua/core/gap_lifecycle.lua` — `compute_gaps_for_track`
