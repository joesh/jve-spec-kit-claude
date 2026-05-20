# Phase 0 — Research: Source-viewer live-bound clip mode

**Spec**: [spec.md](spec.md) | **Plan**: [plan.md](plan.md) | **Date**: 2026-05-19

Phase 0 distills decisions already made during clarification (Sessions 1 + 2 of spec.md ## Clarifications) plus targeted research on industry behavior. The 2026-05-19 scope-trim closed the one open technical spike by dropping the holding-sequence concept (see §3). Each entry follows the Decision / Rationale / Alternatives format.

---

## 1. Two source-viewer modes (staged vs live-bound)

- **Decision**: Source viewer carries an internal `mode` flag with exactly two values: `"staged_sequence"` (today's behavior — holds a sequence row) and `"live_bound_clip"` (new — holds a `clips`-table row).
- **Rationale**: Premiere's observed behavior on Joe's 2026-05-19 screenshots: double-clicking a timeline clip enters a live-bound mode where I/O retrims the clip directly; loading a master via F (MatchFrame) enters a staged mode where I/O sets sequence-row marks for staging. Avid and Resolve have analogues (Avid's Smart Tool zones; Resolve's Trim Mode). JVE adopts the explicit two-mode split.
- **Alternatives considered**:
  - Single mode that infers behavior from "is this entity a clip or a sequence" — rejected because the inferred behavior diverges in too many places (mark routing, playback range, title, effective_source contract); explicit modeselect is cleaner.
  - Three modes (add a "staged-master-with-clip-marks" variant) — rejected as over-engineering; Premiere/Avid/Resolve all collapse to two.

## 2. Trim-mode toggle scope and persistence

- **Decision**: Narrow scope (affects ONLY live-bound source-viewer retrim). Session-transient — resets to `"overwrite"` on every project open. Exposed via `ToggleTrimMode` command (no default keybinding; UI placement deferred).
- **Rationale**: Joe's "narrow" decision in /clarify Session 1. Resolve's broader Trim Mode toggle informed the option set but exceeds 019's scope. Session-transient matches mode-toggle ergonomics (you turn it on, do a thing, turn it off — surprise from persisted state is undesirable). Default `"overwrite"` matches Premiere/Avid (their non-toggle default) and Resolve (their toggle's default).
- **Alternatives considered**:
  - Broad scope across all retrim gestures — deferred; can be added without breaking 019's narrow API by widening the set of gestures that consult `edit_mode.get_trim_mode()`.
  - Per-project persistence (`projects.settings` JSON) — rejected as session-transient default; can be added later as a per-user preference if users request it.
  - Per-user persistence (`~/.jve/`) — same rationale as per-project.

## 3. Live-bound state shape (no holding sequence)

- **Decision**: Source viewer stores `(mode, live_clip_id)` only. Playback binding goes through the existing `SequenceMonitor:load_sequence(clip.sequence_id)` — same code path as staged mode. No in-memory holding sequence, no new entity.
- **Rationale**: The original draft (now rejected) proposed wrapping the loaded clip in an in-memory single-track holding sequence so the playback engine could "stay sequence-only". Closer reading showed the engine ALREADY consumes a sequence_id (the clip's source sequence) via the staged-mode path; the wrap added no behavior the existing path didn't already give. The wrap also forced a spike (does the engine accept non-DB sequences?) and risked schema-row scratch entities if the spike failed. Cutting the wrap removes a parallel mechanism (rule 2.16 no shortcuts) and ~100 LOC of construction + lifecycle.
- **Alternatives considered**:
  - In-memory holding sequence wrap (the original draft) — rejected for the reasons above. Adds an entity for layering's sake.
  - Direct play-a-clip API on the playback engine — rejected; the staged-mode path already plays the clip's source sequence (`clip.sequence_id`). Marks come from clip columns in live-bound, sequence-row marks in staged — that's the only branch needed.
  - Scope-trim date: 2026-05-19 (see spec.md ## Clarifications session 2).

## 4. Mark commands: reuse vs new

- **Decision**: Reuse existing `RippleTrimEdge` for the ripple path. Introduce new `OverwriteTrimEdge` as a peer command for the overwrite path. Source viewer dispatches one or the other based on `edit_mode.get_trim_mode()`.
- **Rationale**: Existing trim-vocabulary uses `trim_type ∈ {"ripple", "roll"}` and the `BatchRippleEdit` engine knows nothing about "overwrite" — overwrite is fundamentally a single-row mutation (clip duration changes; downstream stays put), unlike ripple/roll which are multi-clip operations. Adding `"overwrite"` to `BatchRippleEdit`'s trim_type enum would couple a single-row case to a multi-clip engine; cleaner to have it as its own command. ~40 LOC.
- **Alternatives considered**:
  - One parameterized command `TrimEdge { mode = "ripple" | "overwrite" }` — rejected; would have to dispatch internally to two different code paths (BatchRippleEdit vs direct mutation), losing the cleanly-named undo strings ("Ripple trim X" vs "Overwrite trim X") and per-binding rebindability.
  - Extend `BatchRippleEdit`'s trim_type enum — rejected; overwrite is single-row and doesn't need the batched-ripple machinery. Coupling them would force the overwrite path through ripple's batched-state-capture overhead.

## 5. Effective-source contract amendment (cross-spec)

- **Decision**: In live-bound mode, `effective_source.get()` returns `(sequence_id=clip.sequence_id, in=clip.source_in_frame, out=clip.source_out_frame)` — pass-through with the clip's source-range as in/out overrides. Amends 015's `effective_source` contract (single seq_id → optional triple). Forward-pointing note added to 015 spec; authoritative contract lives in 019 §FR-016d + §Cross-spec touches.
- **Rationale**: The source-viewer marks and the edit-into-timeline bounds must stay in lockstep. Both read the SAME columns (`clips.source_in_frame` / `source_out_frame`) by construction — retrim mutates them, effective_source reads them. No propagation logic, no two values to keep synchronized.
- **Alternatives considered**:
  - Live-bound mode disables Insert/Overwrite from source — rejected; breaks Premiere-equivalent UX where the user can edit the retrimmed clip back into a different track.
  - Use holding sequence directly as the source — rejected; requires effective_source to accept non-DB sequences, larger contract change than the (in, out) override extension.
  - Defer to a follow-up spec — rejected; the gap would leave Insert/Overwrite silently broken in live-bound mode.

## 6. Auto-unload and re-resolve on model mutation

- **Decisions**:
  - Auto-unload on entity deletion: source viewer listens for clip/sequence deletion signals; on a match against the loaded id, calls `unload()` which emits `source_loaded_changed(nil, prev_id)` (FR-004a). MVC posture: view reacts to model.
  - Re-resolve on entity mutation: same listener entry point, but on mutation signals (not delete) the handler reloads clip + source sequence via `Clip.load`/`Sequence.load`, refreshes title + playback binding + selection_hub publish (FR-004b).
- **Rationale**: View pulls from model. Single signal pathway, single handler, two verbs. Both reuse existing Sequence/Clip mutation/deletion signals. No silent stale reads — if a signal is missed, tests can detect via observable state divergence.
- **Alternatives considered**:
  - Hard assert on stale clip_id access — rejected; deleting a clip while it's loaded is a legitimate user action, not an invariant violation.
  - Refresh only on next explicit load — rejected; surfaces a "I have to manually reload" friction the user won't expect.

## 7. Marks-are-edit-bounds-not-playback-bounds in live-bound mode

- **Decision**: In live-bound mode, Play ignores the in/out marks — they gate edit-bounds (the source range used for Insert/Overwrite per FR-016d), not playback. Play starts at current playhead and runs forward to end-of-content. Staged mode keeps its existing behavior of using marks as a playback range.
- **Rationale**: Marks in live-bound mode ARE the clip's source_in/out — i.e., what defines the clip's content extent in the timeline. Treating them as playback bounds would clamp playback to "what's already used", preventing the user from previewing material they're about to extend INTO when widening the clip. Premiere's observed behavior.
- **Alternatives considered**:
  - Snap-to-IN then play (option B in /clarify Session 2 Q2) — rejected; changes the playhead unexpectedly.
  - Play from playhead to OUT (option C) — rejected; OUT can be "infinite" if there are no marks set yet, which is a degenerate case.

## 8. Title format in live-bound mode

- **Decision**: `"Source: <clip_label> (in <owner_sequence_name>)"`. `<clip_label>` is a sentinel selection: `clip.name` when non-empty; otherwise `<clip_id_prefix>` (first 8 chars of clip id, matching SequenceMonitor's existing log convention).
- **Rationale**: Carries enough identity for the user to know what they're editing (clip name) plus context (which timeline it lives on — disambiguating same-named clips in different sequences). Sentinel framing avoids a "fallback" carve-out (rule 2.13) — clips can legitimately be nameless.
- **Alternatives considered**:
  - Just `"Source: <clip_name>"` — rejected; ambiguous when same-named clips exist in multiple sequences (common in editing workflows).
  - Include the source-sequence name (`"Source: <clip_name> from <source_seq_name>"`) — rejected; that's the material being PLAYED, not the placement being EDITED; staged mode is the right tool for inspecting the source sequence by name.

## 9. Browser activation refactored through commands

- **Decision**: `project_browser.activate_item` dispatches through `command_manager.execute_interactive` to one of `OpenSequenceInSourceMonitor` / `OpenSequenceInTimeline` (and `OpenClipInSourceMonitor` from the timeline double-click path). Drops direct `source_viewer.load_master_clip` / `timeline_panel.load_sequence` calls.
- **Rationale**: All activation paths go through the same dispatch surface. Keybindings, double-click, drag-to-source-viewer, MatchFrame, browser modifiers — all become discoverable, rebindable, testable from one place. Aligns with constitution II (command-driven interface).
- **Alternatives considered**:
  - Keep direct calls — rejected; new behaviors (Opt+Return modifier, timeline double-click) would have to be added as ad-hoc branches in `activate_item`, with no single command surface for keyboard customization to bind against.

## 10. Browser modifier: Opt+Return (not Shift)

- **Decision**: Opt+Return on a clip-sequence browser entry overrides the default route (which goes to timeline) and forces load into source viewer. Shift+Return is NOT bound — reserved for future range-select semantics.
- **Rationale**: macOS "alternate action" convention. Single modifier per action avoids "two ways to do the same thing" anti-pattern. Shift kept free for range-select consistency with other Mac apps.
- **Alternatives considered**:
  - Both Shift+Return and Opt+Return — rejected as redundant.
  - Only Shift+Return — rejected; collides with future range-select.

## 11. Key-repeat suppression for I/O in live-bound mode

- **Decision**: Filter Qt's `QKeyEvent::isAutoRepeat()` at the source-viewer key handler — only `isAutoRepeat() == false` events dispatch a mark-set command. Holding key = one undo entry; release-then-press = a new entry.
- **Rationale**: Per-press undo stays atomic, deterministic, and trivially testable (no time-window heuristics). Avoids flooding the undo stack and the command pipeline with key-repeat fire.
- **Alternatives considered**:
  - Coalesce within a time window — rejected as harder to test and the heuristic threshold is arbitrary.
  - One undo per press always (including key-repeat) — rejected; floods the undo stack with N entries the user didn't intend.

## 12. Clear marks disabled in live-bound mode

- **Decision**: `ClearMarkIn`, `ClearMarkOut`, `ClearMarks` no-op (with a logged event) when dispatched to source_monitor in live-bound mode.
- **Rationale**: `clips.source_in_frame` / `source_out_frame` are NOT NULL by schema. Clearing has no defined destination. The commands stay valid for staged mode (where marks are nullable sequence-row columns).
- **Alternatives considered**:
  - Expand to full source-sequence range — rejected; that's a separate "Maximize Clip" gesture, not a "Clear" semantic.
  - Hide the command from the keyboard editor in live-bound mode — rejected; the binding stays valid (it works in staged mode + other panels), only the live-bound dispatch path no-ops.

---

## Summary

All NEEDS CLARIFICATION items from spec.md were resolved during /clarify Sessions 1 + 2 (see spec.md ## Clarifications for the Q/A trail). Phase 0 has no open research items; the playback-engine in-memory-sequence spike that existed in the earlier draft was eliminated by the 2026-05-19 scope-trim (which dropped the holding-sequence concept — see §3).

Phase 0 complete. Proceed to Phase 1 (data-model.md, contracts/, quickstart.md).
