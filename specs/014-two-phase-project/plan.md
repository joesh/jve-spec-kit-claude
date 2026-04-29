# Implementation Plan: Two-Phase Project Switch

**Branch**: `014-two-phase-project` | **Date**: 2026-04-29 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification at `/specs/014-two-phase-project/spec.md`

## Summary

Introduce a two-phase project-switch contract: a new `project_will_change` signal fires synchronously **before** `database.init(new_path)` swaps the connection; the existing `project_changed` signal continues to fire **after**. Pre-switch handlers flush pending writes to the outgoing DB and cancel deferred work that would otherwise fire post-switch with a stale `project_id`. Defensive `current_project_id` ↔ live-DB validation is added to `set_project_setting` and similar entry points and stays permanently as a fail-loud guard. The Lua-callback bridge is updated to log a stack trace when a callback raises (matching JVE_ASSERT semantics) instead of swallowing the bare error message. Background workers (e.g. media probe) get a hybrid cancel-and-drain contract with a 1-second budget. Every existing `project_changed` handler is audited and either migrated to `project_will_change` or made stale-safe; the audit catalog is committed.

The feature is purely additive at the signal level: no existing handler is removed, no contract is broken, but pending-write logic moves to the new pre-switch phase. The `assert_project_exists` failures in TSO disappear; pending probe results no longer end up cross-wired to the wrong project.

## Technical Context

**Language/Version**: Lua (LuaJIT 2.1) + C++17 (Qt 6.x)
**Primary Dependencies**: `core/signals.lua` (broadcast pub/sub), `core/database.lua` (SQLite connection + project-settings JSON I/O), Qt6 (single-shot timers via `qt_create_single_shot_timer`), background-worker thread for media probe
**Storage**: SQLite `.jvp` project files; project settings live in `projects.settings` JSON column
**Testing**: LuaJIT test harness (`tests/test_*.lua`, `tests/run_lua_tests_all.sh`) for unit/black-box; JVEEditor `--test` mode for integration tests that need full C++ bindings
**Target Platform**: macOS (development), cross-platform desktop GUI app
**Project Type**: single — hybrid Lua + C++ modular architecture (rule: views pull from model state)
**Performance Goals**:
- Pre-switch phase synchronous wall-clock budget: ≤ 1s for background-worker drain (FR-003a); other handlers should be sub-millisecond.
- No regression to existing project-open latency (currently ≤ 500ms for typical project).
**Constraints**:
- Signal dispatch is synchronous; handlers run in registration / priority order.
- The C++/Lua callback bridge log-and-continues on Lua errors today; switching to "log stack trace + continue" must not regress existing handlers that don't intentionally throw.
- The audit must touch every `Signals.connect("project_changed", ...)` call site (~15 in src/lua) without breaking unrelated behavior.
**Scale/Scope**:
- ~15 existing `project_changed` handlers to audit
- ~10 distinct `qt_create_single_shot_timer` call sites to audit
- 1 new signal name + dispatch path
- 1 background-worker cancel-and-drain contract
- Zero schema changes (project settings JSON column unchanged)

## Constitution Check

*Reference: `.specify/memory/constitution.md` v2.0.0*

| Principle | Status | Notes |
|---|---|---|
| I. Modular Architecture | PASS | Pre-switch handlers slot into existing modules; signal contract stays modular. MVC unaffected. |
| II. Command-Driven Interface | PASS | Project switch already happens via the `OpenProject` command. No new commands; the new signal phase lives inside the existing flow. |
| III. Test-First Development | PASS | Tests for signal ordering, persist-flush, deferred-timer cancellation, validation-no-op, and the full re-import scenario are written first per FR-010 / FR-011. |
| IV. Documentation-Driven Specifications | PASS | Spec + clarifications + plan + tasks before implementation. |
| V. Template-Based Consistency | PASS | Following `/specify` → `/clarify` → `/plan` → `/tasks` workflow. |
| VI. Fail-Fast Assert Policy | PASS — justified deviation | Spec FR-008 chose "log stack trace + continue" over hard-crash. The "loud and actionable" half of rule 1.14 is preserved (stack trace + ID context). The "hard fatal" half is relaxed to match existing JVE_ASSERT C++ semantics, which already log + continue rather than abort. Hard-crash on a Lua callback assertion would kill user sessions on any signal-handler bug. Recorded under "Complexity Tracking" below. |
| VII. No Fallbacks or Default Values | PASS | Validation no-ops on stale id and logs an assert-style trace; never invents a default project_id. The 1000ms drain budget (FR-003a) is a fixed constant, not a runtime fallback. |
| VIII. No Backward Compatibility | PASS | The new signal is additive. Existing `project_changed` handlers that flush get migrated in-place; no dual-emit, no legacy support layer. |

