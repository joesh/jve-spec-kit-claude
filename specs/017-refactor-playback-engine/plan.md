# Implementation Plan: Two-Engine Playback Model (Source / Record)

**Branch**: `017-refactor-playback-engine` | **Date**: 2026-05-16 | **Spec**: [spec.md](./spec.md)
**Input**: `/Users/joe/Local/jve-spec-kit-claude/specs/017-refactor-playback-engine/spec.md`

## ⚠️ Design revisions superseding this plan

This plan was written before two design revisions landed. Read these BEFORE acting on anything below — the plan's API names and storage claims are stale in two specific places:

1. **No `set_user_transport(role)` / no persisted `transport_target`.** Revised 2026-05-16. The transport target is a pure projection of UI state computed by `transport.get_target()` (focus + displayed tab kind). There is no setter, no `_target` field, no `projects.settings.transport_target` key. Authoritative shape: [`contracts/transport.md`](./contracts/transport.md). Wherever the plan below names `set_user_transport`, `persist_target`, or "transport_target in projects.settings", treat it as historical — the implementation has none of those.

2. **`SequenceMonitor.new` does NOT construct a local fallback engine.** Eliminated 2026-05-17 (anti-pattern #5 in spec.md). The plan's "view widgets own engines" → "two role-bound singletons" framing is intact, but the implementation now leaves `self.engine = nil` pre-`transport_ready` rather than building an orphan; the engine module no longer subscribes to UI signals (project_changed teardown moved to `transport.lua`); the `active_engines` weak-set has been removed.

Everything else in this plan still matches the implementation. The Summary section below preserves the original (stale) framing for historical context; the spec + contracts are the source of truth.

## Summary

Replace the current view-widget-owns-engine model (each `SequenceMonitor` instance owns its `PlaybackEngine`, plus a `pick_playback_monitor` redirect and a focus-driven `_audio_owner` flag) with two role-bound singletons — **source-engine** and **record-engine** — each rebinding to whichever sequence currently fills its role. Replace the four-pointer coordination (`active_sequence_id` / `displayed_tab_id` / `focused_panel` / `_audio_owner`) with a single `transport_target` (`"source"` | `"record"`) that updates only on user-driven role events. Views become pure glass that pulls from whichever engine corresponds to their role. Audio device ownership is structural (whichever engine is playing) — no separate flag.

Concrete symptoms this resolves: silent source-tab playback (audio owner stuck on `timeline_monitor` while transport redirects to `source_monitor`), unhandled `F`/MatchFrame in `timeline_monitor` focus scope, ambiguous `[ticks]` log lines (two engines logging without identifier).

## Technical Context

**Language/Version**: Lua (LuaJIT 2.1) for UI/commands/transport; C++17 (Qt 6.x) for `PlaybackController` (CVDisplayLink driven), TMB, audio device.
**Primary Dependencies**: existing `core.playback.playback_engine`, `core.media.audio_playback`, `ui.panel_manager`, `ui.focus_manager`, `ui.timeline.timeline_state`, `models.sequence`, `core.signals`, `core.command_manager`. C++ side: `src/playback_controller.mm`, EMP (`TMB_*`, `MEDIA_*`), AOP/SSE.
**Storage**: SQLite `.jvp` project files. New per-project setting: `transport_target` in `projects.settings` JSON column. Sequence `playhead_frame` already persisted.
**Testing**: LuaJIT black-box tests under `tests/test_*.lua` via `test_harness.lua`; integration tests via `./build/bin/JVEEditor --test <script.lua>` for binding-dependent flows (audio handover requires real AOP/SSE).
**Target Platform**: macOS (Cocoa NSWindow + Qt 6 widgets); CVDisplayLink playback hot path is platform-specific. Refactor stays platform-agnostic — Cocoa surfaces unchanged.
**Project Type**: Single project (desktop GUI app).
**Performance Goals**: zero added decode latency on the steady-state play hot path; audio handover ≤ 50 ms p95 (single full drain/configure cycle); playhead writeback during play ≤ 1 DB row update / sec / playing engine (FR-007a).
**Constraints**: synchronous audio handover (FR-012) must complete before next video frame delivers; no extra decode on view/engine rebind-away (FR-016 case (b)); no I/O on hot path (writeback is throttled best-effort, droppable).
**Scale/Scope**: 2 engines (singletons), per-project `transport_target` persistence (1 string), keymap-scope rewiring (transport class role-scoped, everything else global), C++ log tag plumbing (sequence-id + role per `JVE_LOG_*` call from playback paths).

## Constitution Check
*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

**I. Modular Architecture (MVC mandatory)**: ✅ Refactor is FOR MVC — engines become role-bound resources, sequences own transport state in Model, views pull. The current four-pointer coordination is the violation; the spec eliminates it.

**II. Command-Driven Interface**: ✅ Transport commands remain commands (`TogglePlay`, `ShuttleForward`, `ShuttleReverse`, `ShuttleStop`, plus existing `Nudge*`, `SetPlayhead`, etc.). New: command dispatch consults `transport_target` instead of `pick_playback_monitor`. No new command-bypass paths.

**III. Test-First Development (NON-NEGOTIABLE)**: ✅ Plan generates failing tests in Phase 1 before any implementation:
- Black-box: source-side playback emits audio (FR-024 regression); `F` reachable in all monitor focus scopes (FR-021); coalesced rapid tab switches (FR-009a); empty source-target Space is no-op (FR-027a); video-only master takes audio ownership silently (FR-013a); `active_sequence_id` change parked + playing (FR-005a/b); writeback cadence ≤ 1 Hz steady (FR-007a).
- Integration (`--test` mode): synchronous audio handover invariants (FR-012's I1 no-overlap + I2 audio-before-video, verified via audio-stream tap); two-view frame lock-step (FR-015); engine log lines tagged (FR-022).

**IV. Documentation-Driven Specifications**: ✅ Spec at v2 with two `/clarify` sessions, 33 FRs, 10 Q→A clarifications, all `[NEEDS CLARIFICATION]` resolved.

**V. Template-Based Consistency**: ✅ Following plan-template structure; data-model.md / contracts/ / quickstart.md generated per template.

**VI. Fail-Fast Assert Policy**: ✅ Spec mandates asserts at every error path: FR-010 (mis-routed transport command asserts with context); FR-012 (handover-step failure asserts, not absorbed); FR-027 (Space-with-no-loaded sequence = clean no-op OR assert, never silent). Plan preserves these.

**VII. No Fallbacks or Default Values**: ✅ FR-008a explicitly forbids implicit default beyond persisted-or-record; FR-013a forbids skipping handover for video-only masters; FR-016 case (b) forbids stale-frame-from-wrong-sequence and "default/blank as if it were content"; FR-027a forbids auto-fallback to record. The refactor REMOVES current fallbacks (`pick_playback_monitor`'s redirect, the `or 0` on `start_timecode_frame` in `playback_engine:load_sequence`).

**VIII. No Backward Compatibility**: ✅ Old per-monitor engine ownership is deleted, not shimmed. `pick_playback_monitor` and `focus_manager.on_focus_change`'s audio-handoff block are removed outright. The `_audio_owner` field on `PlaybackEngine` is deleted. Tests that exercised the old shape (`test_playback_routes_to_displayed_tab.lua`) get rewritten or deleted, not preserved.

**Result**: PASS. No violations to track.

## Project Structure

### Documentation (this feature)
```
specs/017-refactor-playback-engine/
├── plan.md              # This file
├── spec.md              # Feature specification (with 2 /clarify sessions)
├── research.md          # Phase 0 output
├── data-model.md        # Phase 1 output
├── quickstart.md        # Phase 1 output (manual validation walkthrough)
├── contracts/           # Phase 1 output
│   ├── transport.md     # Transport API (set_user_transport, get_user_transport, …)
│   ├── engine.md        # Engine lifecycle API (load, unload, play, stop, …)
│   └── audio_handover.md # Synchronous handover protocol
└── tasks.md             # Phase 2 output (/tasks command — NOT created by /plan)
```

### Source Code (repository root — JVE existing layout)
```
src/
├── lua/
│   ├── core/
│   │   ├── playback/
│   │   │   ├── playback_engine.lua          # MODIFY: remove _audio_owner; expose load/unload contract
│   │   │   └── playback_helpers.lua         # likely unchanged
│   │   ├── playback/
│   │   │   └── transport.lua                # NEW: holds source-engine + record-engine singletons; transport_target accessor; set_user_transport(role)
│   │   ├── media/
│   │   │   └── audio_playback.lua           # MODIFY: device-ownership becomes structural (one current engine pointer at module level); expose halt_current() and acquire_for(engine)
│   │   ├── commands/
│   │   │   └── playback.lua                 # MODIFY: pick_playback_monitor() deleted; commands consult transport.get_engine_for_target()
│   │   └── command_manager.lua              # touch: edit-command dispatch never consults focus for role; clip-context commands reachable from every monitor focus scope (FR-021/021a)
│   ├── models/
│   │   └── sequence.lua                     # unchanged: playhead_frame Model field already exists; engine reads on load, writes on stop/park + throttled during play
│   └── ui/
│       ├── sequence_monitor.lua             # MAJOR: stops owning engine; becomes pure view; pulls from transport.engine_for_role(self.role); registers as observer
│       ├── panel_manager.lua                # MODIFY: no longer registers "active monitor" — role membership only; get_active_sequence_monitor() deleted
│       ├── focus_manager.lua                # MODIFY: audio-handoff block deleted; on_focus_change no longer touches engines
│       ├── timeline/
│       │   ├── timeline_state.lua           # MODIFY: switch_to_source_tab + switch_to_record_tab call transport.set_user_transport("source"|"record")
│       │   ├── timeline_panel.lua           # MODIFY: tab click → transport.set_user_transport(...); source-tab timeline view becomes view bound to source-engine
│       │   └── timeline_tab_strip.lua       # may need minor wiring
│       └── source_viewer.lua                # MODIFY: load_master_clip → calls transport.engine_for_role("source"):load(seq_id) + transport.set_user_transport("source")
└── playback_controller.mm                   # MODIFY: every JVE_LOG_* in playback paths threads role+seq_id prefix per FR-022

tests/
# Behavior tests (rule 2.34 — named after what the user observes, not what code does)
├── test_first_open_project_defaults_to_record_side.lua          # FR-008a
├── test_project_reopen_restores_last_active_side.lua            # FR-008a
├── test_rapid_tab_switching_settles_on_last_click.lua           # FR-009a
├── test_clicking_empty_source_viewer_still_targets_source.lua   # FR-027a
├── test_source_and_record_each_remember_their_own_playhead.lua  # FR-001/002/003 (two-engine independence)
├── test_loading_a_new_master_stops_the_previous_one.lua         # FR-004
├── test_loading_resumes_at_last_stopped_frame.lua               # FR-006/007
├── test_stopping_persists_playhead_for_next_open.lua            # FR-007
├── test_crash_during_play_recovers_within_one_second.lua        # FR-007a
├── test_picking_different_active_sequence_during_play_stops.lua # FR-005a
├── test_picking_different_active_sequence_while_parked_swaps.lua # FR-005b
├── test_no_audio_dropout_when_switching_between_source_and_record.lua # FR-012 (I1) — --test mode
├── test_video_does_not_appear_before_audio_when_switching_sides.lua   # FR-012 (I2) — --test mode
├── test_video_only_master_plays_with_no_sound.lua               # FR-013a
├── test_only_one_side_produces_audio_at_a_time.lua              # FR-011
├── test_pressing_space_on_source_tab_makes_sound.lua            # FR-024 regression — --test mode
├── test_source_viewer_and_source_tab_show_same_frame.lua        # FR-015 — --test mode
├── test_parked_side_keeps_showing_last_frame_during_other_play.lua # FR-016 case b
├── test_new_sequence_shows_empty_placeholder_until_played_once.lua # FR-016 case c
├── test_space_acts_on_the_side_user_just_clicked.lua            # FR-020
├── test_match_frame_works_from_every_clip_selecting_focus.lua   # FR-021
├── test_insert_lands_on_record_even_from_source_focus.lua       # FR-021a
├── test_log_line_identifies_which_side_produced_it.lua          # FR-022 — --test mode
├── test_one_question_answers_which_side_is_playing.lua          # FR-023
├── test_pressing_space_with_nothing_loaded_does_nothing.lua     # FR-027
├── test_focusing_browser_during_play_does_not_silence_audio.lua # FR-009 negative
# Contract tests (rule 2.34 exception — these test public-API surface; name reflects contract entry point)
├── contract/test_transport_contract.lua                         # transport.md contract
├── contract/test_engine_contract.lua                            # engine.md contract
├── contract/test_audio_handover_contract.lua                    # audio_handover.md contract
# Migration of existing tests
├── test_playback_routes_to_displayed_tab.lua                    # DELETE — exercises old pick_playback_monitor redirect that no longer exists
└── (existing test_playback_engine*.lua etc. — many need updates because _audio_owner field is gone; tests that asserted on it must be rewritten or deleted)
```

**Structure Decision**: Single project (JVE desktop app, existing Lua + Qt6/C++ hybrid layout). No new subdirectories needed; new files land in existing `src/lua/core/playback/`, `src/lua/core/media/`, `src/lua/ui/`, `tests/`. One new module — `src/lua/core/playback/transport.lua` — owns the two engine singletons + `transport_target` pointer + the role accessors that replace `pick_playback_monitor`.

## Phase 0: Outline & Research

**Unknowns extracted from spec + tech context**: none mark `NEEDS CLARIFICATION` (resolved across 2 `/clarify` sessions). Remaining research items are *known-unknowns of the existing codebase* — implementation details the spec deliberately doesn't pin:

1. **Current `PlaybackEngine` lifecycle inventory** — what state must move to `transport.lua` vs. stay on the engine? (TMB, decoders, audio cfg stay; `_audio_owner` flag deletes; transport methods stay; the `sequence_id` becomes "loaded_sequence_id" with explicit `load(id)` / `unload()` contract.)

2. **Audio device halt + acquire API in `audio_playback.lua`** — does today's module expose synchronous stop-and-halt, or only fire-and-forget stop? Needed to satisfy FR-012's two invariants (I1 no-overlap, I2 audio-before-video) — the two functions `halt_current()` and `acquire_for(engine)` are the entire public surface for handover.

3. **C++ `PlaybackController` per-engine state** — each `SequenceMonitor.engine` today owns a `_playback_controller` (m_position, m_total_frames, m_bounds, m_surface, m_mirror_surface). With two singleton engines, do we still have two `PlaybackController` instances (one per role) or one shared? Two — keeps decode pools independent so parked engine retains its decoded last frame for view cache (FR-016 b).

4. **Logger tagging mechanism** — `JVE_LOG_EVENT(Ticks, ...)` macros today don't carry a role. Cheapest plumbing: thread a `const char* engine_tag` member on `PlaybackController` (set once on construction: `"source"` or `"record"`); macros expand to include it OR caller passes it explicitly. Resolve in research.

5. **`transport_target` persistence column** — `projects.settings` is JSON; add a key. No schema change.

6. **Keymap-scope rewiring** — does the current keymap loader support "global scope" (edit commands reachable from every focus context) and "role scope" (transport keys filtered to a focus class)? Or is everything panel-scoped today? The TSO showed `F` unhandled in `timeline_monitor` scope — current code is panel-scoped. Research how to refactor to two scope classes minimally.

7. **Test infrastructure for synchronous audio handover** — must run under `--test` mode (real AOP/SSE). Validate the two invariants (I1, I2) via a `--test`-only audio-stream tap that returns recently-produced samples tagged with the source engine, and via timestamps of audio-first-sample vs. video-first-frame post-handover. No internal step probe.

8. **Coalesce mechanism for rapid `transport_target` events** — Qt event-loop is single-threaded for UI; coalescing is "if a handover is in flight, mark a pending-target and apply at the end of in-flight handover; supersede repeatedly until the queue drains." Confirm Qt's event coalescing primitives or implement explicitly.

These produce `research.md` with one Decision/Rationale/Alternatives block per item.

**Output**: `research.md` with the 8 items above resolved.

## Phase 1: Design & Contracts

*Prerequisites: research.md complete.*

1. **`data-model.md`** — concise model+infrastructure entity layout:
   - **Sequence Model fields touched**: `playhead_frame` (existing), `mark_in_frame` (existing), `mark_out_frame` (existing). No new columns; refactor changes who writes them, not the schema.
   - **`projects.settings` JSON**: add `transport_target: "source" | "record"`.
   - **Transport module state** (`src/lua/core/playback/transport.lua`): `source_engine: PlaybackEngine`, `record_engine: PlaybackEngine`, `_target: "source" | "record"`, `_project_id: string`. FR-009a coalescing is structural (Qt event-loop serialization) — no `_pending_target` slot or `_handover_in_flight` flag required.
   - **Engine state per instance**: `role: "source" | "record"` (set at construction), `loaded_sequence_id: string | nil`, `_playback_controller` (C++), `_tmb` (C++), transport state (playing/dir/speed/position) — same as today minus `_audio_owner`.
   - **Audio module state** (`src/lua/core/media/audio_playback.lua`): one module-level `_owning_engine: PlaybackEngine | nil` pointer; two functions — `halt_current()` and `acquire_for(engine)` (which internally configures the device for the engine's bus rate, or for silent output per FR-013a).
   - **View state**: `role: "source" | "record"`, `sequence_id: string` (what it should display), `last_received_frame: cached`, `last_received_for_seq_id: string` (must match `sequence_id` to display).

2. **`contracts/transport.md`** — public surface of `transport.lua`:
   - `transport.init(project_id)` — read persisted target from settings; construct both engines.
   - `transport.shutdown()` — write target to settings; tear down both engines.
   - `transport.get_target() -> "source"|"record"` — single accessor (FR-023).
   - `transport.set_user_transport(role)` — applies coalescing (FR-009a); writes-through to persistence eventually.
   - `transport.engine_for_role(role) -> Engine` — returns one of the two singletons.
   - `transport.engine_for_target() -> Engine` — sugar for `engine_for_role(get_target())`.

3. **`contracts/engine.md`** — engine contract changes:
   - `engine:load(sequence_id)` — read playhead from Model, configure TMB/audio, park at saved playhead.
   - `engine:unload()` — write playhead to Model, release TMB/decoders.
   - `engine:play()`, `engine:stop()`, `engine:shuttle(dir)` — existing semantics + take/release audio device per FR-012/013.
   - `engine.role: "source" | "record"` — read-only.
   - `engine.loaded_sequence_id: string | nil` — read-only.
   - **Removed**: `engine._audio_owner`, `engine:activate_audio()`, `engine:deactivate_audio()`.

4. **`contracts/audio_handover.md`** — the two-invariant synchronous handover (FR-012):
   - **I1 (no-overlap)**: at every sample-instant during handover, audio output is sourced from at most one engine.
   - **I2 (audio-before-video)**: the new engine does not deliver any video frame before its audio output (`acquire_for(engine)`) returns.
   - Implementation surface: two functions on `audio_playback` — `halt_current()` and `acquire_for(engine)`. Engine `play()` body is two lines (`halt_current` if old owner exists; `acquire_for` self). Implementation MAY pipeline internals (pre-warm decoders during halt, etc.) as long as I1/I2 hold.
   - Both functions assert on failure (timeout, acquire error) with role + cause.
   - No mid-handover cancellation needed — handover is short; coalescing is handled structurally by Qt's single-threaded event loop (R8); no `_pending_target` or `_handover_in_flight` state required.

5. **Contract tests (failing)** — one per contract file:
   - `tests/contract/test_transport_contract.lua` — every public function asserts on bad input; `set_user_transport("garbage")` asserts; `get_target()` returns a non-nil value at all times after init.
   - `tests/contract/test_engine_contract.lua` — `engine:load(nil)` asserts; `engine:play()` before any load asserts.
   - `tests/contract/test_audio_handover_contract.lua` — 5 ordering probes via `--test`-mode hooks.

6. **`quickstart.md`** — manual validation steps Joe runs:
   1. Open a project with 1 master (has audio) + 1 record sequence with audio + 1 record sequence video-only.
   2. Click master in browser → source tab opens, source viewer loads master.
   3. Click Source tab → source-tab timeline view shows master tracks. Press Space → master plays with audio in both source viewer + source-tab timeline view simultaneously, playhead numbers identical.
   4. Click Record tab → master stops mid-play, audio silent, source viewer parks on last frame, timeline panel renders record.
   5. Press Space → record plays with audio.
   6. Press `F` while record tab focused → MatchFrame fires.
   7. Press F9 while source viewer focused (source has marks) → Insert lands on active record.
   8. `tail -f` editor log during a play-then-tab-switch session → every line tagged `source:xxxxxxxx` or `record:xxxxxxxx`.
   9. Close + reopen project → transport target restored to whichever side was last used.

7. **Agent file update**: run `.specify/scripts/bash/update-agent-context.sh claude`.

**Output**: `data-model.md`, `contracts/transport.md`, `contracts/engine.md`, `contracts/audio_handover.md`, `tests/contract/test_*` failing tests, `quickstart.md`, updated `CLAUDE.md`.

## Phase 2: Task Planning Approach

*This section describes what `/tasks` will do — DO NOT execute during `/plan`.*

**Task generation strategy:**
- Load `.specify/templates/tasks-template.md`.
- Generate tasks in TDD order: **regression tests for current bugs first** (FR-024 source-tab audio, FR-021 F-unhandled, FR-022 untagged logs) — these must fail red on `master` baseline.
- Then **contract tests** for the three contract files (one task per file).
- Then **scenario tests** for each of the 8 acceptance scenarios in spec.md.
- Then **edge-case tests** for each of the 8 edge cases.
- Then **implementation tasks**, grouped by module touch surface:
  1. New `src/lua/core/playback/transport.lua` (engines + target).
  2. `playback_engine.lua` refactor (remove `_audio_owner`; expose load/unload contract; align with `transport.lua`).
  3. `audio_playback.lua` refactor (module-level single-owner pointer; `halt_current()`, `acquire_for(engine)` — the latter internally handles silent-output for video-only masters).
  4. `src/lua/core/commands/playback.lua` (delete `pick_playback_monitor`; consult `transport.engine_for_target()`).
  5. `sequence_monitor.lua` refactor (view-only; pull from `transport.engine_for_role(self.role)`).
  6. `focus_manager.lua` cleanup (delete audio-handoff block).
  7. `timeline_state.lua` + `timeline_panel.lua` (tab events → `transport.set_user_transport(...)`).
  8. `source_viewer.lua` (load → engine rebind + target set).
  9. C++ `playback_controller.mm` (role+seq_id log tag plumbing).
  10. Keymap scope rewiring (transport keys role-scoped; clip-context + edit globally reachable).
  11. Persistence wiring (`projects.settings` JSON `transport_target` read/write).

**Ordering strategy:**
- TDD: every test before the impl task that satisfies it.
- Bottom-up: `transport.lua` + `engine` contract + `audio_playback` helpers before view rewiring; views before signal wiring; signal wiring before keymap rewiring.
- C++ log tagging is independent and parallel-marked `[P]`.
- Mark `[P]` for tasks operating on disjoint files.

**Estimated output**: 35–45 numbered tasks. Larger than typical because the refactor touches both Lua and C++ and rewrites several existing tests.

**IMPORTANT**: This phase is executed by `/tasks`, NOT by `/plan`.

## Phase 3+: Future Implementation

**Phase 3**: `/tasks` creates `tasks.md`.
**Phase 4**: Tasks executed in order, each test verified red→green per TDD.
**Phase 5**: Validation — run full `make -j4` (luacheck + Lua + C++ + integration), execute `quickstart.md` manually, audit diff against ENGINEERING.md (1.14, 2.5, 2.13, 2.15, 2.20, 2.32, 3.14).

## Complexity Tracking

*Filled only if Constitution Check has violations.*

| Violation | Why Needed | Simpler Alternative Rejected Because |
|-----------|------------|-------------------------------------|
| — | — | — |

No violations. Refactor strictly reduces complexity (eliminates 4-pointer coordination, deletes `pick_playback_monitor`, deletes `_audio_owner` flag, deletes `focus_manager.on_focus_change` audio-handoff block).

## Progress Tracking

**Phase Status**:
- [x] Phase 0: Research planned (research.md TBD by /plan continuation)
- [x] Phase 1: Design planned (artifacts TBD by /plan continuation)
- [x] Phase 2: Task planning approach described (tasks.md NOT created)
- [ ] Phase 3: Tasks generated (/tasks command)
- [ ] Phase 4: Implementation complete
- [ ] Phase 5: Validation passed

**Gate Status**:
- [x] Initial Constitution Check: PASS
- [x] Post-Design Constitution Check: PASS — four audit passes converged; all rules verified (1.4, 1.5, 1.9, 1.10, 1.14, 2.5, 2.6, 2.13, 2.15, 2.16, 2.17, 2.18, 2.20, 2.21, 2.32, 2.34, 3.0, 3.14)
- [x] All NEEDS CLARIFICATION resolved (spec.md `## Clarifications` Session 2026-05-16, 10 Q→A across 2 clarify rounds)
- [x] Complexity deviations documented (none — refactor net-reduces complexity: deletes `_audio_owner`, `pick_playback_monitor`, focus-driven audio handoff, `_pending_target`/`_handover_in_flight`, `output_audio_rate` parameter, `resolve_output_audio_rate` helper)

---
*Based on Constitution v2.0.0 — see `.specify/memory/constitution.md`*
