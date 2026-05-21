# Feature Specification: Source-viewer live-bound clip mode + narrow trim-mode toggle

**Feature Branch**: `019-source-viewer-clip-mode`
**Created**: 2026-05-19
**Status**: Draft

---

## Clarifications

### Session 2026-05-19
- Q: When a live-bound clip is deleted while loaded in the source viewer, what should the viewer do? → A: Auto-unload + emit `source_loaded_changed(nil, prev)` so existing listeners (inspector, transport) react via the established signal pathway.
- Q: After a live-bound retrim moves the OUT mark before the current playhead, where should the source-viewer playhead go? → A: Stay where it is, even if outside the new in/out range. No clamp, no snap to the just-pressed mark.
- Q: Browser modifier override for "force load into source viewer instead of timeline" — Shift+Return, Opt+Return, both, or different semantics? → A: Opt+Return only (macOS "alternate action" convention). Drop Shift+Return.
- Q: Live-bound mark-set undo-entry handling for rapid presses / held keys → A: Suppress key-repeat entirely. Only discrete presses dispatch (Qt `autoRepeat` filtered). Holding key = one entry. Per-press undo stays atomic, deterministic, and easy to test.
- Q: In live-bound mode, what should "clear marks" / "clear in" / "clear out" do? → A: All three are disabled. A clip's source range is required; clearing has no destination. The commands either no-op (preferred) or surface a "not applicable in live-bound mode" event.
- Q: When the source viewer is in live-bound mode, what does `effective_source.get()` supply for Insert/Overwrite into the record timeline? → A: Pass-through to underlying source — `(sequence_id=clip.sequence_id, in=clip.source_in_frame, out=clip.source_out_frame)`. The clip's source material becomes the edit source; retrim and edit-into-timeline share the same `source_in`/`source_out` values, so they remain in lockstep automatically.
- Q: In live-bound mode, what does Play do when the playhead is outside the in/out range? → A: Play full clip ignoring marks — marks gate edit-bounds, not playback. Play plays from current playhead forward through the clip's full content extent, stops at end of content. Marks remain visible but do not affect playback start/end.
- Q: Source viewer title in live-bound mode → A: `"Source: <clip_name> (in <owner_sequence_name>)"`. Clip name plus context naming the timeline the live-bound clip lives on. Disambiguates two different clips with the same name living in different sequences.
- Q: Live-bound clip is mutated by a non-trim edit (rate/enabled/name/etc.) while loaded — what does the source viewer do? → A: Full re-resolve. Signal-driven handler reloads the clip + its source sequence, recomputes title, rebinds playback if rate/duration changed, republishes selection_hub. Same pattern as the FR-004a auto-unload-on-delete handler, just refresh instead of unload.
- Q: Scope-trim 2026-05-19 → A: Dropped the in-memory holding-sequence wrap (was FR-005/006/007). Source viewer stores `clip_id` and binds playback to `clip.sequence_id` directly via existing `SequenceMonitor:load_sequence` — same code path as staged mode. Dropped FR-016d.1 atomicity-invariant overhead (override fields only mutated through documented entry points; defensive in-`get()` assert was paranoia). Dropped Phase 3.2 sub-tests T008a–T008d (folded into broader tests). Dropped Phase 3.3 spike T009 (no longer needed without holding sequence).
- Q: Shift+F binding conflict resolution — Shift+F currently binds `RevealInFilesystem`. Where does it move? → A: `RevealInFilesystem` moves to `Cmd+Option+F` (verified unbound). Shift+F becomes `OpenClipInSourceMonitor` per FR-024.

---

## Why this spec exists

Today the source viewer holds **only sequences**. There is no way to load a timeline-clip placement into it so that editing in/out points retrims that specific clip live. The `F` key (`MatchFrame`) loads the *master* (media sequence) with marks copied across — useful, but it's a different operation: it shows you the underlying media, not the clip.

This is the missing live-bound retrim operation that Premiere, Avid (Smart Tool zones), and Resolve all expose. In Premiere, double-click a timeline clip → source viewer loads that clip; press I/O → the clip retrims live on the timeline. We need the same.

The retrim has two flavors:
- **Overwrite**: clip shrinks/grows in place; downstream stays put; may create a gap.
- **Ripple**: clip shrinks/grows; downstream shifts to absorb the duration change.

Industry default is overwrite. Resolve's Trim Mode is the only system that lets the source-viewer retrim ripple. JVE adopts the Resolve model with a narrow toggle.

---

## Domain Model

### Two source-viewer modes

