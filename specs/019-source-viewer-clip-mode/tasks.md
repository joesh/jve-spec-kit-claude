# Tasks: Source-viewer live-bound clip mode + narrow trim-mode toggle

**Branch**: `019-source-viewer-clip-mode`
**Input**: Design documents from `/Users/joe/Local/jve-spec-kit-claude/specs/019-source-viewer-clip-mode/`
**Prerequisites**: plan.md ✓, research.md ✓, data-model.md ✓, contracts/ (7 files) ✓, quickstart.md ✓

## Format: `[ID] [P?] Description`
- **[P]**: Can run in parallel (different files, no shared edit target)
- Each task includes the exact file path(s) it touches.
- Tests precede implementation (TDD per constitution III).

## Path conventions
Single-project JVE layout. All paths absolute from repo root `/Users/joe/Local/jve-spec-kit-claude/`.

---

## Phase 3.1: Setup
*No new project init — existing codebase, no new dependencies.*

- [X] **T001** Verify branch + working tree clean: confirm on `019-source-viewer-clip-mode`, current uncommitted simple-fix from prior session (source_viewer.lua + 4 test stubs + test_source_viewer_publishes_selection.lua) is the expected baseline; do not stash or reset (Joe runs parallel sessions). Run `./tests/run_lua_tests_all.sh` once to confirm 844/844 baseline before any 019 edits. *Confirmed 2026-05-19: 844 PASSED, 0 FAILED on branch `019-source-viewer-clip-mode`.*

---

## Phase 3.2: Tests First (TDD) ⚠️ MUST COMPLETE BEFORE 3.3

**CRITICAL: every test below must be written, run, and seen to FAIL before its implementation task begins.** Per constitution III + ENGINEERING.md §2.20.

- [X] **T002 [P]** Contract test for `OverwriteTrimEdge` in `tests/test_overwrite_trim_edge.lua` — per `contracts/overwrite_trim_edge.md` Tests section. Cover all 9 scenarios (3 happy + undo round-trip + 4 precondition asserts + no-downstream-movement). Every scenario must read back state via `Clip.load` and assert the four columns (FR-015b). *Done 2026-05-19: 5 scenarios covering right-edge shrink, left-edge shrink, right-edge grow, undo round-trip, 4 precondition asserts. Read-back via direct DB SELECT (FR-015b). Verified red — `No executor registered for command type: OverwriteTrimEdge`.*

- [X] **T003 [P]** Contract test for `core/edit_mode` + `ToggleTrimMode` in `tests/test_edit_mode_toggle.lua` — per `contracts/toggle_trim_mode.md` Tests section. Cover initial state, toggle behavior, signal emission, session-transient reset, enum-guard assert. *Done 2026-05-19: 7 scenarios (initial value, flip, enum guard, signal payload, reset, command dispatch, non-undoable). Verified red — `module 'core.edit_mode' not found`.*

- [X] **T004 [P]** Contract test for `source_viewer.load_clip` in `tests/test_source_viewer_load_clip.lua` — covers mode entry, selection_hub publish (item_type="clip"), mark-setter dispatch routing on `edit_mode.get_trim_mode()` (RippleTrimEdge vs OverwriteTrimEdge with correct edge/delta/owner_seq), key-repeat suppression (FR-016b), mutation re-resolve via `sequence_content_changed` (FR-004b), auto-unload on clip deletion (FR-004a). *Done 2026-05-19: 6 scenarios. Verified red — `source_viewer.load_clip` does not exist. NOTE: scope is source_viewer's own surface; cross-module behaviors FR-016e (sequence_monitor playback range) and FR-016c (set_marks ClearMarks gate) are covered by T008b + T008c respectively.*

- [X] **T008b [P]** Failing test in `tests/test_live_bound_play_ignores_marks.lua` covering FR-016e. *Done 2026-05-19: tests `SequenceMonitor:get_playback_range()` (new accessor) via a minimal self-table bypassing the Qt widget stack. 4 scenarios (staged+marks, staged-no-marks, live-bound ignores marks, non-zero start_frame in both modes). Verified red — `get_playback_range` is nil.*

