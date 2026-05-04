# Feature Specification: Source-in-Timeline + Track-Header Redesign + Tristate Sync-Lock

**Feature Branch**: `015-source-in-timeline`
**Created**: 2026-05-03
**Status**: Draft
**Input**: User description (summarized): tabbed mode-switch on the timeline panel that lets the editor view either the loaded source clip OR the active sequence in the same timeline area; redesigned track-header vocabulary supporting paired src/rec patch buttons; per-track tristate sync-lock; unified solo/mute on both audio AND video.

**Design artifact**: `design examples/source_in_timeline_v4.html`. v4 is authoritative ONLY for **structure** and **semantics** — tab system shape (one Source tab + N Record tabs), track-header cell order (paired src/rec id buttons → label → sync-mode → lock icon → S/M stack), tristate sync icon vocabulary (dot / wave / blade), S/M independence and presence on both audio and video, role color assignments (source = blue, record = red, sync icons neutral). v4 is **NOT** authoritative for pixel-level visual style — fonts, paddings, corner radii, font sizes, panel chrome, button bevels, hover treatments, monitor frame styling, and overall density MUST match JVE's existing visual language as it exists at the time of implementation (track-header rendering at `timeline_panel.lua:1029-1296`, tab styling at `timeline_panel.lua:78-100,392-401`, monitor styling in `sequence_monitor.lua` and `panel_manager.lua`). Where v4 and JVE diverge visually, JVE wins. The earlier `source_in_timeline_v3.html` (split-view experiment) is superseded and out of scope.

---

## Clarifications