The source viewer carries an internal mode flag. Mark-setter behavior branches on it.

| Mode | Entered via | What's held | What marks mean | Commit semantics |
|---|---|---|---|---|
| **Staged sequence** (current) | Browser activation, `MatchFrame` (F) | A sequence_id (any kind: `kind='master'` / `kind='sequence'`) | Marks live on the sequence row (`sequences.mark_in_frame`, `mark_out_frame`); they are **staging state** for the next Insert/Overwrite. | User invokes Insert / Overwrite explicitly. Source-viewer marks do not mutate any clip directly. |
| **Live-bound clip** (new) | Timeline double-click; `OpenClipInSourceMonitor` (Shift+F) | A `clips`-table row (a placement inside a clip sequence) | Marks ARE the clip's `source_in_frame` / `source_out_frame`. Setting them retrims the clip immediately. | Per-mark mutation dispatches `RippleTrimEdge` or `OverwriteTrimEdge` (see Trim mode toggle below). Each I/O press is its own undo step. |

### Live-bound state (implementation detail)

In live-bound mode, the source viewer stores the loaded `clip_id` and binds the playback engine to `clip.sequence_id` — the clip's source sequence — via the existing `SequenceMonitor:load_sequence` path. No new playback-engine concept, no in-memory sequence wrap; playback uses the same code path as staged mode, just with marks read from `clips.source_in/out_frame` instead of `sequences.mark_in/out_frame`.

### Trim mode toggle (narrow scope)

Source viewer carries a `trim_mode` enum: `"overwrite"` (default) | `"ripple"`. **Narrow scope**: this flag affects ONLY the live-bound source-viewer retrim. It does not govern any timeline-side trim gesture (drag-trim, keyboard trims, edge selection). Future broadening to a unified "trim mode" across gestures is out of scope here.

The toggle is **session-transient**: it resets to `"overwrite"` on each application launch / project open. Not persisted to disk. (Matches the ergonomics of mode toggles; per-project or per-user persistence can be added later if users request it.)

The toggle is exposed via a command (`ToggleTrimMode`) so it's discoverable + bindable from the keyboard customization dialog. No default keybinding is assigned in this spec — UI placement (button, modifier, menu, dedicated key) is deferred.

### Inspector binding (unchanged contract, new publisher)

The inspector already handles `item_type="clip"` (clip schema) and `item_type="sequence"` (sequence schema). 019 adds source-viewer as a new *publisher* on the existing contract:
- Live-bound mode → publishes `item_type="clip"` under `panel_id="source_monitor"` (the loaded clip).
- Staged mode → publishes `item_type="sequence"` under `panel_id="source_monitor"` (already implemented in master as the "simple fix" prior to 019; pinned by `tests/test_source_viewer_publishes_selection.lua`).

The inspector branches on `item_type` exactly as it already does.

---

## ⚡ Quick Guidelines
- ✅ Focus on WHAT the user can do and WHY
- ❌ Avoid HOW to implement (no module boundaries, no exact API shapes)
- 👥 New behavior — not a refactor

---

## User Scenarios & Testing

### Primary user story

User clicks a clip on the timeline at frame 1000. They double-click it. The source viewer loads that specific clip; the viewer's playhead lands inside the clip's source range; the viewer's timecode ruler shows the clip's `source_in` and `source_out` as the visible range. The user presses `O` to set a new OUT one second earlier. The clip on the timeline shrinks by one second; downstream clips stay where they are (overwrite default); the inspector continues to show the clip's properties (now reflecting the new shorter duration).

The user toggles trim mode to ripple (mechanism TBD). They press `O` again to shorten by another second. The clip shrinks AND every clip after it on the same track shifts left to close the gap.

The user double-clicks a different timeline clip — the source viewer switches to that one (stays-put across timeline-selection-only changes; switches only on explicit invoke).

### Acceptance scenarios