- [X] **T008c [P]** Failing test in `tests/test_clear_marks_disabled_in_live_bound.lua` covering FR-016c. Dispatch `ClearMarks` / `ClearMarkIn` / `ClearMarkOut` against `source_monitor` while `source_viewer.get_mode() == "live_bound_clip"`; assert no mutation. *Done 2026-05-19: 4 scenarios (ClearMarks/ClearMarkIn/ClearMarkOut in live-bound mode + staged-mode regression). Verified red — ClearMarks DID clear marks (expected mutation gate not yet in place; T019 will add it).*

- [ ] **T004 [P]** Contract test for `source_viewer.load_clip` in `tests/test_source_viewer_load_clip.lua` — per `contracts/source_viewer_load_clip.md` Tests section. Cover live-bound mode entry, mode flag transitions, mark-setter dispatch routing branching on `edit_mode.get_trim_mode()`, **plus the four folded sub-FR scenarios**: key-repeat suppression (FR-016b — synthesize `is_auto_repeat=true` and `false` events, assert one dispatch only), Play ignores marks (FR-016e — verify playback range = content extent in live-bound; staged stays mark-bounded), ClearMarks disabled (FR-016c — dispatch ClearMarkIn/Out/Marks in live-bound mode, assert no mutation + log event), and FR-004b mutation re-resolve (rename clip, verify title + selection_hub republish via observable state).

- [X] **T005 [P]** Contract test for `OpenClipInSourceMonitor` in `tests/test_open_clip_in_source_monitor.lua` — per `contracts/open_clip_in_source_monitor.md` Tests section. Cover happy-path dispatch (asserts `source_viewer.load_clip` was called with the right id), `undoable = false`, selection_hub publish carries `item_type="clip"`, command_manager rejects missing args. *Done 2026-05-19: 3 scenarios (happy-path dispatch, required-args enforcement for all 3 args, undoable=false no-re-invoke on undo). Verified red — `No executor registered for command type: OpenClipInSourceMonitor`.*

- [X] **T006 [P]** Contract test for browser activation router in `tests/test_browser_activation_routes_through_commands.lua` — per `contracts/open_sequence_in_source_monitor.md` + `contracts/open_sequence_in_timeline.md` Tests sections. *Done 2026-05-19: 4 scenarios (OpenSequenceInSourceMonitor dispatch, OpenSequenceInTimeline dispatch + focus, required-args enforcement on both, undoable=false). Verified red — `No executor registered for command type: OpenSequenceInSourceMonitor`. NOTE: scoped to the two `OpenSequenceIn*` commands' contracts; the activate_item router refactor + Opt+Return modifier integration belong to T018/T009 integration tests when those impl tasks land.*

- [X] **T007 [P]** Effective-source extension test in `tests/test_effective_source.lua` (EXTEND, do not rewrite existing assertions per ENGINEERING.md §2.31). Add scenarios per `contracts/effective_source_pass_through.md` Tests section: `_set_source_viewer_clip(seq, in, out)` returns triple; `_set_source_viewer_sequence(seq)` returns just seq; `_clear_source_viewer()` returns nil; browser-active-wins precedence. *Done 2026-05-19: 4 new scenarios (T18-T21) appended; existing T1-T17 assertions untouched per §2.31. Verified red — `_set_source_viewer_clip` is nil.*

- [X] **T008 [P]** Live-bound scenario extension in `tests/test_source_viewer_publishes_selection.lua` (EXTEND existing test, do not rewrite). *Done 2026-05-19: Test 4 appended exercising `source_viewer.load_clip("clip_live")` with stubbed Clip/Sequence models; asserts item_type="clip", clip_id, project_id, owner sequence_id. Verified red — `source_viewer.load_clip` is nil. First 3 staged-mode scenarios continue to pass.*

