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

**Effective source — precedence rule.** The "source" feeding patch routing is the **effective source**, picked from two independent inputs:
- The project browser's currently selected master_clip / timeline item, and
- The clip loaded in the source monitor (`source_viewer`).

The rule is strict precedence based on which panel is *currently active*:
1. If `project_browser` is the active panel AND its selection contains an insertable item (master_clip or timeline-as-sequence) → that item is the source.
2. Otherwise → whatever sequence is loaded in the source viewer (may be nil = no source).

"Active panel" comes from `selection_hub` — the focused panel right now, not a sticky historical state. Shifting focus to any other panel (timeline, inspector, source_monitor, …) immediately reverts the precedence to rule 2; the browser's persisted selection no longer "owns" the source. This is intentional: it makes the user's *current* focus the determining context. Empty/non-insertable browser selection while browser IS active also falls through to rule 2 — the popup layer (see below) distinguishes the empty vs. non-insertable case for the user.

**Cycle and missing-source UX.** `effective_source.resolve_for_edit(rec_id, cmd_name)` is the entry point used by `command_manager.execute_interactive` to inject `source_sequence_id` for Insert/Overwrite. It returns either a valid source id, or a structured `problem` table the UI surfaces as a popup (`ui/edit_source_popup.lua`). Problem kinds: `not_insertable` (browser active, selection is a bin or otherwise non-source), `missing_item` (no source available), `cycle_self` (chosen source IS the destination), `cycle_transitive` (destination already contained within the chosen source). The transitive-cycle check duplicates the invariant guard in `_place_shared.pick_endpoints`; that assert remains as defense-in-depth — it must never fire from a UI dispatch under this design.

This pre-dates the patches feature and applies generally — Insert/Overwrite invoked from a browser-selected master and Insert invoked with the source-viewer loaded both go through the same routing. Implementation: `core/effective_source.lua`; tested in `tests/test_effective_source.lua`.

> **Amended by 019-source-viewer-clip-mode (2026-05-19)**: when the source viewer is in **live-bound clip mode** (a timeline clip loaded for live retrim), `effective_source.get()` additionally carries `(in, out)` overrides drawn from the loaded clip's `source_in_frame` / `source_out_frame`. Insert/Overwrite consume these overrides verbatim, ignoring any sequence-row marks on the underlying source sequence. The single `source_sequence_id` return shape grows to an optional `(seq_id, in?, out?)` triple. See 019 spec FR-016d and the "Cross-spec touches" section there for the authoritative contract.

**Per-(sequence, source-shape)-sticky model.** Patches are state of the record sequence's patch bay, **keyed by the loaded source's shape**. "Shape" is the count of source tracks of the relevant `track_type` (for now — future extension may distinguish dual-mono from stereo at the same count; out of scope here). Different-shape sources each have an independent remembered map on the same record sequence; loading a same-shape source recalls its map. Patches are never per-clip — that's Avid's rejected per-clip-memory model. This is Premiere's per-bay model split per shape so a 2-ch boom and a 4-ch surround on the same record sequence don't fight over the same routing rows.

