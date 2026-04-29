# Tasks: Two-Phase Project Switch

**Feature**: 014-two-phase-project · **Branch**: `014-two-phase-project`
**Input**: Design documents in `/Users/joe/Local/jve-spec-kit-claude/specs/014-two-phase-project/`
**Prerequisites**: `plan.md`, `research.md`, `data-model.md`, `contracts/*`, `quickstart.md`, `handler_audit.md`

## Format

`[ID] [P?] Description`
- **[P]**: independent file, can run in parallel with other [P] tasks in the same phase
- Same file = sequential (no [P])
- Every task lists exact absolute file paths

## Path conventions

Repo root: `/Users/joe/Local/jve-spec-kit-claude`. All paths below are absolute.

---

## Phase 3.1: Setup

- [X] **T001** Working-tree audit. Resolved 2026-04-29: per Joe's call, prior-session fixes committed as 4 separate commits (`emp:` prefetch softening, `drp_importer:` MTBA frame-snap, `conversion_dialog:` pcall + cleanup, `timeline_panel:` blank-state guard) followed by the spec-dir commit (`spec: 014 …`). Tree clean before T002.

- [X] **T002** Verify existing infrastructure prerequisites. Verified 2026-04-29:
  - Signals: `Signals.connect` at `core/signals.lua:23`, `Signals.emit` at line 183, `Signals.disconnect` at line 128.
  - Database: `assert_project_exists` at `core/database.lua:1493`; `get_current_project_id` at line 803; `get_project_settings` at line 1506; `set_project_setting` at line 1540 (singular only — no `set_project_settings` plural form).
  - Other project-id-taking exports surfaced for the T020 audit: `load_master_clips`, `load_sequences`, `load_bins`, `get_project_setting`.
  - Bridge: `jve_handle_lua_callback_error` declared at `src/jve_lua_callback.h:24`, defined at `src/jve_lua_callback.cpp:10`. Existing `JVE_ASSERT(L != nullptr, ...)` and `JVE_ASSERT(where != nullptr, ...)` guards stay; only the body changes (T015).

- [X] **T003** Confirm baseline before any feature work. Captured 2026-04-29:
  - **Luacheck**: 0 warnings (one pre-existing warning in `tests/test_playhead_absolute_no_double_offset.lua:66` — unused `FT` alias — fixed in commit `ac6758c9` per rule 2.4).
  - **Lua suite (`tests/run_lua_tests_all.sh`)**: 659 PASSED / 0 FAILED.
  - **Binding tests (`make -j4`)**: 23 pre-existing failures (V13 schema migration debt — `projects.fps_mismatch_policy NOT NULL`, removed `clips.clip_kind` column, schema version V8 vs V13). Captured to `/tmp/baseline_failures.txt`. NOT caused by feature 014; out of scope per rule 2.15. T042 measures DELTA from this baseline (no NEW failures may be introduced).
  - Build artifacts at `/tmp/baseline_build.txt`.

---

## Phase 3.2: Tests First (TDD) — MUST FAIL before Phase 3.3

**CRITICAL**: every test in this phase MUST be written and MUST FAIL before any production code is touched. Verify each new test fails by running it standalone (`cd tests && luajit test_harness.lua <name>`), capture the failure to `/tmp/<name>.fail.txt`, only then proceed to Phase 3.3.

### Contract tests (one per `contracts/*.md`)

- [X] **T004** [P] Contract test for `project_will_change` signal ordering and payload. Test at `tests/test_project_will_change_ordering.lua`. Verifies the pre/post live-DB invariant via two real SQLite DBs in `/tmp/jve/test_014_t004/`. Has two halves:
  - Manual-emit half: confirms the signal infrastructure works (passes today).
  - Production-emit half: asserts `database.set_path` itself emits `project_will_change` before closing the outgoing connection. Fails today — this is the red-state for T014.

  Failure captured at `/tmp/T004.fail.txt`: `test_project_will_change_ordering.lua:144: PRODUCTION CONTRACT: database.set_path must emit project_will_change before closing the outgoing connection.`

