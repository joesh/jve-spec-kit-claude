# Tasks: No Active Sequence State

**Input**: Design documents from `/Users/joe/Local/jve-spec-kit-claude/specs/010-first-class-no/`
**Prerequisites**: plan.md, research.md, data-model.md, contracts/

## Conventions
- All paths are absolute.
- `[P]` = parallel-safe (different files, no ordering dependency on other `[P]` tasks in the same phase).
- TDD gate: Phase 3.2 tests MUST be red before any Phase 3.3+ implementation starts.
- Commit after each implementation task (not after each test task — tests land together red, then each implementation phase lands green).
- `make -j4` runs luacheck + all Lua tests + C++ tests; use it as the phase gate. `./build/bin/JVEEditor --test <path>` runs binding tests.

---

## Phase 3.1: Setup

- [ ] **T001** Confirm a clean working tree scoped to this branch. Run `git status`; if any file outside this feature's scope is modified by a sibling Claude session, do NOT stash or reset — proceed and scope every later commit to files this feature touches. (See CLAUDE.md "Refactor Safeguard".)

- [ ] **T002** [P] Verify `make -j4` is green on the pre-change baseline. Save the baseline output to `/tmp/010_baseline.txt`. If any test fails, stop and investigate before starting Phase 3.2 — per CLAUDE.md, "no pre-existing issues" excuse.

- [ ] **T002a** [P] Principle VIII pre-impl scan. Grep existing tests for reliance on the silent `Sequence.find_most_recent()` or `sequences[1]` fallback in no-tab-info project setups (e.g. tests that open a project without seeding `last_open_sequence_id` and expect a specific sequence to load). Commands:
  ```
  grep -rn "find_most_recent\|sequences\[1\]" tests/
  ```
  Enumerate each match: is the test relying on the fallback or coincidentally using the same function? For tests relying on the fallback, note them in `/tmp/010_fallback_dependent_tests.txt` and flag for explicit remediation in later phases (a reliance test must either be updated to set tab info explicitly, or deleted as obsolete per principle VIII; do NOT "adjust expected values" without user approval — rule 2.31).

- [ ] **T002b** [P] Menu-binding discovery. Grep for the menu binding of the per-sequence commands (Play, JKL, Mark In/Out, Cut, Copy, Paste, Delete). Commands:
  ```
  grep -rn "menu_item\|register_menu\|MENU_ITEM\|add_menu_command" src/lua/ | head -40
  grep -rn "play\|mark_in\|mark_out" src/lua/ui/menu* 2>/dev/null
  ```
  Record the authoritative menu-binding file path(s) in `/tmp/010_menu_binding_paths.txt`. Used by T032.

---

## Phase 3.2: Tests First (TDD) — MUST FAIL BEFORE PHASE 3.3

Each test in this phase MUST be added, run, and verified to fail (or to error with "function not found") before any implementation begins. Commit all five tests together in one "test: add failing regression tests for no-active-sequence state" commit.

