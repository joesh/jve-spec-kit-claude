# Feature Specification: Two-Engine Playback Model (Source / Record)

**Feature Branch**: `017-refactor-playback-engine`
**Created**: 2026-05-15
**Status**: Draft (revised 2026-05-16 — model changed from engine-per-sequence to source-engine + record-engine)
**Input**: User description: "Refactor playback engine ownership so engines belong to sequences (not to monitor view widgets), eliminating the four-pointer coordination problem (active_sequence_id / displayed_tab_id / focused_panel / audio_owner) that currently requires pick_playback_monitor's redirect and focus_manager's audio handoff."

---

## Architectural Premise (read first)

The first draft of this spec proposed *one engine per sequence*, lazy-cached. Joe pushed back: that drags expensive resources (TMB, decoders, audio config) into model space where they don't belong, and a project with N sequences would carry N decoder pools for no user benefit.

MVC categories applied honestly:
- **Per-sequence transport state** (playhead, marks, mark_in/out, last-stopped-frame) is **Model**. Lives on `Sequence`. Persists to the DB. Already does today.
- **Decoders / TMB / audio device / surface bindings** are **resources** — expensive, infrastructure, not model. They should be scarce and owned by stable roles, not multiplied per sequence.
- **Views** are glass. They observe an engine and render what it produces.

The right ownership in a classic NLE shape is **two engines, one per role**:
- a **source-engine** that plays whatever master is currently loaded in the source slot,
- a **record-engine** that plays whatever record sequence is currently active.

This matches FCP7/Premiere/Resolve mental model: source and record are *independent transports* — you can park one while playing the other, and switching focus between them doesn't pay a decoder warmup. The two engines are singletons bound to the two persistent UI roles (source viewer + timeline-panel-source-tab on one side, timeline_monitor + timeline-panel-record-tabs on the other). They don't multiply per sequence; they re-bind to a different sequence when the role's content changes.

`pick_playback_monitor`, the `_audio_owner` flag on each engine, and the four-pointer coordination disappear. What replaces them: one "transport target" pointer (`source` | `record`), updated by exactly two events — *user clicked something on the source side* or *user clicked something on the record side*. Audio ownership = "which engine is currently playing." Trivially one-of-two; no separate flag.

---

## Clarifications

### Session 2026-05-16
- Q: When `active_sequence_id` changes while record-engine is playing (e.g. user picks a different record sequence mid-play), what happens? → A: Record-engine stops, parks at new sequence's saved playhead, audio silent. User must press Space to play.
- Q: Audio device handover between engines mid-play — sync or async? → A: Synchronous. Transport-start blocks until two observable invariants hold: (1) no-overlap — old engine's audio fully halted before new engine's audio begins; (2) audio-before-video — new engine's video frame delivery does not begin before its audio output is started. Implementation may pipeline internal steps; only the two invariants are mandated.
- Q: Is the 5-step handover protocol (stop / drain / release / configure / start) overkill? → A: Yes. Replaced with the two observable invariants above (FR-012). The original 5-step formulation locked the algorithm and required an internal probe to test, violating black-box test policy. Two invariants are sufficient and directly observable via audio-stream tap.
- Q: Initial `transport_target` on project open? → A: Last value persisted from prior session for this project; if no persisted value (first open after refactor / fresh project), default to `record`.
- Q: Park-frame source when engine rebinds away from a view's sequence? → A: View caches every frame the engine delivers while loaded with `view.sequence_id`; on rebind-away, view continues showing the last cached frame. No extra decode at swap.
- Q: Where are record-side edit commands (Insert/F9, Overwrite/F10, Delete, Blade, etc.) reachable from? → A: Any focus context (browser, source-side view, record-side view, inspector). Edit commands are not focus-scoped — they always target `active_sequence_id`. Only transport keys are role-scoped (act on `transport_target`).
- Q: Audio device behavior when the source slot's master is video-only (no audio media)? → A: Source-engine takes audio ownership symmetrically (same handover protocol as audio-having sequences) but configures the device for silent output during source playback. No special-case branch on "has audio"; the handover is uniform.
- Q: Playhead writeback cadence to Sequence Model DB row? → A: On stop/park (always) AND throttled to ~once-per-second during continuous play / shuttle. Crash mid-play recovers within ~1s of the last-displayed frame; steady-state DB I/O stays bounded (≤1 row update / sec / playing engine).
- Q: Rapid UI events that change `transport_target` — how are they reconciled? → A: Coalesce to the last click. Tab clicks update only the target pointer (no audio handover); intermediate clicks during a transport-start's blocking handover queue and process serially after the handover returns, each just updating the pointer. The final realized `transport_target` equals the user's last click. Transport commands (Space etc.) are NOT coalesced — each triggers its own synchronous handover per FR-012.
- Q: Can `transport_target = source` when source slot is empty (no master loaded)? → A: Yes. Clicking the empty source viewer still sets `transport_target = source`; the empty source-engine is the target. Pressing Space in that state is a clean no-op per FR-027. There is no auto-fallback to `record`.
- Q: `active_sequence_id` change while record-engine is PARKED (not playing) — behavior? → A: Symmetric to the playing case (FR-005a) minus the audio steps. Record-engine writes its current playhead back to the old sequence's Model row, rebinds to the new sequence, and parks at the new sequence's saved playhead. Audio device wasn't in use, so no drain/release is needed. Views immediately re-pull from the rebound engine.