- [ ] **T005** [P] Contract test for Layer 1 `assert_project_exists` coverage at `/Users/joe/Local/jve-spec-kit-claude/tests/test_assert_project_exists_coverage.lua`. Per `contracts/persist_now_validation.md`:
  - For each public DB-write export of `database.lua` that takes a `project_id` arg (`set_project_setting`, `set_project_settings`, plus any others surfaced during Phase 4), call it with a known-bogus project_id while a different real project is the sole row.
  - Each call MUST hard-assert with the `assert_project_exists: project_id 'X' != sole project 'Y'` message format.
  - Wrap in `pcall` and assert the returned error string contains `assert_project_exists`.

- [ ] **T006** [P] Contract test for Layer 2 `assert_project_id_is_live` no-op-on-stale at `/Users/joe/Local/jve-spec-kit-claude/tests/test_assert_project_id_is_live.lua`. Per `contracts/persist_now_validation.md`:
  - Stale path: a fake module caches a project_id from a previous DB; switch to a new DB; call `assert_project_id_is_live(stale_id, "test_caller")`; assert returns `false`, an `[error]`-level log line includes `stale project_id`, includes the caller_label, and includes a stack traceback. No hard assert fires.
  - Live path: same fake module, current cache matches live DB; call returns `true`; no log line emitted.
  - Empty-cache path: call with `nil` cached_id returns `false` quietly (no log line).

- [ ] **T007** [P] Contract test for worker cancel-and-drain at `/Users/joe/Local/jve-spec-kit-claude/tests/test_worker_cancel_drain.lua`. Per `contracts/worker_cancel_drain.md`:
  - Drain-success: synthetic worker queues 5 writes that complete within 100 ms total. Pre-switch invokes `cancel()` then `wait_for_drain(1000)`. Assert `drained == true`, all 5 writes landed in outgoing DB, no warning logged.
  - Drain-timeout: synthetic worker has a write callback that artificially blocks for 2000 ms. Pre-switch invokes `cancel()` then `wait_for_drain(1000)`. Assert `drained == false`, a warning was logged naming the worker and its `pending_count`, switch proceeds (no hang past ~1100 ms wall clock).
  - Stale-write safety net: drain times out, the over-budget write fires AFTER the project switch, write callback consults `assert_project_id_is_live`. Assert: write no-op, Layer 2 warning logged, no `assert_project_exists` hard fail.

- [ ] **T008** [P] Contract test for the Lua-callback bridge stack-trace logging at `/Users/joe/Local/jve-spec-kit-claude/tests/test_lua_callback_stack_trace.lua`. Per `contracts/lua_callback_bridge.md`. This test MUST run via `JVEEditor --test` mode because it exercises the C++ bridge:
  - Wire a synthetic Qt button-box `accepted` handler that calls a Lua function `error("synthetic test error")`.
  - Trigger the signal.
  - Capture stdout/stderr.
  - Assert the captured log contains `Lua callback error in button_box.accepted: synthetic test error` AND a `stack traceback:` block AND at least one frame line below it.
  - Assert the editor is still alive (a follow-up `qt_*` call succeeds).
  - Repeat with a non-string error: `error({reason="t"})`. Assert the log line still contains a usable error description (luaL_traceback output) plus the traceback.

### Integration / scenario tests (from quickstart.md)

- [ ] **T009** [P] Integration test for the failing scenario at `/Users/joe/Local/jve-spec-kit-claude/tests/integration/test_anamnesis_reimport_no_asserts.lua`. Per `quickstart.md` and FR-011. Runs via `JVEEditor --test`:
  - Delete any pre-existing `anamnesis-gold-timeline.jvp` files in the test sandbox.
  - Drive the conversion of `tests/fixtures/resolve/anamnesis-gold-timeline.drp` programmatically via the importer API.
  - Open the resulting `.jvp` programmatically.
  - Trigger a representative interaction sequence (synthetic playhead arrows, a few selection changes, a brief play tick).
  - Switch to a different project and back via `OpenProject` calls.
  - Capture all log output.
  - Assert: zero lines containing `assert_project_exists.*Stale project_id after project switch`. Other unrelated warnings (PeakGenerator, FieldsBlob) are out of scope and not asserted on.