**Initial Constitution Check: PASS** with one tracked deviation under VI.

## Project Structure

### Documentation (this feature)

```
specs/014-two-phase-project/
├── plan.md                      # This file (/plan command output)
├── research.md                  # Phase 0 — handler audit catalog + open-question resolutions
├── data-model.md                # Phase 1 — signal contracts, project-switch state machine, validation rules
├── contracts/
│   ├── signal_will_change.md    # project_will_change signal contract (payload, ordering, error policy)
│   ├── persist_now_validation.md  # set_project_setting / persist_now stale-id validation contract
│   ├── worker_cancel_drain.md   # Background-worker cancel-and-drain contract (1s budget)
│   └── lua_callback_bridge.md   # Updated jve_handle_lua_callback_error contract (stack-trace logging)
├── quickstart.md                # Phase 1 — manual repro steps for the failing scenario
├── handler_audit.md             # Phase 1 — committed audit catalog (FR-007 deliverable)
└── tasks.md                     # Phase 2 — generated by /tasks (NOT created here)
```

### Source Code (existing JVE layout — files this feature touches)

```
src/
├── lua/
│   ├── core/
│   │   ├── signals.lua                      # Register `project_will_change`; dispatch path mirrors `project_changed`
│   │   ├── project_open.lua                 # Emit `project_will_change` immediately before database.init swap
│   │   ├── database.lua                     # Tighten assert_project_exists; ensure get_current_project_id is single SoT
│   │   ├── commands/open_project.lua        # Verify the convert + open flow funnels through project_open
│   │   └── media/
│   │       ├── media_status.lua             # Move persist_now from M.clear (project_changed) to project_will_change handler; cancel pending schedule_persist timer; add stale-id validation to persist_now
│   │       └── peak_cache.lua               # Audit single-shot timers (line 175, 180); add cancel-on-will-change if any capture project_id
│   └── ui/
│       ├── layout.lua                       # Audit project_changed handlers (3 found); migrate any that flush
│       ├── timeline/timeline_state.lua      # project_changed at priority 40 — audit
│       ├── timeline/timeline_panel.lua      # project_changed at priority 50 — audit
│       ├── timeline/view/timeline_view_renderer.lua  # audit
│       ├── inspector/change_listeners.lua   # priority 45 — audit
│       ├── project_browser.lua              # priority 50 — audit
│       ├── sequence_monitor.lua             # audit
│       ├── fullscreen_viewer.lua            # audit
│       ├── edit_history_window.lua          # audit
│       └── playback_engine.lua              # priority 10 — audit (already stops playback; should be safe)
├── jve_lua_callback.cpp                     # Update jve_handle_lua_callback_error to emit luaL_traceback before logging
└── jve_lua_callback.h                       # No surface change expected

tests/
├── test_project_will_change_ordering.lua          # FR-001/FR-002/FR-004 — signal order vs DB swap
├── test_project_switch_persist_flush.lua          # FR-010 — debounced persist lands in OUTGOING DB
├── test_project_switch_deferred_timer_safety.lua  # FR-010 — deferred timer no-ops or cancels, no assert
├── test_project_switch_no_prior_project.lua       # Edge case — cold start
├── test_project_switch_close_no_replacement.lua   # Edge case — close without opening another
├── test_project_id_validation_no_op.lua           # FR-005/FR-006 — stale id → log + no-op (not assert)
├── test_lua_callback_stack_trace.lua              # FR-008 — bridge logs full traceback
└── integration/
    └── test_anamnesis_reimport_no_asserts.lua     # FR-011 — re-import + interact, zero asserts in TSO
```

**Structure Decision**: single project, hybrid Lua + C++. The feature lives mostly in `src/lua/core/` (signal contract, validation, media_status migration) plus one C++ touch in `src/jve_lua_callback.cpp`. UI modules under `src/lua/ui/` are touched only for handler migration / audit; their UI behavior is unchanged.

## Phase 0: Outline & Research

**Output written**: `research.md` (Phase 0 complete in the planning sense — file exists, audit catalog seeded, mechanical questions answered. The TBD rows in `handler_audit.md` get resolved during Phase 4 inspection, not Phase 0).

The clarification phase resolved all `[NEEDS CLARIFICATION]` markers. Phase 0 work is the audit pass and a small number of mechanical questions about Qt single-shot timer cancellation:

1. **Audit pass — Pre-switch obligations.** For each of the ~15 `Signals.connect("project_changed", ...)` call sites, classify as **must-flush-pending-writes**, **must-cancel-deferred-work**, or **no-action**. Output: a per-handler row in `research.md` with classification, reasoning, and migration approach. This is the FR-007 audit catalog basis.

