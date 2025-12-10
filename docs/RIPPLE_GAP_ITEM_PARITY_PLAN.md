# Gap/Item Parity Refactor Plan

## Context
Ripple/roll currently relies on scattered `is_temp_gap` checks, renderer previews that ignore dry-run clamps, and dry-run payloads that do not surface the exact clip/gap geometry returned by the command. This violates Rule 1 (items) and Rule 12 (dragged edge drives the delta), makes previews diverge from execution, and forces every fix to know whether an item is a clip or a gap. We need a test-backed refactor to restore the pre-rational behaviour where gaps are first-class items.

## Guardrails
- Follow `ENGINEERING.md` Rule 1.14 and `docs/RIPPLE-ALGORITHM-RULES.md`: gaps == clips == items.
- No fallbacks/defaults (Rule 2.13). Errors must surface immediately.
- Regression tests precede every fix (Rule 2.20).
- Keep the temp-gap materialisation pipeline from `docs/GAP_RESTORATION_PLAN.md`—do not rewrite gap edges back into neighbour trims.

## Phase 1: Regression Coverage & Test Harness
1. Capture the canonical “three clips with a V2 overlap” layout in a reusable helper under `tests/helpers/ripple_layout.lua` (V1 clip – gap – V1 clip, V2 in the gap).
2. Add failing regressions before touching behaviour:
   - `tests/test_ripple_preview_clamp.lua`: dry-run `BatchRippleEdit` with V1 `gap_after` + V2 `out` and assert payload’s `affected_clips` already reflect the clamp (no V2 duration past the neighbour, gap duration never negative).
   - `tests/test_edge_selection_restore.lua`: select a clip+gap edge pair, persist/restore timeline state, verify selection survives restart.
   - `tests/test_gap_roll_selection.lua`: prove rolls can include gaps (selection + command execution).
3. These tests lock in the current failures so the fixes cannot regress silently.

## Phase 2: Command-Layer Cleanup (BatchRippleEdit) ✅
1. Temp gap creation (Completed)
   - `create_temp_gap_clip` now assigns ±1e15 media bounds and the command errors if a gap fails to materialize.
2. Payload fidelity (Completed)
   - Dry-run payloads surface `affected_clips`/`shifted_clips` directly; renderer normalization uses them verbatim.
3. Special-case deletion (Completed)
   - All `clip.is_temp_gap`/`__temp_gap` branches removed; constraints and trims key off raw `edge_type`.
4. Persistence (Completed)
   - Lead edge metadata is already preserved via `edge_infos` and tested by the new regression suite.

## Phase 3: UI Layer Fixes
1. Renderer preview
   - `timeline_view_renderer` already receives dry-run payloads; change the yellow preview rectangles to use the clamped `preview_affected_clips`/`preview_shifted_clips` instead of re-deriving geometry from `edge_delta`.
   - Continue to use `preview_clamped_delta` for cursor brackets, ensuring yellow overlay and brackets stop at the same clamp.
   - Keep drawing temp gaps by routing unknown ids through `build_temp_gap_preview_clip`.
2. Tests
   - Extend `tests/test_timeline_view_gap_edge_render.lua` (or add a new capture-style test) to inject fake preview payloads and assert the yellow rectangles stay within the clamped boundary pixels.
3. Clean up utilities
   - Delete the `edge_utils.normalize_edge_type` stub and audit callers so bracket logic is explicit.

## Phase 4: Gap-as-Item Sweep
1. ✅ Gap parity regression (`tests/test_gap_item_parity.lua`) exercises ripple and roll scenarios mixing gaps and clips.
2. 🚧 Documentation: capture the “gap items have ±∞ media bounds” invariant in a short doc and reference it from `ENGINEERING.md`.
3. 🔍 Audit remaining modules (timeline constraints, renderer helpers, tests) for any residual `temp_gap_` branches that can be removed or justified.

## Outcome
- Previews honour the same clamps as execution (no more yellow-rectangle drift).
- Undo/redo/restart keep gap selections intact.
- BatchRippleEdit code no longer forks on temp gaps; gaps behave as first-class items.
- Tests guarantee future changes cannot regress gap behaviour or sneak in new fallbacks.