### Session 2026-05-03
- Q: Are patch on/off, patch drag-redirect, and per-track sync-mode toggle on the per-sequence undo stack? → A: B — session-level non-undoable preferences. They persist with the sequence (saved across sessions) but Cmd-Z does NOT affect them and no snapshot is captured.
- Note (volunteered): Audio tracks have NO type enforcement. Tracks accept any channel-count clip (mono, stereo, 5.1, n-channel), mirroring JVE's tolerance for mixed frame rates on one track. Resolve nominally has track types ("Stereo", "Adaptive N") but doesn't enforce them; JVE doesn't even nominally type audio tracks.
- Q: Multi-channel source routing UI — per-channel vs per-clip vs hybrid? → A: **B + preference for C + modifier-key for D**. Operational default is B (per-channel buttons, 1:1 default routing, modifier-drag merges multiple sources onto one record track). A user preference MAY flip the default to C (per-clip representation — one source button representing the whole source audio). A held modifier key temporarily flips the view in either direction (per-clip preference + modifier held → expand to per-channel; per-channel preference + modifier held → collapse to per-clip).
- Q: Modifier-key choice for stacking-drag (FR-010a) and view-toggle (FR-029d)? → A: **D — same key (Option/Alt) by default for both, with user remappability via the keybindings/preferences config.** Each gesture's modifier is independently rebindable.
- Note (volunteered + bug discovered): Solo, Mute, and Lock toggles SHOULD be session-level non-undoable routing preferences — same category as patch on/off, drag-redirect, and sync-mode toggle. This matches Premiere convention (solo/mute toggles don't land on Cmd-Z). **Joe verified the current JVE behavior: solo/mute toggles ARE landing on the undo stack today — that is a pre-existing bug.** Feature 015 corrects this as part of FR-040's non-snapshotting category. A failing regression test MUST be written first (rule 2.20: "ALWAYS add a failing regression test BEFORE fixing a bug"); the test asserts that toggling solo, mute, or lock on a track does NOT produce a `snapshots` row and Cmd-Z does NOT revert the toggle. The fix lands in this feature.

---

## ⚡ Quick Guidelines
- Single timeline panel — Avid-faithful one-tab-displayed-at-a-time. No split view. No "modes" — only tabs.
- Mode is a UI affordance (visible tabs) plus a menu command.
- All header buttons that exist must do something or be omitted.
- Honor existing memory: solo and mute remain independent toggles (`feedback_solo_mute_separate.md`); timecode preservation is the source of truth (`feedback_timecode_is_truth.md`).

---

## User Scenarios & Testing *(mandatory)*

### Primary User Story
An editor working a multi-track sequence with multichannel field recordings (e.g. 8-channel BWF: V1 + boom + 3 lavs + cam-mics + room + slate) needs to:
1. Load a source clip into the source viewer.
2. Click the Source tab in the timeline panel to inspect the source's tracks at full timeline fidelity (waveforms, marks, scrubbing). The active sequence remains unchanged.
3. Set per-track patches (which source tracks map to which sequence tracks) directly from track headers, with each patch visually distinct.
4. Mark IN/OUT on either source or sequence and let the editor compute the missing 4th mark.
5. Perform 3-point edits with confidence that patch routing is correct. They may switch back to the Active sequence or remain in the Source View Tab.
6. Keep music beds, room tone, and BWF-anchored content from drifting when ripple-trimming dialog tracks, by setting those tracks to Cut sync mode.

### Acceptance Scenarios
1. **Given** a sequence is open and a source clip is loaded, **When** the editor clicks the Source tab on the timeline panel, **Then** the timeline displays the source clip's tracks (V1 + N audio channels), the timecode readout shows source TC, and the panel takes on the blue accent. The active sequence is unchanged.
2. **Given** the Source tab is displayed and the active sequence is "Main", **When** the editor clicks the "Main" Record tab, **Then** the timeline displays the sequence content unchanged from before the displayed-tab switch — same marks, patches, and selection state are preserved.
3. **Given** a source track has no patch destination, **When** the Source tab is displayed, **Then** the rec-patch slot of that track header renders as an empty dashed cell and the track is marked "unrouted" with a hollow port.
4. **Given** a Record tab is displayed and the editor has set src IN, src OUT, and rec IN, **When** the editor inspects the timeline, **Then** the computed rec OUT appears as a ghost (dashed) mark on the sequence ruler and is shown as "computed" in the inspector.
5. **Given** a track header showing src "A1" filled-blue and rec "A2" outline-red, **When** the Source tab is displayed, **Then** the editor reads "source A1 patches to record A2 on the active sequence."
6. **Given** sync mode is set to Cut on a music track and Ripple on dialog tracks, **When** the editor ripple-inserts N frames at a trim point on a dialog clip and a music clip spans the trim point, **Then** the music clip is split at the trim point, the downstream half ripples by N frames (uniform shift, same as the dialog tracks), and the music remains in sync with the dialog. Any resulting empty interval between the two halves of the split music clip is rendered using JVE's existing gap-clip mechanism — no new "filler" entity is introduced.
7. **Given** sync mode is set to Off on the slate track, **When** the editor ripple-trims dialog, **Then** the slate track is wholly unaffected.
8. **Given** an audio track has both Solo lit and Mute lit, **When** playback occurs, **Then** the system does not raise an error — solo and mute coexist and the audio routing logic treats them as orthogonal.
9. **Given** a video track has Mute lit, **When** the timeline is composited at a point where that track has content, **Then** the renderer skips that track and the next non-muted lower track is treated as the topmost candidate.
10. **Given** a video track has Solo lit, **When** the timeline is composited at a point where that track has content, **Then** the renderer ignores all higher tracks and shows only the soloed track's content (or black if none).
11. **Given** the active sequence is "Main" and the displayed tab is the Source tab, **When** the editor performs a 3-point edit operation, **Then** the edit targets the active sequence "Main" — NOT the source — even though the timeline is currently rendering the Source tab's content.
12. **Given** a sequence is closed and reopened, **When** the editor inspects the track headers, **Then** the per-track sync-mode and the patch routing are exactly as they were when the sequence was last saved.

### Edge Cases
- **Cut sync mode + ripple-DELETE**: behaves exactly like a normal ripple-delete — if the operation would be invalid (would clobber content, etc.), it blocks. No special-case absorption logic.
- **Cut sync mode when the affected track has no clip at the trim point**: behaves exactly like Ripple. Cut is "Ripple PLUS auto-split any clip spanning the trim point." If there's nothing to split, Cut and Ripple are identical for that track.
- **Channel-count mismatch on patch attempt**: not a real condition under the on/off source-button model (FR-029a). Each source-track button is independently on or off. ON-buttons whose default destination doesn't exist yet auto-create a new record track during the edit; OFF-buttons are dropped. The visual cue that a source track has no destination is the absence of a parallel record track in the row beside it (a "blank area" to the right of the source button).
- **Active sequence changed elsewhere while Source tab is displayed**: the displayed tab MUST stay put. The active-sequence pointer updates independently of the displayed-tab pointer. The user must explicitly click the desired tab if they want the displayed tab to follow.
- **Solo on multiple video tracks simultaneously**: confirmed — additive-soloed-set semantics. Only soloed tracks participate in the top-down composite; muted tracks are excluded from the soloed set; non-soloed non-muted tracks are ignored when at least one track is soloed.
- **Source clip unloaded while the Source tab is displayed**: see FR-007b — empty placeholder.

## Requirements *(mandatory)*

### Functional Requirements

#### Tab System (Source-in-Timeline) — extends the existing per-sequence tab strip with a single Source tab
There are NO "modes" in this feature. There are only tabs. Each tab is either a Record tab (one per open sequence — existing behavior) or THE Source tab (singular, exactly one). The terminology "Source mode" / "Sequence mode" is not used in the implementation or the UI; tab type is the only concept.

- **FR-001**: The timeline panel MUST support exactly one **Source tab** at most, in addition to its Record tabs. The Source tab represents the master sequence currently loaded in the source monitor (`source_viewer.load_master_clip(master_seq_id)` at `src/lua/ui/source_viewer.lua:14` — source clips ARE master sequences in JVE). The Source tab is a singleton; loading a different source replaces the Source tab's content, it does not create a second Source tab.
- **FR-001a**: The Source tab is **closeable and re-openable** under user control. The user MAY close the Source tab via its `×` close affordance; the tab disappears from the strip but the underlying source-monitor master remains loaded and the routing/patches state is unaffected. A **"Show Source Tab"** command MUST exist (in the menu system per the Quick Guidelines "menu command" qualifier) that re-opens the Source tab. Re-opening the Source tab MUST restore it with whatever master sequence the source monitor currently has loaded — the tab does not preserve a "previous" loaded source independently of the source monitor.
- **FR-002**: The Source tab MUST render with blue accent styling (tab highlight, timecode readout color, header tint, panel background gradient). Record tabs MUST render with red accent styling. Styling is determined by tab type, not by a separate "mode" flag.
- **FR-003**: Two distinct pointers MUST be tracked:
   1. **Displayed tab** — the tab whose content the timeline body is currently rendering. Exactly one tab is displayed at any time.
   2. **Active sequence** — the sequence whose tab was last selected. The active sequence is the target of edit operations (e.g. the rec side of a 3-point edit). The Source tab is NEVER the active sequence; it is a viewer.
- **FR-004**: Clicking a Record tab MUST update both pointers: the displayed tab becomes that tab AND the active sequence becomes that tab's sequence.
- **FR-005**: Clicking the Source tab MUST update only the displayed tab. The active sequence MUST remain unchanged. This means an editor can be looking at the Source tab while the rec side of a pending 3-point edit still targets the previously-active sequence.
- **FR-006**: The Source tab MUST be activatable by clicking the visible tab OR by a menu command (the "menu command" qualifier in Quick Guidelines). No keyboard shortcut is defined by this feature.
- **FR-007**: Switching the displayed tab MUST NOT lose or alter marks, patches, or per-track sync_mode. Marks and patches are persisted with their owning sequence; switching the displayed tab is a view change only, not a data fork. Per CLAUDE.md MVC rule (3.0) the timeline view pulls from the model on activation; it does NOT depend on imperative push from `source_viewer`.
- **FR-007a**: Switching the displayed tab MUST be perceived as instantaneous (no observable storage round-trip).
- **FR-007b**: When the source monitor has no loaded master clip, the Source tab MUST render an empty placeholder (no track headers, no clips, a "no source loaded" message in the timeline body). The active sequence is unaffected by source unload. The Source tab itself is NOT auto-closed when the source unloads — it persists with the empty-placeholder state until the user closes it via `×` (FR-001a).

#### Track Header Layout — affects `timeline_panel.lua:1029-1296` (existing inert L/P/V buttons + audio M/S/R/W)
- **FR-008**: Each track header MUST present cells in this left-to-right order: source-track-id button or blank placeholder, record-patch-id button, label (flex-grows), lock cell, sync-mode cell, vertical S/M stack. This replaces the existing L/name/P/V layout (video, lines 1030-1048) and L/name/P/M/S/R/W layout (audio, lines 1208-1296).
- **FR-009**: The src-id and rec-patch-id MUST be paired buttons. The displayed tab's matching side renders filled with the tab's accent color (blue if the displayed tab is the Source tab, red if a Record tab); the other side renders outline-only.
- **FR-010**: Each source-track button is a binary **on/off toggle**, not a presence indicator. ON = the source track will be included in any edit performed against the active sequence, routed to its destination record-track index (default = identity index, i.e. src N → rec N; can be redirected per FR-010a). OFF = the source track is dropped from edits, even if a parallel record track exists.
- **FR-010a**: A source-track button MAY be dragged from its current row onto a different record-track header to redirect its patch destination. Two drag gestures exist:
   - **Plain drag** (no modifier): **redirect**. The dragged source's `record_track_index` is updated to the dragged-onto row's index. If the destination already had a different source patched to it, that prior patch's `enabled` is unchanged but its `record_track_index` is unchanged too — multiple sources can target the same record_track_index only via the modifier-drag below.
   - **Modifier-drag** (per FR-029d's stacking modifier): **merge / stack**. The dragged source ALSO targets the dragged-onto record_track_index, in addition to whatever source(s) were already patched there. At edit time, multiple sources targeting the same `record_track_index` produce a single multi-channel clip on that record track (channel order = source-track-index ascending). Visual: the record track header shows stacked source-id pills (e.g. "A1+A2+A3").
   - Dragging back onto the source's identity row, or invoking a "reset patches to identity" command, restores the identity-default destination.
   - Cross-track-type drag (audio source onto video record, or vice versa) MUST be refused with an explicit error per rule 2.13.
   The stacking modifier defaults to **Option/Alt** (per Clarifications 2026-05-03). The key is independently rebindable via the keybindings/preferences config so editors with conflicting muscle memory can choose a different key without affecting the view-toggle modifier (FR-029d).
- **FR-011**: Clicking the rec-patch-id while the Source tab is displayed MUST initiate the assignment of that source track's patch destination on the active sequence.
- **FR-012**: Clicking the src-id while a Record tab is displayed MUST initiate the assignment of that record track's patch source.
- **FR-013**: The header MUST NOT contain a separate "P" (patch) button. The track-id pair IS the patch affordance.
- **FR-014**: The header MUST NOT contain an "R" (record-arm) button.
- **FR-015**: The lock cell MUST use a graphical lock icon (not the letter "L").
- **FR-016**: The S/M stack MUST present Solo and Mute as two independent buttons stacked vertically at the rightmost edge of the header.
- **FR-017**: Solo and Mute MUST remain independent: a track CAN be both soloed AND muted simultaneously, and the system MUST NOT enforce mutual exclusion. The existing `tracks.muted` and `tracks.soloed` columns (`schema.sql:162-163`) already model this correctly; no schema change.
- **FR-018**: S and M MUST apply to BOTH audio and video tracks. The existing `tracks.muted`/`tracks.soloed` columns are agnostic to track_type and apply unchanged to video tracks.
- **FR-019**: On video tracks, Mute MUST cause the renderer to skip that track during compositing such that the next-lower non-muted track becomes the topmost candidate.
- **FR-020**: On video tracks, Solo MUST cause the renderer to ignore all higher non-soloed tracks. When multiple video tracks are soloed, the **additive-soloed-set** semantic applies: only soloed tracks participate in the top-down composite; muted tracks are excluded from the soloed set; non-soloed non-muted tracks are ignored when at least one track is soloed. Confirmed in Edge Cases (Clarifications 2026-05-03 inline note).
- **FR-021**: Audio track headers MUST display the track's channel count inline (e.g., "2.0", "(2)", "1.0") in a compact non-interactive label.
- **FR-021a**: The existing `tracks.enabled` column (`schema.sql:160`) is orthogonal to sync_mode and to S/M. `enabled` is the playback-include toggle (existing semantics, unchanged); sync_mode controls ripple behavior; M/S control playback. The implementer MUST NOT conflate these three axes.
- **FR-021b**: The existing `clip_links` table (`schema.sql:281`) provides V+A clip-level linkage (existing feature). Track-level Patches (FR-029) are a SEPARATE concept and MUST NOT share schema or code paths with `clip_links`.
- **FR-021c**: All new track-header widgets and the patch-edit affordances MUST inherit/use PersistentWidget per ENGINEERING.md rule 1.6. UI state (per-track expand/collapse, last-active tab, etc.) MUST persist via the same mechanism every other widget uses.
- **FR-021d**: **No audio-track-type enforcement.** Per Clarifications 2026-05-03 — JVE audio tracks do not carry a "stereo" / "5.1" / "adaptive N" type. A single track accepts clips of any channel count (mono, stereo, 5.1, etc.), in any combination, on the same track — mirroring JVE's existing tolerance for mixed frame rates on a single track. The implementation MUST NOT introduce a `track.audio_type`, channel-count constraint, or any validation that rejects clips on the basis of channel-count. The channel-count badge from FR-021 is a passive display, not a constraint.

#### Tristate Sync Mode — extends the existing ripple pipeline at `core/ripple/batch/pipeline.lua`
- **FR-022**: Each track MUST have a `sync_mode` property with three possible values: `'off'`, `'ripple'`, `'cut'`. Persisted as a TEXT column on the existing `tracks` table.
- **FR-023**: The default sync_mode for newly-created tracks MUST be `'ripple'`. This matches the existing ripple pipeline's behavior — Ripple mode IS the current default.
- **FR-024**: The sync-mode cell in the track header MUST cycle Off → Ripple → Cut → Off on click. Each cycle is a non-snapshotting command per FR-040 — sets `sequence_id` but does NOT land on the per-sequence undo stack.
- **FR-025**: The Off state MUST render with a dim dot icon. The Ripple state MUST render with a stacked sine-wave (ripple) icon. The Cut state MUST render with a diagonal blade icon.
- **FR-026**: The existing ripple pipeline at `src/lua/core/ripple/batch/pipeline.lua` and `src/lua/core/commands/batch_ripple_edit.lua` (notably `inject_implicit_gap_edges`, line ~488) MUST be extended with a per-track sync_mode dispatch BEFORE the implicit-gap injection. Each dispatch branch MUST `assert()` its own invariants:
   - `'off'` branch: skip the track entirely. Post-condition assert: track length unchanged after operation.
   - `'ripple'` branch: existing behavior unchanged (uniform downstream shift via existing `compute_downstream_shifts`). Post-condition assert: applied delta equals canonical ripple delta.
   - `'cut'` branch: identical to `'ripple'` PLUS, before the shift, any clip on this track that spans the trim point is split at the trim point. After the split the downstream half ripples like every other clip on a `'ripple'` track. Any empty interval that results between the two halves is rendered via JVE's existing gap-clip mechanism (no new "filler" entity). Post-condition asserts: (a) no clip on this track ends up spanning the trim point; (b) the downstream half's `timeline_start` shifted by exactly the canonical ripple delta; (c) no produced clip is shorter than one frame at the sequence rate.
- **FR-027**: Split points in the `'cut'` branch MUST round at the sequence's frame boundary (rate from `sequences.frame_rate`, resolved by existing `prepare.resolve_sequence_rate`). Existing quantization handling for splits (used by manual blade/split tools elsewhere in JVE) MUST be reused; this feature does NOT introduce a new quantization policy.
- **FR-028**: Per-track sync_mode MUST be persisted via the schema migration in FR-046, and restored verbatim on reopen.
- **FR-028a**: Sync_mode toggles are non-snapshotting commands per FR-040: they include `sequence_id` for routing scope (rule 2.29) but produce no `snapshots` row and are not undoable.

#### Patches (Source → Record Routing) — new entity, new schema, distinct from `clip_links`
- **FR-029**: A Patch is a new entity scoped to a specific record sequence: `{sequence_id, source_track_index, enabled, record_track_index}`. `enabled` is the on/off state of the source-track button. `record_track_index` is the destination on the active record sequence — defaults to identity (= `source_track_index`) but MAY be set to a different index via drag (FR-010a). Patches are stored in a new `patches` table (see FR-046). Patches are NOT clip_links and MUST NOT share schema, code, or naming with `clip_links`.
- **FR-029a**: The on/off button on the source-track header is the **canonical UI for the patch's `enabled` flag**. Edit operations against the active sequence include exactly the source tracks whose button is ON. Source tracks whose button is OFF are silently dropped from the edit; this is the intended user-controlled behavior, not a silent failure.
- **FR-029b**: When an edit fires with a source track ON whose `record_track_index` exceeds the active sequence's existing track count, the edit MUST auto-create record tracks up to that index as part of the same command (so the edit and the track creation are in one undoable unit). Auto-created tracks inherit the default sync_mode (`'ripple'`) and the default S/M/lock state.
- **FR-029c**: **Source-button display preference.** A user preference `source_routing_view` controls how source-track patch buttons are presented:
   - `'per_channel'` (default): one source button per source-track-index (one per track in the source's master sequence). Each button has its own `enabled` flag and `record_track_index`. This is the operational default and supports independent per-channel routing including FR-010a stacking.
   - `'per_clip'`: source presents ONE collapsed button representing all of the source's audio tracks together. The collapsed button drags as a single unit onto a record track; under the hood the system writes one patch row per source-track-index, all with the same `record_track_index`. The collapsed button's `enabled` toggle applies to all underlying patch rows.
   The preference is per-user (not per-sequence), persisted with app preferences (rule 1.6 PersistentWidget). Default = `'per_channel'`.
- **FR-029d**: **Modifier-key view-toggle.** Holding a modifier key while interacting with the source row MUST temporarily flip the display from the persistent `source_routing_view` preference (FR-029c) to the opposite mode for the duration the modifier is held: `'per_channel'` preference + modifier → display collapses to a single per-clip button; `'per_clip'` preference + modifier → display expands to per-channel buttons. Releasing the modifier returns to the persistent preference's display. The underlying `patches` rows are unchanged by the view toggle — only the rendered representation flips. The view-toggle modifier defaults to **Option/Alt** (per Clarifications 2026-05-03) — same default as FR-010a's stacking-drag modifier — and is independently rebindable via the keybindings/preferences config (a user CAN remap stacking-drag to a different key from the view-toggle if desired).
- **FR-030**: Patches MUST be persisted in the project DB and restored verbatim on reopen.
- **FR-031**: Patch indicators are colored by ROLE, not by per-patch hue. The source-side indicator uses the source role color (blue) when ON; appears off/dim when OFF. The record-side indicator uses the record role color (red). There is no per-patch unique color and no patch color palette — each patch is shown inline once on its track row, fully disambiguated by row position.
- **FR-034**: When a source track has no parallel record track at its `record_track_index` (because the active sequence has fewer tracks than the source), the right-side of that source row in the header column renders as a **blank area** — there is no record-track cell to draw. This is the visual cue. If the user then turns the source button ON and performs an edit, FR-029b auto-creates the record track.
- **FR-035**: The on/off behavior is the user's explicit choice. OFF tracks are dropped from edits without warning or error; this is not a silent failure (rule 2.32 distinguishes a silent failure from an explicit user-controlled exclusion). The implementation MUST `assert()` only that the patch's `enabled` boolean was actually consulted before the routing decision was made.
- **FR-035a**: Patch creation, deletion, and modification (including the on/off toggle and the drag-to-redirect) are non-snapshotting commands per FR-040: they include `sequence_id` (rule 2.29) but do NOT produce a snapshot and do NOT land on the per-sequence undo stack.

#### 3-Point Edit Math
- **FR-036**: When any 3 of the 4 marks (src IN, src OUT, rec IN, rec OUT) are set, the system MUST compute the missing 4th and display it as a "ghost" mark (dashed visual treatment) at its computed timeline position.
- **FR-037**: The computed mark MUST be labeled "computed" wherever it appears textually (inspector, status bar).
- **FR-038**: 3-point math MUST be independent of the displayed tab: source marks live on the loaded master sequence (the SourceTab's content) and persist regardless of which tab is displayed; sequence marks live on the active sequence and persist regardless of which tab is displayed. Edit operations target the active sequence even when the SourceTab is the displayed tab.

#### Persistence & Undo
- **FR-039**: Per-track sync_mode and patches MUST persist via the schema migration (FR-046). Restored verbatim on sequence reopen.
- **FR-040**: The following per-track / per-sequence toggles are **session-level non-undoable routing preferences** (per Clarifications 2026-05-03):
   1. Patch on/off (`patches.enabled`)
   2. Patch drag-redirect (`patches.record_track_index`)
   3. Sync-mode toggle (`tracks.sync_mode`)
   4. Solo (`tracks.soloed`)
   5. Mute (`tracks.muted`)
   6. Lock (`tracks.locked`)
   They persist in the project DB and survive close+reopen, but they DO NOT land on the per-sequence undo stack — Cmd-Z does not revert any of these toggles. They are still implemented as commands (per rule 1.10 — go through the command dispatcher) and MUST set `sequence_id` (rule 2.29) for routing scope, but the command framework MUST treat them as non-snapshotting: they write directly to their target column/table and produce no `snapshots` row.
- **FR-040a**: **Pre-existing bug fix.** Solo, Mute, and Lock toggles on existing JVE tracks currently DO produce snapshots and land on the undo stack — verified by Joe. This is a pre-existing bug (Premiere convention is non-undoable; Joe's design intent has always been non-undoable). Feature 015 corrects this. Per ENGINEERING.md rule 2.20, a failing regression test MUST be written first that asserts toggling solo/mute/lock produces no `snapshots` row and is not reverted by Cmd-Z; only after demonstrating the failure may the fix land.

#### Schema & Migration — forward-only per rule 2.15
- **FR-046**: Schema migrates forward (rule 2.15, no backward compatibility). Required changes:
   1. `tracks`: add `sync_mode TEXT NOT NULL DEFAULT 'ripple' CHECK(sync_mode IN ('off','ripple','cut'))`.
   2. New table `patches(id TEXT PRIMARY KEY, sequence_id TEXT NOT NULL REFERENCES sequences(id) ON DELETE CASCADE, source_track_index INTEGER NOT NULL, record_track_index INTEGER NOT NULL, enabled INTEGER NOT NULL DEFAULT 1 CHECK(enabled IN (0,1)), UNIQUE(sequence_id, source_track_index))`. `record_track_index` defaults to identity (= `source_track_index`) but may differ when the user has dragged the patch (FR-010a). `enabled` is the on/off button state. No `color_index` column — see FR-031.
   3. The `snapshots` mechanism is **NOT extended** by this feature. Per Clarifications 2026-05-03 and FR-040, sync_mode and patch state are non-undoable preferences — they are persisted directly in their own tables (`tracks.sync_mode`, `patches`) and do not participate in snapshot/restore.
   4. Schema version bumped per rule 3.1; no migration code preserves prior behavior.

#### Required Assert Sites — explicit per rule 1.14
- **FR-047**: The implementation MUST `assert()` (with the offending id in the message) at each of these sites — no nil-tolerant reads, no `or` defaults:
   1. Patch lookup by id: assert the patch row exists for the given (sequence_id, source_track_index).
   2. Sync_mode dispatch in the ripple pipeline: assert `track.sync_mode` is one of the three legal values; an unrecognized value crashes immediately with the track id and the bad value in the message.
   3. SourceTab display: assert the source monitor has a loaded master_seq_id before the SourceTab can render any content; refuse-and-assert if the SourceTab is asked to display while no source is loaded (unless FR-007b's clarified empty-placeholder path applies).
   4. Displayed-tab switch: assert the target tab's `sequence_id` (or, for the SourceTab, the source monitor's loaded master_seq_id) exists in the DB before re-rendering. Assert the active-sequence pointer is unchanged when the SourceTab becomes the displayed tab; assert the active-sequence pointer DOES change when a different Record tab becomes the displayed tab.
   5. Patch creation/edit commands: assert `sequence_id` is set and references a real sequence; assert `source_track_index` and `record_track_index` are both valid for that sequence.
   6. Edit-time routing (FR-029a / FR-029b path): assert each source track's `enabled` flag was consulted before that track was included or excluded from the edit; assert that any auto-created record tracks were registered into the active sequence's track list before the edit's mutation step.
   7. 3-point math: assert at least 3 of the 4 marks are set before computing the 4th.
   8. Patch/sync-mode command execution: assert the command's `sequence_id` is set (per FR-040) and that the command's executor writes directly to its target table (`patches` or `tracks.sync_mode`) without invoking the snapshot path — these are non-snapshotting commands per FR-040.

#### Test Surface — explicit per rule 2.32
- **FR-048**: Each new codepath MUST be exercised by tests written BEFORE the implementation (rule 2.20) and MUST cover happy + failure paths (rule 2.32):
   - Each sync_mode branch (Off / Ripple / Cut), happy + edge (clip-spans-trim-point, clip-exactly-on-trim-point, no-clip-at-trim-point). Cut branch must verify spanning-clip auto-split with no produced sub-frame fragments.
   - Source-tab open/close: open via "Show Source Tab" command; close via `×`; verify routing/patches state survives close+reopen.
   - Source-tab empty placeholder when source monitor has no loaded master.
   - Active-sequence pointer immutability when the displayed tab is the Source tab (covers active-sequence-changed-elsewhere edge case: displayed tab does NOT auto-switch).
   - Patch on/off toggle: ON includes source in edits; OFF drops it. Verify drop is intended exclusion, not error.
   - Patch drag redirect (FR-010a plain drag): drag source A1 onto record A3; subsequent edit lands on A3.
   - Modifier-drag stacking (FR-010a stacking modifier): with source A1 already targeting record A1, modifier-drag source A2 onto record A1; verify both patches now have `record_track_index=1`; verify the next edit produces a multi-channel clip on record A1 with channel order src-A1 then src-A2.
   - Cross-track-type drag refusal (FR-010a): drag an audio source onto a video record header → explicit refusal with assert-or-error; `patches` rows unchanged.
   - Source-button display preference (FR-029c): switching `source_routing_view` between `'per_channel'` and `'per_clip'` MUST NOT alter underlying `patches` rows — only the rendered representation. Re-render after preference change shows the new layout.
   - Modifier-key view-toggle (FR-029d): with `source_routing_view='per_channel'`, hold modifier → source row collapses to one button. Release → re-expands. With `'per_clip'`, hold modifier → expands to N buttons. Release → re-collapses. Underlying `patches` rows unchanged in either direction.
   - Auto-create record track (FR-029b): edit with source button ON whose `record_track_index` exceeds existing track count; verify new track is created and the edit + track-creation are a single undoable command.
   - Patch create/delete/modify, including unique-constraint violation on `(sequence_id, source_track_index)`.
   - Snapshot/restore cycle for sync_mode and patch state.
   - Mute and Solo coexistence on a single track (no mutex assert at read site).
   - Video Mute / Solo compositing decisions, including additive-soloed-set semantics.
   - **Regression test for FR-040a**: toggling Solo, Mute, or Lock on a track MUST NOT produce a `snapshots` row, and Cmd-Z MUST NOT revert the toggle. Test must FAIL on the current codebase (demonstrating the pre-existing bug) BEFORE the fix lands, per rule 2.20. After the fix, the same test passes. Same regression-test pattern applies to patch on/off, patch drag-redirect, and sync-mode toggle (these don't have a pre-existing bug to demonstrate, but the same invariants — no snapshot row, no Cmd-Z revert — must hold).
   - Required-data assert sites (FR-047) tested via `pcall()` per rule 2.32, validating the error message includes the offending id.

#### Out-of-Scope (Explicit Rejections)
- **FR-041**: The split-timeline view (source and sequence visible simultaneously, with a patch-bridge connector panel) is OUT OF SCOPE for this feature.
- **FR-042**: The track-level patch-bridge connector UI with curved colored lines drawn between source-side and record-side ports is OUT OF SCOPE for this feature.
- **FR-043**: A speaker/monitor button on audio tracks (Avid-style transient session-scoped monitor toggle separate from Mute) is OUT OF SCOPE. Solo + Mute are sufficient.

### Key Entities

- **SourceTab** (UI singleton): exactly one Source tab exists in the timeline panel. Its content is the master sequence currently loaded in the source monitor. Replaces, not appends, when a different source is loaded. Styled blue. NEVER the active sequence.
- **RecordTab** (UI, one per open sequence): a tab that displays a sequence being edited. Pairs with the SourceTab to form the canonical Source/Record dichotomy (Avid convention). Active record-tab text color matches JVE's existing tab red `#e64b3d` (`timeline_panel.lua:73`); inactive uses the existing `#9a9a9a` grey. The underlying data is still a Sequence; "Record" is the role of the tab, not a new data type.
- **DisplayedTab** (UI pointer): the tab whose content the timeline body is currently rendering. Either the SourceTab or one RecordTab.
- **ActiveSequence** (UI pointer): the sequence whose tab was last selected. The target of edit operations (3-point rec side, patch destination, etc.). The SourceTab never sets the ActiveSequence.
- **TrackHeader** (UI): per-track row composed of {src-id button, rec-patch-id button, label, sync-mode cell, lock-icon cell, S/M vertical stack}. Inherits PersistentWidget per rule 1.6.
- **Track** (existing schema, extended): gains `sync_mode TEXT` column. Existing `enabled`, `locked`, `muted`, `soloed` columns retain their current semantics — orthogonal axes, no conflation.
- **Patch** (NEW): routing binding {id, sequence_id, source_track_index, record_track_index, enabled}. Stored in new `patches` table. UNIQUE per (sequence_id, source_track_index). `enabled` is the on/off button state; `record_track_index` defaults to identity (= source_track_index) but may be redirected by drag (FR-010a). NOT a `clip_link` — distinct concept, distinct schema. No per-patch color — indicators are colored by role (source = blue, record = red).
- **Mark** (existing): src-IN, src-OUT, rec-IN, rec-OUT. Independent of which tab is displayed; rec-side marks live on the active sequence, src-side marks live on the loaded master sequence.
- **GhostMark** (derived, not persisted): the computed 4th mark in a 3-point edit. Recomputed each render.

---

## Review & Acceptance Checklist
*GATE: Automated checks run during main() execution*

### Content Quality
- [x] No implementation details (languages, frameworks, APIs) — spec describes WHAT and WHY.
- [x] Focused on user value (editor workflow, sync preservation, patch clarity).
- [x] Written for non-technical stakeholders (NLE editors, designers, PMs).
- [x] All mandatory sections completed.

### Requirement Completeness
- [x] No [NEEDS CLARIFICATION] markers remain — resolved in Clarifications 2026-05-03 (Q1 undoability, Q2 multi-channel routing UI, Q3 modifier-key choice; FR-020 additive solo set promoted from inline note).
- [x] Requirements are testable and unambiguous (each FR can be exercised by a scenario).
- [x] Success criteria are measurable (mode switch is instant; sync modes have explicit invariants; 3-point math has explicit ghost-mark behavior).
- [x] Scope is clearly bounded (split-view explicitly out; speaker monitor explicitly out; record-arm explicitly out).
- [x] Dependencies and assumptions identified (per-sequence undo, existing TC-as-truth invariant, existing solo/mute independence).

---

## Execution Status

- [x] User description parsed
- [x] Key concepts extracted
- [x] Ambiguities marked
- [x] User scenarios defined
- [x] Requirements generated
- [x] Entities identified
- [ ] Review checklist passed (clarifications outstanding)

---
