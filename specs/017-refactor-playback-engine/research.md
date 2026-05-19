# Phase 0 Research: Two-Engine Playback Refactor

**Feature**: 017-refactor-playback-engine
**Date**: 2026-05-16

Eight known-unknowns identified in plan.md. Each resolved below.

---

## R1. Current `PlaybackEngine` state inventory — what moves, what stays, what dies

**Decision**: Engine retains: TMB handle, C++ `_playback_controller`, decoder pool references, transport state (`state`, `direction`, `speed`, `transport_mode`, `_last_committed_frame`, `_latch`), `fps_num`/`fps_den`, `total_frames`, `start_frame`, `_video_track_indices`, `_audio_track_indices`, `_effective_video_track_indices`, `_clip_info_by_id`, `max_media_time_us`. Adds: `role: "source"|"record"` (immutable, set at construction). Renames `sequence_id` → `loaded_sequence_id` (semantically same field; name reflects new lifecycle). Deletes: `_audio_owner` flag, `activate_audio()`, `deactivate_audio()`, `_audio_owner`-gated branches in `_try_audio` / `_configure_and_start_audio` / play/stop/seek paths. The audio-ownership condition becomes structural ("am I the one currently in the audio module's owning pointer?") not flag-based.

**Rationale**: `_audio_owner` exists today because two view-bound engines might both be "live" (parked) and focus had to choose which one talks to the device. With one device-owning pointer in `audio_playback.lua` (R3 below), the engine asks "am I the current owner?" by pointer-equality, not by checking a flag whose source-of-truth is `focus_manager`. Eliminates the four-pointer coordination at the engine layer.

**Alternatives considered**: keep `_audio_owner` for symmetry — rejected because it duplicates state that already lives at the audio module level and was the proximate cause of the silent-source-playback bug.

---

## R2. Audio device API in `audio_playback.lua` — what does the two-invariant handover need?

**Decision**: Today's `audio_playback.lua` exposes `set_max_time`, `session_initialized`, and is consumed via `_configure_and_start_audio` / `_stop_audio` on the engine. For the FR-012 two-invariant handover (no-overlap + audio-before-video), expose two new module-level functions:
  - `audio_playback.halt_current() -> nil` — synchronously stop the currently-owning engine's audio output; returns when no further samples will be produced. Bounded by a module-internal named constant `AUDIO_HALT_TIMEOUT_MS = 100` (rule 1.4: timeout policy is the audio module's concern; engine callers do not pass or know the value); assert on timeout with elapsed + role context.
  - `audio_playback.acquire_for(engine) -> nil` — acquire device for `engine`, configure for its loaded sequence's bus rate (or silent for video-only masters per FR-013a). Assert on acquire failure or if `_owning_engine != nil`.

Both are synchronous from the Lua caller's perspective; both assert on failure. The pair replaces the prior 4-function `drain/release/configure/start` decomposition — that breakdown locked the algorithm and required an internal probe to test (see R7 revision below).

**Rationale**: The two functions correspond directly to the two invariants. `halt_current` enforces I1; `acquire_for` enforces I2's prerequisite. The implementation is free to do whatever it needs internally (drain, release, reconfigure, pre-warm in parallel) provided the observable invariants hold. This restores implementation freedom without losing correctness.

**Alternatives considered**: keep the 5-step API (drain/release/configure/start) — rejected as over-specification; locks the algorithm and forces internals-testing. Do handover entirely in C++ — rejected per original analysis (target decision lives in Lua).

---

## R3. C++ `PlaybackController` — one instance shared, or one per engine?

**Decision**: Two instances. Each Lua engine constructs its own `PlaybackController`. They are independent: each owns its surface bindings (`m_surface`, `m_mirror_surface`), its CVDisplayLink, its TMB, its bounds. Only one CVDisplayLink runs at a time (FR-010: at most one engine playing) but both `PlaybackController` instances exist for the project lifetime.

**Rationale**: Parked engines hold their last decoded frame for view-cache (FR-016 case b). Sharing a single `PlaybackController` would lose the parked engine's state on every transport-target switch, requiring an extra decode at each swap — the very cost the two-engine model is designed to avoid. Two singletons preserves the FCP7/Premiere/Resolve UX of independent source/record transports.

**Alternatives considered**: single `PlaybackController` with role-swappable bindings — rejected: extra decode at every swap, loses parked-frame caching, and complicates the synchronous handover (the device is bound to a single C++ object that has to forget its old config before reconfiguring).

---

## R4. Log tagging mechanism — how does role+seq_id reach `JVE_LOG_*`?

**Decision**: Add a `std::string m_log_tag` member on `PlaybackController`, set at construction by the Lua engine via a new binding `PLAYBACK.SET_LOG_TAG(pc, tag)`. The tag is `"<role>:<first-8-of-seq-id>"`, recomputed and pushed on every `engine:load(seq_id)`. Macros in `playback_controller.mm` already take format args — wrap or replace each `JVE_LOG_EVENT(Ticks, "Play dir=%d ...", dir)` with `JVE_LOG_EVENT(Ticks, "%s Play dir=%d ...", m_log_tag.c_str(), dir)`. Touchpoints: every `JVE_LOG_*` call site in `playback_controller.mm` (~25 sites; mechanical edit).

**Rationale**: Cheapest plumbing — no new macro, no new logger area, no per-call argument. The tag lives where it's emitted. Recomputing on `engine.load` keeps it accurate across rebinds. Lua-side log emitters in `playback_engine.lua` use the same convention via `log.event("%s ...", self._log_tag, ...)`.

