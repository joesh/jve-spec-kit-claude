# Ripple Gap Debug Context (Dec 11)

## Canonical Test Layout
- V1 track: clip c1 → gap g1 → clip c2.
- V2 track: single clip overlapping tail of V1.c1 and head of V1.c2.
- Using `tests.helpers.ripple_layout` and new regression file `tests/test_batch_ripple_gap_drag_behavior.lua`.

## Regressions Captured in Tests
1. **V2 `]` drag right**
   - Selection: V1 gap `[`, V2 clip `]`.
   - Lead edge should be the V2 `]` (the user clicks on V2 when starting the drag).
   - Delta positive (opening the gap).
   - Expected behaviour: V2 hits its own media limit; gap should open fully even if it exceeds existing gap space.
   - Test asserts V1.c2 moves by full delta; dry-run payload should have empty `clamped_edges`.

2. **V1 `[` drag left**
   - Same selection, but lead edge should be V1 gap `[`.
   - Delta negative (closing the gap).
   - V2 has limited media; expected behaviour: V2's `]` clamps at media, highlighted red.
   - Test asserts dry-run payload includes `clip_v2_overlap:out` in `clamped_edges` and V2 duration stays within media.

## Current Status
- Tests are failing at scenario 1: command clamps to the gap (~600 frames) instead of taking full delta (+1800).
- Need to adjust `BatchRippleEdit` so positive delta for V2 `]` honours clip media limit (not gap width).
- For negative delta (closing gap), ensure `clamped_edges` flags V2 `]` when media exhausted.

## Next Steps After Restart
1. Re-run `luajit tests/test_batch_ripple_gap_drag_behavior.lua` to see current failures.
2. Inspect `BatchRippleEdit` clamp logic (`global_min_frames/global_max_frames` and `clamped_edge_lookup`). Ensure appropriate edges marked.
3. Fix positive delta logic so V2 leads and gap does not constrain.
4. Fix `clamped_edges` map so media limit clamps mark V2 `]` instead of gap.
5. Re-run tests + `make -j4`.
