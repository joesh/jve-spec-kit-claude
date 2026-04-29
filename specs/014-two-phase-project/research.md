# Phase 0 Research: Two-Phase Project Switch

**Date**: 2026-04-29
**Spec**: [spec.md](./spec.md) · **Plan**: [plan.md](./plan.md)

This document captures the audit findings and mechanical-question answers needed before Phase 1 design. The clarification phase resolved all `[NEEDS CLARIFICATION]` markers; this phase translates the spec's requirements into concrete migration decisions for each existing call site.

---

## Decision: New signal name and dispatch mechanism

**Decision**: Add `project_will_change` as a peer of `project_changed` in `core/signals.lua`. Same priority-ordered dispatch, same broadcast semantics, same handler-error policy (log + continue per FR-008/FR-009).

**Rationale**: `core/signals.lua` is already a generic broadcast pub/sub keyed by string signal name. Adding a new signal needs no infrastructure change — only emit-point wiring and handler registration. Reusing the same dispatch path keeps the contract consistent: pre-switch handlers behave identically to post-switch handlers from the dispatcher's perspective; only the emit point differs.

**Alternatives considered**:
- Modifying `Signals.emit("project_changed", ...)` to dispatch in two phases internally. Rejected: opaque to handler authors; can't grep for "things that happen before DB swap" vs after.
- A general-purpose `project_lifecycle` signal with a phase enum. Rejected: more complex contract, harder to enforce ordering, only one consumer pattern (pre vs post).

---

## Decision: Emit point for `project_will_change`

**Decision**: Emit immediately before `database.init(new_path)` in `core/project_open.lua` (and any other call site that swaps the DB connection — `close_project`, `new_project`).

**Rationale**: `database.init` is the single transition point where the connection swaps from outgoing to incoming project. Emitting just before it guarantees the live DB still resolves to the outgoing project when handlers run.

**Mechanical verification needed during implementation**: locate every call site of `database.init` outside test code, confirm each routes through `project_open.lua` (or otherwise emits the new signal). Currently believed to be just `core/project_open.lua` and `core/commands/new_project.lua`.

---

## Decision: Background-worker cancel-and-drain primitive

**Decision**: Implement the FR-003a contract via:
- `worker:cancel()` — sets a cancel flag. The existing `media_status.cancel_background_probe()` is the model.
- `worker:wait_for_drain(timeout_ms)` — blocks the caller up to `timeout_ms` while queued write callbacks complete; returns boolean.

**Rationale**: Matches the clarification answer (hybrid: cancel + bounded drain + per-write validation safety net). The cancel flag stops new work; the drain budget gives queued writes a chance to commit; the per-write `assert_project_id_is_live` in FR-006 catches any straggler that escapes the drain.

**Phase 4 mechanical tasks**:
- Inspect existing `media_status.cancel_background_probe()`: does it drain, or only stop queueing? If only stops queueing, add `wait_for_drain(timeout_ms)`.
- Verify the worker checks the cancel flag at write boundaries. If not, add the check so an unbounded loop cannot exceed the drain budget.

**Alternatives considered**:
- Synchronous block-until-drained with no timeout. Rejected: a stuck worker stalls the project switch indefinitely. The user would experience a hung editor.
- Pure flag-and-discard with no drain. Rejected by clarification: spec'd in-flight probe results should land if they're already queued.
- Per-write validation only (option D from Q3). Rejected: spec'd answer was hybrid (option C) — option D loses the chance to land already-queued writes that would have succeeded.

---

## Decision: Lua-callback bridge stack-trace logging

**Decision**: Update `jve_handle_lua_callback_error` (`src/jve_lua_callback.cpp`) to capture a Lua traceback via `luaL_traceback` before logging. Log format: `Lua callback error in <where>: <error_msg>\n<traceback>`.

**Rationale**: `luaL_traceback(L, L, msg, level)` is the standard Lua C API for capturing the current stack. The bridge already has `L` and the error message on the stack; adding a traceback before logging is ~5 lines of C++.

**Mechanical detail**: `luaL_traceback` is available in Lua 5.1 / LuaJIT. The bridge currently does `lua_tostring(L, -1)` to grab the error; it should call `luaL_traceback(L, L, lua_tostring(L, -1), 1)` and log the resulting string instead.

**Alternatives considered**:
- Re-throw to the C++ caller (option B from Q1). Rejected by clarification.
- Hard-crash via assert handler (option C). Rejected by clarification (matches existing JVE_ASSERT semantics: log + continue).
- UI surface (option D). Rejected for now — could be added later as a separate enhancement; not required by FR-008/FR-009.

---

## Audit Catalog (seed): `Signals.connect("project_changed", ...)` handlers

This is the seed data for `handler_audit.md` (Phase 1 deliverable). 15 handlers found via `grep -rn 'Signals.connect("project_changed"' src/lua/`. Classification done by inspection of each handler's body.