- [ ] **T010** [P] Edge-case test: cold start at `/Users/joe/Local/jve-spec-kit-claude/tests/test_project_switch_cold_start.lua`. Per spec Edge Cases:
  - With no project DB attached, trigger an open(P1).
  - Assert: `project_will_change` fired with `outgoing_project_id == nil`; no handler errored; post-switch `project_changed` fired with `incoming = P1`.

- [ ] **T011** [P] Edge-case test: close without replacement at `/Users/joe/Local/jve-spec-kit-claude/tests/test_project_switch_close_no_replacement.lua`. Per spec Edge Cases:
  - Open P1; trigger close.
  - Assert: `project_will_change` fired with `outgoing = P1`; pending writes (one synthetic `media_status` entry) flushed to P1's DB; `project_changed` fired with `incoming = nil`; no handler errored.

- [ ] **T012** [P] Edge-case test: handler-error isolation at `/Users/joe/Local/jve-spec-kit-claude/tests/test_project_will_change_handler_error_isolation.lua`. Per FR-008/FR-009:
  - Register two pre-handlers at adjacent priorities. The first deliberately calls `error("synthetic")`.
  - Trigger a switch.
  - Assert: second handler still ran; switch completed; the first handler's error logged with stack trace at error level. Switch never blocked.

- [ ] **T013** [P] Edge-case test: rapid sequential switches at `/Users/joe/Local/jve-spec-kit-claude/tests/test_project_switch_rapid.lua`. Per spec Edge Cases:
  - Schedule three switches P1 → P2 → P3 within a single Qt event-loop turn.
  - Inject a pending `media_status` write during P1.
  - Assert: P1's DB received the flush BEFORE the P1→P2 switch; P2's DB and P3's DB never received the P1 write.

### Test-failure verification gate

- [ ] **T014** Run each of T004–T013 in isolation, capture failure output to `/tmp/test_<name>.fail.txt`, and confirm every test fails for the expected reason (signal not registered, helper not implemented, bridge not updated). Do not proceed to Phase 3.3 until all 10 tests are red.

---

## Phase 3.3: Core Implementation (only after Phase 3.2 tests are red)

### Bridge update (independent of signal work; parallelizable up front)

- [ ] **T015** Update `jve_handle_lua_callback_error` in `/Users/joe/Local/jve-spec-kit-claude/src/jve_lua_callback.cpp` per `contracts/lua_callback_bridge.md`:
  - Replace the bare-error log path with the three-line sequence: `luaL_tolstring(L, -1, NULL)` → `luaL_traceback(L, L, err_str, 1)` → `JVE_LOG_ERROR` reading `lua_tostring(L, -1)` (the traceback) → `lua_pop(L, 3)`. See the contract for the exact stack progression.
  - Use `luaL_tolstring` (not bare `lua_tostring`) so non-string errors (tables, userdata) get a proper string representation via `__tostring` instead of NULL.
  - Remove the now-redundant `<non-string error of type %s>` fallback branch.
  - Keep `jve_discard_non_function_handler` unchanged — separate concern.
  - Build with `make -j4`. T008 must turn green after this change. T012 stays red until T016 + T018 land (it depends on the new signal flow).

### Signal registration & emit (foundational)

- [ ] **T016** Register `project_will_change` in `/Users/joe/Local/jve-spec-kit-claude/src/lua/core/signals.lua`:
  - Add a docblock above the existing `project_changed` documentation describing the new signal name, payload, ordering invariants, and pre-switch contract (cross-reference `contracts/signal_will_change.md`).
  - No dispatcher code change required — `Signals.connect`/`Signals.emit` are already generic over signal names. Adding the doc is the registration.

- [ ] **T017** Locate every call to `database.init(new_path)` outside test code:
  - Run `grep -rn 'database\.init(' /Users/joe/Local/jve-spec-kit-claude/src/lua/core/ /Users/joe/Local/jve-spec-kit-claude/src/lua/ui/ 2>/dev/null` to enumerate.
  - Expected sites (verify): `core/project_open.lua`, `core/commands/new_project.lua`. Document any others found.

