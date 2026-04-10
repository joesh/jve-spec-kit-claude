# Feature Specification: Bounded Edit Region

**Feature Branch**: `008-bounded-edit-region`  
**Created**: 2026-04-09  
**Status**: Draft

## Problem Statement

Edit operations (execute, undo, redo) load ALL clips from the database and recompute gaps for ALL tracks, even when the edit touches only 2 edges on 1 track. In a 20-track sequence with hundreds of clips, a simple roll edit takes ~2 seconds — 596 gap computations for an operation that affects 2 clips.

The cost chain:
1. `build_clip_cache` loads ALL clips from SQLite + computes gaps for ALL 20 tracks
2. `compute_shift_bounds` runs per-clip constraint checks on ALL downstream clips (they all shift by the same amount — pointless)
3. `recompute_gap_clips` strips ALL gaps and recomputes for ALL 20 tracks again

Additionally, the pipeline special-cases gaps (`clip_kind ~= "gap"` in `prime_neighbor_bounds_cache`, `collect_downstream_clips`, etc.) which breaks the gap-as-clip abstraction and causes crashes when gap clips appear where the pipeline doesn't expect them.

## Architectural Invariants

**1. An edit operation has two scopes:**
- **Edit region** — the directly edited clips and their neighbors. Constraint checking (`compute_shift_bounds`) applies here. Gaps participate as clips.
- **Downstream block** — everything after the edit region on affected tracks. Shifts as one opaque unit. No per-clip examination. One max-shift check across all affected tracks.

**2. Gaps are clips.** The pipeline must not distinguish gap clips from media clips. No `clip_kind ~= "gap"` checks in the edit pipeline.

**3. Downstream shift is a per-track bulk operation.** One SQL update per track, not per-clip enumeration. The only constraint is: minimum available space at the boundary across all affected tracks.

## User Stories

### US-1: Fast Edit Operations
As an editor, when I execute, undo, or redo a roll/ripple edit, the operation completes in under 16ms (one frame at 60fps) regardless of sequence size.

### US-2: Bounded Clip Access
As an editor, when I perform a trim/roll/ripple, the system loads only the participating clips, not the entire sequence.

## Functional Requirements

### FR-1: Bounded build_clip_cache
`build_clip_cache` loads only:
1. Clips whose edges are being edited (from `edge_infos`)
2. Their immediate neighbors on the same track — gaps included (for constraint computation)
3. For multitrack ripple: clips at the boundary position on other tracks

An assert enforces that no pipeline step accesses clips outside this set.

### FR-2: Downstream Max-Shift Check
Replace per-clip `compute_shift_bounds` on downstream clips with a single per-track check: for each affected track, compute the space between the last non-shifting clip and the first shifting clip at the boundary. The minimum across all tracks is the max allowable shift. If any track has zero space (adjacent clips, zero-length gap), the entire ripple is clamped to zero — all tracks use one global delta.

### FR-3: Bulk Downstream Shift
Replace `collect_downstream_clips` + per-clip shift mutations with one SQL-level bulk shift per affected track: `UPDATE ... SET timeline_start = timeline_start + delta WHERE track_id = ? AND timeline_start >= boundary`.

### FR-4: Scoped Gap Recomputation
`recompute_gap_clips` must accept a set of affected track IDs and only recompute gaps on those tracks. An all-tracks recompute is only permitted on sequence init/load.

### FR-5: Gap-as-Clip Abstraction
Remove all `clip_kind ~= "gap"` checks from the edit pipeline. Gaps participate in neighbor bounds, constraints, and edge injection the same as media clips.

### FR-6: Multi-Sequence Future-Proofing
A sequence generation counter (incremented on any mutation) enables O(1) staleness detection for nested sequence references. Infrastructure only — cross-sequence cascade logic deferred to nested sequences feature.

## Non-Functional Requirements

### NFR-1: Performance
- Roll edit: O(2 clips + neighbors), not O(all clips)
- Ripple edit: O(edit region clips) + O(1 per affected track for max-shift + bulk shift)
- Gap recompute: O(affected tracks), not O(all tracks)

### NFR-2: Safety
- Bounded clip set access outside the edit region = hard assert
- No fallback to full recomputation — that masks bugs

## Acceptance Criteria

1. Roll edit on a 20-track sequence loads exactly the abutting pair + neighbors, not all clips
2. `build_clip_cache` loads only participating clips + neighbors; assert fires if pipeline accesses anything outside the bounded set
3. `recompute_gap_clips` after mutation touches only affected tracks
4. No `clip_kind ~= "gap"` checks remain in the edit pipeline
5. Downstream shift uses bulk per-track mutation, not per-clip enumeration
6. Max-shift check computes one number across affected tracks
7. Sequence generation counter increments on mutation and is readable

## Clarifications

### Session 2026-04-09

**Q: For ripple edits, does the affected region extend to end-of-track?**  
A: No. Everything beyond the edited edges shifts as one opaque block. The downstream shift is a bulk per-track operation.

**Q: Should recompute_gap_clips also be scoped?**  
A: Yes, to affected tracks only. The mutation system already knows which tracks were touched.

**Q: Is compute_shift_bounds needed at all?**  
A: Yes, but only for the edit region. Multi-edge selections can squeeze intermediate clips/gaps. The constraint is real for edited clips and their neighbors. It is NOT needed for downstream clips — they all shift by the same delta.

**Q: What about the gap special-casing in the pipeline?**  
A: Remove it. The gap-as-clip refactor means gaps ARE clips. `prime_neighbor_bounds_cache` should include gaps. `collect_downstream_clips` is eliminated entirely (replaced by bulk shift). The crash where gap clips appear in `post_boundary_first_clip` goes away because the pipeline no longer treats gaps differently.

**Q: Cross-sequence effects from nested sequences?**  
A: Future-proofed via sequence generation counter. Cross-sequence cascade deferred to nested sequences feature.

**Q: When max-shift check yields zero available space on a track, what happens?**  
A: Clamp delta to zero on ALL tracks. The most constrained track determines the global limit. No per-track independent deltas.

## Technical Dependencies

- `src/lua/core/commands/batch_ripple_edit.lua` — `build_clip_cache`, executor, undoer
- `src/lua/core/ripple/batch/pipeline.lua` — pipeline step orchestration
- `src/lua/core/ripple/batch/context.lua` — ctx construction
- `src/lua/ui/timeline/state/timeline_core_state.lua` — `recompute_gap_clips`
- `src/lua/ui/timeline/state/clip_state.lua` — `apply_mutations`
- `src/lua/ui/timeline/timeline_state.lua` — `apply_mutations` wrapper
- `src/lua/core/command_manager.lua` — `apply_command_mutations`
- `src/lua/core/gap_lifecycle.lua` — `compute_gaps_for_track`
- `src/lua/core/timeline_active_region.lua` — `build_snapshot_for_region`
