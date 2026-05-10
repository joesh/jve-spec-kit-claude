# Feature Specification: Source-in-Timeline + Track-Header Redesign + Tristate Sync-Lock

**Branch**: `015-source-in-timeline`
**Created**: 2026-05-03 · **Rewritten**: 2026-05-09 (50-FR morass → 6 orthogonal features)
**Status**: Draft

**Design reference**: `design examples/source_in_timeline_v4.html` (structure + semantics only — JVE's existing visual language wins where they diverge). v1/v2/v3 superseded.

---

## Architectural foundation: TimelineTab abstraction

The timeline panel hosts a strip of **TimelineTabs**. Each TimelineTab is a **thin handle**: `{id, kind, sequence_id}` plus listener pub/sub. All displayed state (marks, viewport, playhead, scroll) lives on the **sequence row** — tab getters pull lazily so model mutations propagate without explicit cache sync (MVC pull, rule 3.0). Selection and drag are **global** on timeline_state (selection is one-at-a-time across the app; drag is global so cross-timeline drag works).

The strip is a subpart of TimelineView. It is reinitialized whenever TimelineView is reinitialized (i.e., on `project_changed`). The codebase already persists the open-tab list as `open_sequence_ids` on `project_settings`; the strip encapsulates that existing state rather than inventing a parallel one.

Two pointers select tabs:

- **DisplayedTab** — the tab whose content the timeline body is rendering. Exactly one.
- **ActiveRecordTab** — the Record tab targeted by edits (3-point rec side, patch destination). Never the SourceTab.

Switching the displayed tab is a pointer rebind on the holder; consumers (renderer, ruler, scrollbar, listeners) read fields off the displayed tab's referenced sequence directly. There are no display-aware accessor wrappers, no scribble across a flat singleton, and no flag forests deciding "am I source or active right now?".

TimelineTabs come in two kinds:
- **RecordTab** — one per open sequence (existing behavior, encapsulated).
- **SourceTab** — singleton; its sequence_id = the sequence (not necessarily a master) currently loaded in the source monitor. On a brand-new project (no persisted tab state), the SourceTab defaults to **open** and renders the empty placeholder until a source is loaded.

Visual indicators on the strip: an **underline** marks the DisplayedTab. **Red text** marks the ActiveRecordTab. Source tab styled with blue accent; Record tabs red.

---

## Features

### F1 · SourceTab in the timeline panel
A singleton SourceTab joins the existing Record tab strip. It displays the source monitor's loaded sequence at full timeline fidelity (track headers, waveforms, marks, scrubbing).

- SourceTab is **closeable** (× affordance) and **re-openable** via a "Show Source Tab" menu command.
- When open, the SourceTab is always the **first** tab in the strip.
- The SourceTab's open/closed state is **persisted across sessions** (same as RecordTabs).
- **Click-to-display, never to activate**: clicking the SourceTab updates `DisplayedTab` only. `ActiveRecordTab` is unchanged. Clicking a RecordTab updates both.
- **Empty placeholder** when no source is loaded.

### F2 · Track-Patches (source→record routing)
A Patch is a routing rule scoped to **`(record_sequence, source_track_index)`** → `{record_track_index, enabled}`. Distinct from `clip_links` (which is V↔A *clip* linkage). Stored in a new `patches` table; persisted; survives close+reopen.

**Per-sequence-sticky model.** Patches are state of the record sequence's patch bay, not of any individual source clip. Loading a different source into the source monitor does NOT mutate patch state — the same patch rules apply to whatever source is loaded next. This matches Premiere (the documented mainstream model). Avid's per-clip-memory is rejected as the outlier; users get equivalent ergonomics from named presets (below).

- **Shape-gated visibility** (UI behavior, not data model): when the loaded source's track inventory differs from the patch bay's expectations, source rows that have no corresponding source channel are hidden / greyed (the patch button doesn't render). Switching to a same-shape clip restores them. The underlying `patches` rows are never deleted by load events — only visually filtered.
- **Defaults**: when a `(record_seq, source_track_index)` pair has no row, routing is identity (src N → rec N) and `enabled=true`. No patch rows are written until the user overrides. Absence ⇒ identity-and-enabled.
- **src-id ON/OFF**: clicking a source-track button flips `enabled` on the corresponding patch row (creates the row if absent; subsequent toggles update in place).
- **Edit-time inclusion gate**: a source channel participates in an edit iff `(no patch row exists, OR the patch row's enabled=1) AND record_track.autoselect=1`. OFF on either side drops the channel (intended exclusion, not silent failure).
- **Drag to redirect**: dragging a source button onto a different record track (or another source row's record cell) writes/updates `record_track_index` for that (sequence, src_index) patch row. Holding a modifier (default Option/Alt, rebindable) **stacks** — multiple sources targeting one record track produce a multi-channel clip on that record track at edit time.
- **Cross-type drag refused** (audio source onto video record, etc.).
- **Auto-create**: if an edit needs a `record_track_index` beyond the active sequence's track count, missing tracks are created up to that index in the same command (single undo unit). Filling 1..N is required — you cannot have a track 5 with no track 4.
- **Browser-drag-to-timeline** uses the dragged clip and the current patch bay (no parallel UI patch context); routing is consistent with what an Insert from Source Monitor would do.
- **Source Patch Presets** (named saved configurations): users may save the current patch bay state as a named preset for later recall. Stored per-project in a `source_patch_presets` table with optional keybinding. Recall replaces patch rows for the current record sequence; saving snapshots the current rows. This is the explicit-recall workflow that supersedes Avid's automatic per-clip memory.
- **Restore Default Patch** command (à la Premiere/Avid right-click): deletes all `patches` rows for the current record sequence. Subsequent edits revert to identity-routed-and-enabled defaults. Available from the menu and right-click on the src-id column. Per F6 this is non-undoable (deletion of routing preferences).
- **Per-user view preference** (`source_routing_view`, persisted in `~/.jve/`): `'per_channel'` (default) shows one button per source track; `'per_clip'` collapses the source's tracks into a single button. A held modifier (default Option/Alt, independently rebindable) temporarily flips the rendered view. Underlying `patches` rows are unchanged either way.

### F3 · Tristate sync-mode (off / ripple / cut)
Each track has a `sync_mode` ∈ `{off, ripple, cut}`, default `'ripple'` (matches existing pipeline). Header cell cycles **Ripple → Cut → Off** on click (sine-wave / blade / empty).

The ripple pipeline dispatches per-track before implicit-gap injection:
- **off** — track skipped; track length unchanged.
- **ripple** — existing uniform downstream shift.
- **cut** — same as ripple, but any clip spanning the trim point is split first; downstream half ripples normally; resulting empty interval renders via JVE's existing gap-clip mechanism. Splits use the existing blade/split quantization (sequence frame-rate).

### F4 · Track header redesign (S/M on video too)
Header cells, left to right: **src-id button | lock icon | rec-patch-id button | label (flex) | sync-mode cell | Solo/Mute vertical stack**.

- Solo and Mute are independent (a track can be both). **Solo always trumps Mute.**
- **Solo/Mute applies to video** as well as audio. On video: Mute skips the track during compositing (next-lower non-muted becomes topmost). Solo uses additive-set semantics — only soloed tracks composite, muted excluded from the set, non-soloed-non-muted ignored when ≥1 track is soloed.
- **src id button** renders filled blue when ON, outline-only when OFF.
- **rec-patch-id button** is the **auto-select** toggle (Avid term; Premiere calls the same behavior "track targeting") — NOT record arming. ON = this record track participates in selection-driven operations (Select-in-Range, Ripple Delete, marquee, range-based commands, etc.) and is a destination for incoming patched edits. OFF = excluded. The pair (src-id + rec-patch-id) is the patch affordance — no separate P button. No record-arm button.
- No track-type enforcement on audio (mono/stereo/N-channel coexist on one track, mirroring mixed-frame-rate tolerance).

### F5 · 3-point ghost mark
When 3 of 4 marks (src in/out, rec in/out) are set, the 4th is computed and rendered as a **dashed ghost** at its timeline position, labeled "computed" wherever shown textually. Source marks live on the loaded master sequence; record marks on the active record sequence; both persist regardless of which tab is displayed. Edit operations target `ActiveRecordTab` even when SourceTab is displayed.

### F6 · Non-undoable routing preferences (incl. pre-existing bug fix)
The following toggles are **session-level non-undoable preferences**: persisted to the project DB, restored on reopen, NOT on the per-sequence undo stack:

1. Patch enabled (`patches.enabled`, src-id on/off — keyed by (record_seq, source_shape, src_idx))
2. Patch routing (`patches.record_track_index`, drag-redirect)
3. Record-track auto-select (`tracks.autoselect`, rec-id on/off)
4. Track sync_mode
5. Track soloed
6. Track muted
7. Track locked

Solo/Mute/Lock currently land on the undo stack — pre-existing **BUG**. Per rule 2.20, a failing regression test is written first, then the fix lands.

Track volume/pan (`SetTrackMixValue`) IS undoable — distinct from these routing toggles.

---

## Schema

Forward-only migration (rule 2.15). Adds:
- `tracks.sync_mode TEXT NOT NULL DEFAULT 'ripple' CHECK(sync_mode IN ('off','ripple','cut'))`
- `tracks.autoselect INTEGER NOT NULL DEFAULT 1 CHECK(autoselect IN (0,1))` — auto-select (rec-id on/off, F4)
- new `patches(id, sequence_id FK→sequences ON DELETE CASCADE, track_type TEXT NOT NULL CHECK(track_type IN ('VIDEO','AUDIO')), source_track_index INTEGER NOT NULL, record_track_index INTEGER NOT NULL, enabled INTEGER NOT NULL DEFAULT 1 CHECK(enabled IN (0,1)), created_at INTEGER NOT NULL, UNIQUE(sequence_id, track_type, source_track_index))` — per-sequence-sticky; absence ⇒ identity-routed and enabled. `track_type` separates V and A index spaces (V1 and A1 are independent patch rows). Shape-gating happens at the UI layer (hide rows whose source channel doesn't exist on the current load), not the data layer.
- new `source_patch_presets(id, project_id FK→projects ON DELETE CASCADE, name TEXT NOT NULL, keybind TEXT, snapshot_json TEXT NOT NULL, created_at INTEGER NOT NULL, UNIQUE(project_id, name))` — named patch-bay configurations recall to current record sequence's `patches` rows.

`snapshots` table is **not** extended — non-undoable preferences write directly to their own columns.

---

## Acceptance scenarios

1. Source loaded + click SourceTab → timeline shows source tracks; ActiveRecordTab unchanged; SourceTab is first in the strip with blue accent and underlined. Click back to "Main" RecordTab → both pointers update; "Main" gains underline + red text; marks/patches/sync_mode preserved.
2. Source track unrouted → rec-patch slot empty (dashed/blank); first edit with src-id ON auto-creates rec track(s) up to the referenced index in one undoable unit.
2a. **Per-sequence-sticky patches**: in sequence R1, redirect src-A1→rec-A3 and toggle src-A4 OFF. Load a different source clip into source monitor → R1's patch bay is unchanged; the next edit from source monitor still routes A1→A3 with A4 dropped. Switch active sequence to R2 → R2's patch bay shows identity defaults (independent of R1). Switch back to R1 → A1→A3 and A4 OFF restored.
2b. **Shape-gated visibility**: with R1's A1→A3/A4-OFF patches set, load a stereo (2-ch) source → only the src-A1 and src-A2 buttons render in the header (src-A3 and src-A4 are hidden because the loaded source has no channel 3 or 4). Underlying `patches` rows are unchanged; loading a 4-ch source restores all four buttons with the same routing.
2c. **Restore Default Patch**: with R1's patches diverging from identity, invoke "Restore Default Patch" → all `patches` rows for R1 are deleted; subsequent loads show identity routing and all enabled. R2's state is untouched.
2d. **Source Patch Presets**: save the current R1 patch bay state as a named preset ("Dialogue Boom"). Modify routing on R1. Recall the "Dialogue Boom" preset → R1's `patches` rows are replaced by the snapshot.
3. Marks: src-in, src-out, rec-in set → ghost rec-out displayed dashed and labeled "computed".
4. sync_mode=cut on music + ripple-insert N frames in dialog where music spans the trim point → music splits, downstream half ripples by N, gap fills the interval.
5. Both Solo and Mute on a track → no error; Solo trumps Mute on video composite (per F4).
6. Video track muted → renderer skips it; lower non-muted track becomes topmost. Two video tracks soloed → only those composite.
7. SourceTab displayed, edit fires → edit targets ActiveRecordTab (the previously-selected RecordTab), not the source.
8. Close + reopen project → patches, per-track sync_mode, per-track auto-select, AND SourceTab open/closed state restored verbatim.
9. Toggle Solo/Mute/Lock → no `snapshots` row, Cmd-Z does not revert.

---

## Out of scope

- Split-timeline view (source + sequence visible simultaneously).
- Patch-bridge connector UI (curved colored lines between source/record ports).
- Avid-style speaker/monitor button separate from Mute.
- Per-patch color palette (the original 12-hue palette assumed colored connector lines, which are out of scope; src-id is plain blue, rec-id is plain red — no per-patch hue).

---

## Notes carried forward from prior clarifications (2026-05-03)

- Q1 (undoability) → answered by F6.
- Q2 (multichannel routing UI) → answered by F2 (per_channel default + per_clip preference + modifier toggle).
- Q3 (modifier-key choice) → Option/Alt default for both stacking-drag and view-toggle, independently rebindable.
- Audio-track-type enforcement: none (matches existing mixed-rate tolerance).
- Solo/Mute coexist; never collapse to a tristate (memory `feedback_solo_mute_separate.md`). Solo trumps Mute on render.

---

## Engineering posture

Rules from CLAUDE.md / ENGINEERING.md apply by default — fail-fast asserts (1.14), no fallbacks (2.13), forward-only schema (2.15), failing-test-first for bug fixes (2.20), `sequence_id` on commands (2.29), command framework (1.10), PersistentWidget (1.6), MVC pull-not-push, no shortcuts. The spec does not re-enumerate them.

TimelineTab abstraction is load-bearing: implementations that scribble new fields onto `timeline_state.M.state` instead of onto a TimelineTab object are wrong by construction.
