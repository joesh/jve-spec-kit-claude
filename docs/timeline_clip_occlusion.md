# Timeline Clip Occlusion Enforcement

**Last updated:** 2025‑10‑24  
**Area:** Timeline edit mutator layer

---

## Background

Historically, commands such as `Overwrite` manually trimmed or deleted occluded clips, while other operations (drag, nudge, ripple) *prevented* overlaps by clamping moves. That left gaps:

- Batch drag/nudge of adjacent clips could trim the wrong clip when the save order changed.
- Overlaps introduced by new commands would silently persist unless each command re‑implemented the trimming logic.
- Ripple edits occasionally produced zero-length clips, tripping the `duration > 0` constraint.

## Current Behaviour

1. **Centralised occlusion logic**  
   `core.clip_mutator.resolve_occlusions` now owns the rules:
   - Inserting a clip trims or deletes anything it covers.
   - Moving a clip across neighbours applies the same rules.
   - Clips straddling the new region split into left/right fragments (new UUID for the tail).

2. **Model integration (`Clip:save`)**  
   - Normalises `start_time`, `duration`, `source_in/out` to integer ms, clamping duration ≥ 1.
   - Always runs occlusion resolution; callers may supply `{pending_clips = {...}}` so the mutator evaluates a batch move atomically. If those future positions still collide, the save fails instead of trimming.
   - A dedicated `Clip:restore_without_occlusion` helper is reserved for undo/redo to persist historical states without reapplying occlusion.

3. **Commands updated**  
   - `Overwrite` simply calls `clip:save(db, {resolve_occlusion = true})`.
   - Clip moves (`Nudge`) pre-compute future start times and pass them via `pending_clips`, so the mutator validates the whole move atomically and keeps the invariant intact.
   - Ripple edit downstream selection now uses `>= ripple_time - 1` to ensure adjacent clips shift, and provides the same pending map so no temporary trimming happens before the batch shift.
   - Insert calls into the mutator so clips covering the insertion point split into left/new/right fragments automatically.
   - Overwrite reuses the fully-covered clip's ID when the incoming media completely replaces it, keeping downstream commands pointed at the same identifier.
   - Gap-edge drags materialise temporary clips for constraint evaluation, but once a gap collapses the selection is normalised back onto the real clip edge, guaranteeing the next drag/redo starts from the same state as the original command.
   - RippleEdit and BatchRippleEdit now save affected clips with occlusion resolution enabled, so aggressive gap closures trim or delete overlapped media instead of leaving hidden overlaps across tracks.
   - Batch ripple clamps negative downstream shifts so clips never rewind past t=0, preserving replay safety during multi-track gap closures.

4. **Regression coverage**  
   `tests/test_clip_occlusion.lua` now covers tail trims, deletion, splits, multi-clip moves, gap expansion/contraction, selection normalisation after gap closure, and the multi-track batch ripple scenario that previously left overlapping clips.

## Migration Notes

* All future commands that persist timeline clips should call `clip:save`, optionally providing `pending_clips` when batching moves, and avoid hand-written trimming logic in executors. Use `clip:restore_without_occlusion` only for replay/restore code paths.
* If a command manipulates multiple clips simultaneously, pre-compute their future positions and pass them via `pending_clips`; the mutator will abort the save if those positions would still collide.
* When adding new timeline operations, add Lua tests similar to `test_clip_occlusion.lua` to lock in occlusion expectations.

## Open Items

- Evaluate whether `timeline_constraints` should be relaxed further now that the mutator enforces safety automatically.
- Investigate exposure of the mutator module for C++ callers so native tools can leverage the same behaviour.
- Add UI-level integration tests that drag overlapping clips to confirm the end-to-end path. 
