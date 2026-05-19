# Contract: `core.playback.transport` module

**Feature**: 017 | **Phase**: 1 | **File**: `src/lua/core/playback/transport.lua`

The single source of truth for "what is the user playing?" Replaces `pick_playback_monitor()` (deleted) and `focus_manager.on_focus_change`'s audio-handoff block (deleted).

## Design note: derived target, not stored target

The first draft of this contract proposed a stored `_target` pointer with `set_user_transport(role)` as the setter, plus `persist_target()` for write-through. That was revised on 2026-05-16 (see spec.md "Architectural Premise" + Clarification 2026-05-16): the target is a **pure projection of two UI properties** — `focus_manager.get_focused_panel()` and `timeline_state.get_displayed_tab_kind()` — computed on demand by `get_target()`. There is no `_target`, no setter, no persistence. The four-pointer coordination problem collapses to "ask the UI" instead of "keep yet another pointer in sync."

Tab clicks and source-viewer focus changes do NOT call into transport; transport reads from `timeline_state` / `focus_manager` at the moment of `get_target()`. This eliminates the coalescing problem (FR-009a) structurally — there is nothing to coalesce since the target is recomputed each query.

## Public API

### `transport.init(project_id) -> nil`
Construct both role-bound engines (`M.source_engine`, `M.record_engine`). Emit `transport_ready` so views (constructed pre-init by layout.lua) can bind their callbacks via the canonical role engine. Asserts:
- `project_id` is a non-empty string.
- Not already initialized (caller must `shutdown` first; double-init is a bug).
- Both engines construct successfully (each engine's TMB + PlaybackController init asserts internally on failure — propagates here).

No persisted-target read: the target is derived, not stored.

### `transport.shutdown() -> nil`
Release both engine references (GC reclaims them). Reset `_project_id` to nil. Asserts:
- `init` was called (i.e., transport is bootstrapped).

Project-change teardown of engine resources (PlaybackController STOP/CLOSE, audio session shutdown) is driven by the `project_changed` signal listener in this module (priority 5), NOT by `shutdown()`. The two paths are decoupled: `shutdown()` releases module references; `project_changed` tears down the C++ side. `project_changed` fires before `shutdown` in the project-change sequence.

### `transport.get_target() -> "source" | "record"`
Pure projection. Computed as: focused panel is `source_monitor` → `"source"`; OR displayed timeline tab kind is `"source"` → `"source"`; OR else `"record"`. Asserts that transport is initialized. Constant-time.

This is the single accessor FR-023 mandates. There is **no setter**.

### `transport.engine_for_role(role) -> PlaybackEngine`
Pure read. Returns `M.source_engine` or `M.record_engine`. Asserts that transport is initialized and `role ∈ {"source", "record"}`.

### `transport.engine_for_target() -> PlaybackEngine`
Sugar for `engine_for_role(get_target())`. Used by `core.commands.playback`'s transport-command dispatchers.

### `transport.is_bootstrapped() -> bool`
Public bootstrap-state predicate. External readers asking "is transport up?" use this instead of poking `M._project_id` directly. Constant-time, no asserts.

### `transport.bound_project_id() -> string | nil`
The project_id this transport is initialized for, or nil pre-init / post-shutdown. `command_manager` uses it to detect "different project than the one transport currently holds" without reading the private `_project_id` field.

### `transport.bind_role_to_sequence(role, seq_id) -> nil`
Rebind a role's engine to `seq_id`: stops any in-flight playback, calls `engine:load(seq_id)`. Idempotent: no-op when the engine is already loaded with that sequence. No-op pre-bootstrap (headless test environments).

### `transport.seek_target_if_loaded(seq_id, frame) -> nil`
Seek the displayed-side engine to `frame`, but only when it's the engine currently bound to `seq_id`. No-op pre-bootstrap or when the target engine carries a different sequence. Stops the engine if it was playing.

### `transport.play_frame_audio_target_if_loaded(seq_id, frame) -> nil`
Fire a jog-audio burst on the displayed-side engine when it's the one bound to `seq_id`. No-op pre-bootstrap or when the target engine has no `play_frame_audio` method.

## Signal subscriptions (transport owns the UI→engine coordination)

`transport.lua` is the resource orchestrator (017 module-responsibility rule). It subscribes to:

- **`displayed_tab_cleared(prev_seq_id)`** — emitted by `timeline_core_state.clear` when the user closes the last tab (or ShowSourceTab/Toggle hits the no-master branch). Walks `{"source", "record"}` and calls `engine:stop()` on whichever role-bound engine has `engine.sequence.id == prev_seq_id`. Prevents a deferred Park scheduled by the timeline panel's viewer-seek (with the stale playhead) from firing against a now-different sequence's bounds.

- **`project_changed`** (priority 5, before media_cache@20 so PlaybackController finishes with TMB references before media readers are released) — walks `{"source", "record"}` calling `PlaybackEngine.teardown_engine(engine)` per role, then `PlaybackEngine.shutdown_audio_session()`. Engine module exposes the building blocks; transport composes them.

No other module subscribes to UI signals on behalf of engines — that is exclusively transport's job (see spec §"Module Responsibilities & Dependency Direction").

## Forbidden behaviors

- `get_target` MUST be a pure projection of UI state. It MUST NOT cache a target between calls or be updated by a setter.
- `set_user_transport(role)` and `persist_target()` MUST NOT exist. They belong to the rejected pre-2026-05-16 design.
- No function in this module may silently fall back. Bad input asserts; missing engines assert.

## Contract tests

Pinned by `tests/test_contract_transport.lua`:
1. Required public surface present: `init`, `shutdown`, `get_target`, `engine_for_role`, `engine_for_target`.
2. Forbidden surface absent: `set_user_transport`, `persist_target`.
3. `get_target` pre-init asserts.
4. `init(nil)` and `init("")` assert.
5. `init` succeeds; default `get_target` returns `"record"` (no source-side UI state simulated).
6. `engine_for_role("source")` and `engine_for_role("record")` return distinct non-nil objects.
7. `engine_for_target()` returns the same object as `engine_for_role(get_target())`.
8. `is_bootstrapped()` / `bound_project_id()` semantics pinned by `tests/test_transport_bootstrap_accessor.lua`.
9. `displayed_tab_cleared` + `project_changed` listener semantics pinned by `tests/test_transport_subscribes_to_signals.lua`.