**Alternatives considered**: a new logger area per role (`source_ticks` / `record_ticks`) — rejected: changes log-filtering semantics for users; doesn't solve the "two engines logging" disambiguation as well as a prefix because mixed areas still need correlation. Per-call tag arg — rejected: ~25 call sites in C++ + ~15 in Lua, error-prone.

---

## R5. `transport_target` persistence

**Decision**: Stored as `transport_target` key in `projects.settings` JSON column. Read on `transport.init(project_id)`; written through eventually on `transport.set_user_transport(role)`. No schema change. On project close, a final write flushes the latest value. If the JSON is malformed or the key is absent, FR-008a's explicit default of `"record"` applies — *but* malformed JSON is itself a fail-fast assert (existing `core.database` invariant), not a soft fallback.

**Rationale**: `projects.settings` already holds per-project UI state (window geometry, recent paths, etc.); `transport_target` belongs there. JSON-add is cheap, no migration needed.

**Alternatives considered**: dedicated SQLite column on `projects` — rejected per constitution VIII (no backward compat); rejected per spec scope (1 string of state doesn't earn a column).

---

## R6. Keymap-scope rewiring

**Decision**: Today's keymap dispatch is panel-scoped via `focused_panel` (e.g., `focused_panel=timeline_monitor` matches a per-panel keymap subset). The current model has `F` registered but unreachable in `timeline_monitor` scope (TSO 2026-05-15). The refactor splits keymap entries into two classes:
  - **Transport class** (`Space`, `J`, `K`, `L`, `Home`, `End`, arrow keys, slow-play combos): role-scoped to any monitor focus (`source_monitor`, `source_tab`, `record_tab`, `timeline_monitor`). Dispatched against `transport.engine_for_target()`.
  - **Global class** (everything else: edit commands like `F9`/`F10`/`Delete`, clip-context like `F`/`Shift+F`/`Alt+F`, app-level like Cmd+S, etc.): reachable from every focus context including monitor focuses. Dispatched as commands with their existing target-resolution rules (edit commands target `active_sequence_id`; clip-context commands target the current selection).

The mechanism: extend the keymap loader to recognize a per-key `scope: "transport" | "global"` attribute (default `global`). The existing per-panel keymap inheritance gets replaced by `global` keys reaching every scope.

**Rationale**: Resolves FR-021 and FR-021a as a single architectural rewire rather than per-key whitelist patches. The current per-panel keymap inheritance is the root cause of `F`-unhandled-in-timeline_monitor; splitting at the right axis (key-class, not panel) fixes it cleanly.

**Alternatives considered**: add `F` and others to each monitor panel's keymap subset individually — rejected: doesn't scale, fragile per-panel maintenance, recreates the original bug for the next key Joe adds. The class-based split is the right abstraction.

---

## R7. Test infrastructure for synchronous handover (REVISED — black-box invariant tap)

**Decision**: Audio handover tests (FR-012's two invariants) run under `--test` mode (`./build/bin/JVEEditor --test <script.lua>`) to exercise real AOP/SSE. Tap the audio output stream via a `--test`-only inspector that returns a small ring buffer of recently-produced samples tagged with the source engine. Test asserts the two invariants directly:
  - **I1 (no-overlap)**: walk the ring buffer; verify no sample-instant has samples tagged with BOTH engine roles.
  - **I2 (audio-before-video)**: capture the timestamp of the first audio sample produced by the new engine post-handover; capture the timestamp of the first video frame the new engine delivers post-handover; assert audio_first_ts ≤ video_first_ts.

No internal step-counter probe. No `audio_playback._test_handover_state()`. The invariants are the contract; the test verifies the contract directly.

**Rationale**: Aligns with the project's "black-box tests only" rule (CLAUDE.md). Tests don't depend on internal step decomposition; if a future implementation pipelines or restructures the handover, the tests still verify correctness. The audio-stream tap is a thin `--test`-mode introspection — it observes outputs, not internals.

**Alternatives considered**: pure log-scraping (verify event order in [audio] log) — rejected: timing-dependent, flaky, doesn't cleanly express sample-instant overlap. Internal step probe — rejected (prior decision now reversed): locks the algorithm, violates black-box rule, gives false confidence by testing what the code does rather than what the user hears.

---

## R8. Coalesce mechanism for rapid `transport_target` events (REVISED — structural, no explicit state)

**Decision**: No explicit coalescing machinery in `transport.lua`. The behavior falls out of two existing platform invariants:

1. `transport.set_user_transport(role)` does NOT trigger an audio handover — it only writes `_target`.
2. Audio handovers happen only on transport-start (`engine:play()`), which blocks the Lua thread on its synchronous handover. Tab clicks during this window queue in Qt and process serially after the call returns.

Result: a rapid burst of `set_user_transport` calls collapses to "the final call's value of `_target`" with no intermediate observable side effects. Intermediate handovers never start because handovers only run when the user issues a transport command — and that's a separate, later event.

The earlier `_pending_target` slot + `_handover_in_flight` flag were redundant: they implemented coalescing for a window (mid-handover tab clicks triggering further handovers) that doesn't exist in this model.

**Rationale**: Cheapest correct model. Relies on a strong platform guarantee (Qt event loop is single-threaded) rather than on runtime flags. Per rule 2.21 (statically verifiable), structural invariants beat runtime state.

**Alternatives considered**: keep `_pending_target` for safety — rejected: dead state. queue + cancel — rejected: more state, more failure modes, no observable user benefit. Make `set_user_transport` itself trigger a handover — rejected: would cause N handovers for N rapid clicks, the exact problem FR-009a forbids.

---

## Summary

All 8 items resolved. Zero `NEEDS CLARIFICATION` remain. Phase 1 design can proceed.