---

## ⚡ Quick Guidelines
- WHAT the user pressing Space, J/K/L, arrow keys, Home/End experiences when source and record content are both loaded.
- The bugs from 015-source-in-timeline (silent source playback, unhandled MatchFrame, ambiguous tick logs) are *symptoms* of the ownership confusion this refactor eliminates.

---

## User Scenarios & Testing *(mandatory)*

### Primary User Story

Joe loads a project. He clicks a master clip in the project browser — it loads into the source viewer (top-left) and a Source tab appears in the timeline panel. He clicks the Source tab — the timeline panel now also shows the master's tracks. The source viewer and the source tab in the timeline panel are two windows onto the same playing thing; they share a playhead. He presses Space — the master plays with audio in both windows in lock-step. He clicks a Record tab — master stops, audio falls silent, the source viewer parks on its last-shown frame (still visible, not playing), and the timeline panel switches to the record sequence's tracks. The timeline_monitor (the top viewer's record-side equivalent, if separately present) updates to the record's playhead frame. He presses Space — the record plays. He never has to think "which engine owns audio" or "which monitor is active." Source is one transport; record is another transport; the side he most recently interacted with is the one his keys drive.

### Focus vs. transport target (resolves Joe's inline question on the draft)

The source viewer (top-left widget) and the timeline panel's *Source tab area* are **two views of the same source-engine** — same loaded master, same playhead, same frames. Likewise the timeline_monitor (if/when present as a separate widget) and the timeline panel's *Record tab area* are two views of the same record-engine.

Keyboard focus is independent: only one widget at a time has Qt focus, but **both views of an engine render in parallel** regardless of which one has focus. Focus controls only keymap scope (which keybindings are reachable) and is one of two inputs to "which engine is the transport target." The other input is the user-visible content of the timeline panel's currently-displayed tab.

Rule: **the transport target is the side the user most recently acted on** — clicking the source viewer, clicking the Source tab, scrubbing the source playhead, loading a new master — these all set transport target = source. Clicking a Record tab, clicking the timeline_monitor, editing the record sequence — all set transport target = record. Clicking the project browser, the inspector, or a non-monitor area does NOT change transport target.

### Acceptance Scenarios

1. **Given** a master with audio is loaded in the source slot and the Source tab is displayed in the timeline panel, **When** Joe presses Space (focus on any source-side view), **Then** the master plays with audio audible, both source-side views advance frames in lock-step, the playhead displayed in the source viewer and in the timeline panel's source tab stay numerically identical.

2. **Given** the Source tab is displayed and the master is playing, **When** Joe clicks a Record tab in the timeline panel, **Then** master playback stops immediately, audio device falls silent, the timeline panel renders the record sequence, the source viewer's last-shown master frame remains visible (source-engine parked, not torn down), and transport target = record.

3. **Given** a record sequence is playing in the timeline panel, **When** Joe clicks the source viewer widget and presses Space, **Then** record playback stops, source-engine takes audio ownership, the master plays with audio in both source-side views, and the timeline panel does NOT auto-switch tabs (it stays on the record tab; the record's playhead does not move; the record's parked frame stays on screen).

4. **Given** the Source tab is displayed and the master is playing with audio, **When** Joe presses J (shuttle reverse), **Then** the master playback stops (J at 1× forward → first press stops, second press reverses, matching existing JKL semantics); the source-side views remain in sync; the record sequence is not affected.

5. **Given** the Source tab is displayed (master loaded), **When** Joe presses an arrow key, Home, or End, **Then** the source-engine's playhead steps / jumps within the master — the record sequence's playhead is untouched. Symmetric for arrow/Home/End pressed while a Record tab is displayed.

6. **Given** Joe has both a master loaded into the source slot and a record sequence active, with the Source tab currently displayed, **When** he presses 'F' (Match Frame) on a clip selected in the record's selection (the selection itself is record-side state, independent of which tab is currently displayed), **Then** MatchFrame dispatches — the keybinding is reachable in every focus context where a record-side selection exists.

7. **Given** transport is running on the master via the Source tab, **When** Joe inserts the source's marked range into the active record sequence (Insert/F9), **Then** the edit lands on `active_sequence_id` (the record), source playback continues uninterrupted on the source-engine, no change to source-side transport state. Insert/Overwrite semantics are unchanged from 015.

8. **Given** master and record have both played at various points in a session, **When** a developer reads the [ticks] log, **Then** every Play / Park / deliverFrame / clip_transition / Stop / audio line is prefixed (or otherwise tagged) with `source:` or `record:` plus the first-8 of the loaded sequence's id — the engine that wrote a line is unambiguous.

### Edge Cases

- **Source tab closed mid-play** → master playback stops, audio silent, source-engine unloads its sequence (decoders idle, ready to be re-bound), source viewer shows last decoded frame until another master is loaded. The source-engine itself persists.
- **Source viewer reloaded with a different master mid-play** → previous master playback stops, source-engine rebinds (`load(new_master_id)`), parks at new master's saved playhead, audio device is silent until Space.
- **No record sequence in the project** → record-engine exists but has no loaded sequence; the timeline panel renders empty / a hint; pressing Space when transport target = record asserts (no record to play) or no-ops cleanly per fail-fast policy.
- **Audio device owned by record-engine, Space pressed on source-side view** → handover from record to source: record fully halts audio output (FR-012 invariant I1) before source-engine acquires the device for the master's bus rate. Source-engine does not deliver any video frame until its audio output is started (FR-012 invariant I2). No torn buffers; no two-engines-pushing window.
- **User focuses project browser / inspector / non-monitor area mid-play** → playback continues uninterrupted; transport target does not change; audio ownership does not change. Focus is independent.
- **Both engines parked simultaneously** → normal state. Both hold their last decoded frame for their views. No audio. No CPU/GPU cost beyond surface presentation.
- **Source-engine and record-engine asked to play simultaneously** → cannot happen by construction. Only one transport command runs at a time; only one transport target exists. If somehow both received `play()`, the second one's audio-takeover would silence the first.
- **Source viewer + timeline-panel-source-tab both visible** → both pull frames from the single source-engine. One decode per frame, two surface presents.

## Requirements *(mandatory)*

### Functional Requirements

#### Engine roles & lifetime

- **FR-001**: There MUST be exactly two playback engines per running editor process: a **source-engine** bound to the source slot, and a **record-engine** bound to the record slot. Neither engine is created per-sequence; neither is destroyed on tab/sequence changes.

- **FR-002**: Each engine owns its own decoder pool / TMB / audio configuration / surface bindings. The two engines do not share these resources; each can independently be parked or playing (though only one plays at a time — see FR-009).

- **FR-003**: Both engines exist for the lifetime of an open project. They are torn down only when the project closes (before the DB connection closes) or when the editor process exits.

- **FR-004**: Each engine has, at most, one **loaded sequence** at a time. Re-binding (`engine.load(seq_id)`) reads that sequence's playhead/fps/track set from the Sequence Model, configures TMB and audio for it, and parks at the saved playhead. The previous loaded sequence is unbound — no resources leak, no state from the previous sequence influences the next.

- **FR-005**: A source-engine load is triggered by *source viewer loading a new master* (via project browser click, MatchFrame target resolution, etc.). A record-engine load is triggered by *active_sequence_id changing*. The engines do not load themselves; they're driven by Model events.

- **FR-005a**: When `active_sequence_id` changes while the record-engine is *playing*, the record-engine MUST stop the current sequence, write its playhead back to that sequence's Model row, rebind to the new sequence and park at the new sequence's saved playhead, and release the audio device. Playback does NOT continue into the new sequence; the user must press Space to start playing it. Symmetric for the source-engine when the source viewer rebinds to a new master mid-play.

- **FR-005b**: When `active_sequence_id` changes while the record-engine is *parked* (not playing), the record-engine MUST perform the same rebind sequence as FR-005a minus the audio steps: write current playhead back to the outgoing sequence's Model row, rebind to the new sequence, park at the new sequence's saved playhead. The audio device is not touched (it was not in use). The rebind is unconditional and synchronous with the `active_sequence_id` change — there is no "lazy" mode where the engine keeps the old sequence loaded until the next play attempt. Symmetric for source-engine when source viewer rebinds to a new master while parked.

#### Per-sequence transport state lives on the Sequence (Model)

- **FR-006**: `Sequence.playhead_frame`, `Sequence.mark_in_frame`, `Sequence.mark_out_frame`, and any other per-sequence transport state MUST live on the Sequence Model and persist to the DB as they do today. The engine does NOT own a per-sequence playhead — it has a *current* playhead for whatever it's loaded, which it writes back to the Model on stop/park and reads on load.

- **FR-007**: When an engine stops or parks, it MUST write its current playhead back to its loaded sequence's Model row. When it loads a new sequence, it MUST read the playhead from that sequence's Model row.

- **FR-007a**: While an engine is in continuous transport (Play, Shuttle, Slow-Play), it MUST also write its current playhead back to its loaded sequence's Model row at a throttled cadence of approximately once per second. This is in addition to the unconditional writeback on stop/park (FR-007). The throttled writeback guarantees that a process crash mid-play recovers the playhead to within ~1 second of the last-displayed frame, and bounds steady-state DB I/O to ≤1 row update per second per playing engine. The throttle MUST NOT delay or block the playback hot path; if a write cannot complete promptly it is dropped (the next 1-second tick will retry) — never queued indefinitely, never blocking decode.

#### Transport target

- **FR-008**: The system MUST maintain exactly one **transport target** pointer with value `source` or `record`. Transport commands (Space → TogglePlay; J/K/L → ShuttleReverse/Stop/Forward; ShuttleSlow combos; arrow keys for single-frame step; Home/End for sequence start/end) MUST act on the engine indicated by transport target. No transport command may consult "which monitor widget is focused" or any of `displayed_tab_id` / `focused_panel` / `active_sequence_id` to decide which engine to drive.

- **FR-008a**: The transport target is **derived** from persisted UI state — it is NOT itself stored under a `transport_target` key (superseded 2026-05-19; see [plan.md §10](./plan.md) and [data-model.md §15](./data-model.md)). The persisted inputs are: (a) `last_focused_panel` (per-project setting written by focus_manager on every focus change) and (b) the **displayed side** of the timeline tab strip, which `transport.get_target()` reads live via `timeline_state.get_displayed_tab_kind()`. That displayed side persists as part of the `timeline_tab_strip` blob (spec 015 — the strip's DisplayedTab pointer; it superseded the former standalone `displayed_tab_kind` setting). On project open, `last_focused_panel` and the strip are both restored before any transport query runs; the next `transport.get_target()` call computes `source` or `record` from them. First-open default — no `last_focused_panel`, no displayed source tab — falls out as `record`, matching `transport.get_target()`'s closing branch.

- **FR-009**: Transport target updates on, and only on, these user actions:
  - Clicking the source viewer widget or any of its sub-elements → target = source.
  - Clicking the Source tab in the timeline panel or scrubbing within the source-tab-displayed timeline → target = source.
  - Loading a new master into the source viewer → target = source.
  - Clicking a Record tab in the timeline panel or scrubbing within a record-tab-displayed timeline → target = record.
  - Clicking the timeline_monitor (top-area record-side viewer, where present) → target = record.
  - Switching the active record sequence via menu → target = record.
  - Focus changes to the project browser, inspector, or any non-monitor panel do NOT change transport target.

- **FR-009a**: `transport_target` updates are **coalesced to the last user click**: when multiple UI events that change the target arrive in rapid succession (faster than the system can fully realize each), the realized `transport_target` after the burst equals the most recent click — intermediate clicks have no user-visible effect. Tab clicks themselves do NOT trigger audio handovers; they only update the target pointer. Audio handovers happen only on transport-start (Space, J/K/L) and the in-flight handover for the previously-active target is allowed to complete uninterrupted before the next transport command's handover begins. Transport COMMANDS MUST NOT be coalesced — each is a discrete user intent and runs its own synchronous handover per FR-012.

- **FR-010**: At most one engine MAY be playing at a time. Transport commands MUST route only to the transport-target engine. Routing a transport command to the non-target engine is a programming error and MUST assert with the offending command name, the engine role it was sent to, and the current transport target — never silently absorbed.

#### Audio device ownership

- **FR-011**: The audio output device MUST be owned by exactly one engine at any moment: the one currently producing audio output. Ownership is structural, not a separately-tracked flag — "which engine is playing" = "which engine owns the device." With at most one engine playing (FR-010), the single-owner invariant is automatic.

- **FR-012**: When transport-start is invoked on an engine that is not currently the audio device owner, the call MUST block until two observable invariants hold:
  - **No-overlap**: the previously-owning engine (if any) has fully halted audio output — no samples are being produced from it.
  - **Audio-before-video**: the new engine has acquired the device and started its audio output (or `configure_silent` for video-only masters per FR-013a) BEFORE the new engine delivers any video frame.

  At every sample-instant during a handover the audio output stream is sourced from at most one engine — never two. The implementation is free to pipeline internal steps (e.g., pre-warm new-engine decoders during old-engine drain) as long as both invariants hold at every observable instant. If audio acquisition fails, or if halting the previous engine times out (bound: 100 ms), the call MUST assert with the offending engine roles, the elapsed time, and the failure cause — never swallow and proceed silently. Black-box testable by tapping the audio output stream during a handover.

- **FR-013**: When an engine stops (Play→Stop, hits content end, parks via Space-while-playing), it MUST release the audio device cleanly. The other engine remains parked and silent until the user starts it.

- **FR-013a**: When an engine's loaded sequence has no audio content (video-only master, or any sequence with no audio media_refs/clips), the engine MUST still satisfy FR-012's invariants: the previously-owning engine fully halts its audio output, and the new engine acquires the device for silent output (no samples produced, or zero-valued samples per platform requirement) before delivering any video frame. No special-case "skip handover" branch — the single-owner invariant (FR-011) holds even when the new engine produces silence. From an audio-stream-tap perspective, the stream is sourced from the new engine (producing silence) rather than from the old engine.

#### View ↔ engine binding (pull, not push)

- **FR-014**: Source-side views (source viewer surface + timeline-panel-source-tab tracks/ruler/monitor area) MUST observe the source-engine and pull from it. Record-side views (timeline_monitor surface + timeline-panel-record-tab tracks/ruler/monitor area) MUST observe the record-engine. Views never own or instantiate engines.

- **FR-015**: When two views observe the same engine (source viewer + timeline-panel source tab area), a single transport tick MUST cause both views to display the same frame at the same time. There is one decode per frame; both surfaces present from the same source. No double-decode; no half-frame drift.

- **FR-016**: A view's renderable state is derivable from {its sequence id, the engine's loaded sequence id, the engine's current playhead, the engine's last decoded frame}. Specifically:
  - If `view.sequence_id == engine.loaded_sequence_id` and engine is *playing*: view renders engine's hot-path frames.
  - If `view.sequence_id == engine.loaded_sequence_id` and engine is *parked*: view renders engine's last-decoded frame (or pulls one fresh via a park-decode at saved playhead).
  - If `view.sequence_id != engine.loaded_sequence_id` (engine has rebound away to a different sequence): view MUST render the most recent frame the engine produced *while loaded with `view.sequence_id`*. This frame is cached on the view itself, updated on every frame the engine delivers during the matching-loaded window; on rebind-away the view simply continues showing the last cached frame. The engine does NOT perform a one-shot park-decode at rebind; no extra decode is incurred at the swap. The view MUST NOT show the engine's current frame (which belongs to a different sequence) and MUST NOT silently substitute a default/blank frame as if it were content.
  - If `view.sequence_id != engine.loaded_sequence_id` AND the view has never received a frame for its sequence: view MUST render the documented empty-state placeholder (e.g. black with sequence name, or whatever the explicit empty-state design is) — this placeholder is its own visual asset, never a stale frame from another sequence and never an arbitrary "first available" frame.
  - This is the MVC pull rule: views ask, engines answer.

- **FR-017**: When the loaded sequence on an engine changes (`engine.load(new_id)`), all views observing that engine MUST re-pull state and re-render. No view may retain frames from the previous loaded sequence after the engine has re-bound.

#### Edit-vs-transport separation

- **FR-018**: `active_sequence_id` (the record sequence that edit commands target) MUST remain independent from transport target. Editing the source-tab-displayed master never changes the active record; transporting the master never changes which record sequence Insert/Overwrite/Delete target.

- **FR-019**: Insert / Overwrite / Trim / Ripple / etc. (any command that mutates the record sequence) MUST act on `active_sequence_id`'s record sequence, regardless of which engine is the transport target. The 015 behavior of Insert-from-source-with-marks lands on the active record is unchanged.

#### Keyboard dispatch

- **FR-020**: Transport + movement keys are the ONLY role-scoped key class — they act on the engine indicated by `transport_target`. The class comprises:
  - Transport: `Space` (TogglePlay), `J` / `K` / `L` (Shuttle Reverse / Stop / Forward), shuttle-slow combos (`K+J`, `K+L`), `Home`, `End`.
  - Movement: arrow keys for single-frame step, `I` (SetMark in), `O` (SetMark out), `Alt+I` (ClearMark in), `Alt+O` (ClearMark out), `Alt+X` (ClearMarks), `GoToMarkIn`, `GoToMarkOut`, and any other command whose semantics is "move the playhead/marks on the currently-displayed sequence."

  All of these MUST dispatch from every focus context that user-visibly corresponds to a playable sequence — source viewer focus, source tab focus in timeline panel, record tab focus in timeline panel, timeline_monitor focus. They MUST act on `transport_target`'s engine — NEVER on `active_sequence_id`'s engine when those differ (marks and playhead belong to whatever the user is looking at; this is the long-standing CLAUDE.md "movement → displayed tab" rule).

- **FR-021**: Clip-context commands (MatchFrame/F, Reveal-In-Filesystem/Shift+F, FindMasterClipInBrowser/Alt+F, and analogous) MUST be reachable in every focus context where a clip is selectable — including the timeline_monitor focus scope, where they're currently unhandled (TSO 2026-05-15). They act on the current selection (record-side or browser-side), independent of `transport_target`.

- **FR-021a**: Record-side edit commands (Insert/F9, Overwrite/F10, Delete, Blade, Trim, Ripple, and other commands that mutate the record sequence) MUST be reachable from ANY focus context — project browser, source viewer, source tab, record tab, timeline_monitor, inspector. Edit commands are NOT focus-scoped; they always target `active_sequence_id`. The user MUST NOT have to refocus the timeline panel record area to press F9; pressing F9 with the source viewer focused while a source range is marked MUST still insert into the active record. The only role-scoped key class is the transport class enumerated in FR-020.

#### Observability

- **FR-022**: Every diagnostic log line emitted from playback-engine code (Play / Park / Seek / deliverFrame / clip_transition / Stop / audio events / TMB lifecycle) MUST be prefixed with an engine role tag (`source:` or `record:`) and the first-8 of the engine's currently-loaded sequence id. Example: `[ticks] EVENT: source:ffb76dbb Play dir=1 speed=1.0 audio=1`. Reading the [ticks] stream during interleaved source/record activity MUST never require guessing which engine produced a line.

- **FR-023**: The transport target MUST be inspectable from a single accessor: e.g. `playback.transport_target()` returns `"source"` or `"record"`. The implementation MUST NOT require composing answers from `focused_panel` + `displayed_tab_id` + `active_sequence_id` + `_audio_owner` to determine "what is the user playing right now?"

#### Regressions explicitly prohibited

- **FR-024**: Source-tab playback in the timeline panel MUST produce audio. (Regression target — the bug that prompted this refactor.)

- **FR-025**: Switching from Source tab to Record tab while master playback is running MUST stop master playback, silence audio, and park the source viewer's surface (it does NOT continue advancing visually).

- **FR-026**: Source viewer surface and timeline-panel-source-tab monitor surface MUST stay in lock-step when both render the source-engine's frames (no double-decode, no drift between the two surfaces — guaranteed structurally by FR-014/015).

- **FR-027**: Pressing Space when no transport-target engine has a loaded sequence (e.g. fresh project, no master loaded, no record open) MUST be a clean no-op OR surface an actionable assert per fail-fast policy. Never a silent failure or crash.

- **FR-027a**: `transport_target = source` is valid even when the source slot is empty (no master loaded). UI events that target the source side (clicking the empty source viewer widget, opening the Source tab before any master is loaded) MUST still set `transport_target = source`; the system MUST NOT auto-fallback to `record` based on the source-engine's loaded-or-empty state. Pressing Space in this state is a clean no-op per FR-027 — the no-op is the documented outcome, not a hidden fallback. Symmetric for `transport_target = record` when no record sequence exists in the project.

- **FR-027b**: PlaybackEngine maintains the lifecycle invariant `loaded_sequence_id ~= nil` ⟺ `_playback_controller ~= nil`. `load_sequence` sets both atomically (assigns `loaded_sequence_id`, then `_setup_playback_controller()` asserts the C++ create succeeded); `teardown_engine` clears both — together with the rest of the load-set state (sequence model, fps, start_frame, _position, total_frames, track-index snapshots, TMB) — returning the engine to constructor defaults. There is no legal "loaded but not wired" or "wired but not loaded" intermediate state. Consequence: `loaded_sequence_id` is the single canonical predicate for "is this engine bound to a sequence?" — used by `core/commands/playback.lua::target_ready` (FR-027 no-op gating), signal-driven entry points (`on_model_changed`, `notify_content_changed`) that fire across all engines and document a no-op when not bound, and external callers (command_manager auto-inject, view filtering per FR-016). Callers MUST NOT consult `_playback_controller` to ask the bound-or-not question; it is an internal C++-binding handle, not a public state field. (Replaces an earlier formulation that admitted a "loaded but not yet activated" window and scattered `_playback_controller == nil` guards across read sites — that was a symptom of an asymmetric teardown, not a legitimate state.)

### Key Entities

- **Source-engine** (singleton): The one engine bound to the source slot. Owns a decoder pool, TMB, audio config, surface bindings. Has at most one loaded sequence at a time (always a master). Process-lifetime.

- **Record-engine** (singleton): Symmetric. Bound to the record slot. Loaded sequence is always a non-master record sequence. Process-lifetime.

- **Transport target** (Controller pointer): `"source"` or `"record"`. Updated by FR-009's specific user actions; queryable as a single accessor.

- **Loaded sequence** (per-engine pointer): The sequence id currently bound to that engine. Read by views to determine "is this engine showing my content?" Re-bound on master-loaded-into-source or active-record-changed events.

- **Sequence (Model)**: Owns per-sequence transport state — `playhead_frame`, `mark_in_frame`, `mark_out_frame`. Persists to DB unchanged from today. Engine reads on load; engine writes back on stop/park.

- **View (source viewer surface, timeline-panel monitor surface, timeline-panel tracks/ruler, timeline_monitor)**: Pure glass. Holds a sequence id (its content) and a reference to one of the two engines (its role's engine). Renders by pulling from the engine when the engine's loaded sequence matches the view's; otherwise shows last frame or placeholder.

- **Active sequence (edit target)**: Unchanged. `active_sequence_id` selects which record sequence edit commands target. Independent of transport target — present in the model both before and after this refactor.

---

## Module Responsibilities & Dependency Direction (read before touching playback code)

These rules formalize the resource model from the Architectural Premise. They've been violated by good-faith Claudes more than once; the same mistakes are listed below as anti-patterns so future readers can recognize them before re-introducing them.

### Roles

- **`core.playback.playback_engine`** — **resource definition.** Defines the engine type: state machine, decoder pool, TMB, audio handover steps, surface bindings, playhead writeback. Has no opinion about which engine instance corresponds to which user-facing role. Knows nothing about tabs, displayed pointers, focus, or active sequences. A unit test of this module SHOULD be able to construct an engine instance and exercise its state machine without booting transport, timeline_state, or any UI signal.

- **`core.playback.transport`** — **resource orchestrator.** Owns the two role-bound engine singletons. Owns the `transport_target` derivation. Translates *UI events* into *engine actions*. ALL cross-domain coordination between UI/model events and engine lifecycle lives here: project_changed, displayed_tab_changed, displayed_tab_cleared, active_sequence_changed, focus_change, source_loaded_changed. Transport subscribes to these signals; transport then calls `engine:load(...)`, `engine:stop()`, etc.

- **`ui.sequence_monitor`** — **view (pure glass).** Holds a role + a view_id. Renders frames the engine produces. Caches the last frame it received for FR-016. Does NOT own an engine instance in the resource sense; it observes the role-bound engine via `transport.engine_for_role(self.role)`.

- **`ui.timeline.timeline_state`** — **model layer for view-state.** Owns the displayed pointer, per-sequence playhead/viewport/marks (writes them to the Sequence Model row). Emits `displayed_tab_changed` / `displayed_tab_cleared` / `active_sequence_changed`. Does NOT know about engines.

### Dependency Direction

```
UI gesture (click, key, tab close)
   ↓
timeline_state / focus_manager / panel_manager  (Model + Controller layer)
   ↓  emits signal
core.signals
   ↓  transport subscribes
core.playback.transport  (resource orchestrator)
   ↓  calls
core.playback.playback_engine  (resource definition)
```

**The arrows never point upward.** `playback_engine` does not `require("core.signals")` to subscribe to UI events. `playback_engine` does not know that `displayed_tab_cleared` exists. If you find yourself adding `Signals.connect(...)` inside `playback_engine.lua`, stop — the listener belongs in `transport.lua`.

No exceptions today. `project_changed` engine teardown — the last upward-pointing arrow in `playback_engine.lua` — was migrated to `transport.lua` on 2026-05-17 as part of anti-pattern #5's elimination. The engine module no longer subscribes to any `core.signals` channel. If you add such a subscription, you are re-introducing the wrong-direction arrow.

### Anti-patterns (caught and corrected; do not re-introduce)

1. **"One engine per sequence."** The first draft of this spec proposed lazy-cached per-sequence engines. Wrong: engines are resources (TMB, decoders, audio device), not model data. A project with N sequences would warm N decoder pools for no user benefit. The realized design is **two engines per role**, each rebinding to whichever sequence currently fills its role. See Architectural Premise.

2. **"Engine subscribes to UI signal."** A Claude (2026-05-17) added `Signals.connect("displayed_tab_cleared", ...)` inside `playback_engine.lua` to stop an engine when its loaded sequence's tab closed. Wrong direction — the engine module should not know about tabs. The listener belongs in `transport.lua`, which knows both the UI event and which role's engine corresponds to the closed tab.

3. **"Iterate a per-instance engine pool to find the engine for a sequence."** Same Claude, same listener, iterated `playback_engine.lua`'s `active_engines` weak-set looking for an engine whose `engine.sequence.id == seq_id`. Wrong abstraction on two counts: (a) it's an instance pool, so it conflates "any engine" with "the role-bound engine" — and at the time it also held orphan local engines from `SequenceMonitor.new`'s pre-transport fallback (anti-pattern #5); (b) treating engines as a sequence-keyed pool is the rejected per-sequence-engine thinking sneaking back in. The role model says: there are exactly two role-bound engines, ask transport which role holds the seq. The `active_engines` weak-set itself was removed on 2026-05-17 (see anti-pattern #5 below). The rule survives the removal: if you find yourself wanting to enumerate "all engines" to locate one, you've misframed the question — walk `{"source", "record"}`.

4. **"Cosmetic wrapper to hide a mutation."** Same Claude attempted `PlaybackEngine:attach_view(view_id, cb_table)` to package `engine._on_X = cb` assignments under a method name. The wrapper enforced nothing; the silent-overwrite semantics were identical. Don't add wrappers that don't add invariants. Multi-view-per-engine is a real design question (multicast frame delivery vs single-attach with detach) — solve it with structure, not a method name.

5. **"`SequenceMonitor.new` falls back to a locally-owned engine when transport isn't bootstrapped."** ELIMINATED 2026-05-17. Previously, layout.lua constructed monitor widgets at app launch (before transport.init runs at project open), and the monitor's constructor built a local `PlaybackEngine` to avoid `self.engine = nil`. The local engine spent its life being abandoned when `transport_ready` emitted and the monitor rebound to the canonical role engine, with the rebind dance reaching into the canonical engine's `_on_*` private fields from outside. Current shape: `SequenceMonitor.new` leaves `self.engine = nil` pre-transport; `_create_widgets`' surface-attach guards with `if self.engine`; the `transport_ready` listener binds the canonical engine and attaches the surface via the shared `bind_to_engine(self, engine)` helper (same helper the constructor uses on the bootstrapped path — no duplicated callback installation). Tests that construct monitors call `transport.init(project_id)` first (matching the production order at project open) — see `tests/test_sequence_monitor_no_orphan_engine.lua` for the invariant pin.

  Consequence: the engine module's `active_engines` weak-set has been **removed** (it existed only to power the project_changed teardown loop, and with orphans gone there's no need to enumerate "all engines"). Project-change teardown now flows: transport.lua's `project_changed` listener walks `{"source", "record"}` and calls `PlaybackEngine.teardown_engine(engine)` per role, then `PlaybackEngine.shutdown_audio_session()`. The engine module exposes per-engine teardown as a building block; transport composes them. This is the resource-model contract in code: engine = resource definition, transport = resource orchestrator + iteration.

### How to extend playback-related behavior without violating the above

- **New UI event needs to drive engine behavior** → add `Signals.connect("<event>", function(...) ... end)` in `transport.lua`, route through `M.engine_for_role(role)`.
- **New engine method (load, stop, seek, configure)** → add to `playback_engine.lua`; transport calls it. Engine method has no `Signals.connect`.
- **View needs to react to an engine state change** → view observes via existing engine listeners (`monitor:add_listener`), OR transport emits a domain signal that views subscribe to. The engine itself doesn't emit `core.signals`.
- **Asking "which engine holds sequence X?"** → walk `{"source", "record"}` via `transport.engine_for_role(role)` and check `engine.loaded_sequence_id`. Do NOT introduce a per-instance engine pool (sequence_id → engine map, weak-set of all engines, etc.) to iterate over.

---

## Review & Acceptance Checklist

### Content Quality
- [x] No implementation details (no module names, file paths, function signatures — only role-level architectural shapes)
- [x] Focused on user value (source plays with audio; transport follows where the user just acted; logs are unambiguous; no per-sequence resource overhead)
- [x] Written so a non-developer could read scenarios and acceptance criteria
- [x] All mandatory sections completed

### Requirement Completeness
- [x] No [NEEDS CLARIFICATION] markers remain — the three open questions from the draft are resolved by the two-engine structure:
  - "Engine teardown timing" → N/A (engines live for project life; only the loaded-sequence pointer changes).
  - "F-key scope" → reachable in every clip-selection focus context (FR-021).
  - "Log identifier format" → `role:first-8-of-id` prefix (FR-022).
- [x] Requirements are testable (audio audible/silent; log lines parsable for role; both surfaces show the same frame; single accessor exists)
- [x] Success criteria measurable
- [x] Scope clearly bounded (engine ownership + transport target + audio device + view-pull. Explicitly NOT changed: Insert/Overwrite semantics, `active_sequence_id` semantics, per-sequence Model fields)
- [x] Dependencies/assumptions identified (depends on 015 source-tab infrastructure; assumes Sequence Model already persists playhead/marks)

---

## Execution Status

- [x] User description parsed
- [x] Architectural premise revised after MVC re-audit (engine-per-sequence rejected; two-engine model adopted)
- [x] Joe's inline questions on draft resolved (focus-vs-transport equivalence, J first-press semantics, arrow/Home/End scoping, why-not-per-sequence)
- [x] User scenarios defined
- [x] Requirements generated (27 FRs across 8 buckets)
- [x] Entities identified
- [x] Review checklist passed (all clarifications resolved)

---

## Resolved Open Questions (from draft)

1. **Engine teardown timing** → engines are process-lifetime singletons; only their *loaded sequence* changes. No per-sequence teardown question exists.
2. **F-key scope** → reachable in every focus context where a clip is selectable (FR-021).
3. **Log identifier format** → `source:` / `record:` role prefix + first-8 of loaded sequence id (FR-022).
4. **`source_viewer.load_master_clip` ↔ Source-tab auto-open** → kept coupled; loading a master into the source slot opens the Source tab if not already open, and rebinds source-engine. One atomic user-visible operation.
5. **Focus on timeline_monitor vs. record tab in timeline panel** → no functional difference; both are views of the record-engine. Both render record-engine frames simultaneously (parallel glass). Qt focus controls only keymap scope. Both being "active" at once IS the correct state.
6. **Source-side symmetry** → same: source viewer and timeline-panel-source-tab area are parallel glass on the source-engine.
