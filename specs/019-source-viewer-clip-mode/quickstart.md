# Quickstart — Manual validation script for 019

**Spec**: [spec.md](spec.md) | **Plan**: [plan.md](plan.md)

This is the user-facing validation script. Run it manually in a JVE session after T10 (full Lua suite green) to verify the feature works end-to-end. Each step maps to an Acceptance Scenario from spec.md ## User Scenarios & Testing.

## Setup

1. Open JVE with a project that has:
   - At least one media sequence (file-wrapping clip in the browser).
   - At least one clip sequence (regular timeline) with two clips on a single track, separated by a gap or adjacent.
2. Verify the source monitor is empty ("Source" title only) and the timeline panel shows the clip sequence.

## A — Browser routing (FR-021)

3. **Double-click the media sequence in the browser**. ✅ Expect: source monitor loads it; title shows `"Source: <sequence_name>"`; selection_hub publishes `item_type="sequence"`; inspector shows sequence schema.
4. **Double-click the clip sequence in the browser**. ✅ Expect: TIMELINE panel loads it as the active record sequence (NOT source viewer). Focus moves to timeline.
5. **Click the clip sequence in the browser, then press Opt+Return** (FR-022). ✅ Expect: source monitor loads the clip sequence (staged mode); title shows `"Source: <clip_seq_name>"`.

## B — Live-bound entry via timeline double-click (FR-026)

6. With a clip sequence loaded as the active record, **double-click a clip on the timeline**. ✅ Expect:
   - Source monitor loads THAT clip in live-bound mode.
   - Title shows `"Source: <clip_name> (in <owner_sequence_name>)"`.
   - Inspector shows the clip schema (NOT sequence schema).
   - Source viewer's mark IN and mark OUT visibly correspond to the clip's `source_in_frame`/`source_out_frame`.

## C — Live-bound retrim, overwrite mode (FR-013, FR-014, FR-016d, FR-016a)

7. With the clip live-bound and trim mode at default (overwrite), **scrub the source-viewer playhead to a frame INSIDE the current OUT mark, then press `O`**. ✅ Expect:
   - The timeline clip immediately shrinks: its right edge moves to the new OUT.
   - Downstream clips on the same track DO NOT shift (gap appears if they were adjacent).
   - One undo entry created (verify via the menu / Cmd+Z trial then redo).
   - Source viewer playhead remains where it was (FR-016a) — even though it may now be outside the new in/out range.
8. **Press Cmd+Z** (Undo). ✅ Expect: the clip is restored to its prior duration. Downstream clips unmoved.

## D — Live-bound retrim, ripple mode (FR-008..012, FR-013)

9. Toggle trim mode to ripple. Since UI placement is deferred (FR-024 has no default binding), this step requires manually invoking `ToggleTrimMode` from the keyboard customization dialog OR using `command_manager.execute("ToggleTrimMode")` in a `--test` script.
10. **Press `O` again at a frame before the current OUT**. ✅ Expect:
    - Clip shrinks AND every clip after it on the same track shifts left to close the gap.
    - One undo entry.

11. Toggle trim mode back to overwrite (or restart JVE — session-transient, FR-010).

## E — F-key path unchanged (FR-024)

12. With the timeline still showing the clip sequence, position the playhead over a clip. **Press F (MatchFrame)**. ✅ Expect:
    - Source monitor loads the *master* (media sequence) underlying the clip, NOT the clip.
    - Title shows `"Source: <master_name>"` (staged mode).
    - The master sequence's in/out marks are copied from the clip.
13. **Press `O` in source viewer**. ✅ Expect: the MASTER's `mark_out_frame` column updates. The timeline clip is NOT retrimmed. (Staged mode behavior — UNCHANGED by 019.)

## F — Effective source pass-through (FR-016d)

14. Re-enter live-bound mode (double-click a timeline clip).
15. **Press `.` (Overwrite into record)** OR drag to invoke an insert (the record-side target should be a separate track than the live-bound clip's track).
16. ✅ Expect: a new clip lands on the record timeline whose `source_in_frame` / `source_out_frame` match the live-bound clip's source range. The live-bound clip itself is unaffected.

## G — Auto-unload on clip deletion (FR-004a)

17. With a clip still live-bound, select it on the timeline (click). Press Delete.
18. ✅ Expect: the timeline clip is gone; the source monitor goes blank (`"Source"` title only); `source_loaded_changed(nil, prev_clip_id)` was emitted (verify via inspector — it should go blank or fall back to whatever the active panel's selection is).

## H — Stays-put on different timeline-clip selection (Acceptance scenario 7)

19. Re-enter live-bound mode for clip A (double-click).
20. **Single-click a different clip B on the timeline** (just selection, no double-click).
21. ✅ Expect: source viewer still shows clip A (no auto-switch). Inspector switches to clip B's properties (timeline panel publishes the new selection). Source viewer only changes target on explicit double-click / `OpenClipInSourceMonitor` invocation.

## I — Key-repeat suppression (FR-016b)

22. Re-enter live-bound mode. Hold `O` for ~1 second.
23. ✅ Expect: ONE undo entry (not multiple). Release and press `O` again — second undo entry.

## J — ClearMarks disabled in live-bound (FR-016c)

24. With a clip live-bound, **press Alt+X** (`ClearMarks`).
25. ✅ Expect: no mutation to the clip. A log event records "not applicable in live-bound source-viewer mode". The clip's `source_in_frame` / `source_out_frame` are unchanged.

## K — Non-trim mutation re-resolve (FR-004b)

26. With a clip live-bound, rename it via the inspector or by mutating its `name` field.
27. ✅ Expect: source viewer's title updates to reflect the new name (no manual reload). Source viewer re-resolves clip + source sequence under the covers (FR-004b).

## Definition of Done for this quickstart

- All steps 3-27 pass as described.
- No regressions on existing manual flows: browser double-click on media still loads source, F-key still does MatchFrame, Alt+X still clears marks on the timeline / when source is in staged mode.
- No new luacheck warnings; `make -j4` clean.