1. **Double-click → live-bound** — User double-clicks a clip on the timeline. Source viewer enters live-bound mode for that clip. Inspector shows the clip's clip-schema fields. Source viewer's playhead is inside the clip's source range.
2. **Set OUT (overwrite default)** — In live-bound mode with `trim_mode="overwrite"`, user sets a new OUT mark inside the existing range. Clip's `source_out_frame` is updated; clip's `duration_frames` decreases; no other clips on the timeline move. One undo entry. Inspector reflects the new duration.
3. **Set OUT (ripple)** — Same setup with `trim_mode="ripple"`. Clip retrims; every clip after it on the same track shifts left to absorb the duration delta. One undo entry. Reversible.
4. **F-key path unchanged** — User presses F (MatchFrame) on a timeline clip. Source viewer loads the *master* (staged mode) with copied marks. Behavior identical to today.
5. **Browser route preserved** — User double-clicks a media sequence in the browser → source viewer enters staged mode (sequence-row marks). User double-clicks a clip sequence → timeline panel opens it as the active record sequence. (Browser stays-put on a click; only double-click activates.)
6. **Browser Opt+Return** — User selects a clip sequence in the browser and presses Opt+Return. Source viewer enters staged mode for the clip sequence (not the timeline). Lets the user inspect / play / use a clip sequence as a source for nesting. Shift+Return is NOT bound to this action (reserved for future range-select semantics).
7. **Cross-clip stays-put** — User has clip A live-bound in source viewer. They click clip B on the timeline (single click, just selection). Source viewer keeps clip A loaded; inspector switches to clip B per its existing publish rules. Only an explicit double-click or `OpenClipInSourceMonitor` invoke changes the source viewer's target.
8. **Toggle persistence** — User toggles trim_mode to ripple, retrims, quits, reopens project. Trim mode is back at overwrite. Session-transient.

### Edge cases

- **Setting OUT before IN** (or vice versa) — must assert and reject (no silent re-ordering). Same behavior as `Sequence:set_in / set_out`.
- **Setting OUT past the clip's source-sequence content boundary** — must assert and reject; the retrim cannot extend the clip past available source material. (Existing edge-trim machinery in BatchRippleEdit / RippleTrimEdge already enforces this — 019 inherits.)
- **Ripple retrim on a clip with locked downstream clips** — defer to existing ripple machinery's behavior; 019 does not add new locking semantics.
- **Clip is deleted while loaded in source viewer** (e.g., another action removes the clip row) — source viewer auto-unloads and emits `source_loaded_changed(nil, prev_clip_id)`. Inspector and transport react via the existing signal pathway; no separate code path required. See FR-004a for the contract.
- **Live-bound clip whose source sequence becomes offline / missing** — source viewer's existing offline overlay surfaces it. Mark-set still works on the row (database-only); playback shows offline.

---

## Functional Requirements

### Source viewer modes

- **FR-001** Source viewer carries an internal `mode` flag with exactly two values: `"staged_sequence"` and `"live_bound_clip"`. Set by the load API; never inferred.
- **FR-002** `source_viewer.load_sequence(sequence_id, opts)` — enters staged mode. Replaces `source_viewer.load_master_clip` (rename; new name reflects that the argument is a sequence of any kind, not a master clip). 019 keeps `load_master_clip` as a thin alias until 020 lands the global rename; the alias just calls `load_sequence`.
- **FR-003** `source_viewer.load_clip(clip_id, opts)` — enters live-bound mode. Loads the clip row + its source sequence (`clip.sequence_id`); binds playback by calling `SequenceMonitor:load_sequence(clip.sequence_id)` (same code path as staged mode); **parks the engine + view at `clip.source_in`** so the visible playhead and the engine position agree from the first frame the viewer is shown (without this, the engine inherits the master sequence's saved `playhead_position` — commonly its `start_frame` TC origin — and the first jog-step below that frame trips the engine's start-boundary assert). Stashes `clip_id` so the mark-setter and selection_hub publish know to read from clip columns. Transitions the mode flag to `"live_bound_clip"`.
- **FR-004** `source_viewer.unload()` — clears state, transitions to a neutral mode (no clip / no sequence loaded), and emits the existing `source_loaded_changed` signal with `(nil, prev_seq_id)`.
- **FR-004a** Source viewer auto-unloads when its currently-loaded entity (clip in live-bound mode; sequence in staged mode) is deleted. Listener: `sequence_content_changed` (existing JVE signal, emitted by `delete_clip.lua:126,166` and other clip-mutating commands on the owner sequence). On receipt for the loaded entity's owner sequence, source_viewer re-reads via `Clip.load`/`Sequence.load`; if the loaded id has vanished, calls `unload()` which emits `source_loaded_changed(nil, prev_id)`. Inspector and transport react via that single signal — no separate teardown wiring per listener. No assert on stale access; viewer is a reactive listener (rule 3.14 MVC).
- **FR-004b** Source viewer **re-resolves** when its currently-loaded entity is mutated by any non-delete edit (rate / enabled / name / source-sequence rename / etc.). Same `sequence_content_changed` listener as FR-004a: if the loaded id still resolves but its fields have changed, source_viewer refreshes its title (FR-016f), re-binds the playback engine if rate/duration changed, and republishes to selection_hub (FR-028, FR-029). Single handler, two outcomes (delete vs mutate) — distinguished by whether `Clip.load`/`Sequence.load` returns nil. NSF posture: a missed signal surfaces as a stale title or stale published selection (observable in tests), not a silent stale read.