- [ ] **T018** Emit `project_will_change` in `/Users/joe/Local/jve-spec-kit-claude/src/lua/core/project_open.lua` immediately before `database.init(new_path)`:
  - Read the outgoing project_id via `database.get_current_project_id()` (or nil if no project is attached).
  - `Signals.emit("project_will_change", outgoing_project_id_or_nil)`.
  - Same change pattern in any additional emit sites surfaced by T017 (e.g. `new_project.lua` if it detaches a prior DB).
  - Do NOT emit on cold start with no prior DB? — DO emit, with `outgoing = nil`, per FR-001 and the cold-start edge case. T010 verifies.

### Database validation surface

- [ ] **T019** [P] Add `assert_project_id_is_live(cached_id, caller_label)` helper in `/Users/joe/Local/jve-spec-kit-claude/src/lua/core/database.lua` per `contracts/persist_now_validation.md`. Algorithm-style structure with extracted helpers (`stale_check_possible`, `log_stale_project_violation`). Logs at `log.error` level with full `debug.traceback`. Returns boolean.

- [ ] **T020** [P] Audit Layer 1 `assert_project_exists` coverage in `/Users/joe/Local/jve-spec-kit-claude/src/lua/core/database.lua`:
  - For every public function (`function M.<name>`) that takes a `project_id` argument and writes, confirm the call chain reaches `assert_project_exists`.
  - For any uncovered write, add a direct `assert_project_exists(project_id)` at the top of the function.
  - Update the function-level docblock for each touched function. T005 verifies coverage.

### `media_status` migration (the canary)

- [ ] **T021** Move `M.persist_now()` invocation out of `M.clear()` in `/Users/joe/Local/jve-spec-kit-claude/src/lua/core/media/media_status.lua`:
  - `M.clear()` keeps cancel-background-probe, in-memory cache reset, and `current_project_id = nil`. Drop the `M.persist_now()` call from `M.clear()`.
  - Verify `M.clear()` no longer touches the DB.

- [ ] **T022** Register a `project_will_change` handler in `/Users/joe/Local/jve-spec-kit-claude/src/lua/core/media/media_status.lua` at priority 12 (mirroring the existing `project_changed` priority):
  - Cancel pending `schedule_persist` timer (track its id; call cancel-by-flag).
  - Call worker cancel + wait_for_drain(1000ms) on the background probe (depends on T024 below).
  - Call `M.persist_now()` to flush pending status changes to the OUTGOING DB.

- [ ] **T023** Add Layer 2 validation in `M.persist_now()` (same file). Restructure the body to read as an algorithm, with extracted helpers:
  - `has_pending_persist_state()` — guards on `current_project_id` and DB connection.
  - `project_id_is_live()` — calls `database.assert_project_id_is_live(current_project_id, "media_status.persist_now")`.
  - `flush_status_cache_to_db()` — performs the actual `set_project_setting` write.
  - Main `M.persist_now()` body is three early-return checks. T006 verifies the stale path. T011/T013 verify the flush path.

### Background-worker cancel & drain

- [ ] **T024** Extend `cancel_background_probe` in `/Users/joe/Local/jve-spec-kit-claude/src/lua/core/media/media_status.lua` (or wherever the probe runs) per `contracts/worker_cancel_drain.md`:
  - Inspect existing implementation: does it set a flag, does it drain?
  - Add `wait_for_drain(timeout_ms)` if missing — blocks the caller while queued write callbacks land; returns `true` on drain, `false` on timeout.
  - Add `pending_count()` accessor for the timeout-warning log line.
  - Verify the worker checks the cancel flag at every write boundary so it cannot exceed the drain budget.
  - T007 verifies all three drain scenarios.

### Test-pass verification

- [ ] **T025** Run T004–T013 again. Confirm all 10 turn green. Re-run the full Lua suite (`./tests/run_lua_tests_all.sh > /tmp/post_phase33.txt 2>&1`). Diff against `/tmp/baseline_build.txt` from T003: only the new tests should differ; no regressions.

---

## Phase 3.4: Handler Audit Migration

