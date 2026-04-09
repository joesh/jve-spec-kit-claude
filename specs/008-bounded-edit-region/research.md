# Research: Bounded Edit Region

## Current Architecture Analysis

### build_clip_cache (batch_ripple_edit.lua:376-498)

Three code paths, selected by context:

1. **Preloaded snapshot** (dry_run preview) — uses in-memory snapshot from UI, returns early. Fast.
2. **Timeline state cache** (dry_run + `__use_timeline_state_cache`) — reads from `timeline_state` in-memory. Fast.
3. **DB path** (execute) — `database.load_clips(sequence_id)` loads ALL clips, then `gap_lifecycle.compute_gaps_for_track()` for EVERY track. This is the slow path.

Decision: Execute should use a bounded variant — load only edit region clips + neighbors from DB or timeline_state.

### Pipeline Step Dependencies on build_clip_cache

| Step | Uses all_clips | Uses clip_lookup | Uses track_clip_map | Actual need |
|------|---------------|-----------------|-------------------|-------------|
| prime_neighbor_bounds_cache | no | no | YES (all tracks) | Neighbors of edited clips only |
| inject_implicit_gap_edges | YES | YES | YES | Clips at boundary position on other tracks |
| assign_edge_tracks | YES | no | no | Track IDs for edited clips (already in edge_infos) |
| compute_constraints | indirect | indirect | no | Neighbor bounds (already cached) |
| compute_downstream_shifts | YES | YES | no | ELIMINATED — replaced by bulk shift |
| determine_lead_edge | no | no | no | edge_infos only |
| analyze_selection | no | YES | no | Edited clips only |
| process_edge_trims | no | indirect | no | Cached bounds only |
| build_planned_mutations | no | no | no | Modified clips only |
| finalize_execution | no | no | no | Mutations only |

Decision: `track_clip_positions` is populated but never read — dead code, remove it.

### Gap Special-Casing (the abstraction leak)

The pipeline has multiple `clip_kind ~= "gap"` checks:
- `prime_neighbor_bounds_cache` excludes gaps from neighbor cache
- `collect_downstream_clips` excludes gaps from shift list
- This causes crashes when gap clips appear in `post_boundary_first_clip` (TSO crash: `compute_shift_bounds: missing neighbor cache for clip gap_0912eecd...`)

Decision: Remove all gap special-casing. Gaps are clips. The gap-as-clip refactor's whole point was to eliminate these distinctions.

### compute_shift_bounds: Two Scopes, One Algorithm

Current code runs `compute_shift_bounds` on BOTH:
1. Edited clips + neighbors (real constraint: multi-edge selection can squeeze intermediate clips)
2. All downstream clips (pointless: they all shift by the same delta, can't overlap each other)

The only downstream constraint that matters: minimum available space at the boundary across all affected tracks. One number. One pass.

Decision: `compute_shift_bounds` scoped to edit region only. Downstream replaced by per-track max-shift check.

### recompute_gap_clips (timeline_core_state.lua:51-149)

Called after every mutation via `timeline_state.apply_mutations()`. Strips ALL gap clips from `data.state.clips`, rebuilds per-track sorted lists for ALL tracks, calls `gap_lifecycle.compute_gaps_for_track()` for each.

Decision: Add `affected_track_ids` parameter. When provided, only strip/recompute gaps on those tracks.

### Multi-Sequence Mutations (command_manager.lua:201-229)

`apply_command_mutations` already supports multi-bucket format keyed by sequence_id. Future-proofing is partially in place.

Decision: Sequence generation counter is the missing piece. Add to sequence model.

## Design Decisions

### Decision 1: Two-Scope Model
**Chosen**: Edit region uses constraint checking (gaps as clips). Downstream uses bulk per-track shift with one max-shift check.  
**Rationale**: Downstream clips all shift by the same delta — per-clip constraint checking is O(n) work for a trivially correct operation.  
**Alternative rejected**: Keeping per-clip downstream shifts — O(all clips), breaks gap abstraction.

### Decision 2: Bounded build_clip_cache
**Chosen**: Load only edit region clips + neighbors from timeline_state (already in memory).  
**Rationale**: Pipeline steps only need local context. timeline_state is the authoritative in-memory representation.  
**Alternative rejected**: Full DB load with caching — doesn't enforce the invariant, just masks the cost.

### Decision 3: Gap Abstraction Restored
**Chosen**: Remove all `clip_kind ~= "gap"` checks from pipeline. Gaps participate in neighbor bounds, constraints, everything.  
**Rationale**: This is the whole point of gap-as-clip. Special-casing caused the TSO crash and adds complexity.  
**Alternative rejected**: Adding more gap filters to handle edge cases — papering over a broken abstraction.

### Decision 4: Scoped recompute_gap_clips  
**Chosen**: Accept `affected_track_ids` set, only recompute those tracks.  
**Rationale**: Gap recomputation is the dominant cost. 20-track recompute for a 1-track edit is pure waste.  
**Alternative rejected**: Incremental gap update — more complex, and per-track recompute is already fast.

### Decision 5: Assert-Enforced Bounds
**Chosen**: Wrap clip access through a proxy that asserts clip_id is in the bounded set.  
**Rationale**: Without enforcement, future code will regress to O(all-clips).  
**Alternative rejected**: Convention-only — guaranteed to drift.

### Decision 6: Sequence Generation Counter
**Chosen**: Add `mutation_generation` integer column to sequences table, increment on every mutation.  
**Rationale**: Enables O(1) staleness check for nested sequence references. Cheap to add now.  
**Alternative rejected**: Timestamp-based — coarser, clock-dependent.