- **src-btn visibility = "one per source track in the current shape, placed at its routed rec row".** Algorithm: iterate the effective source's tracks of this `track_type`; for each `source_track_index s`, look up `patches(record_seq, track_type, source_shape, s)` → `record_track_index r`; draw the src-btn on the rec row of index `r` with the source's label. **No source loaded ⇒ zero src-btns rendered.** The number of src-btns of a given type is always equal to the source's track count of that type — never more, never fewer. There is no separate "visibility filter" pass; the source's tracks ARE the iteration domain.
- **Routing lookup binds at source-change time, not edit-time.** When `effective_source_changed` fires, the rec headers re-render against the new shape's map immediately so the src-btns visibly reflect **what would happen on the next Insert/Overwrite**. Edit-time uses the same key; the binding is just frozen-by-then.
- **Patches are the sole edit-time routing mechanism.** Identity routing (src N → rec N, enabled=1) is achieved by *seeding* identity rows for the current shape, not by an absence-implies-identity rule. Seeding is per-channel idempotent: any `(record_seq, track_type, source_shape, source_track_index)` tuple that has no row gets one with identity rec_idx and `enabled=1`; existing rows (user-rerouted or disabled) are never touched. Seeding fires at the top of `Insert.execute` and `Overwrite.execute` (the authoritative API entry points — `Patch.ensure_identity_for_source(rec_seq, src_seq)`) and from `timeline_panel`'s seeding handler on BOTH `effective_source_changed` (source side moved) and `active_sequence_changed` (rec side moved) — identity is a function of (rec_seq, source), so either change can leave src-btns rendering stale; the handler reseeds and rerenders symmetrically. There is no implicit "absence-as-identity" fallback in routing code; once execute returns the rows exist for the current shape.
- **src-id ON/OFF**: clicking a source-track button flips `enabled` on the current-shape patch row (the row exists because seeding ran).
- **Edit-time inclusion gate**: a source channel participates in an edit iff its current-shape patch row has `enabled=1`. Routing target = `patch.record_track_index`. Disabled patches drop the channel. **`record_track.autoselect` is unrelated to patching** — autoselect is the Premiere "track targeting" toggle that gates selection-driven operations (Ripple Delete scope, marquee, range commands); it does NOT gate clip placement during Insert/Overwrite.
- **Drag to redirect**: dragging a source button onto a different record track (or another source row's record cell) writes/updates `record_track_index` for the **current-shape** `(record_seq, track_type, source_shape, source_track_index)` patch row. A drag under a different source's shape would not affect this shape's map. Holding a modifier (default Option/Alt, rebindable) **stacks** — multiple sources targeting one record track produce a multi-channel clip on that record track at edit time.
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
Header cells, left to right: **src-id button | rec-patch-id button | label (flex) | lock icon | sync-mode cell | Solo/Mute vertical stack**. (Audio rows append a waveform toggle as a UI extension beyond the spec-required six.)

- Solo and Mute are independent (a track can be both). **Solo always trumps Mute.**
- **Solo/Mute applies to video** as well as audio. On video: Mute skips the track during compositing (next-lower non-muted becomes topmost). Solo uses additive-set semantics — only soloed tracks composite, muted excluded from the set, non-soloed-non-muted ignored when ≥1 track is soloed.
- **src id button** renders filled blue when ON, outline-only when OFF.
- **rec-patch-id button** is the **track-targeting / auto-select** toggle (Premiere "track targeting"). ON = this record track participates in selection-driven operations (Select-in-Range, Ripple Delete, marquee, range-based commands). OFF = excluded from those. **It does NOT gate patch routing.** Patch destination is controlled solely by `patches.record_track_index` (via src-button drag, F2). The pair (src-id + rec-patch-id) sits side-by-side on each track row; together they form the patch affordance (visual mapping src→rec) without overlapping their semantics — no separate P button. No record-arm button.
- No track-type enforcement on audio (mono/stereo/N-channel coexist on one track, mirroring mixed-frame-rate tolerance).

### F5 · 3-point ghost mark
When 3 of 4 marks (src in/out, rec in/out) are set, the 4th is computed and rendered as a **dashed ghost** at its timeline position, labeled "computed" wherever shown textually. Source marks live on the loaded master sequence; record marks on the active record sequence; both persist regardless of which tab is displayed. Edit operations target `ActiveRecordTab` even when SourceTab is displayed.

**Cross-rate ghost display:** `three_point_math.compute` has two rounding modes. Committed edits (Insert/Overwrite) use the default **strict** mode, which asserts integer divisibility (e.g. 150 src-frames @ 25fps → 144 rec-frames @ 24fps is exact). The transient ghost-mark display invokes the same module with `{ rounding = "floor" }`, which floors the converted duration and returns `exact=false` when a sub-frame remainder was dropped. This avoids spurious assertion storms during routine cross-rate editing (e.g. 241 src-frames @ 24fps → 251.04 rec-frames @ 25fps) while keeping the commit-path invariant intact. Callers may surface the `exact=false` flag in the inspector/status bar later; today it is computed but not rendered.

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
- new `patches(id, sequence_id FK→sequences ON DELETE CASCADE, track_type TEXT NOT NULL CHECK(track_type IN ('VIDEO','AUDIO')), source_shape INTEGER NOT NULL CHECK(source_shape > 0), source_track_index INTEGER NOT NULL, record_track_index INTEGER NOT NULL, enabled INTEGER NOT NULL DEFAULT 1 CHECK(enabled IN (0,1)), created_at INTEGER NOT NULL, UNIQUE(sequence_id, track_type, source_shape, source_track_index))` — per-(sequence, source-shape)-sticky. `track_type` separates V and A index spaces (V1 and A1 are independent rows). `source_shape` is the count of source tracks of this `track_type` at the time the row was seeded; different-shape sources have independent remembered maps. Identity rows are seeded automatically per current shape (see F2). **No `color` column** — per-patch color was the original connector-line design which is out of scope (see Out of scope).
- new `source_patch_presets(id, project_id FK→projects ON DELETE CASCADE, name TEXT NOT NULL, keybind TEXT, snapshot_json TEXT NOT NULL, created_at INTEGER NOT NULL, UNIQUE(project_id, name))` — named patch-bay configurations recall to current record sequence's `patches` rows.

`snapshots` table is **not** extended — non-undoable preferences write directly to their own columns.

---

## Acceptance scenarios

1. Source loaded + click SourceTab → timeline shows source tracks; ActiveRecordTab unchanged; SourceTab is first in the strip with blue accent and underlined. Click back to "Main" RecordTab → both pointers update; "Main" gains underline + red text; marks/patches/sync_mode preserved.
2. First edit from a freshly loaded source seeds identity patches for every source track (Patch.ensure_identity_for_source). If the seeded or user-customised patch points at a `record_track_index` beyond the existing rec track count, the missing rec tracks are auto-created in the same undoable unit as the edit.
2a. **Per-(sequence, shape)-sticky patches**: in sequence R1, with a 4-ch source loaded, redirect src-A1→rec-A3 and toggle src-A4 OFF. Load a *different* source of the **same** 4-ch shape → R1's 4-ch map applies; the next edit still routes A1→A3 with A4 dropped. Switch active sequence to R2 → R2's 4-ch map shows identity defaults (independent of R1). Switch back to R1 → A1→A3 and A4 OFF restored.
2b. **Per-shape remembered maps**: with R1's 4-ch map customised (A1→A3, A4 OFF), load a stereo (2-ch) source → **two** src-btns render (src-A1, src-A2), positioned per R1's *2-ch* map (identity by default if untouched). Reroute under 2-ch: src-A2→rec-A4. Reload a 4-ch source → R1's 4-ch map restored (A1→A3, A4 OFF). The 2-ch and 4-ch maps are independent rows in `patches`; neither is mutated by the other.
2b-i. **No source ⇒ no src-btns**: with the source monitor empty and no master_clip selected in the project browser, the header renders zero src-btns regardless of how many `patches` rows exist for R1.
2c. **Restore Default Patch**: with R1's patches diverging from identity across multiple shapes, invoke "Restore Default Patch" → **all** `patches` rows for R1 across **every shape** are deleted; the next source load reseeds identity-and-enabled for the loaded shape. R2's state is untouched.
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
