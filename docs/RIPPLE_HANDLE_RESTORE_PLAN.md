# Ripple Handle Restoration Plan

This document captures the agreement made on 2025‑12‑05 regarding how to bring the rational-timebase branch back in line with the canonical ripple rules (`docs/RIPPLE-ALGORITHM-RULES.md`). Keep this as the reference when future work touches `BatchRippleEdit`, gap handling, or the timeline UI.

## Guiding Principles

1. **Only two handle types exist: `[` and `]`.** Gaps and clips behave identically—any edge you can drag is either a left bracket (`[`) or a right bracket (`]`). Naming things `gap_before` / `gap_after` was an implementation shortcut that obscured the real rules.
2. **Dragging a `[` to the right always shrinks the owning item**, regardless of whether that item is a clip or a gap. Dragging `[` left grows it. `]` behaves symmetrically for the trailing edge. This mirrors both the rule sheet and the pre‑rational behavior.
3. **Only edges participating in the current ripple should materialize gaps.** We do **not** want to generate placeholder clips for every gap in the sequence—just the gaps whose handles are being dragged (plus their immediate neighbours).
4. **Delta negation only happens for opposing brackets.** The dragged edge determines the sign (Rule 12). If an opposing edge participates in a roll, it gets the negated delta (Rule 11). Nothing else should flip the delta.

## Implementation Strategy

1. **Revert the “compensating” test changes.**
   * `tests/test_batch_ripple_gap_*` and `tests/test_ripple_multitrack_overlap_blocks.lua` go back to asserting the original semantics (drag `[ right ⇒ gap shrinks). This gives us a red test suite that reflects the intended behaviour.

2. **Materialize affected gaps on demand.**
   * When `BatchRippleEdit` receives `edge_infos`, inspect only the edges in that list.
   * For any edge that exposes empty space (e.g., a `[` handle on the leading side of a clip, or a `]` on the trailing side), create a temporary gap clip spanning the void between its neighbours. These temp clips live only in memory (they never hit the DB) and are bound to the current command.
   * Record these temp ids in the dry-run payload so the UI can render anchored gap handles.

3. **Normalize every edge into `in`/`out` before applying deltas.**
   * Use `edge_utils.normalize_edge_type` (or equivalent) to collapse all edge strings (clip or gap) to `in` (`[`) or `out` (`]`).
   * Feed that normalized value into `apply_edge_ripple`, which already knows how to trim the owning item based on bracket direction. Remove the `gap_before`/`gap_after` branches.

4. **Reuse `apply_edge_ripple` for both clips and gaps.**
   * Because temp gaps carry `timeline_start`, `duration`, and `source_in/out`, the same math works for either item type. `[`: adjust the start side; `]`: adjust the tail. No special-casing.

5. **Propagate downstream shifts via cumulative events.**
   * Keep the existing “ripple events” approach: every edited edge contributes a timeline-length delta at its ripple point. Downstream clips sum every event that happens at or before their start time.
   * With normalized brackets this produces the right sign without checking “gap_before” vs “gap_after”.

6. **Roll behaviour stays local.**
   * A roll occurs when both sides of the same edit (`][`) are selected. The dragged edge sets the delta sign; the opposing bracket receives the negated delta so one item grows while the other shrinks (Rule 11).
   * No downstream shift propagates during a roll—the timeline length stays constant (Rule 9).

7. **UI alignment (post command fix).**
   * Edge selection/hover already exports `[` or `]`. Once the command behaves correctly, preview payloads will show the temp gaps, and cursor behaviour will again match the rule sheet.

## Verification Checklist

* `tests/test_ripple_overlap_blocks.lua`, `tests/test_batch_ripple_gap_*`, and `tests/test_ripple_multitrack_overlap_blocks.lua` all pass without modifying their original assertions.
* Manual drag of a gap `[`: dragging right shrinks the gap, dragging left grows it. Downstream clips shift by the actual drag distance.
* Multi-track ripple where one track has the tighter gap clamps both tracks to that delta (Rule 8).
* Roll selections (`[` + `]`) negate the delta for the opposing bracket only, and the timeline length stays constant.

Keep this plan close any time we revisit ripple/roll logic so we don’t drift back into “gap_before” special cases.
