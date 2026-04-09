# Research: Bounded Edit Region

## Current Architecture Analysis

### build_clip_cache (batch_ripple_edit.lua:376-498)

Three code paths, selected by context:

1. **Preloaded snapshot** (dry_run preview) — uses in-memory snapshot from UI, returns early. Fast.
2. **Timeline state cache** (dry_run + `__use_timeline_state_cache`) — reads from `timeline_state` in-memory. Fast.
3. **DB path** (execute/redo) — `database.load_clips(sequence_id)` loads ALL clips, then `gap_lifecycle.compute_gaps_for_track()` for EVERY track. This is the slow path.

Decision: Redo must not use path 3. Execute should use a bounded variant of path 3.

### Pipeline Step Dependencies on build_clip_cache

| Step | Uses all_clips | Uses clip_lookup | Uses track_clip_map | Actual need |
|------|---------------|-----------------|-------------------|-------------|
| prime_neighbor_bounds_cache | no | no | YES (all tracks) | Neighbors of edited clips only |
| inject_implicit_gap_edges | YES | YES | YES | Clips at boundary position on other tracks |
| assign_edge_tracks | YES | no | no | Track IDs for edited clips (already in edge_infos) |
| compute_constraints | indirect | indirect | no | Neighbor bounds (already cached) |
| compute_downstream_shifts | YES | YES | no | Downstream clips on affected tracks |
| determine_lead_edge | no | no | no | edge_infos only |
| analyze_selection | no | YES | no | Edited clips only |
| process_edge_trims | no | indirect | no | Cached bounds only |
| build_planned_mutations | no | no | no | Modified clips only |
| finalize_execution | no | no | no | Mutations only |

Decision: `track_clip_positions` is populated but never read — dead code, remove it.

### recompute_gap_clips (timeline_core_state.lua:51-149)

Called after every mutation via `timeline_state.apply_mutations()`. Strips ALL gap clips from `data.state.clips`, rebuilds per-track sorted lists for ALL tracks, calls `gap_lifecycle.compute_gaps_for_track()` for each.

Also called on `reload_clips()` and `init()`.

Decision: Add `affected_track_ids` parameter. When provided, only strip/recompute gaps on those tracks. Assert that init/load uses all-tracks, mutations use scoped.

### Redo Flow (command_manager.lua:1760-1795)

`run_redo_executor` calls the executor function (same as execute), then `apply_command_mutations`, then potentially `reload_clips` as fallback.

The executor re-runs the full pipeline including `build_clip_cache` from DB. This is unnecessary — the command already has persisted `original_states`, `executed_mutations`, `executed_mutation_order`, and `bulk_shifts`.

Decision: Redo should skip the executor entirely and apply persisted mutations directly, with pre/post-condition checks.

### Mutation Data Structure (clip_state.lua:262-442)

`apply_mutations` accepts: `{ updates: [...], deletes: [...], inserts: [...], bulk_shifts: [...] }`

Each update has: `clip_id`, `start_value`, `duration_value`, `source_in_value`, `source_out_value`, `track_id`.

This already contains enough information to apply mutations without re-running the executor. The `original_states` parameter on the command captures pre-mutation state for validation.

### Multi-Sequence Mutations (command_manager.lua:201-229)

`apply_command_mutations` already supports multi-bucket format keyed by sequence_id. Future-proofing is partially in place.

Decision: Sequence generation counter is the missing piece. Add to sequence model.

## Design Decisions

### Decision 1: Redo Fast Path via Direct Mutation Application
**Chosen**: Skip executor on redo, apply persisted `__timeline_mutations` directly with pre/post checks.  
**Rationale**: Executor re-runs the entire pipeline unnecessarily. Mutations are already persisted and authoritative.  
**Alternative rejected**: Optimizing the executor's build_clip_cache for redo — still runs 10 pipeline steps when only mutation application is needed.

### Decision 2: Bounded build_clip_cache for Execute
**Chosen**: Load only clips on affected tracks within the edit region bounds, plus neighbors.  
**Rationale**: Pipeline steps only need local context. No step genuinely needs all clips on all tracks.  
**Alternative rejected**: Keeping full load but caching — doesn't enforce the invariant, just masks the cost.

### Decision 3: Scoped recompute_gap_clips  
**Chosen**: Accept `affected_track_ids` set, only recompute those tracks.  
**Rationale**: Gap recomputation is the dominant cost. 20-track recompute for a 1-track edit is pure waste.  
**Alternative rejected**: Incremental gap update (update only the gap adjacent to the edit point) — more complex, fragile, and compute_gaps_for_track on 1 track is already fast.

### Decision 4: Assert-Enforced Bounds
**Chosen**: Wrap clip access through a proxy that asserts clip_id is in the bounded set.  
**Rationale**: Without enforcement, future code will regress to O(all-clips). Asserts catch this in development.  
**Alternative rejected**: Convention-only ("don't access clips outside the set") — guaranteed to drift.

### Decision 5: Sequence Generation Counter
**Chosen**: Add `mutation_generation` integer column to sequences table, increment on every mutation.  
**Rationale**: Enables O(1) staleness check for nested sequence references. Cheap to add now.  
**Alternative rejected**: Timestamp-based — coarser, clock-dependent.