### Live-bound state

- **FR-005** Source-viewer live-bound state is `(mode, live_clip_id)` only — no new in-memory entity, no DB row. `mode == "live_bound_clip" ⇔ live_clip_id ~= nil` (asserted on every transition). Playback is bound to `clip.sequence_id` via `SequenceMonitor:load_sequence` — the same code path staged mode uses. The choice not to wrap the clip in an in-memory holding sequence keeps the playback engine sequence-only without inventing a new entity (alternative considered + rejected in research.md §3).

### Trim mode toggle

- **FR-008** `core/edit_mode.get_trim_mode()` returns `"overwrite"` or `"ripple"`. Module-level session state.
- **FR-009** `core/edit_mode.set_trim_mode(mode)` asserts `mode ∈ {"overwrite","ripple"}`; no fallback. Emits a `trim_mode_changed` signal.
- **FR-010** Initial value on every application launch / project open is `"overwrite"`. Never read from / written to disk.
- **FR-011** `ToggleTrimMode` command flips the value via `set_trim_mode`. SPEC: `undoable = false` (UI state, not edit history). No default keybinding.
- **FR-012** Trim mode affects ONLY the source viewer's live-bound retrim dispatch. No timeline-side gesture consults it. (Future broadening is a separate spec.)

### Mark-setter dispatch