The seed `handler_audit.md` has TBD rows that must be resolved before the feature is done (FR-007). Each TBD row is a separate inspection/migration task. Tasks are parallelizable [P] because each handler lives in a separate file (no [P] within the same file).

### Inspect & classify (each updates `handler_audit.md` — sequential because they all write the same audit catalog file)

- [ ] **T026** Inspect handler `peak_cache` at `/Users/joe/Local/jve-spec-kit-claude/src/lua/core/media/peak_cache.lua:401`. Read the body. Determine if it writes any per-project DB rows. Classify in `handler_audit.md` as `no-action`, `must-cancel-deferred-work`, or `must-flush-pending-writes`. Update the row.

- [ ] **T027** Inspect handler `project_generation` at `/Users/joe/Local/jve-spec-kit-claude/src/lua/core/project_generation.lua:31`. Same as T026.

- [ ] **T028** Inspect handler `timeline_state.on_project_change` at `/Users/joe/Local/jve-spec-kit-claude/src/lua/ui/timeline/timeline_state.lua:448`. Same.

- [ ] **T029** Inspect handler `inspector change_listeners` at `/Users/joe/Local/jve-spec-kit-claude/src/lua/ui/inspector/change_listeners.lua:71`. Same.

- [ ] **T030** Inspect handler `project_browser.on_project_change` at `/Users/joe/Local/jve-spec-kit-claude/src/lua/ui/project_browser.lua:2596`. Same. Watch for `persist_open_tabs`-style writes.

- [ ] **T031** Inspect handler `timeline_panel.on_project_change` at `/Users/joe/Local/jve-spec-kit-claude/src/lua/ui/timeline/timeline_panel.lua:2482`. Same. Likely contains `persist_open_tabs` to DB; if so → must-flush.

- [ ] **T032** Inspect handler `timeline_view_renderer` at `/Users/joe/Local/jve-spec-kit-claude/src/lua/ui/timeline/view/timeline_view_renderer.lua:36`. Same.

- [ ] **T033** Inspect handler `sequence_monitor` at `/Users/joe/Local/jve-spec-kit-claude/src/lua/ui/sequence_monitor.lua:147`. Same.

- [ ] **T034** Inspect handler `fullscreen_viewer` at `/Users/joe/Local/jve-spec-kit-claude/src/lua/ui/fullscreen_viewer.lua:202`. Same.

- [ ] **T035** Inspect handler `edit_history_window` at `/Users/joe/Local/jve-spec-kit-claude/src/lua/ui/edit_history_window.lua:252`. Same.

### Inspect deferred-work timer call sites (also updates `handler_audit.md`)

- [ ] **T036** Inspect timer callbacks in `peak_cache.lua` (lines 175, 180), `edit_history_window.lua:263`, `project_browser.lua:209`, `sequence_monitor.lua:709`, `timeline_panel.lua:2117`, `layout.lua:714`. For each, determine if the callback touches DB or holds project-scoped state. Classify each row in `handler_audit.md` and decide mitigation: `cancel-on-will-change`, `validate-at-fire-time`, or `none-needed`.

### Migrate (per handler classified as must-flush or must-cancel)

- [ ] **T037** Migrate handlers from T026–T035 classified `must-flush-pending-writes` or `must-cancel-deferred-work`. Each handler lives in its own file, so the per-file work is parallelizable [P], BUT each migration also updates `handler_audit.md` — those edits must be serialized. For each handler:
  - Add a `project_will_change` handler in the same module at the same priority that does the flush/cancel.
  - In the existing `project_changed` handler, remove the flush/cancel obligation; keep clear-and-load semantics only.
  - Update the row in `handler_audit.md` `migration_status` to `migrated`.
  - For handlers stale-safe via Layer 2 validation only (no flush, but reads project-scoped data on a deferred path), set `migration_status = safe-by-validation` and add the validation call to the deferred path.

- [ ] **T038** Migrate every deferred-work timer site classified `cancel-on-will-change` from T036. Each gets a cancel hook in its module's `project_will_change` handler (or a flag-and-no-op-in-callback pattern, depending on what `qt_create_single_shot_timer` supports — verify during this task).