- [ ] **T003** [P] Create `/Users/joe/Local/jve-spec-kit-claude/tests/test_timeline_state_clear.lua`. Covers the `state.clear()` contract from `contracts/timeline_state.md`. Assertions:
  - After `init("s1","p1")`, call `clear()`; assert `get_sequence_id() == nil`, `get_project_id() == "p1"`.
  - After `clear()` + `init("s2","p1")`, `get_sequence_id() == "s2"`.
  - A listener added via `add_listener(fn)` fires once per `clear()`.
  - Calling `clear()` before any `init` is a no-op (does not error).
  Ends with `print("✅ test_timeline_state_clear.lua passed")`. Must fail on current master (function doesn't exist).

- [ ] **T004** [P] Create `/Users/joe/Local/jve-spec-kit-claude/tests/test_drop_sequence_name_building.lua`. Pure-function test for `build_drop_sequence_name(first_name, additional)` from `contracts/timeline_panel.md`:
  - `build_drop_sequence_name("clip.mov", 0) == "clip.mov"`.
  - `build_drop_sequence_name("clip.mov", 3) == "clip.mov (+3 more)"`.
  - `build_drop_sequence_name("a", 1) == "a (+1 more)"`.
  - `build_drop_sequence_name("very_long name with spaces.R3D", 12) == "very_long name with spaces.R3D (+12 more)"`.
  Must fail on current master (function doesn't exist on `M`).

- [ ] **T005** [P] Create `/Users/joe/Local/jve-spec-kit-claude/tests/test_drp_resolver_asserts_malformed.lua`. Pure-Lua; builds in-memory fixtures for `resolve_project_tab_ids` (see `contracts/drp_importer.md`). Wraps each call in `pcall` and asserts the expected error message substring:
  - **Case 1 (legitimate empty)**: `tabs_data=nil, handle_vec_ids={}, cti=nil` → succeeds, sets `open_timeline_ids = {}`, `active_timeline_id == nil`.
  - **Case 2 (cti out of range)**: `handle_vec_ids={"a","b"}, cti=5` → pcall returns false, error contains `"out of range"`.
  - **Case 3 (no Sm2Sequence mapping)**: `handle_vec_ids={"a"}, cti=0, timeline_id_map={}` → pcall returns false, error contains `"no corresponding Sm2Sequence"`.
  - **Case 4 (cti missing)**: `handle_vec_ids={"a"}, cti=nil` → pcall returns false, error contains `"<CurrentTimelineIndex> is missing"`.
  Must fail on current master (current code uses `log.warn` + silent fallthrough for cases 2/3/4).

- [ ] **T006** [P] Create `/Users/joe/Local/jve-spec-kit-claude/tests/test_project_open_no_tab_info_stays_blank.lua`. Pure Lua. Seeds a `.jvp` test DB in `/tmp/jve/` with one project + two sequences but no `last_open_sequence_id` and empty `open_sequence_ids=[]`. Invokes the open path via the `core.commands.open_project` module and asserts:
  - After open: `timeline_state.get_sequence_id() == nil`.
  - `command_manager`'s active stack is nil.
  - No auto-creation of a tab; no `find_most_recent`-style fallback.
  Must fail on current master (open path falls back to `find_most_recent`).

- [ ] **T007** [P] Create `/Users/joe/Local/jve-spec-kit-claude/tests/binding/test_close_last_tab_enters_blank.lua`. `--test` mode. Creates a fresh `.jvp` with one project + one sequence; calls `timeline_panel.create({sequence_id=s,project_id=p,…})`; calls `timeline_panel.close_tab(s)`. Asserts:
  - `timeline_state.get_sequence_id() == nil` post-close.
  - `database.get_project_setting(p, "last_open_sequence_id") == ""` (or nil).
  - `database.get_project_setting(p, "open_sequence_ids")` is an empty array.
  - `open_tabs` (as observed via any public accessor; else `timeline_panel.restore_tab_order` no-op) contains zero entries — the phantom tab was NOT recreated.
  Must fail on current master (the TODO hack at `timeline_panel.lua:486-491` reopens the closed tab).

- [ ] **T008** Run every new test (`T003`–`T007`). Confirm each one is red. Do NOT proceed to Phase 3.3 until all five are red. Save the consolidated "red output" transcript to `/tmp/010_red.txt` as evidence.

- [ ] **T009** Commit T003–T008 together: `test: failing regression suite for no-active-sequence state`. Attribution: `Authored-By: Joe Shapiro <joe@shapiro.net>` + `With-Help-From: Claude`. Scope the commit to the five new test files only.

---

## Phase 3.3: Core Implementation — State Layer

Makes T003 pass.

- [ ] **T010a** Edit `/Users/joe/Local/jve-spec-kit-claude/src/lua/ui/timeline/state/timeline_core_state.lua`. Add two functions:
  - `M.clear()` per `contracts/timeline_state.md` — sets `data.state.sequence_id = nil`, leaves `data.state.project_id` intact, resets selection/marks to defaults, notifies listeners (same notification mechanism `init()` uses on successful entry). Idempotent.
  - `M.set_project_id(project_id)` — asserts non-nil non-empty; sets `data.state.project_id = project_id`; does NOT touch sequence_id. This is the new primitive used by `timeline_panel.create({sequence_id=nil, project_id=pid})`.
  - Keep `init(sequence_id, project_id)` strict (non-nil both) — do NOT soften.

- [ ] **T010b** Edit `/Users/joe/Local/jve-spec-kit-claude/src/lua/ui/timeline/timeline_state.lua` (the facade at ~line 74 where `M.init = core.init` re-exports). Add:
  ```
  M.clear = core.clear
  M.set_project_id = core.set_project_id
  ```
  This is the surface consumers (`timeline_panel`, tests) import. Without the re-export, `clear()` is internal-only.

- [ ] **T011** Run `T003` (pure-Lua test, which imports via `require("ui.timeline.timeline_state")`). Must now pass. Run `make -j4`; must stay green. Commit: `feat: timeline_state.clear() + set_project_id() primitives`.

---

## Phase 3.4: Core Implementation — Command Manager

Prepares for the UI primitives (T013+).

- [ ] **T012a** [P] Create two failing tests BEFORE editing `command_manager.lua`:
  - `/Users/joe/Local/jve-spec-kit-claude/tests/test_command_manager_deactivate.lua`:
    - Init with sequence `"s1"`; execute a per-sequence command; call `deactivate()`; assert the per-sequence command is NOT visible to subsequent `undo()` (it remains on the persisted per-sequence stack).
    - Execute a project-level command (e.g. `create_sequence`); call `undo()`; assert the project-level command was reverted.
    - Call `deactivate()` twice; assert no error.
  - `/Users/joe/Local/jve-spec-kit-claude/tests/test_command_manager_undo_routes_to_project_when_blank.lua`:
    - After `deactivate()` with empty project-level stack, `undo()` is a no-op (no error, no state change).
    - After `deactivate()` with two project-level commands on the stack, two `undo()`s revert both. `redo()` re-applies in LIFO order.
  Both tests must fail on current master (`deactivate` doesn't exist).

- [ ] **T012b** Create `/Users/joe/Local/jve-spec-kit-claude/src/lua/core/command_manager.lua` edits:
  - Add `M.init_project_only(project_id)` — same setup as `init` but without activating a per-sequence timeline stack and without loading a sequence. Asserts `project_id` non-nil non-empty. Calls existing `registry.init`, `history.init(db, nil, project_id)` (verify `history.init` tolerates nil sequence — if not, extend it minimally in the same commit), `state_mgr.init(db)`. Does NOT call `activate_timeline_stack`. Used by startup when no sequence is active.
  - Add `M.deactivate()` — idempotent; sets `active_sequence_id = nil`; sets the active per-sequence stack reference to nil via the existing stack-activation machinery (mirror whatever `activate_timeline_stack` does in reverse — inspect `activate_stack(stack_id, opts)` at ~line 2360). Does NOT touch the persisted per-sequence stack row.
  - Modify `M.undo()` and `M.redo()` so that when the active per-sequence stack is nil, they dispatch to the project-level stack instead. When both are empty, no-op (no error).

- [ ] **T013** Run `T012a` tests + `make -j4`. Commit: `feat: command_manager.init_project_only() + deactivate(); undo routes to project stack when no active seq`.

---

## Phase 3.5: Core Implementation — UI Primitives

Makes T004 pass. Prepares for wiring.

- [ ] **T014a** [P] Create failing test `/Users/joe/Local/jve-spec-kit-claude/tests/test_unload_sequence_persists_empty.lua`. Pure Lua. Stubs the Qt widget API (`qt_constants.WIDGET.SET_PARENT`, etc. — use the approach that existing pure-Lua tests which touch `timeline_panel` use; if no precedent, promote this test to `tests/binding/` and run via `--test`). Asserts:
  - After seeding `last_open_sequence_id="s1"`, `open_sequence_ids={"s1"}` and calling `timeline_panel.unload_sequence()`:
    - `timeline_state.get_sequence_id() == nil`.
    - `database.get_project_setting(pid, "last_open_sequence_id") == ""`.
    - `database.get_project_setting(pid, "open_sequence_ids")` is a table with zero entries.
  - Idempotency: a second call leaves the same state.
  Must fail on current master (function doesn't exist).

- [ ] **T014b** Edit `/Users/joe/Local/jve-spec-kit-claude/src/lua/ui/timeline/timeline_panel.lua`:
  - Add pure helper `M.build_drop_sequence_name(first_name, additional)` per `contracts/timeline_panel.md`. Export on `M` for test access.
  - Add `M.unload_sequence()` inverse of `M.load_sequence`. Must:
    1. `state.clear()`.
    2. `command_manager.deactivate()`.
    3. Blank the timeline monitor — query the existing monitor registry (`panel_manager.register_sequence_monitor("timeline_monitor", …)`). Grep for `timeline_monitor` usage to find the pull-path accessor. The correct MVC move is: do NOT push an empty frame to the monitor; instead, invalidate the monitor's sequence reference so its next poll reads `state.get_sequence_id() == nil` and draws blank. If no such accessor exists, add a minimal `SequenceMonitor:invalidate_sequence()` that nils the internal reference — document the addition in a comment in `unload_sequence`.
    4. `selection_hub.update_selection("timeline", {})`.
    5. `database.set_project_setting(pid, "last_open_sequence_id", "")`.
    6. `database.set_project_setting(pid, "open_sequence_ids", {})`.
    7. Remove all visible tab widgets via the existing per-tab teardown loop (reuse code from `close_tab` but without its "load next tab" branch).
  - Do NOT remove the per-sequence command stack persisted rows (FR-014).

- [ ] **T015** Run `T004` (build_drop_sequence_name) + `T014a` (unload_sequence persists). Both must now pass. Run `make -j4`. Commit: `feat: timeline_panel.unload_sequence() + build_drop_sequence_name()`.

---

## Phase 3.6: UI Wiring — close_tab + create(nil)

Makes T007 pass.

- [ ] **T016** Edit `/Users/joe/Local/jve-spec-kit-claude/src/lua/ui/timeline/timeline_panel.lua` at lines ~486–491:
  - Replace the TODO-hack fallback (`ensure_tab_for_sequence(sequence_id)` + `M.load_sequence(sequence_id)`) with a call to `M.unload_sequence()`.
  - Keep the "next tab exists → load that one" branch untouched.

- [ ] **T017** Edit `/Users/joe/Local/jve-spec-kit-claude/src/lua/ui/timeline/timeline_panel.lua` at lines ~1289–1290 (`M.create(opts)`):
  - Allow `opts.sequence_id` to be nil or `""`. When nil/empty:
    - Call `state.set_project_id(opts.project_id)` (added in T010a) — NOT `state.init`. This sets project_id without touching sequence_id.
    - Call `state.clear()` afterward to initialize selection/marks to defaults and fire listeners.
    - Do not call `ensure_tab_for_sequence` for an initial tab.
  - When `opts.sequence_id` is non-nil/non-empty: existing call `state.init(sequence_id, project_id)` unchanged.
  - `opts.project_id` stays strict (required). Keep the existing `assert(project_id and project_id ~= "", ...)`.

- [ ] **T018** Run `T007` (binding test) and the full `make -j4`. Both must pass. Commit: `feat: close_tab last-tab enters blank state; create() tolerates nil sequence_id`.

---

## Phase 3.7: Startup Path — drop find_most_recent + sequences[1]

Makes T006 pass.

- [ ] **T019** Edit `/Users/joe/Local/jve-spec-kit-claude/src/lua/ui/layout.lua`:
  - In `open_and_init_project` (~L107–110): remove `if not sequence then sequence = Sequence.find_most_recent() end`. If `last_seq_id` is missing or doesn't resolve, `sequence` stays nil. Remove the `assert(sequence, …)` at L110.
  - Where `active_sequence_id = sequence.id` (~L114): guard with `if sequence then active_sequence_id = sequence.id end`. Leave `active_sequence_id` nil when no sequence.
  - In `command_manager.init` call (~L119): branch — if `active_sequence_id` is non-nil, call `command_manager.init(active_sequence_id, active_project_id)`; if nil, call `command_manager.init_project_only(active_project_id)` (added in T012b). No fallback inside `init`.
  - At lines ~580–582: remove the `initial_sequence_id = sequences[1].id` fallback. Leave `initial_sequence_id` nil if nothing resolves.
  - At line ~427 (`timeline_panel.create({sequence_id=active_sequence_id,…})`): the create call now tolerates nil thanks to T017 — verify.

- [ ] **T020** Edit `/Users/joe/Local/jve-spec-kit-claude/src/lua/core/commands/open_project.lua` at ~L311. Remove `Sequence.find_most_recent()` fallback and the subsequent assert. Leave the resulting active_sequence_id as nil if none was saved.

- [ ] **T021** Edit `/Users/joe/Local/jve-spec-kit-claude/src/lua/core/commands/new_project.lua` at ~L233. Same treatment as T020.

- [ ] **T022** Run `T006` (pure) — must now pass. Run `make -j4`. Commit: `fix: drop find_most_recent + sequences[1] fallbacks; honor no-active-sequence on open`.

---

## Phase 3.8: DRP Importer Resolver Asserts

Makes T005 pass.

- [ ] **T023** Edit `/Users/joe/Local/jve-spec-kit-claude/src/lua/importers/drp_importer.lua` at `resolve_project_tab_ids` (~L528):
  - After checking priority 1 (SequenceTabsData), before touching priority 2, detect case 4: `#handle_ids > 0 AND cti == nil` → `assert(false, "drp_importer: TimelineHandleVec has N entries but <CurrentTimelineIndex> is missing…")`.
  - If `#handle_ids > 0`, replace the `cti >= 0 and cti < #handle_ids` gate with an explicit `assert(cti >= 0 and cti < #handle_ids, "drp_importer: CurrentTimelineIndex=%d out of range for TimelineHandleVec of length %d…")`.
  - After `tl_db_id = handle_ids[cti + 1]`, replace the silent `if mapped and mapped.seq_id` branch with `assert(mapped and mapped.seq_id, "drp_importer: TimelineHandleVec[%d]=%s has no corresponding Sm2Sequence in MediaPool…")`.
  - Remove the `log.warn(...)` line.
  - Case 1 (handle_ids empty AND tabs_data empty) still falls through to return with `open_timeline_ids = {}`, `active_timeline_id = nil`. That path is legitimate.

- [ ] **T024** Run `T005` (pure) — must now pass. Run `make -j4`. Also re-run the three DRP binding tests manually (`./build/bin/JVEEditor --test tests/binding/test_drp_active_timeline_restored.lua`, `_open_timelines`, `_anamnesis_full`); all must stay green. Commit: `fix: drp_importer resolve_project_tab_ids asserts on malformed TimelineHandleVec`.

---

## Phase 3.9: Drop-to-blank Drag Handler

Implements FR-011 (drop-to-blank creates new sequence). No existing test covers this end-to-end; add one binding test.

- [ ] **T025** Edit `/Users/joe/Local/jve-spec-kit-claude/src/lua/ui/timeline/timeline_panel.lua`: add `M.handle_drop_on_blank_timeline(payload)` per `contracts/timeline_panel.md`:
  - Partitions `payload.sequences` and `payload.clips`.
  - For each sequence: `M.open_tab(seq.id)`.
  - If clips exist:
    - `name = build_drop_sequence_name(clips[1].name, #clips - 1)`
    - `fps, w, h = settings_from_first_clip(clips[1])` — helper reads the media's cached asset_info (fps + resolution); falls back to project defaults only if both are nil or zero. This is a user-requested fallback (spec Q2 answer B), not a silent engineering fallback — principle VII applies to required data, not to spec-driven UX fallbacks.
    - Wrap in one `command_manager.execute_group`: `create_sequence(name, fps, w, h)`, then `insert_clip(new_seq_id, c)` per clip in payload order.
    - Verify the new sequence inherits the project-wide `track_height_template` — this is the existing `create_sequence` command's responsibility per ENGINEERING.md 2.30. If grep of `create_sequence` shows it already reads the template, confirm in a comment; if not, this task fails and Joe must weigh in on whether to fix `create_sequence` in-scope or defer.
    - `M.open_tab(new_seq_id)`; becomes active (last one activated).
  - Invariant post-call: exactly one tab is active.
  - All commands in the group MUST carry `sequence_id = new_seq_id` per ENGINEERING.md 2.29 — `create_sequence` is project-scoped so it doesn't set sequence_id; each subsequent `insert_clip` does.

- [ ] **T026** Edit `/Users/joe/Local/jve-spec-kit-claude/src/lua/ui/timeline/view/timeline_view_drag_handler.lua` at ~L43 and ~L237:
  - Before accessing sequence-scoped state, check `timeline_state.get_sequence_id() == nil`.
  - If nil AND the drop target is the timeline area: collect `sequences` + `clips` from the payload (recurse bins via existing project-browser helper), then call `timeline_panel.handle_drop_on_blank_timeline({sequences=…, clips=…})`.
  - If nil AND the drop target is anything else: early-return no-op.
  - When not nil: existing behavior unchanged.

- [ ] **T027** Create `/Users/joe/Local/jve-spec-kit-claude/tests/binding/test_drop_on_blank_creates_sequence.lua`. `--test` mode. Seeds a project with a couple of media clips + an existing sequence; enters blank state via `unload_sequence`; calls `timeline_panel.handle_drop_on_blank_timeline(...)` with a 3-clip payload. Asserts:
  - One new sequence was created.
  - New sequence name matches `<first-clip> (+2 more)`.
  - New sequence's fps and resolution match the first clip's asset_info.
  - All 3 clips are on the timeline in drop order.
  - Active sequence after the call is the new sequence.
  - Second sub-case: payload with one existing sequence → that sequence becomes active, no new sequence created.

- [ ] **T028** Run T027 (binding) + `make -j4`. Commit: `feat: drop-to-blank-timeline creates new sequence or opens dropped sequence`.

---

## Phase 3.10: Cross-cutting Nil-Guards

These may ride along with earlier phases, but split to their own commit for isolation.

- [ ] **T029** Edit `/Users/joe/Local/jve-spec-kit-claude/src/lua/core/keyboard_shortcuts.lua` at ~L222 and ~L273:
  - Before dispatching any command that targets the active sequence, check `timeline_state.get_sequence_id() == nil`. If nil, silently no-op (grey-out behavior at the menu layer plus silent key ignore).
  - If non-nil, existing dispatch unchanged.

- [ ] **T030** Enumerate remaining nil-guard candidates. Source: the `/plan` Phase 0 agent survey (see plan.md "Consumers of active sequence"). Re-run the survey with a fresh grep to catch drift:
  ```
  grep -rn "timeline_state.get_sequence_id\|state.get_sequence_id" src/lua/ \
      | grep -v -E "(if not|== nil|~= nil|tests/)"
  ```
  For each hit, inspect whether the caller already handles nil. Produce a list in `/tmp/010_nil_audit.txt` with three columns: `file:line | currently handles nil? | remediation (guard | assert | already-safe)`. Apply remediations:
  - **Guard and no-op** when the command is targeting the active sequence and the user-visible correct behavior is "do nothing" (menu items, JKL, Mark In/Out, cut/paste keystrokes).
  - **Assert** when the callsite is a code path that should never fire without an active sequence (e.g., internal timeline_view rendering assuming state is populated — if it's a MVC pull-path the caller shouldn't exist without state).
  - **Already-safe** when grep found a match inside an explicit `if get_sequence_id() then …` block or similar.
  Do NOT soften asserts that catch real bugs — principle VI.

- [ ] **T031** Run `make -j4`. Manual smoke: launch `./build/bin/JVEEditor`, press J/K/L and every timeline shortcut in blank state; confirm no console asserts. Commit: `fix: nil-guard keyboard shortcuts + drag handler for no-active-sequence state`.

---

## Phase 3.11: Menu Grey-Out (FR-008)

- [ ] **T032** Menu gating. For each menu item whose command is per-sequence (Play, JKL, Mark In/Out, Cut, Copy, Paste, Delete, etc.), attach an `enabled` predicate that returns `false` when `timeline_state.get_sequence_id() == nil`. Prefer a single shared predicate helper (`ui.menu.requires_active_sequence()` or similar) over duplicating the check.
  - Location: read `/tmp/010_menu_binding_paths.txt` from T002b for the authoritative file(s). If T002b has not run, re-run its grep.
  - Edit the menu system so menu-item enabled state refreshes on `timeline_state.add_listener` callbacks — the existing state listener mechanism drives this pull-based update (MVC principle I + rule 3.0).
  - Enumerate every per-sequence command in the menu binding file and add the predicate. Do not miss any — the grey-out behavior is FR-008; a missed item is a bug.

- [ ] **T033** Run `make -j4`. Manual smoke: open Edit menu in blank state; confirm relevant items are greyed. Transition to an active sequence; confirm they re-enable. Commit: `feat: menu grey-out in no-active-sequence state`.

---

## Phase 3.12: Validation

- [ ] **T034** Full `make -j4`. Must be green. All new tests + existing 508 + binding suite.

- [ ] **T035** Execute `quickstart.md` scenarios 1–9 against `./build/bin/JVEEditor`. Record pass/fail notes inline in `quickstart.md` or a companion `quickstart-results.md`.

- [ ] **T036** ENGINEERING.md audit of the accumulated diff against principles 1.14, 2.4, 2.5, 2.13, 2.15, 2.20, 2.21, 2.32, 3.14. Document any findings and remediate before merge.

- [ ] **T037** Merge `010-first-class-no` into `master`. Use a worktree at `/tmp/jve-010-merge` checked out to `master` to perform the merge so any parallel Claude session's uncommitted working-tree edits stay intact (see CLAUDE.md WARNING #5 and the worktree pattern used on the 009 merge).

---

## Dependencies

- **T001–T002b** (setup + pre-impl scans) before anything.
- **T003–T009** (test phase) before any implementation. Tests must be red.
- **T010a–T011** (state.clear + set_project_id + facade re-export) before **T014b** (unload_sequence calls state.clear) and **T017** (create(nil) calls state.set_project_id).
- **T012a–T013** (command_manager.init_project_only + deactivate) before **T014b** (unload_sequence calls deactivate) and **T019** (layout calls init_project_only).
- **T014a–T015** (unload_sequence + build_drop_sequence_name) before **T016–T018** (close_tab rewire) and **T025** (drop handler).
- **T016–T018** (close_tab + create(nil)) before **T019–T022** (layout relies on `create(nil)` tolerance).
- **T019–T022** (startup fallback removal) independent of **T023–T024** (DRP resolver) — can be interleaved.
- **T025–T028** (drop handler) depends on T014b, T012b, and existing `command_manager.execute_group`.
- **T029–T031** (nil-guards) can start after T010a + T002b (menu-binding scan), independent of most others.
- **T032–T033** (menu grey-out) depends on T002b (binding discovery) and T010a (state.clear fires listeners for menu refresh).
- **T034–T037** (validation + merge) strictly last.

## Parallel Execution Examples

### Phase 3.2 tests (all five in parallel)
```
Task: "Create tests/test_timeline_state_clear.lua"           (T003 [P])
Task: "Create tests/test_drop_sequence_name_building.lua"    (T004 [P])
Task: "Create tests/test_drp_resolver_asserts_malformed.lua" (T005 [P])
Task: "Create tests/test_project_open_no_tab_info_stays_blank.lua"  (T006 [P])
Task: "Create tests/binding/test_close_last_tab_enters_blank.lua"   (T007 [P])
```

### Phase 3.7 ↔ 3.8 (startup path and DRP resolver touch different files)
```
Task: "Edit src/lua/ui/layout.lua (remove fallbacks)"         (T019)
Task: "Edit src/lua/core/commands/open_project.lua"           (T020 [P with T019 only if separate commits])
Task: "Edit src/lua/core/commands/new_project.lua"            (T021 [P])
Task: "Edit src/lua/importers/drp_importer.lua"               (T023 [P])
```
(T019 and T020/T021 touch related-but-separate files; if you bundle them into one commit, serialize. If separate commits, they can run parallel.)

### Phase 3.10 ↔ 3.11 (nil-guards and menu grey-out)
```
Task: "Edit src/lua/core/keyboard_shortcuts.lua nil-guards"       (T029 [P])
Task: "Menu grey-out predicate wiring"                             (T032 [P])
```

## Validation Gate

Before marking /tasks complete for execution:
- [x] Every contract file (`timeline_state.md`, `timeline_panel.md`, `command_manager.md`, `drp_importer.md`) has at least one corresponding test task in Phase 3.2 or 3.4.
- [x] Every entity in data-model.md has an implementation task (ActiveSequenceRef → T010a; ProjectTabState persistence → T014b; DropPayload transient → T025).
- [x] Every user-story acceptance scenario (AS-1..AS-6) maps to at least one test task:
  - AS-1 (close last tab) → T007.
  - AS-2 (drop on blank creates / opens) → T027.
  - AS-3 (reopen stays blank) → T006 + manual quickstart step 1.
  - AS-4 (DRP with tab metadata — existing behavior) → existing `test_drp_active_timeline_restored.lua` (re-run in T024).
  - AS-5 (DRP with no tab metadata) → T005 Case 1 + manual quickstart step 4.
  - AS-6 (malformed DRP asserts) → T005 Cases 2/3/4.
- [x] Every contract "Required tests" is a task: `timeline_state` → T003 ✓; `timeline_panel` → T004 + T014a + T027 ✓; `command_manager` → T012a (two tests) ✓; `drp_importer` → T005 ✓.
- [x] TDD ordering preserved: T003–T009 must be red before any of T010a+.
- [x] No two `[P]` tasks modify the same file in the same phase.
- [x] ENGINEERING.md 2.34 note: T003, T004, T012a tests are **contract-level unit tests** (they assert contracts defined in `contracts/*.md`, not derived-by-tracing-code). The **domain-level tests** that satisfy rule 2.34 are T006 (project open), T007 (close last tab), T027 (drop on blank). Both layers are required: contract tests catch broken primitives; domain tests catch broken user outcomes.

## Notes

- Commit after each implementation phase (not after every sub-step). Scope every commit strictly to files this feature touches — Joe runs parallel Claude sessions on this repo; never stash or reset the whole tree.
- If a test in Phase 3.2 passes on current master, STOP — either the test is testing nothing (falsely green), or the feature is already partly present. Investigate before proceeding.
- When in doubt about scope, ask before implementing (CLAUDE.md: "Don't decide scope — ask Joe").
- `selection_hub` is the existing inspector-notification bus; do not invent a new signal (research.md §3).