- **FR-013** In live-bound mode, setting a new IN or OUT mark dispatches one of two commands via `command_manager.execute_interactive`:
  - `trim_mode == "ripple"` → `RippleTrimEdge` (existing command)
  - `trim_mode == "overwrite"` → `OverwriteTrimEdge` (new command, FR-014)
  The dispatch carries: `clip_id`, `edge` (`"left"` for IN, `"right"` for OUT), `delta_frames` (new_mark − old_mark), `sequence_id` (the clip's owner), `project_id`. **Collapse-rejection precondition:** `SetMarkAndTrimIfClip` computes the new owner-timebase duration as `clip.duration ± delta_frames` and rejects the press at the command-layer boundary (log event, return without dispatching the nested trim) when `new_duration <= 0`. This catches the wrong-key UX case — setting IN at-or-beyond OUT, or OUT at-or-before IN — without crashing through the trim command's model assert. Wrong-key presses are routine UX, not invariant violations, so they MUST surface as a clean no-op, not a stack trace. Forward and reverse clips both go through the same arithmetic (reverse clips have `source_in > source_out` but still positive owner-timebase `duration`).
- **FR-014** New command `OverwriteTrimEdge` — peer of `RippleTrimEdge`. Same SPEC.args shape (`clip_id`, `edge`, `delta_frames`, `sequence_id`, `project_id`, all required). Executor mutates the focus clip's `source_in_frame` (or `source_out_frame`) and `duration_frames` consistent with the delta; `sequence_start_frame` shifts only on left-edge trims (right-edge leaves it unchanged). **Direction-aware (forward vs reverse clips).** For a reverse clip (`source_in > source_out`, source plays backwards as timeline advances) the duration and `sequence_start_frame` deltas invert sign — pushing `source_in` higher GROWS the playback range, and the head moves left rather than right. Direction is computed at the model layer (`Clip.compute_trim_duration` derives `sign = (source_out > source_in) ? +1 : -1`); `compute_trim` applies the same sign to `sequence_start`. Source-bound arithmetic (`source_in + delta`, `source_out + delta`) is direction-agnostic. Gap clips (`is_gap = true`, both source bounds nil) trim as pure timeline-frame arithmetic with the forward sign. **fps_mismatch (non-1:1 source↔timeline ratio) is a separate latent concern** — the current math assumes 1:1; non-1:1 trim is tracked separately. **Growth into occupied space absorbs neighbors in the path** — the same "overwrite" semantics Insert / Overwrite / Paste use. Implementation reuses the canonical primitive `ClipMutator.resolve_occlusions(db, { track_id, sequence_start, duration, exclude_clip_id })`: clips on the same track whose range intersects the new span are trimmed at head, trimmed at tail, deleted (fully covered), or split (straddle). The focus update + neighbor mutations are submitted to `command_helper.apply_mutations` as one batch. Owns its own undo entry — the planned mutation list is persisted under `_executed_mutations` and reverted via `command_helper.revert_mutations` (the same shape Paste / LiftRange / ExtractRange use). No downstream ripple; absorbed clips do NOT shift.
- **FR-015** `OverwriteTrimEdge` asserts on every precondition violation: clip not found; edge not in `{"left","right"}`; `delta_frames == 0`; new source range out of the clip's source-sequence content extent. No silent clamps.
- **FR-015b** (NSF Half-2 invariant) `OverwriteTrimEdge`'s post-mutation state MUST be read back from the DB and asserted by the regression test in `tests/test_overwrite_trim_edge.lua`. After execute, the test re-loads the clip via `Clip.load(args.clip_id)` and asserts `source_in_frame`, `source_out_frame`, `duration_frames`, and (for left-edge trims) `sequence_start_frame` all equal the expected post-mutation values. After undo, the test re-loads and asserts the four columns equal the pre-execute values bit-for-bit. The point: catches partial-write bugs, save() silent failures, and undoer omissions — output-validation, not just input-validation. Same pattern applied to ripple round-trip tests in the existing `tests/test_ripple_trim_edge.lua` (extend if not already covered).
- **FR-016** In staged mode, setting a new IN or OUT mark continues to update the sequence row's `mark_in_frame` / `mark_out_frame` (existing behavior; this spec does not change staged-mode semantics).
- **FR-016a** After any live-bound retrim, the source-viewer playhead is **left untouched** — no clamp into the new range, no snap to the just-pressed mark, no jump to IN. Marks are metadata, not playback bounds; the playhead remains a free navigation cursor. If the playhead ends up outside the new in/out range, the viewer renders the frame at the playhead position (decode is unaffected — the underlying source range is still valid; marks gate playback-range/edit-range, not scrub). Next user action (play, step, jog) operates from wherever the playhead is. This matches Premiere's observed behavior in the screenshots Joe captured 2026-05-19.
- **FR-016b** Key-repeat for the I/O mark-set keys (and any other key bound to a live-bound mark-mutation command) is **suppressed**. Qt's `QKeyEvent::isAutoRepeat()` flag is filtered at the source-viewer key handler — only `isAutoRepeat() == false` events dispatch a mark-set command. Holding the key down yields exactly one undo entry; releasing and pressing again yields a second. This keeps per-press undo atomic, deterministic, and trivially testable (no time-window heuristics, no coalescing logic). Applies in live-bound mode only — staged mode's I/O presses already only mutate sequence-row marks (cheap), so key-repeat there is not a concern unless a future change makes it one.
- **FR-016c** `ClearMarkIn`, `ClearMarkOut`, and `ClearMarks` are **disabled in live-bound mode**. A clip's `source_in`/`source_out` are required (not nullable); clearing has no defined destination. When any of the three commands dispatches with `panel_context="source_monitor"` and the source viewer is in live-bound mode, the executor returns early with a logged event (`log.event("ClearMarks*: not applicable in live-bound source-viewer mode")`) and no mutation. Existing `Alt+X` binding (`ClearMarks @timeline @source_monitor @timeline_monitor`) still routes to those scopes — only the source_monitor-in-live-bound-mode case no-ops. Staged-mode behavior is unchanged: clearing remains valid for sequence-row marks.
- **FR-016d** In live-bound mode, `effective_source.get()` returns `(sequence_id=clip.sequence_id, in=clip.source_in_frame, out=clip.source_out_frame)` — pass-through to the clip's underlying source sequence with the clip's own source range as in/out. Insert/Overwrite from the record-side use these values; because the same `source_in`/`source_out` columns drive both the retrim (FR-013/014) and the effective-source pass-through, the source-viewer marks and the edit-into-timeline bounds stay in lockstep automatically with no extra propagation logic. Implementation: source viewer's live-bound state contributes through the existing `effective_source._source_viewer_seq_id` channel, extended to carry an optional `(in, out)` override when the loaded entity is a clip rather than a sequence. **This amends 015's `effective_source` contract — see "Cross-spec touches" below.**
- **FR-016e** In live-bound mode, **Play ignores the marks** — they gate edit-bounds (the source range used for Insert/Overwrite per FR-016d), not playback. Pressing Play starts at the current playhead and runs forward through the clip's full content extent (the underlying source sequence's playable range), stopping at end-of-content. Marks remain visually drawn (so the user can see what they have set), but the playback range engine uses content bounds, not marks. This DIVERGES from staged-mode behavior, where the source viewer's playback range is `[mark_in or start_frame, mark_out or total_frames)` per the existing SequenceMonitor convention (`sequence_monitor.lua:1021-1024`). Implementation: SequenceMonitor exposes a new public method `M:get_playback_range()` returning `(range_start, range_end)`. It branches on `source_viewer.get_mode()` — `"live_bound_clip"` → `(start_frame, total_frames)`, otherwise → `(mark_in or start_frame, mark_out or total_frames)`. The playback engine (and any other consumer) reads from this single accessor so the divergence has one home, not two. The existing duration-label code path at `sequence_monitor.lua:1021-1024` should be refactored to call `get_playback_range()` for consistency.
- **FR-016f** Source viewer title in live-bound mode is `"Source: <clip_label> (in <owner_sequence_name>)"`. Staged mode keeps the existing `"Source: <sequence_name>"` form (`sequence_monitor.lua:580`). `<clip_label>` is **defined** as: `clip.name` when it is a non-empty string; otherwise `<clip_id_prefix>` (the first 8 chars of the clip id) — same convention SequenceMonitor's log lines use today. This is a sentinel selection (the executor produces one deterministic title from the row's available data), NOT a fallback masking an error: clips can legitimately have no `name` (gap-as-clip rows, freshly-created clips before naming), and the clip-id prefix uniquely identifies the row. No truncation logic in 019 (titles wider than the panel are an existing Qt concern).