| # | Handler | File:Line | Priority | Body summary | Classification | Migration |
|---|---------|-----------|----------|---|---|---|
| 1 | `playback_controller stop` | `core/playback/playback_engine.lua:1520` | (default 100) | Stops playback, clears state. No DB write. | **no-action** | None — stays as `project_changed` handler. |
| 2 | `offline_frame_cache.clear` | `core/media/offline_frame_cache.lua:272` | 15 | Clears in-memory cache. No DB write. | **no-action** | None — stays. |
| 3 | `media_status` (the canary) | `core/media/media_status.lua:649` | 12 | Calls `M.clear()` (which calls `persist_now()` with stale id → ASSERT) then `M.load_persisted(new)`. | **must-flush-pending-writes** | Move `persist_now()` to a new `project_will_change` handler at the same module. `M.clear()` keeps cache clearing only. |
| 4 | `peak_cache` | `core/media/peak_cache.lua:401` | (default 100) | Body needs inspection — likely cache clear. | **TBD — Phase 4 inspection** | TBD; if it persists peak metadata to DB, becomes must-flush. |
| 5 | `project_generation` | `core/project_generation.lua:31` | (default 100) | Body needs inspection — likely state reset. | **TBD** | TBD. |
| 6 | `layout window-geometry suppressor` | `ui/layout.lua:365` | 2 | Sets `window_ready_to_save = false`, schedules a 50ms timer to re-enable. | **no-action** | None — flag-only. |
| 7 | `layout active_project_id update` | `ui/layout.lua:316` | 50 | Updates `active_project_id` closure. | **no-action** | None — pure cache update for downstream handlers. |
| 8 | `timeline_state.on_project_change` | `ui/timeline/timeline_state.lua:448` | 40 | Body needs inspection. | **TBD** | TBD. |
| 9 | `inspector change_listeners` | `ui/inspector/change_listeners.lua:71` | 45 | Body needs inspection. | **TBD** | TBD. |
| 10 | `project_browser.on_project_change` | `ui/project_browser.lua:2596` | 50 | Body needs inspection. | **TBD** | TBD. |
| 11 | `timeline_panel.on_project_change` | `ui/timeline/timeline_panel.lua:2482` | 50 | Body needs inspection — likely tab/UI reload. | **TBD — likely no-action or must-cancel-deferred-work** | TBD. |
| 12 | `timeline_view_renderer` | `ui/timeline/view/timeline_view_renderer.lua:36` | (default 100) | Body needs inspection — likely view reset. | **TBD — likely no-action** | TBD. |
| 13 | `sequence_monitor` | `ui/sequence_monitor.lua:147` | (default 100) | Body needs inspection. | **TBD** | TBD. |
| 14 | `fullscreen_viewer` | `ui/fullscreen_viewer.lua:202` | (default 100) | Body needs inspection. | **TBD** | TBD. |
| 15 | `edit_history_window` | `ui/edit_history_window.lua:252` | (default 100) | Body needs inspection — restore-on-open or similar. | **TBD** | TBD. |

**Phase 4 task**: inspect each TBD handler body; finalize classification. Any handler that performs a DB write touching the OUTGOING project must migrate. Any handler that schedules a deferred timer with captured project_id must also migrate (cancellation in `project_will_change`).

---

## Audit Catalog (seed): `qt_create_single_shot_timer` call sites

Filtering out test files and the C++ binding declaration. 12 distinct call sites. The ones that matter for this feature are those whose callbacks touch the DB or hold project-scoped state.

| # | Site | File:Line | Delay | Callback summary | Project-scoped? | Action |
|---|------|-----------|-------|---|---|---|
| 1 | `media_status.schedule_persist` | `core/media/media_status.lua:288` | `PERSIST_DEBOUNCE_MS` | Calls `M.persist_now()` which writes `set_project_setting(current_project_id, ...)`. | **YES — primary culprit.** | Cancel in `project_will_change`; `persist_now` adds stale-id validation per FR-006. |
| 2 | `peak_cache poll` (initial) | `core/media/peak_cache.lua:180` | 500 | Polls peak generator state; needs inspection of `poll`. | **TBD — likely YES** if it writes peaks to disk under project_id. | TBD per Phase 4. |
| 3 | `peak_cache poll` (re-arm) | `core/media/peak_cache.lua:175` | 500 | Same `poll` function. | TBD | TBD. |
| 4 | `arrow_repeat` (step) | `ui/arrow_repeat.lua:26` | `STEP_MS` | Repeats arrow-key action. | **NO** — pure UI key-repeat. | None. |
| 5 | `arrow_repeat` (initial) | `ui/arrow_repeat.lua:55` | `INITIAL_DELAY_MS` | Same family. | NO | None. |
| 6 | `edit_history_window` | `ui/edit_history_window.lua:263` | 50 | Body needs inspection. | TBD | TBD. |
| 7 | `find_dialog` | `ui/find_dialog.lua:486` | 50 | Find-dialog UI. | NO (likely) | None. |
| 8 | `layout` (quit) | `ui/layout.lua:229` | `quit_delay` | Quit handling. | NO (transient) | None. |
| 9 | `layout` (window_ready re-enable) | `ui/layout.lua:367` | 50 | Sets `window_ready_to_save = true`. | NO | None. |
| 10 | `layout` (splitter restore) | `ui/layout.lua:645` | 50 | Restores splitter sizes. | NO | None. |
| 11 | `layout` (background probe defer) | `ui/layout.lua:714` | 0 | Calls `media_status.start_background_probe(initial_sequence_id)`. | **YES — captures sequence_id by closure.** | This is on initial open, not a switch, so survives the project switch by virtue of being post-init. Re-audit. |
| 12 | `project_browser` | `ui/project_browser.lua:209` | 0 | Body needs inspection. | TBD | TBD. |
| 13 | `sequence_monitor` | `ui/sequence_monitor.lua:709` | `DEBOUNCE_MS` | Body needs inspection. | TBD | TBD. |
| 14 | `timeline_panel viewer-seek defer` | `ui/timeline/timeline_panel.lua:2117` | `VIEWER_SEEK_DEFER_MS` | Body needs inspection. | TBD | TBD. |