### Audit-catalog gate

- [ ] **T039** Verify the FR-007 invariant in `/Users/joe/Local/jve-spec-kit-claude/specs/014-two-phase-project/handler_audit.md`:
  - No row with `classification ∈ {must-cancel-deferred-work, must-flush-pending-writes}` AND `migration_status = none-needed`.
  - No row contains "TBD" in any column.
  - All 15 `project_changed` handlers + all timer sites enumerated.
  - Run `grep -E 'TBD|must-(cancel|flush).*none-needed' /Users/joe/Local/jve-spec-kit-claude/specs/014-two-phase-project/handler_audit.md`. Expected: empty output.

---

## Phase 3.5: Integration & Validation

- [ ] **T040** Run T009 (anamnesis re-import zero-asserts integration test). Confirm green.

- [ ] **T041** Execute `quickstart.md` manually:
  - Reset state per quickstart step 1.
  - Launch `JVEEditor`, import `anamnesis-gold-timeline.drp`, interact (arrow, play, select, switch), per steps 2–3.
  - Verify TSO has zero `assert_project_exists ... Stale project_id` lines per step 4.
  - Verify pre-switch flush populated outgoing DB per step 5.
  - Verify `handler_audit.md` is committed (T039 already gated this) per step 6.

- [ ] **T042** Re-run full test suite: `make -j4 > /tmp/final_build.txt 2>&1` from repo root. Required:
  - Zero luacheck warnings (rule 2.4).
  - All Lua tests pass.
  - Diff against `/tmp/baseline_build.txt` from T003: only new tests added, no regressions.

---

## Phase 3.6: Polish

- [ ] **T043** [P] Re-grep for new module-local project caches that may have been added without validation. Run `grep -rn 'local current_project_id\|local _project_id' /Users/joe/Local/jve-spec-kit-claude/src/lua/` and verify every hit is in `handler_audit.md` with `validate_before_write = YES`.

- [ ] **T044** [P] Confirm the conversion-dialog `pcall` wrapper from the prior session (in `src/lua/ui/conversion_dialog.lua`) is still in place. It is intentionally OUT of scope for this feature (separate concern, separate commit) but should not have regressed.

- [ ] **T045** Update memory: append a `feedback_two_phase_project_switch.md` entry to `/Users/joe/.claude/projects/-Users-joe-Local-jve-spec-kit-claude/memory/` capturing the contract: "every project_changed handler that wrote to the outgoing DB has been migrated to project_will_change; new modules with project-scoped state must register both signals." Add a 1-line pointer in `MEMORY.md`.

- [ ] **T046** Document the closed audit at `handler_audit.md` (already enforced by T039) and remove the "(seed)" annotation from the file's header. The committed file is the FR-007 deliverable.

- [ ] **T047** Final tone audit on this feature's docs (rules 2.1, 3.14): re-grep `/Users/joe/Local/jve-spec-kit-claude/specs/014-two-phase-project/` for marketing-speak (`robust|powerful|professional|enterprise|amazing|seamless|elegant`) — expect zero hits.

---

## Dependencies

```
T001 ──► T002 ──► T003 ──► (Phase 3.2)
              ┌────────────────────────────┐
              │  T004 [P]  T005 [P]  T006 [P]
              │  T007 [P]  T008 [P]  T009 [P]
              │  T010 [P]  T011 [P]  T012 [P]
              │  T013 [P]
              └────────────┬───────────────┘
                           │
                          T014 (verify all red)
                           │
                           ▼
              ┌────────────────────────────┐
              │  T015 [P, C++ bridge]
              │  T016 [signals.lua doc]
              │  T017 ──► T018 [emit point]
              │  T019 [P, db helper]
              │  T020 [P, db audit]
              │  T021 ──► T022 ──► T023
              │              ▲
              │              │
              │              T024 (worker cancel/drain)
              └────────────┬───────────────┘
                           │
                          T025 (verify green)
                           │
                           ▼
              ┌────────────────────────────┐
              │  T026 .. T035 (per-handler inspection)
              │  T036 (deferred timer inspection)
              └────────────┬───────────────┘
                           │
                          T037, T038 (migrations)
                           │
                          T039 (audit gate)
                           │
                           ▼
              T040 ──► T041 ──► T042
                           │
                           ▼
              T043 [P]  T044 [P]  T045  T046  T047
```