### New commands

- **FR-017** `OpenClipInSourceMonitor` — load a timeline clip into source viewer (live-bound mode). SPEC.args: `clip_id` (required), `project_id` (required), `sequence_id` (required, the clip's owner). `undoable = false`. Executor calls `source_viewer.load_clip(clip_id)`.
- **FR-018** `OpenSequenceInSourceMonitor` — load any sequence (kind='master' or kind='sequence' under V13; kind='media' or kind='clip' post-020) into source viewer (staged mode). SPEC.args: `sequence_id` (required), `project_id` (required). `undoable = false`. Executor calls `source_viewer.load_sequence(sequence_id)`.
- **FR-019** `OpenSequenceInTimeline` — load a sequence into the timeline panel as the active record sequence. SPEC.args: `sequence_id` (required), `project_id` (required). `undoable = false`. Executor calls the timeline panel's existing `load_sequence` API.

### Browser command refactor

- **FR-020** `project_browser.activate_item` stops calling `source_viewer.load_master_clip` / `timeline_panel.load_sequence` directly. Instead it dispatches through `command_manager.execute_interactive` to one of `OpenSequenceInSourceMonitor` / `OpenSequenceInTimeline` based on item type and modifiers.
- **FR-021** Browser routing rules (default Return + double-click):
  - `item.type == "master_clip"` (will rename to `"sequence"` with `kind="media"` after 020) → `OpenSequenceInSourceMonitor`
  - `item.type == "timeline"` (will rename to `"sequence"` with `kind="clip"` after 020) → `OpenSequenceInTimeline`
  - `item.type == "bin"` → `focus_bin` (unchanged; bins are not commandable activations in 019 scope)
- **FR-022** Modifier override: **Opt+Return** on a clip-sequence browser entry routes to `OpenSequenceInSourceMonitor` instead of `OpenSequenceInTimeline`. Lets the user load a clip sequence into the source viewer (for inspection / nesting). Single modifier only — Opt is the macOS "alternate action" convention; Shift is not also bound, to avoid two routes to the same action and to leave Shift available for future multi-select / range semantics.
- **FR-023** Modifier override is not applied to media-sequence entries (they always go to the source viewer); no need to "redirect to timeline" — there is no such thing as loading a media sequence onto the record side.

### Keybindings

- **FR-024** `keymaps/default.jvekeys`:
  - `F` → `MatchFrame` (unchanged)
  - `Shift+F` → `OpenClipInSourceMonitor` (new; **replaces existing `RevealInFilesystem` binding** — see FR-024a)
  - `Cmd+Option+F` → `RevealInFilesystem` (**relocated** from `Shift+F` to free that slot for 019)
  - `Alt+F` → `FindMasterClipInBrowser` (unchanged; renames to `FindSourceInBrowser` after 020)
  - No default binding for `ToggleTrimMode` (UI placement deferred).
  - **Clip resolution.** `OpenClipInSourceMonitor` declares `clip_id` *optional*. The timeline double-click path (FR-026) supplies it explicitly from the view's hit-test. The keymap path (Shift+F) leaves it nil, and the command resolves the target clip via the same canonical policy `MatchFrame` uses (`command_helper.resolve_clips_at_playhead` + `pick_best_clip`): clips intersecting the playhead, filtered by selection when selection intersects, then video-trumps-audio + topmost-track-index. This ensures F (master) and Shift+F (live-bound clip) always act on the same row. Gap-as-clip rows are rejected with a loud assert per FR-027. **Known gap:** the canonical resolver does NOT yet honor `tracks.autoselect` — tracked in MEMORY as "Canonical clip resolver doesn't honor track autoselect".
- **FR-024a** The `RevealInFilesystem` move (`Shift+F` → `Cmd+Option+F`) is part of 019 (not deferred): the keymap edit lands in the same commit as the new `Shift+F` binding to avoid a transient state where two commands fight over one key. `Cmd+Option+F` was verified unbound at audit time (2026-05-19); if a future spec needs it, that spec is responsible for picking another slot for `RevealInFilesystem`.
- **FR-025** Browser keymap adds `Opt+Return` for the modifier override (FR-022). Plain `Return` continues to invoke `ActivateBrowserSelection`. `Shift+Return` is intentionally NOT bound to this action (reserved for future range-select semantics).

### Timeline double-click

- **FR-026** `src/timeline_renderer.cpp::mouseDoubleClickEvent` dispatches mouse double-click events through the existing mouse-event handler with `type = "double_click"`. `timeline_view_input.handle_mouse` branches on the type and calls `M.handle_clip_double_click(view, x, y)`. The handler queries `view.hit_test_clip(x, y)` to pick the clip (or nil) under the mouse, then dispatches `OpenClipInSourceMonitor` with only `clip_id` — `project_id` and the owner sequence are re-derived from the clip row inside `source_viewer.load_clip`, so they are not passed through the command dispatch.
- **FR-027** `handle_clip_double_click` rejects two cases without dispatching: (a) `view.hit_test_clip` returns nil (empty timeline space) — no-op; (b) the resolved clip's `is_gap` is true (gap-as-clip row) — log event, no dispatch. Gaps cannot be loaded into the source viewer because they have no underlying media to play.

### Selection-hub publishing

- **FR-028** In live-bound mode, source_viewer publishes `item_type="clip"` to selection_hub under `panel_id="source_monitor"`, with `clip_id`, `project_id`, and `sequence_id` (clip's owner) populated. Replaces the staged-mode item published by the master-prior-to-019 simple fix when the mode is live-bound.
- **FR-029** On mode transition (staged → live-bound or vice versa), source_viewer republishes the appropriate selection item. The inspector reacts via its existing selection-binding pathway.
- **FR-030** On `unload`, source_viewer clears its selection_hub entry (existing behavior from the simple fix; pinned by `tests/test_source_viewer_publishes_selection.lua` test 2).

### Test coverage

- **FR-031** New tests:
  - `test_overwrite_trim_edge.lua` — per-edge mutation, no downstream movement, undo round-trip, precondition asserts, post-mutation read-back assertions (FR-015b).
  - `test_source_viewer_load_clip.lua` — source_viewer surface: live-bound mode entry + `M.get_mode()`, selection_hub publish (`item_type="clip"`), mark-setter dispatch routing (Ripple vs OverwriteTrimEdge), key-repeat suppression (FR-016b), `sequence_content_changed` reactor for both delete (FR-004a) and mutate (FR-004b) outcomes.
  - `test_live_bound_play_ignores_marks.lua` — sequence_monitor surface: playback-range computation branches on source_viewer mode (FR-016e). Content extent in live-bound; `[mark_in or start, mark_out or total)` in staged.
  - `test_clear_marks_disabled_in_live_bound.lua` — set_marks.lua surface: ClearMarkIn/Out/Marks no-op + log event when source_viewer in live-bound mode (FR-016c). Staged-mode dispatch unchanged.
  - `test_edit_mode_toggle.lua` — `core/edit_mode` get/set asserts, signal emission, session-transient (re-require resets).
  - `test_open_clip_in_source_monitor.lua` — command dispatches `source_viewer.load_clip`; inspector publish carries `item_type="clip"`.
  - `test_browser_activation_routes_through_commands.lua` — `activate_item` dispatches through `OpenSequenceInSourceMonitor` / `OpenSequenceInTimeline`; verifies the modifier override path.
  - `test_timeline_double_click_dispatches_open_clip.lua` — double-click on a clip dispatches `OpenClipInSourceMonitor`; gap-as-clip rejected; empty space no-op (FR-026, FR-027).
  - `test_effective_source.lua` (EXTEND) — override channel scenarios (live-bound triple, staged single, clear, browser-active-wins precedence).
  - `test_source_viewer_publishes_selection.lua` (EXTEND from simple-fix) — live-bound mode publishes `item_type="clip"`.
- **FR-032** Existing tests touched by the rename (`load_master_clip` callers, ActivateBrowserSelection paths) update in-place to invoke the new APIs; old API alias kept until 020.

---

## Cross-spec touches

This spec amends a contract from a previously shipped spec. Forward-pointing notes are added to the affected spec; the canonical authority is here.

### 017-refactor-playback-engine (playhead auto-injection)

- **017 contract today**: `command_manager.execute_interactive` auto-injects `playhead` only for MOVEMENT-class commands (those with `args.sequence_id = {}`). Edit-class commands (`args.sequence_id = { required = true }`) received only `sequence_id`; any need for the playhead was satisfied by each executor locally reading `Sequence.find(args.sequence_id).playhead_position`.
- **019 amendment**: a third command, `ExtendEdit` (this spec, FR-014), takes the same shape as Insert/Overwrite — needs both the active-record `sequence_id` and the playhead at the moment the keystroke fires. Repeating the `Sequence.find().playhead_position` lookup in a third place violates DRY and accretes drift surface. Playhead auto-injection is therefore extended to ACTIVE-RECORD commands when their SPEC declares `args.playhead`. Resolution source is the record engine when it's bound to the active sequence; otherwise the sequence row's persisted `playhead_position` (model authoritative — MVC).
- **Affected surfaces**: `command_manager.inject_context` (single entry point, opts.inject_sequence_id selects dispatch posture) now handles both routing classes uniformly. `Insert.execute` and `Overwrite.execute` lose their local `Sequence.find().playhead_position` resolution; they consume the framework-injected `args.playhead` directly.
- **Why this is not a workaround**: the centralization keeps the contract declarative — every command that declares `args.playhead` in its SPEC receives it, with no executor-side fallback code to drift. The model remains the single source of truth in the no-engine path.

### 015-source-in-timeline (`effective_source`)

- **015 contract today**: `effective_source.get()` returns a single `source_sequence_id` (or nil). Marks for Insert/Overwrite come from the sequence row itself (`sequences.mark_in_frame`, `mark_out_frame`).
- **019 amendment (FR-016d)**: when the source viewer is in live-bound mode, `effective_source.get()` may additionally carry `(in, out)` overrides drawn from the loaded clip's `source_in_frame` / `source_out_frame`. Insert/Overwrite consume these overrides verbatim, ignoring any sequence-row marks on the underlying source sequence.
- **Why this is not a workaround**: the override path uses the same `clips.source_*_frame` columns that the live-bound retrim mutates (FR-013/014). Single source of truth — the source-viewer marks and the edit-into-timeline bounds are the SAME columns by construction, not two values that have to be kept in sync.
- **Affected 015 surface**: `effective_source.get` / `resolve_for_edit` signatures gain an optional return field; `command_manager.execute_interactive`'s `source_sequence_id` injection grows to inject `source_in` / `source_out` when present.
- **Implementation order**: this contract amendment is a sub-task of T7 (selection-hub publish from live-bound mode). The override channel + the publish carry the same per-clip state through different surfaces.

## Out of scope

- **Master→media rename** — that's spec 020. 019 ships with the old vocabulary intact (`master_clip` item_type, `master_seq_id` parameter names, `kind='master'` schema values). 020 renames the world.
- **Persisting trim mode** — session-transient only in 019. Per-project or per-user persistence can be added later if users want it.
- **Broadening trim mode to other gestures** — narrow scope. Timeline drag-trim, keyboard mark-trims, edge selection — all keep their existing behavior. A future spec may unify.
- **UI placement of the trim-mode toggle** — explicitly deferred. The command exists, the state is consultable, but no button / menu item / modifier key / dedicated keybinding is wired up by 019.
- **Auto-switch on different timeline clip selection** — stays-put per FR (Acceptance scenario 7). Future preference may add an auto-switch mode.
- **Trim across nested-sequence boundaries** — if a live-bound clip's source sequence has its own clips inside (clip-kind nesting), retrimming the outer clip changes the outer placement only. Inner-clip retrim requires loading the inner clip separately. No recursion in 019.

---

## Open questions

- **Inspector branch on `sequence.kind` for kind-specific fields** — live-bound mode's clip schema works uniformly. But in staged mode, does the inspector want to render kind-specific fields differently for `kind='master'` vs `kind='sequence'`? Out of 019's scope (inspector schemas unchanged) but flagging.
