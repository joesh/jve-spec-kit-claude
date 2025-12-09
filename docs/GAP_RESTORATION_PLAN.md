# Gap Materialization Restoration Plan

## Context

Multiple compacts claimed the “temporary gap clip” system from the pre‑migration codebase had been restored, yet the current tree still uses the interim shortcut (rewriting `gap_after` and sliding adjacent clips). The result is a steady stream of ripple/roll regressions: gap trims crash, rolls cannot involve gaps, previews drift with the cursor, and DB occlusion errors resurface. This document records the concrete findings and the plan required to get back to the known-good behaviour the project had before the rational timebase work.

## Findings

1. **No temporary gap clips are created.** `BatchRippleEdit` still rewrites `gap_after` into `gap_before`/`out` trims (src/lua/core/commands/batch_ripple_edit.lua:197‑215) and `apply_edge_ripple` errors on `gap_after`. The renderer/picker never see a standalone gap item.
2. **Gap previews translate clips instead of resizing gaps.** `edge_drag_renderer` is invoked with empty trim constraints and treats `gap_*` edges as “move the neighbouring clip”, so the handle follows the cursor instead of staying anchored (docs/RIPPLE-ALGORITHM-RULES.md rule 7 is broken).
3. **Roll selection cannot span gaps.** `edge_picker.build_boundaries` reuses the adjacent clip id for both sides of a gap boundary, so `pick_edges` refuses to form a roll because it requires two distinct clip ids.
4. **Planned mutations still overlap.** Without temp gap inserts the update order can create transient overlaps and trigger the database `VIDEO_OVERLAP` constraint, especially when closing a gap causes the next clip to move into the previous clip’s original slot.
5. **Trailing gaps are invisible.** Gap selection never surfaces the tail gap after the last clip, so users cannot ripple the final hole and the command receives raw `gap_after` edges that crash.

These symptoms match the reports the user has been seeing (gap ripple crash, roll selection missing, downstream clips locked to old positions, etc.).

## Restoration Plan

1. **Reintroduce gap materialisation layer.**
   - Before running any clip edits, scan each affected track and explicitly insert temporary gap rows (one before and one after each real clip) that behave like clips with `clip_kind = 'gap'`.
   - Carry those temp rows through `apply_edge_ripple` so `edge_type == "gap_*"` manipulates the gap object rather than a neighbouring clip.
   - Ensure command dry-run paths also materialise gaps so previews show the anchored handle.
2. **Update selection & renderer to treat gaps as first-class items.**
   - `edge_picker.build_boundaries` should assign unique ids for gap objects (e.g., `temp_gap_<track>_<start>`) so rolls across gap+clip boundaries are legal.
   - `edge_drag_renderer` must clamp and color edges based on the real limits of the gap or clip and keep the edge anchored (green when legal, red when clamped).
   - Gap selections should survive end-of-track positions (fix `find_gap_at_time` to materialise tail gaps).
3. **Apply mutations via temp gaps to avoid overlaps.**
   - When a clip shrinks or moves, first insert/update the downstream gap clip, then update the clip, then adjust the next clip. This mirrors the pre‑migration order and avoids `VIDEO_OVERLAP`.
   - Wrap per-track mutations in a single transaction so the DB only sees gap placeholders while real clips are in-flight.
4. **Share invariant constraints with the UI.**
   - The clamping rules used by `BatchRippleEdit` must be surfaced to the preview renderer so the cursor zones turn red when you run out of room, matching Premiere’s behaviour.
5. **Tests before fixes.**
   - Add Lua regression tests: `gap_after` ripple (already failing), gap roll against gap+clip, multi-track ripple that shortens upstream clips without moving their timeline start, drag-block test ensuring moving clips consider pending moves, etc.
   - Capture record/replay tests that cover the user’s canonical layout (three clips with overlapping positions) for quick verification.

## Guardrail / Invariant

This materialised-gap pipeline is not an optional optimization—it is the compatibility baseline with every major NLE we are targeting. Any refactor or migration **must preserve**:

> “Gaps are first-class timeline items. Ripple/roll operations must act on gap objects exactly the same way they act on clips, including previews, cursor zones, constraint enforcement, and command mutation ordering.”

If a future change proposes to “simplify” the system by deleting temp gaps or collapsing `gap_*` edges back into clip trims, that change is a regression by definition and must not be merged.

Keep this document referenced (see ENGINEERING.md) whenever gap/ripple logic is touched so future contributors know this requirement is non-negotiable.