Key blocking edges:
- T014 (red-test gate) blocks T015–T024.
- T022 depends on T024 (handler calls drain API).
- T021 → T022 → T023 are sequential (same file).
- T026–T035 are sequential as written (each updates `handler_audit.md`); they could be parallelized only if the audit catalog edits are coordinated by hand or done in separate PRs. Default: sequential.
- T037 and T038 cover migrations — each is per-file so [P] per file but each must follow its inspection task.
- T039 (gate) blocks T040.
- T042 (full test suite green) blocks T043+ (polish).

---

## Parallel execution examples

### Phase 3.2: launch all contract + scenario tests together

```text
Task: "Write contract test test_project_will_change_ordering.lua per T004"
Task: "Write contract test test_assert_project_exists_coverage.lua per T005"
Task: "Write contract test test_assert_project_id_is_live.lua per T006"
Task: "Write contract test test_worker_cancel_drain.lua per T007"
Task: "Write integration test test_lua_callback_stack_trace.lua per T008"
Task: "Write integration test test_anamnesis_reimport_no_asserts.lua per T009"
Task: "Write edge-case test test_project_switch_cold_start.lua per T010"
Task: "Write edge-case test test_project_switch_close_no_replacement.lua per T011"
Task: "Write edge-case test test_project_will_change_handler_error_isolation.lua per T012"
Task: "Write edge-case test test_project_switch_rapid.lua per T013"
```

### Phase 3.3: parallelizable core implementations

```text
Task: "Apply C++ bridge change per T015 in src/jve_lua_callback.cpp"
Task: "Add assert_project_id_is_live helper per T019 in src/lua/core/database.lua"
Task: "Audit assert_project_exists coverage per T020 in src/lua/core/database.lua"
```

(T015 is C++; T019 and T020 are Lua and could conflict on the same file — pick one to land first, then the other.)

### Phase 3.4: migrations are per-file [P]

```text
Task: "Inspect handler peak_cache per T026"
Task: "Inspect handler timeline_panel per T031"
# ...etc, but each writes handler_audit.md so coordinate that file
```

---

## Validation Checklist

*Gate before considering this tasks.md ready to execute.*

- [x] All four contracts in `contracts/` have corresponding tests (T004 → signal_will_change, T005/T006 → persist_now_validation, T007 → worker_cancel_drain, T008 → lua_callback_bridge).
- [x] All entities in `data-model.md` have implementation tasks: Project Switch Event → T016+T018; Module-Local Project Cache → T019+T023; Audit Catalog → T026–T039.
- [x] All tests come before implementation (T004–T014 before T015–T025) — TDD enforced by T014 gate.
- [x] [P] tasks operate on different files and have no dependencies on each other.
- [x] Each task specifies an exact absolute file path.
- [x] No two [P] tasks modify the same file (verified: handler-audit edits are flagged as serialized).
- [x] FR-007 audit-catalog invariant has its own gate task (T039).
- [x] FR-011 anamnesis re-import scenario has its own gate task (T040).
- [x] Constitution rule 2.20 (Regression Tests First) honored: every implementation task is preceded by the test that would fail without it.
- [x] Constitution rule 2.32 (New Codepaths Require Tests) honored: every new branch (cold start, close-no-replacement, rapid switches, drain timeout, stale-write safety net, handler error isolation) has a dedicated test.

---

## Notes

- Commit attribution per rule 2.8: `Authored-By: Joe Shapiro <joe@shapiro.net> With-Help-From: Claude`.
- Tasks are not marked done until Joe agrees (per ENGINEERING.md tail).
- TDD ordering is non-negotiable. T014 is the hard gate — every test from T004–T013 must be observably red before any production code is touched.
- This branch's working tree contains uncommitted changes from a prior session (see T001). T001's confirmation step decides their disposition before any new work begins.