2. **Audit pass — Deferred work.** For each `qt_create_single_shot_timer` call site, determine whether the callback uses `current_project_id` (cached or live-DB-derived) or any other project-scoped state. If yes: classify as cancel-on-will-change or validate-at-fire-time. Output: a per-timer row.

3. **Qt single-shot timer cancellation primitive.** Investigate whether `qt_create_single_shot_timer` returns a handle that can be cancelled, or whether cancellation is via flag-and-no-op-in-callback. If no handle exists, the contract leans on flag-and-no-op (which we already need for FR-006 anyway).

4. **Background-worker (media probe) cancel surface.** `media_status.cancel_background_probe()` already exists; verify its semantics (does it set a flag, drain in-flight, or just stop queueing?) and document. Decide whether it satisfies FR-003a's hybrid contract or needs extension.

5. **Lua-traceback API in the bridge.** `lua_pcall` with a message handler can capture `debug.traceback`-style traces. Document the exact API choice for the C++ bridge update.

**Output**: `research.md` with audit catalog seeded from greppable evidence + answers to mechanical questions.

## Phase 1: Design & Contracts

*Prerequisites: research.md complete*

### Data model (`data-model.md`)

The feature is light on data, heavy on contracts. `data-model.md` captures:

- **Project Switch Event** — fields: outgoing_project_id, incoming_project_id, phase (pre|post), drain_budget_ms (default 1000). Emitted twice per switch (one pre, one post). No persisted state — purely an in-flight signal payload.
- **Module-Local Project Cache** — every module that holds `current_project_id` declares it. Schema: name, set-on-event, validate-before-use, cleared-on. Documented for the audit catalog.
- **Audit Catalog Schema** — table format used in `handler_audit.md`: handler module, signal, priority, classification, current behavior, migrated behavior, owner.
- **State transitions** — Project Open lifecycle: `none → open(P1) → switching(P1, P2) → open(P2) → switching(P2, none) → none`. Pre-switch fires on every transition out of `open`; post-switch fires on every transition into `open` (and into `none`).

### Contracts (`contracts/`)

Four contract docs, one per concern:

#### `contracts/signal_will_change.md`

- **Signal name**: `project_will_change`
- **Payload**: `outgoing_project_id` (string|nil — nil if no project was open)
- **Emit point**: `core/project_open.lua`, immediately before `database.init(new_path)`. Also `close_project` and any other path that detaches the DB.
- **Handler signature**: `function(outgoing_project_id) ... end`
- **Handler ordering**: by priority ascending, identical to `project_changed` semantics
- **Handler error policy** (FR-009): a thrown error logs a stack trace via the Lua-callback bridge (per FR-008) and dispatch continues with the next handler. Switch is never blocked.
- **Live DB invariant**: when the handler runs, `database.get_current_project_id() == outgoing_project_id` (cold-start case excepted, where outgoing is nil)

#### `contracts/persist_now_validation.md`

- Every public function that writes to `projects.settings` (or any other per-project DB row) and takes a `project_id` argument MUST internally call `assert_project_exists(project_id)`.
- `assert_project_exists` is the single validation point. No other module duplicates the check.
- Call sites: `database.set_project_setting`, `database.set_project_settings`, `database.update_project_*`, and any other write taking `project_id`.
- For modules that hold `current_project_id` (per FR-006): a wrapper helper, `database.assert_project_id_is_live(cached_id, caller_label)`, logs a JVE_ASSERT-style trace and returns false on mismatch (caller no-ops). Permanent invariant.

#### `contracts/worker_cancel_drain.md`

- **Cancellation API**: `worker:cancel()` sets a flag the worker observes between work units; existing `media_status.cancel_background_probe()` is the model.
- **Drain API**: `worker:wait_for_drain(timeout_ms)` blocks the caller up to `timeout_ms` while in-flight write callbacks complete; returns `true` if drained, `false` if timed out.
- **Pre-switch protocol**:
  1. Cancel the worker (sets flag).
  2. Wait for drain with budget = 1000 ms.
  3. If drain returns false: log a single warning naming the worker and the dropped count.
  4. Return — switch proceeds.
