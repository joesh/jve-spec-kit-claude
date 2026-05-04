# Quickstart: Source-in-Timeline + Track-Header Redesign + Tristate Sync-Lock

**Feature**: 015-source-in-timeline
**Date**: 2026-05-03

End-to-end manual smoke test. After implementation completes (post-Phase 4), an editor MUST be able to follow this script and reproduce every step with the documented outcome. This script doubles as the integration-test scenario for `/tasks`.

---

## Prerequisites

1. Build is green: `make -j4` from repo root reports zero failures.
2. JVEEditor binary at `./build/bin/JVEEditor` has been rebuilt with this feature's code.
3. Schema migration has been applied; existing project DB at `~/Documents/JVE Projects/Untitled Project.jvp` either deleted or re-created (rule 2.15 — no auto-migration of pre-existing projects).
4. A multichannel test source clip is available — recommend an 8-channel BWF or equivalent (e.g., the project's existing `A023_10251352_C026.mov` if it has multi-track audio).

---

## Step 1 — Open a project and load a source

1. Launch `./build/bin/JVEEditor`.
2. Open or create a project with at least one Record sequence (3+ audio tracks recommended for downmix scenarios).
3. In the Browser, double-click a multichannel source clip.
4. Verify: the **Source Monitor** displays the source. Verify: the timeline tab strip does NOT yet contain a Source tab (FR-001a — the SourceTab is closed by default; user must explicitly open it).

**Expected:** Source Monitor populated, timeline still shows the active Record sequence's tab. No SourceTab in the strip yet.

---

## Step 2 — Open the Source tab

1. From the menu, invoke **Show Source Tab** (location TBD per /tasks; menu spec).
2. Verify: a new tab appears in the timeline tab strip, **blue accented**, labeled with the source clip's file name.
3. Verify: the timeline body still displays the Record sequence's content (the Source tab is now visible but not yet displayed).

**Expected:** SourceTab present, blue, inactive. Active Record tab still red and displaying.

---

## Step 3 — Switch the displayed tab to the Source

1. Click the SourceTab in the strip.
2. Verify: the timeline body now renders the source clip's tracks (V1 + audio channels).
3. Verify: the timecode readout is the source's TC (e.g., `13:52:18:11`).
4. Verify: the panel takes on the blue accent (header tint, gradient).
5. Verify: the **active sequence pointer is unchanged** (FR-005). Open a separate transport / inspector view and confirm it still shows the Record sequence as the active edit target.

**Expected:** timeline displays source content. Active sequence is still the previously-clicked Record sequence.

---

## Step 4 — Inspect track headers (per-channel mode, default)

1. With the SourceTab displayed, examine each audio track header.
2. For each row, verify the cell layout (left to right):
   - Source-id button (e.g. `A1`), **filled blue** (the SourceTab is displayed).
   - Record-patch-id button (e.g. `A1`), **outline red** if a patch exists for that source-track, or a dashed empty cell if no parallel record track exists.
   - Track label (e.g. `boom`).
   - Lock icon (graphical, replaces letter "L").
   - Sync-mode cell (cycling icon: dot/wave/blade).
   - Vertical S/M stack (rightmost).
3. Verify: there is NO `P` button and NO `R` button on any row (FR-013, FR-014).
4. Verify: the channel-count label appears inline on audio rows (e.g., `2.0`, `(2)`, `1.0` per FR-021).

**Expected:** new header layout matches FR-008. No P, no R. Lock is iconic.

---

## Step 5 — Toggle a source patch off

1. On source row A1, click the source-id button (`A1`) once to toggle it OFF.
2. Verify: the source-id button visually dims (FR-031 — OFF state visually distinct from ON).
3. Verify: open a SQL inspector; the `patches` row for `(active_sequence_id, source_track_index=1)` has `enabled=0`.
4. Verify: NO `snapshots` row was created for this command (FR-040 — non-undoable). Direct DB inspection confirms.
5. Press **Cmd-Z**.
6. Verify: the patch toggle is NOT reverted. The patch remains `enabled=0`.

**Expected:** per-patch on/off works; OFF is silent-drop intent (FR-029a, FR-035); not undoable.

---

## Step 6 — Drag-redirect a patch

1. Re-toggle source A1 ON.
2. Drag the source-id button on row A2 (`A2`) onto the row for record A4 (or beyond — even if record A4 doesn't exist yet).
3. Verify: the dragged source-id snaps to the destination row.
4. Verify: `patches` row for `(seq, source_track_index=2)` now has `record_track_index=4`.
5. Verify: NO `snapshots` row.
6. Press **Cmd-Z**.
7. Verify: drag NOT reverted (FR-040 — non-undoable).

**Expected:** drag-redirect works and persists; not undoable.

---

## Step 7 — Modifier-drag stack

1. Hold **Option/Alt** and drag source A3 onto record A1 (which already has source A1 patched to it).
2. Verify: `patches` rows now include both `(seq, source_track_index=1, record_track_index=1)` and `(seq, source_track_index=3, record_track_index=1)` — two sources both targeting record A1.
3. Verify: track header on record A1 shows stacked source pills (e.g., `A1+A3` visual).

**Expected:** stacking creates the second patch row; visual indicator updates.

---

## Step 8 — View-toggle modifier

1. With `source_routing_view='per_channel'` (default), hold **Option/Alt** while hovering over the source row.
2. Verify: the per-channel buttons collapse to a single per-clip button for the duration of the hold.
3. Verify: `patches` rows are unchanged (the view flip is purely UI).
4. Release.
5. Verify: per-channel buttons re-expand.
6. Switch the user preference `source_routing_view` to `'per_clip'`. Verify: source row default-displays one button.
7. Hold modifier. Verify: row expands to per-channel buttons.

**Expected:** view-toggle is reversible; underlying patches unchanged across either flip.

---

## Step 9 — Sync mode cycle and Cut behavior

1. On the active Record sequence's track A4 (or whichever track holds music / room tone), click the sync-mode cell.
2. Verify: sync-mode cell cycles `Off → Ripple → Cut → Off` on successive clicks. Each click writes to `tracks.sync_mode` and emits `sync_mode_changed`. NO `snapshots` row.
3. Set the music track to **Cut** mode.
4. Set dialog tracks to **Ripple** mode (the default — they should already be there).
5. Place a music clip spanning a known timecode point (say, sequence frame 100 to 500), with the trim point falling inside the clip (say, frame 200).
6. Perform a ripple-trim on a dialog clip such that N=12 frames are inserted at frame 200.
7. Verify (FR-026 Cut branch):
   - The music clip is split at frame 200 into two halves.
   - The downstream half ripples by +12 frames (now at sequence frame 212–512).
   - Music plays seamlessly from a source-time perspective: the audio you hear past the split picks up where it left off.
   - A gap clip (existing JVE gap mechanism) appears on the music track from frame 200 to 212.
   - NO new "filler" entity exists — just the same gap-clip mechanism JVE already uses.
8. Press **Cmd-Z**. Verify: the ripple itself IS reverted (it's an editing command). But the sync_mode setting on the music track is NOT reverted (FR-040).

**Expected:** Cut = Ripple + auto-split spanning clips. Music stays in sync with dialog. Sync_mode is sticky.

---

## Step 10 — Off mode

1. Set the slate track's sync_mode to **Off**.
2. Perform a ripple-trim on dialog.
3. Verify: the slate track is wholly unaffected. Its track length is unchanged. Its clip positions are unchanged. (FR-026 Off branch.)

**Expected:** Off-mode track sits out of ripple operations entirely.

---

## Step 11 — FR-040a regression test (Solo / Mute / Lock non-undoable)

1. Click the Solo button on track A1.
2. Verify: `tracks.soloed` for A1 is now `1`.
3. Verify: NO `snapshots` row was created.
4. Verify: NO entry pushed to the per-sequence undo stack (`commands` table — the Solo command's row exists but is excluded from the undo cursor; OR the command's `undo_group_id` is NULL).
5. Press **Cmd-Z**. Verify: `tracks.soloed` is still `1`. Solo is NOT reverted.
6. Repeat for Mute and Lock.

**Expected:** all three toggle types are non-undoable, fixing the FR-040a pre-existing bug.

---

## Step 12 — Solo coexists with Mute (no mutex)

1. With Solo lit on A1, click Mute on A1.
2. Verify: `tracks.muted = 1` AND `tracks.soloed = 1` simultaneously. NO error.
3. Verify: the audio routing correctly handles the both-on case (FR-017).

**Expected:** solo and mute are independent; both can be on; no exclusion.

---

## Step 13 — Video Mute and Solo

1. On a video track that has content at the playhead, click Mute.
2. Verify: at playback, the muted video track is skipped. Lower non-muted tracks are reconsidered for topmost (FR-019).
3. Click Solo on a different video track that has content at the playhead.
4. Verify: at playback, only soloed video tracks compose top-down (FR-020 additive-soloed-set).

**Expected:** video Mute/Solo apply with the documented compositing semantics.

---

## Step 14 — 3-point edit math + ghost mark

1. Mark **src IN** at a known TC on the source clip.
2. Mark **src OUT** at another TC on the source clip.
3. Mark **rec IN** at a chosen point on the active Record sequence.
4. Verify: a **ghost** (dashed) mark appears at the computed `rec OUT` TC on the Record sequence's ruler.
5. Verify: the inspector / status bar shows the ghost mark labeled `(computed)`.
6. Switch to the SourceTab. Verify: source marks (IN, OUT) are still visible. Switch back to the Record tab. Verify: rec marks + ghost still visible.

**Expected:** 3-point math is tab-independent (FR-038).

---

## Step 15 — Active sequence pointer immutability while SourceTab displayed

1. Click the SourceTab.
2. Verify: active sequence pointer unchanged (Step 3 confirmed this; re-confirm).
3. Trigger a 3-point edit (e.g., Splice / Overwrite via menu or keyboard).
4. Verify: the edit operates on the **active Record sequence**, NOT the source. The source clip is the SOURCE side; the rec side targets the active Record sequence even though the SourceTab is the displayed tab.

**Expected:** edit targets the active sequence regardless of which tab is displayed (FR-038, scenario 11).

---

## Step 16 — Close + reopen the project

1. Save the project. Close JVEEditor.
2. Re-launch and re-open the project.
3. Verify: all `patches` rows persist (FR-039) — re-inspect the track headers to confirm the on/off and routing match what was saved.
4. Verify: `tracks.sync_mode` values persist (FR-028) — the music track is still in Cut mode.
5. Verify: the SourceTab open/closed state is restored to what it was at save time (FR-001a per `project_settings.open_sequence_ids` extension).
6. Verify: the `source_routing_view` per-user preference persists across the relaunch.

**Expected:** full persistence round-trip.

---

## Step 17 — Auto-create record track at edit time (FR-029b)

1. With an 8-channel source loaded and the active Record sequence having only 3 audio tracks, ensure source A4-A8 patches are ON (toggle them).
2. Their `record_track_index` defaults to identity (4–8), which exceed the sequence's existing 3-track count.
3. Perform an Insert/Overwrite edit.
4. Verify: the active Record sequence now has 8 audio tracks. Tracks A4-A8 were auto-created with the default sync_mode (`'ripple'`) and default S/M/lock state.
5. Press **Cmd-Z**. Verify: the edit AND the auto-created tracks are reverted as a single undoable unit (one Cmd-Z reverts both — FR-029b).

**Expected:** auto-create works inside the same undo group as the edit.

---

## Failure modes to confirm

| Action | Expected behavior |
|---|---|
| Drag audio source onto a video record track | Refused with explicit error (FR-010a cross-track-type refusal) |
| Insert duplicate `(sequence_id, source_track_index)` patch row | SQL UNIQUE error |
| Insert track with `sync_mode='invalid'` | SQL CHECK error |
| Activate SourceTab when no master is loaded | Empty placeholder renders (FR-007b); no crash |
| Pass non-Off/Ripple/Cut value to ripple-pipeline dispatch | Hard assert with track id and bad value (rule 1.14) |

---

## Test-script equivalent (for /tasks)

The `/tasks` command should produce concrete `tests/test_*.lua` files — including a `tests/test_quickstart_015.lua` that mechanizes Steps 1–17 against `--test`-mode JVEEditor. The test asserts each "Expected" outcome programmatically.

Per rule 2.20, the FR-040a regression test (Step 11) MUST be written FIRST and verified to FAIL on the current codebase before the SetTrackProperty refactor (C4) lands. After the refactor, the same test passes.