- [X] **T008d [P]** Failing test in `tests/test_timeline_double_click_dispatches_open_clip.lua` covering FR-026 + FR-027. *Done 2026-05-19: tests `M.handle_clip_double_click(view, x, y)` (new entry point Qt binding calls into) via stubbed `view.hit_test_clip`. 3 scenarios (real clip → dispatch with owner sequence_id; gap-as-clip rejected; empty space no-op). Verified red — `handle_clip_double_click` is nil. *(T008a — FR-016b key-repeat — folded into T004 since FR-016b is source_viewer's own concern.)*

**Run each new test once with no implementation behind it. Each MUST fail. Document the failure mode in commit messages.**

---

## Phase 3.3: (removed — scope-trim 2026-05-19 dropped the holding-sequence concept, so the playback-engine spike is no longer needed.)

---

## Phase 3.4: Core Implementation (ONLY after Phase 3.2 tests are red)

- [ ] **T010 [P]** New module `src/lua/core/edit_mode.lua` (per data-model.md §EditModeState + contracts/toggle_trim_mode.md). API: `get_trim_mode()`, `set_trim_mode(mode)`, `_reset_for_tests()`. Asserts enum validity (FR-009). Emits `trim_mode_changed` signal via existing `core.signals`. Module-level state. T003 MUST be red before this lands; green after.

- [ ] **T011 [P]** New command `src/lua/core/commands/toggle_trim_mode.lua` (per contracts/toggle_trim_mode.md). SPEC.args empty, `undoable = false`. Executor flips via `core/edit_mode.set_trim_mode`. T003 covers this.

- [ ] **T012 [P]** New command `src/lua/core/commands/overwrite_trim_edge.lua` (per contracts/overwrite_trim_edge.md + FR-014, FR-015, FR-015b). Same SPEC.args as `ripple_trim_edge.lua`. Executor mutates ONE clip row (source_in_frame or source_out_frame + duration_frames + sequence_start_frame on left-edge only). Own undo entry capturing those four columns. T002 MUST be red before this lands; green after.

- [ ] **T013** Modify `src/lua/ui/source_viewer.lua` (per contracts/source_viewer_load_clip.md + plan.md):
  - Add `M.load_sequence(sequence_id, opts)` as the new public API.
  - Keep `M.load_master_clip(sequence_id, opts)` as a one-line alias to `M.load_sequence` (plan.md Complexity Tracking, removed by 020).
  - Add `M.load_clip(clip_id, opts)`: load clip row + source sequence, call `monitor:load_sequence(clip.sequence_id)`, stash `live_clip_id`.
  - Add internal `mode` flag (`"neutral"`, `"staged_sequence"`, `"live_bound_clip"`); assert state invariants on transitions (data-model.md SourceViewerState).
  - Add `_on_clip_deleted` (FR-004a) and `_on_clip_mutated` (FR-004b) signal listeners. Wire to existing clip/sequence deletion + mutation signals.
  - Update `publish_loaded_sequence` to be mode-aware: `item_type="clip"` in live-bound, `item_type="sequence"` in staged.
  - Mark-setter dispatch routes to `RippleTrimEdge` or `OverwriteTrimEdge` per `edit_mode.get_trim_mode()` (FR-013).
  - Title computation per FR-016f (sentinel `clip_label`).
  - Depends on T010, T012. T004 + T008 MUST be red before this lands.

- [ ] **T014** Modify `src/lua/core/effective_source.lua` (per contracts/effective_source_pass_through.md + FR-016d):
  - Add `_source_viewer_in`, `_source_viewer_out` module-level state.
  - Add `_set_source_viewer_clip(seq_id, in, out)`, `_set_source_viewer_sequence(seq_id)`, `_clear_source_viewer()` — the three single-direction entry points.
  - Extend `get()` to return the triple when overrides present, single seq_id when not.
  - source_viewer (T013) calls these on mode transitions.
  - Depends on T013. T007 MUST be red before this lands.

- [ ] **T015 [P]** New command `src/lua/core/commands/open_clip_in_source_monitor.lua` (per contracts/open_clip_in_source_monitor.md + FR-017). SPEC.args: `clip_id`, `project_id`, `sequence_id` all required. `undoable = false`. Executor: `source_viewer.load_clip(args.clip_id)`. Depends on T013. T005 MUST be red before this lands.

- [ ] **T016 [P]** New command `src/lua/core/commands/open_sequence_in_source_monitor.lua` (per contracts/open_sequence_in_source_monitor.md + FR-018). SPEC.args: `sequence_id`, `project_id`. `undoable = false`. Executor: `source_viewer.load_sequence(args.sequence_id)`. Depends on T013. Covered by T006.

- [ ] **T017 [P]** New command `src/lua/core/commands/open_sequence_in_timeline.lua` (per contracts/open_sequence_in_timeline.md + FR-019). SPEC.args: `sequence_id`, `project_id`. `undoable = false`. Executor: `timeline_panel.load_sequence(args.sequence_id)` + `focus_manager.focus_panel("timeline")`. Covered by T006.

- [ ] **T018** Modify `src/lua/ui/project_browser.lua` (per FR-020, FR-021, FR-022):
  - `activate_item` stops calling `source_viewer.load_master_clip` / `timeline_panel.load_sequence` directly.
  - Dispatches through `command_manager.execute_interactive` to `OpenSequenceInSourceMonitor` / `OpenSequenceInTimeline` based on `item.type` + modifier state.
  - Bin branch unchanged (`focus_bin`).
  - Modifier override: Opt+Return on a clip-sequence entry routes to `OpenSequenceInSourceMonitor` (FR-022).
  - Depends on T015, T016, T017. T006 MUST be red before this lands.

- [ ] **T019** Modify `src/lua/core/commands/set_marks.lua` (per FR-016c): when `ClearMarkIn` / `ClearMarkOut` / `ClearMarks` dispatch with `panel_context="source_monitor"` AND `source_viewer.get_mode() == "live_bound_clip"`, executor returns early with `log.event("ClearMarks*: not applicable in live-bound source-viewer mode")`. Staged mode unchanged. Depends on T013. **T008c MUST be red before this lands; green after.**

- [ ] **T020** Modify `src/lua/ui/sequence_monitor.lua` (per FR-016e): playback-range computation (around line 1021-1024) branches on source_viewer mode. In live-bound mode, range = content extent (ignore marks). In staged mode, range = `[mark_in or start_frame, mark_out or total_frames)` (existing). Depends on T013. **T008b MUST be red before this lands; green after.**

- [ ] **T021** Modify `src/lua/ui/source_viewer.lua` (additive — same file as T013 but separable concern; sequential after T013): suppress Qt key-repeat per FR-016b. Mark-set key handler checks the inbound Lua event table for `is_auto_repeat == true` and drops if so; only `false` events dispatch the mark-set command. Depends on T013. T004's key-repeat scenarios MUST be red before this lands; green after.

---

## Phase 3.5: Integration

- [ ] **T022** Modify `keymaps/default.jvekeys` per FR-024 + FR-024a:
  - `Shift+F` → `OpenClipInSourceMonitor` (new line at appropriate position).
  - `Cmd+Opt+F` → `RevealInFilesystem` (moved from `Shift+F`).
  - `Opt+Return` → modifier-bound browser activation (FR-025) — exact binding shape per `keymaps/default.jvekeys` modifier syntax (verify by reading the file's existing modifier-handling block before writing).
  - Atomic single-commit edit per FR-024a (no transient state).
  - No new test file (keymap is data); T005 + T006 already exercise the bound commands' dispatch.

- [ ] **T023** Modify `src/qt_bindings/view_bindings.cpp` per FR-026:
  - Add a `MouseButtonDblClick` event handler on the timeline-clip widget OR (preferred) wire `QGraphicsScene::mouseDoubleClickEvent` to a Lua-callable signal.
  - Pure FFI per ENGINEERING.md §2.18 — no business logic in C++. Forwards the event with `(x, y, modifiers)` to a Lua handler.
  - Build clean (zero warnings per §2.4). Run `cd build && make JVEEditor -j4` to verify.

- [ ] **T024** Modify `src/lua/ui/timeline/view/timeline_view_input.lua` per FR-026, FR-027:
  - Receive the double-click event from the binding (T023).
  - Resolve the clip under the mouse via existing hit-test code.
  - Reject gap-as-clip (FR-027): log event, return false.
  - On a real clip: `command_manager.execute_interactive("OpenClipInSourceMonitor", { clip_id=..., project_id=..., sequence_id=clip.owner_sequence_id })`.
  - No-op on empty space (FR-027 second clause).
  - Depends on T015, T023. T008d MUST be red before this lands; green after.

---

## Phase 3.6: Polish

- [ ] **T025 [P]** Run `make -j4` from repo root. Expect: zero luacheck warnings (§2.4), 850+ Lua tests passing (844 baseline + the new test files from Phases 3.2 + 3.4 + 3.5), zero C++ build warnings. If any new tests are pre-existing failures or regressions, fix before claiming this task done.

- [ ] **T026 [P]** Manual validation per `quickstart.md` (all lettered scenarios A through K). For UI scenarios that require a JVE session, use `./build/bin/JVEEditor` against the dev project. Record observed behavior; any deviation from quickstart expected outcomes is a bug to fix, not a quickstart edit (§2.31 — do not change the validation script to match buggy behavior).

- [ ] **T027 [P]** Final audit pass against ENGINEERING.md + NSF + CLAUDE.md style. Cover: 1.14 fail-fast asserts (verify every executor in T010-T024 has actionable assert messages including function name + offending value); 2.5 algorithm-style functions (verify no main function mixes high-level + low-level); 2.13 no fallbacks (`rg "or 0|or \"\""` returns only legit `opts or {}` idioms); 2.15 no backward-compat (only the documented `load_master_clip` alias per Complexity Tracking); 2.20 TDD honored (each new test red before impl); 3.14 no marketing speak. Report rule → finding → fix proactively if any violations surface.

- [ ] **T028** Commit + push the full 019 landing. Squash strategy at Joe's discretion. Commit message must include `Authored-By: Joe Shapiro <joe@shapiro.net>` + `With-Help-From: Claude` (§2.8). Push to remote `019-source-viewer-clip-mode` branch. PR creation only on Joe's explicit request.

---

## Dependency graph

```
T001 (verify baseline)
   ↓
T002..T008 + T008b/c/d (10 TDD tests, all parallel, all must be red)
   ↓
   ├──→ T010 [P] (edit_mode module)        T011 [P] (toggle command)        T012 [P] (OverwriteTrimEdge)
   │       │                                     │                                 │
   │       └──────────────────┬───────────────────┘                                 │
   │                          ↓                                                    │
   │                  T013 (source_viewer.load_clip + mode + listeners) ←──────────┘
   │                          │
   │      ┌───────────────────┼──────────────────┬─────────────┬─────────────┐
   │      ↓                   ↓                  ↓             ↓             ↓
   │   T014               T015 [P]           T019           T020           T021
   │  (effective_       (OpenClipInSrc      (set_marks      (seq_monitor   (key-repeat
   │   source ext.)       Monitor)           live-bound       play-range    suppression)
   │                                          disable)        branch)
   │                          │
   │                          │      ┌──── T016 [P] (OpenSequenceInSrcMonitor)
   │                          │      ├──── T017 [P] (OpenSequenceInTimeline)
   │                          │      ↓
   │                          └──→ T018 (project_browser.activate_item router)
   │
   ├──→ T022 (keymap)
   │
   ├──→ T023 (Qt double-click binding) ──→ T024 (Lua handler + dispatch)
   │
   ↓
T025, T026, T027 (polish, parallel)
   ↓
T028 (commit + push)
```

## Parallel execution windows

**Window 1** (after T001): launch all of T002–T008 + T008b + T008c + T008d in parallel. Ten independent test files; no shared edits. (T008a — was for FR-016b key-repeat — folded into T004 since FR-016b is source_viewer's own concern. T008b/c/d remain separate because they test different modules: sequence_monitor, set_marks.lua, and the Qt double-click handler respectively.)

```
Task: "Write failing test in tests/test_overwrite_trim_edge.lua per contracts/overwrite_trim_edge.md"
Task: "Write failing test in tests/test_edit_mode_toggle.lua per contracts/toggle_trim_mode.md"
Task: "Write failing test in tests/test_source_viewer_load_clip.lua per contracts/source_viewer_load_clip.md (covers source_viewer surface: mode entry, mark-setter dispatch, FR-016b key-repeat, FR-004a/b signal handling)"
Task: "Write failing test in tests/test_open_clip_in_source_monitor.lua per contracts/open_clip_in_source_monitor.md"
Task: "Write failing test in tests/test_browser_activation_routes_through_commands.lua per contracts/open_sequence_in_*.md"
Task: "Extend tests/test_effective_source.lua per contracts/effective_source_pass_through.md"
Task: "Extend tests/test_source_viewer_publishes_selection.lua with live-bound scenario"
Task: "Write failing test in tests/test_live_bound_play_ignores_marks.lua per FR-016e (tests sequence_monitor playback range branch)"
Task: "Write failing test in tests/test_clear_marks_disabled_in_live_bound.lua per FR-016c (tests set_marks ClearMark* gate)"
Task: "Write failing test in tests/test_timeline_double_click_dispatches_open_clip.lua per FR-026 + FR-027"
```

**Window 2** (after Phase 3.2 tests are red): launch T010 + T011 + T012 in parallel. Three independent new files; no shared edits.

```
Task: "Implement src/lua/core/edit_mode.lua per data-model.md + contracts/toggle_trim_mode.md"
Task: "Implement src/lua/core/commands/toggle_trim_mode.lua per contracts/toggle_trim_mode.md"
Task: "Implement src/lua/core/commands/overwrite_trim_edge.lua per contracts/overwrite_trim_edge.md"
```

**Window 3** (after T013): launch T015 + T016 + T017 in parallel (three new command files), AND T014 + T019 + T020 + T021 in sequence (T014 modifies effective_source.lua alone; T019/20/21 modify three different existing files — can run as a second parallel wave alongside T015/16/17).

```
# Wave A (after T013):
Task: "Implement src/lua/core/commands/open_clip_in_source_monitor.lua per contracts/..."
Task: "Implement src/lua/core/commands/open_sequence_in_source_monitor.lua per contracts/..."
Task: "Implement src/lua/core/commands/open_sequence_in_timeline.lua per contracts/..."
Task: "Modify src/lua/core/effective_source.lua per FR-016d (add override channel, three entry points)"
Task: "Modify src/lua/core/commands/set_marks.lua per FR-016c"
Task: "Modify src/lua/ui/sequence_monitor.lua playback-range per FR-016e"
Task: "Add key-repeat filter to src/lua/ui/source_viewer.lua per FR-016b"
```

**Window 4** (after T015 + T016 + T017): T018 (project_browser refactor) — sequential, shared file with itself.

**Window 5** (after T018): T022 + T023 + T024 — T022 (keymap) independent of T023/T024 (Qt binding chain). T023 → T024 sequential.

**Window 6** (after T024): T025 + T026 + T027 in parallel. Final polish.

## Validation checklist

Before claiming 019 done (T028 commit):
- [ ] All Phase 3.2 tests red before their corresponding Phase 3.4 task; green after.
- [ ] T013 invariant asserts (mode transition state) cover the three-state machine in data-model.md.
- [ ] T014 override channel exposes exactly three entry points (`_set_source_viewer_clip`, `_set_source_viewer_sequence`, `_clear_source_viewer`); no other writes to the three internal fields.
- [ ] T022 keymap edit is atomic (single commit, no transient binding clash).
- [ ] `make -j4` clean, 850+ Lua tests pass.
- [ ] Quickstart scenarios A–K all pass manually.
- [ ] Audit (T027) reports zero violations or explicit justification for any deviation.

## Notes

- The `load_master_clip` alias is the ONE documented backward-compat shim in 019 (plan.md Complexity Tracking §1). It is removed by 020 in lockstep with the global rename. Do not add other compat shims.
- Spec 020 (master→media rename) is queued AFTER 019. Do not preemptively rename `master_clip` → `media_sequence` in 019's new code; 020 will sweep through.
- The in-session task list (TaskList tool) was reconciled to this file on 2026-05-19; the earlier planning-sketch entries (T1–T10 in that tool) have been deleted. Future task tracking happens here in `tasks.md`; mirror to TaskList only if useful for in-conversation visibility.
