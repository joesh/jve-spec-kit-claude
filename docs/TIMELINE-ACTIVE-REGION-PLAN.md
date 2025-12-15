# Timeline Active Region Plan

## Goal
Make edge-drag (roll + ripple) preview performance scale with the *active interaction zone* of the timeline, not with total sequence clip count, even when the project contains thousands of clips.

The intent is to preserve the “small timeline feels fast” behavior by *making the preview system operate on an equivalent small timeline slice*.

## Core Concept: `TimelineActiveRegion`
`TimelineActiveRegion` is the smallest time-scoped region needed to evaluate clip-to-clip constraints for an interactive edit.

It intentionally does **not** mean “all clips” (avoid “universe” naming).

### Two regions
- **Interaction window**: where clips can “slide against each other” and constraint evaluation must be local and explicit (neighbors, overlap clamps, gap closure, roll coupling).
- **Rigid (bulk-shift) region**: beyond a boundary time where ripple semantics are a rigid translation and do **not** require per-clip reasoning for preview.

## Requirements
- Works for **ripple**:
  - Downstream clips shift as a block once beyond the interaction window boundary.
  - Preview must not enumerate downstream shifted clips as a per-clip list.
- Works for **roll**:
  - No downstream shift block; only local geometry updates.
- Applies to **all ripple-enabled tracks** (do not add track-scoping complexity).
- Architectural simplicity:
  - One place defines the active region.
  - No hidden fallbacks that silently revert to scanning/loading all clips.
  - Renderer is a consumer; command is a consumer; neither “invents” scoping.

## Non-goals (for this pass)
- Level-of-detail rendering for extreme zoom-out where thousands of visible clips map to <1px each.
- Full DB-level range updates for execution (preview path first). Execution can remain per-clip for correctness initially, but preview must not be per-clip for downstream.

## Proposed Architecture

### New module: `core.timeline_active_region`
Single responsibility: compute the active region from inputs that exist *before* preview is computed (no circular dependency on preview output).

API:
- `TimelineActiveRegion.compute_for_edge_drag(state_module, edges, opts) -> region`

`region` fields (frames-based):
- `fps_numerator`, `fps_denominator`
- `interaction_start_frames`, `interaction_end_frames`
- `bulk_shift_start_frames` (time boundary for rigid downstream shift; may be nil for roll-only)
- `pad_frames`
- `signature` (stable identifier derived from edge set + boundary times)

Implementation notes:
- Use per-track indices (`state_module.get_track_clip_index(track_id)` or equivalent) and binary search to find neighbors around the edit point.
- Do not scan `state_module.get_clips()` in the hot path.
- Interaction window should include:
  - selected edge clips’ intervals
  - immediate neighbors on those tracks
  - padding (e.g., max(60 frames, 2 seconds))

### Drag state owns the region
At drag start:
- `drag_state.active_region = TimelineActiveRegion.compute_for_edge_drag(...)`

This is shared across timeline panes via the shared drag state, so both video and audio views use the same region.

### Command dry-run consumes the region (no global loads)
BatchRippleEdit dry-run must accept:
- `__timeline_active_region` (region fields)
- `__preloaded_clip_snapshot` (clips and indices for the interaction window across all tracks)

Dry-run must:
- **Not** call `database.load_clips` when preloaded snapshot is provided.
- Operate only on interaction-window clips for constraint evaluation.
- Return a preview payload that includes **shift blocks**, not per-clip downstream lists.

### Preview payload: shift blocks
Replace large `shifted_clips` lists for downstream with:
- `shift_blocks = [{ start_frames, delta_frames, applies_to = "ripple_enabled_tracks" }]`

Keep:
- `affected_clips` as a small list of explicitly edited geometry inside the interaction window.

### Renderer consumes shift blocks
Renderer must:
- Continue drawing base clips as usual (viewport-culled).
- For edge-drag preview:
  - Draw small overlays for `affected_clips`.
  - Draw shifted outlines for *visible* clips impacted by `shift_blocks` by applying the shift in-place while iterating visible clips (O(visible clips), not O(total clips)).

Renderer must not:
- Build global clip lookups as fallbacks (no `build_clip_lookup(get_clips())` in edge preview).

## Large Visible Viewport Case
If the viewport itself contains thousands of visible clips, we cannot avoid draw cost. However, the plan still prevents:
- enumerating non-visible clips,
- per-clip downstream preview lists,
- repeated global DB loads or scans.

Future optimization (separate):
- Level-of-detail rendering / pixel bucketing for extreme zoom-out.

## Testing / Verification
Add regressions that fail on the current behavior:
- Dry-run preview payload contains `shift_blocks` (and does not contain a massive `shifted_clips` list for downstream).
- BatchRippleEdit dry-run uses preloaded snapshot (no `database.load_clips`) when `__preloaded_clip_snapshot` is provided.
- Edge preview path does not fall back to global `get_clips()` lookup building.

## Rollout Steps
1) Add `TimelineActiveRegion` module + unit tests.
2) Build and attach `drag_state.active_region` at edge-drag start.
3) Wire BatchRippleEdit dry-run to consume `__timeline_active_region` + `__preloaded_clip_snapshot`.
4) Switch preview payload to `shift_blocks`.
5) Update renderer preview drawing to use `shift_blocks`.
6) Remove renderer “rot” that attempted to re-scope in multiple places.