- Background workers SHOULD cooperate by checking the cancel flag at every write boundary (so unbounded loops don't blow the drain budget).

#### `contracts/lua_callback_bridge.md`

- `jve_handle_lua_callback_error` (`src/jve_lua_callback.cpp`) is updated to capture a Lua stack trace via `luaL_traceback` before logging.
- Log format: `Lua callback error in <where>: <error_msg>\n<traceback>`.
- Behavior: log + continue (unchanged).
- Applies to all C++ → Lua callback paths (Qt slots, single-shot timers, signal handlers via `Signals.emit`).
- The conversion-dialog `convert_fn` direct-call site (separately addressed earlier this session) gets its own pcall wrapper; this contract covers the bridge but not direct call sites.

### Quickstart (`quickstart.md`)

Manual repro for FR-011:
1. Delete `~/Documents/JVE Projects/anamnesis-gold-timeline.jvp`.
2. Launch JVEEditor.
3. File > Open > select `tests/fixtures/resolve/anamnesis-gold-timeline.drp`.
4. Conversion dialog completes; project opens.
5. Arrow through the timeline at the GOLD master clip (REC 01:36:49:17, 01:51:37:09, 01:01:30:15, etc.).
6. Press Play; let it run a few seconds.
7. Inspect TSO: zero `assert_project_exists ... Stale project_id after project switch?` lines.
8. Open Recent > another project, then back.
9. Inspect TSO again: zero new asserts after the switch.

### Handler audit catalog (`handler_audit.md`)

The committed FR-007 deliverable. Table format, one row per existing `Signals.connect("project_changed", ...)` site:

| Handler | File:Line | Priority | Classification | Action |
|---|---|---|---|---|
| (filled by Phase 0 audit) | ... | ... | ... | ... |

Plus a parallel table for `qt_create_single_shot_timer` sites that touch project state.

### Agent context update

Run `.specify/scripts/bash/update-agent-context.sh claude` after Phase 1 artifacts exist, to refresh `CLAUDE.md` with the new signal contract.

**Output**: `data-model.md`, `contracts/*.md` (4 files), `quickstart.md`, `handler_audit.md`, refreshed `CLAUDE.md`.

## Phase 2: Task Planning Approach

*This section describes what the /tasks command will do — DO NOT execute during /plan*

**Task Generation Strategy**:

1. Each contract → one or more contract-test tasks (signal ordering, validation no-op, drain budget, traceback presence) [P]
2. Each entry in the handler audit catalog → one migration task (per handler) [P where independent]
3. Each integration test scenario from quickstart → one integration test task
4. Implementation tasks to make each test pass (write tests first — TDD per Constitution III)

**Ordering Strategy**:

1. Bridge update first (`jve_handle_lua_callback_error` traceback) — independent, unblocks better diagnostics for everything downstream
2. New signal registration in `core/signals.lua` — foundational, blocks all handler migrations
3. Emit point in `core/project_open.lua` — depends on signal registration
4. `assert_project_exists` tightening + `assert_project_id_is_live` helper — depends on database.lua only; parallel with signal work
5. `media_status` migration (the canary case) — first real handler migration
6. Other handler migrations, [P] where independent
7. Worker cancel-and-drain contract — depends on `media_status.cancel_background_probe` review
8. Integration test (FR-011) — depends on all above
9. Audit catalog committed (`handler_audit.md` finalized)

**Estimated Output**: 30-40 numbered tasks in tasks.md (heavy because of per-handler audit migrations).

## Phase 3+: Future Implementation

**Phase 3**: Task execution (`/tasks` command creates tasks.md)
**Phase 4**: Implementation (execute tasks.md following constitutional principles, TDD)
**Phase 5**: Validation (run `tests/run_lua_tests_all.sh`, execute quickstart.md, verify zero asserts in TSO)

## Complexity Tracking

| Deviation | Why Needed | Stricter Alternative Rejected Because |
|---|---|---|
| Constitution VI: Lua-callback assertion failures log a stack trace and continue (instead of hard-crashing the process). | Matches existing JVE_ASSERT C++ semantics: loud and actionable, but non-fatal so the user keeps their session. Stack-trace logging preserves the "loud" half of fail-fast. | Hard-crash on every Lua callback assertion would abort the editor on any signal-handler bug — regressing UX for what is, in this domain, an actively-developed scripting layer where assertion-firing is itself the bug-finding mechanism. Confirmed by Joe in clarification session 2026-04-29 (see spec Clarifications). |

## Progress Tracking

**Phase Status**:
- [x] Phase 0: Research complete (/plan command — see `research.md`)
- [x] Phase 1: Design complete (/plan command — see `data-model.md`, `contracts/`, `quickstart.md`, `handler_audit.md`)
- [x] Phase 2: Task planning complete (/plan command — described above; tasks.md NOT created here)
- [x] Phase 3: Tasks generated (/tasks command — see `tasks.md`, 47 tasks)
- [ ] Phase 4: Implementation complete
- [ ] Phase 5: Validation passed

**Gate Status**:
- [x] Initial Constitution Check: PASS (one justified deviation under VI, documented above)
- [x] Post-Design Constitution Check: PASS (no new violations after design — the deviation under VI is unchanged)
- [x] All NEEDS CLARIFICATION resolved (resolved during /clarify session 2026-04-29)
- [x] Complexity deviations documented (none beyond the VI deviation)

---
*Based on Constitution v2.0.0 — see `.specify/memory/constitution.md`*