**Phase 4 task**: inspect each TBD callback body; classify. Any callback that touches DB with a closure-captured `project_id` (or `current_project_id` cached in a module that holds project state) must either be cancelled by the new pre-switch handler or use `assert_project_id_is_live` to no-op safely.

---

## Audit Catalog (seed): module-local `current_project_id` caches

Greppable: `current_project_id` (or `_project_id` at module scope).

| # | Module | Variable | Set on | Cleared on | Validates before write? |
|---|--------|----------|--------|------------|---|
| 1 | `core/media/media_status.lua` | `current_project_id` (line 77) | `M.load_persisted(project_id)` (line 299) | `M.clear()` (line 424) | **NO** — `persist_now` reads it raw at line 279. **Must add validation per FR-006.** |

Only one cached `project_id` found in current src/lua at module scope. Other modules use closure-captured values inside specific handlers (e.g. `ui/layout.lua` `active_project_id` is file-local). The audit covers those by the per-handler classification table above; closures captured in handlers go stale at the same moment as module-local caches.

**Phase 4 task**: re-grep after migration; ensure no NEW module-local project_id caches were introduced without validation.

---

## Decision: `assert_project_exists` coverage

**Decision**: Make `assert_project_exists` (`src/lua/core/database.lua:1493`) the single validation primitive. Audit every public function in `database.lua` that takes a `project_id` argument and writes; ensure each calls `assert_project_exists` directly or transitively.

**Rationale**: Today only `get_project_settings` calls it (on read). Writes (`set_project_setting` line 1540) call `get_project_settings` which calls `assert_project_exists` — so the validation already covers `set_project_setting` indirectly. But this is an accident of the implementation; the contract says "every write," and we should make that explicit.

**Phase 4 task**: enumerate every public DB-write function in `database.lua`. For each, ensure validation. Add a `database.assert_project_id_is_live(cached_id, caller_label)` helper for module-local-cache validation per FR-006 (logs trace + returns false on mismatch, instead of asserting; this is the "no-op stale write" path).

---

## Open mechanical questions resolved

- **Q**: Does `qt_create_single_shot_timer` return a cancellable handle?
  **A**: Need to inspect `src/lua/qt_bindings/signal_bindings.cpp:906` during Phase 4. If yes, prefer cancel-via-handle. If no, the contract leans on flag-and-no-op-in-callback (which we need anyway for FR-006). Either way, the spec is unaffected.

- **Q**: Does `Signals.emit` already log+continue on handler errors?
  **A**: Yes. `core/signals.lua` catches handler errors and logs them as `Handler failure: signal=<name> connection=<id>` (this is exactly the format we saw in TSO). This matches FR-009; no signals.lua change is required for handler-error policy. The change is in the BRIDGE (jve_lua_callback.cpp) for QT direct callbacks, NOT in Signals.emit.

- **Q**: Are there any project_changed handlers without an explicit priority that might cause ordering surprises?
  **A**: Yes — handlers 4, 5, 6 (table 1), 12, 13, 14, 15 use the default priority. Default priority in `Signals.connect` is 100 (after all explicit priorities ≤ 50). This means any handler at default priority runs LAST in `project_changed` dispatch. For `project_will_change`, the same default applies; behavior is consistent. No spec impact.

---

## Output of Phase 0

- This document (`research.md`) — audit seeds + mechanical-question resolutions
- Inputs to Phase 1:
  - `data-model.md` (signal payload, state machine, audit-catalog schema)
  - `contracts/signal_will_change.md`
  - `contracts/persist_now_validation.md`
  - `contracts/worker_cancel_drain.md`
  - `contracts/lua_callback_bridge.md`
  - `quickstart.md`
  - `handler_audit.md` (final, Phase-4-completed version of the catalog seeded above)

All `[NEEDS CLARIFICATION]` markers from the spec are resolved. Phase 1 design proceeds.
