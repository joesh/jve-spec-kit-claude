# Tasks: Two-Engine Playback Model (Source / Record)

**Input**: Design documents in `/Users/joe/Local/jve-spec-kit-claude/specs/017-refactor-playback-engine/`
**Prerequisites**: plan.md, research.md, data-model.md, contracts/{transport,engine,audio_handover}.md, quickstart.md ✓

## Format

`[T###] [P?] Description (file path)`

- **[P]** = parallelizable (different files, no dependencies on earlier same-phase tasks)
- File paths are absolute. **Convention for test files:** when a task names just `test_X.lua`, the path is `/Users/joe/Local/jve-spec-kit-claude/tests/test_X.lua` (the JVE flat-test convention). Non-test paths are always given in full.
- TDD strict: every test task MUST land red BEFORE its implementation task. "Red" verified by running `cd /Users/joe/Local/jve-spec-kit-claude/tests && luajit <file>` and observing a non-zero exit with an assert/error message that names the missing capability — not a silent skip.

---

## Phase 0: Setup & baseline

- [ ] **T001** Confirm clean working tree on branch `017-refactor-playback-engine`: `git status` shows only feature-017 spec/plan/contracts/research/quickstart/tasks files; no foreign uncommitted state belonging to a sibling Claude session. If foreign state exists, STOP and ask Joe before proceeding. **Working dir**: `/Users/joe/Local/jve-spec-kit-claude`
- [ ] **T002** Capture baseline test counts: run `./tests/run_lua_tests_all.sh` once and record `PASSED: N, FAILED: M` in `/tmp/jve_017_baseline.txt`. This is the ground truth against which post-implementation test counts are compared.
- [ ] **T003** [P] Verify all spec/plan/research/contracts/quickstart docs in `/Users/joe/Local/jve-spec-kit-claude/specs/017-refactor-playback-engine/` parse as valid markdown and contain no `[NEEDS CLARIFICATION]` markers (grep check; should return zero hits).

---

## Phase 1: Regression tests (must fail RED on master baseline)

Each test in this phase exercises a TSO 2026-05-15 bug. They MUST fail red before any implementation change lands (rule 2.20 — failing test precedes the fix).

**JVE test-file boilerplate** (mandatory for every new `.lua` test in Phases 1–3 — applying it is part of each task's exit condition, not optional):
```lua
#!/usr/bin/env luajit
-- One-sentence description: what user-observable behavior is verified.

require('test_env')              -- sets package.path, qt stubs, monotonic clock

print("=== <test_filename>.lua ===")

-- ... test body: arrange / act / assert. Uses Lua assert() with a message.
-- For pcall-checked failure paths: assert(not ok); assert(err:match("expected substring"), err).

print("✅ <test_filename>.lua passed")
```
For `--test` mode tests: the file is invoked via `./build/bin/JVEEditor --test <path>` and the same `require('test_env')` + print conventions still apply. Tests must NOT use bare `print` for logging during the body (use `--` comments or skip); rule: no bare `print` outside the title/done markers (CLAUDE.md test policy).

- [ ] **T004** [P] Write failing regression test for **FR-024 silent source-tab playback**. Black-box: load a master with audio into source slot, display Source tab in timeline panel, press Space, verify audio is audible (or — in `--test` mode — that `audio_playback.current_owner()` is `source_engine` and that audio samples are non-silent). File: `/Users/joe/Local/jve-spec-kit-claude/tests/test_pressing_space_on_source_tab_makes_sound.lua`. Runs via `--test` mode (real AOP/SSE). Verify it fails red on master.

- [ ] **T005** [P] Write failing regression test for **FR-021 F-key unhandled in timeline_monitor focus**. Focus the timeline_monitor area; simulate `F` keypress; verify `MatchFrame` command fires (observable side effect: a `[commands] EVENT: MatchFrame` log line OR a state change). File: `/Users/joe/Local/jve-spec-kit-claude/tests/test_match_frame_works_from_every_clip_selecting_focus.lua`. Verify it fails red on master (current code logs `→ unhandled key=70`).

- [ ] **T006** [P] Write failing regression test for **FR-022 ambiguous `[ticks]` log lines**. Run a session with both source and record playback; capture `[ticks]` log lines; verify every line is prefixed with `source:<8>` or `record:<8>` (regex). File: `/Users/joe/Local/jve-spec-kit-claude/tests/test_log_line_identifies_which_side_produced_it.lua`. Runs via `--test` mode. Verify it fails red on master (current logs are unprefixed).

---

## Phase 2: Contract tests (must fail RED — APIs don't exist yet)

- [ ] **T007** [P] Write **contract test for `core.playback.transport`** per `contracts/transport.md`. 10 numbered cases (init/get_target/set_user_transport/engine_for_role/engine_for_target/shutdown + coalescing). File: `/Users/joe/Local/jve-spec-kit-claude/tests/test_contract_transport.lua`. Tests pcall(require, "core.playback.transport") and expects failure or missing functions — fails red because module doesn't exist yet.

- [ ] **T008** [P] Write **contract test for refactored `PlaybackEngine`** per `contracts/engine.md`. 10 numbered cases (new(role)/load(seq_id)/play preconditions/kind-mismatch asserts/unload/log_tag set on PlaybackController). File: `/Users/joe/Local/jve-spec-kit-claude/tests/test_contract_engine.lua`. Tests fail red because: (a) `PlaybackEngine.new(role)` constructor doesn't exist, (b) `_audio_owner` still exists, (c) log_tag binding `PLAYBACK.SET_LOG_TAG` doesn't exist.

- [ ] **T009** [P] Write **contract test for audio handover** per `contracts/audio_handover.md`. 7 numbered cases (I1 no-overlap, I2 audio-before-video, video-only master, drain timeout assert, acquire failure assert, idempotent re-play, rapid swap). File: `/Users/joe/Local/jve-spec-kit-claude/tests/test_contract_audio_handover.lua`. Runs via `--test` mode with `audio_playback._test_audio_stream_tap()` introspector (which doesn't exist yet → fails red).

---

## Phase 3: Behavior tests (must fail RED — one per FR)

All tests in this phase are pure-luajit black-box tests unless noted `--test mode`. Names describe user-observable behavior, never implementation (rule 2.34). Each test MUST land red before the corresponding implementation task in Phase 5.

Group A — transport_target identity & persistence:
- [ ] **T010** [P] `test_first_open_project_defaults_to_record_side.lua` → FR-008a default. Test: fresh project with no `transport_target` key in `projects.settings`; call `transport.init(project_id)`; assert `transport.get_target() == "record"`.
- [ ] **T011** [P] `test_project_reopen_restores_last_active_side.lua` → FR-008a persistence. Test: `init` → `set_user_transport("source")` → `shutdown` → re-`init` → assert `get_target() == "source"`. Repeat for `"record"`.
- [ ] **T012** [P] `test_clicking_empty_source_viewer_still_targets_source.lua` → FR-027a. Test: source slot has no loaded sequence; simulate clicking the source viewer (call `transport.set_user_transport("source")`); assert `get_target() == "source"`; then `TogglePlay` is a no-op (no error, no state change on the parked engines).
- [ ] **T013** [P] `test_rapid_tab_switching_settles_on_last_click.lua` → FR-009a structural coalescing. **Mode: pure luajit** with `audio_playback` stubbed (or real-module loaded — handover doesn't need to physically run since `set_user_transport` never triggers it). Test: call `transport.set_user_transport("record")` then `("source")` then `("record")` then `("source")` in tight sequence (one Lua thread, no Qt yield in between); assert final `get_target() == "source"`. Stub `audio_playback.halt_current` with a counter; assert call count == 0 (no handover fired — none of the set_user_transport calls should reach the audio layer).
- [ ] **T014** [P] `test_one_question_answers_which_side_is_playing.lua` → FR-023 single accessor. Test: `transport.get_target()` returns `"source"` or `"record"` post-init; the function reads no other module state (verify by stubbing `timeline_state`, `panel_manager`, `focus_manager`, `audio_playback` to return error-throwing tables — `get_target` MUST still succeed because it doesn't consult them).
- [ ] **T015** [P] `test_focusing_browser_during_play_does_not_silence_audio.lua` → FR-009 negative. Test (`--test` mode): record-engine playing with audio; simulate focus moving to project browser (emit `focus_change` signal); assert `audio_playback.current_owner() == record_engine` still, audio stream still produces samples, `transport.get_target() == "record"` unchanged.

Group B — engine lifecycle:
- [ ] **T016** [P] `test_source_and_record_each_remember_their_own_playhead.lua` → FR-001/002/003.
- [ ] **T017** [P] `test_loading_a_new_master_stops_the_previous_one.lua` → FR-004. Test: source-engine loaded with master A at playhead 100, playing; `engine:load(master_B_id)` MUST: (a) write A's current playhead back to A's `sequences.playhead_frame` row; (b) release the audio device (`audio_playback.current_owner() == nil` between unload and rebind); (c) bind to B and park at B's saved `sequences.playhead_frame`; (d) `engine.loaded_sequence_id == master_B_id` post-load. All four assertions in one test.
- [ ] **T018** [P] `test_loading_resumes_at_last_stopped_frame.lua` → FR-006/007. Test: set `sequences.playhead_frame = 12345` for master M in DB; `engine:load(M)`; assert `engine.loaded_sequence_id == M` and the engine's current position == 12345 (read via existing position accessor, NOT via internal field).
- [ ] **T019** [P] `test_stopping_persists_playhead_for_next_open.lua` → FR-007. Test: `engine:load(M)`; advance position to 5000 via `engine:seek(5000)`; `engine:stop()`; read `sequences.playhead_frame` from DB; assert == 5000. No reliance on engine in-memory state for the assertion — read from Model.
- [ ] **T020** [P] `test_crash_during_play_recovers_within_one_second.lua` → FR-007a writeback throttle. Test (pure luajit, no real crash): drive the throttled-writeback API directly. Set `qt_monotonic_s` to a controllable stub. `engine:load(M)` parked at 0. Simulate play: advance `engine._position` to 25 (1s @ 25fps); call the throttle tick. Verify DB row updated. Advance to 50, tick within same second — verify NO additional DB write (throttle dropped it). Advance time past the 1-second window, advance position to 100, tick — verify DB write occurred and now reflects 100. The "recovers within one second" guarantee is operationalized as "the persisted playhead is at most 1 second behind the live position at any tick."
- [ ] **T021** [P] `test_picking_different_active_sequence_during_play_stops.lua` → FR-005a.
- [ ] **T022** [P] `test_picking_different_active_sequence_while_parked_swaps.lua` → FR-005b.

Group C — audio handover invariants (all `--test` mode):
- [ ] **T023** [P] `test_no_audio_dropout_when_switching_between_source_and_record.lua` → FR-012 I1.
- [ ] **T024** [P] `test_video_does_not_appear_before_audio_when_switching_sides.lua` → FR-012 I2.
- [ ] **T025** [P] `test_video_only_master_plays_with_no_sound.lua` → FR-013a.
- [ ] **T026** [P] `test_only_one_side_produces_audio_at_a_time.lua` → FR-011 single owner.

Group D — views as pure glass:
- [ ] **T027** [P] `test_source_viewer_and_source_tab_show_same_frame.lua` → FR-015 (`--test` mode).
- [ ] **T028** [P] `test_parked_side_keeps_showing_last_frame_during_other_play.lua` → FR-016 case (b) view cache.
- [ ] **T029** [P] `test_new_sequence_shows_empty_placeholder_until_played_once.lua` → FR-016 case (c).

Group E — keyboard dispatch:
- [ ] **T030** [P] `test_space_acts_on_the_side_user_just_clicked.lua` → FR-020 transport-class.
- [ ] **T031** [P] `test_arrow_keys_move_playhead_on_displayed_side_not_active_record.lua` → FR-020 movement-class. Test covers: single-frame step via arrow keys, `Home`/`End` jumps, `I` set-mark-in, `O` set-mark-out, `Alt+I` clear-mark-in, `Alt+O` clear-mark-out, `Alt+X` clear-marks, `GoToMarkIn`, `GoToMarkOut`. Every one of these MUST act on the engine indicated by `transport.get_target()` (the displayed side), NEVER on `active_sequence_id`'s engine when those differ. Per-key sub-assertions in the same test file; run all permutations of (transport_target = source OR record) × (active_sequence_id = same OR different).
- [ ] **T032** [P] `test_insert_lands_on_record_even_from_source_focus.lua` → FR-021a edit-class global.

Group F — fail-fast paths:
- [ ] **T033** [P] `test_pressing_space_with_nothing_loaded_does_nothing.lua` → FR-027 (clean no-op at command layer).

**All tests T010–T033 must fail red** on master baseline before proceeding to Phase 5.

---

## Phase 4: Test runner integration

- [ ] **T034** Confirm test harness discovers all 30 new flat-layout tests from Phases 1–3 (3 regression + 3 contract + 24 behavior). **Exit condition (binary)**: `./tests/run_lua_tests_all.sh 2>&1 | grep -cE "test_(pressing_space_on_source_tab_makes_sound|match_frame_works_from_every_clip_selecting_focus|log_line_identifies_which_side_produced_it|contract_transport|contract_engine|contract_audio_handover|first_open_project_defaults_to_record_side|project_reopen_restores_last_active_side|clicking_empty_source_viewer_still_targets_source|rapid_tab_switching_settles_on_last_click|one_question_answers_which_side_is_playing|focusing_browser_during_play_does_not_silence_audio|source_and_record_each_remember_their_own_playhead|loading_a_new_master_stops_the_previous_one|loading_resumes_at_last_stopped_frame|stopping_persists_playhead_for_next_open|crash_during_play_recovers_within_one_second|picking_different_active_sequence_during_play_stops|picking_different_active_sequence_while_parked_swaps|no_audio_dropout_when_switching_between_source_and_record|video_does_not_appear_before_audio_when_switching_sides|video_only_master_plays_with_no_sound|only_one_side_produces_audio_at_a_time|source_viewer_and_source_tab_show_same_frame|parked_side_keeps_showing_last_frame_during_other_play|new_sequence_shows_empty_placeholder_until_played_once|space_acts_on_the_side_user_just_clicked|arrow_keys_move_playhead_on_displayed_side_not_active_record|insert_lands_on_record_even_from_source_focus|pressing_space_with_nothing_loaded_does_nothing)\.lua"` returns exactly 30. If the count is less, identify which file is missing from discovery and either rename/relocate the test or extend the harness — do NOT proceed to Phase 5 until the count is 30.

- [ ] **T035** Confirm the 30 new tests added in Phases 1–3 all land RED. **Exit condition (binary)**: read `PASSED: N, FAILED: M` from `/tmp/jve_017_baseline.txt` (T002), run `./tests/run_lua_tests_all.sh`, capture the new `PASSED: N', FAILED: M'`. Assert `M' == M + 30` (every new test failed; no new test silently passed) AND `N' == N` (no regressions in pre-existing tests). Record both numbers + the asserted delta in `/tmp/jve_017_red_phase.txt`. If `M' < M + 30`, one or more new tests silently passed against master — that's a TDD bug (the test verifies behavior that's accidentally already true): inspect each suspected test, tighten the assertion until it fails red for the right reason, before advancing to Phase 5.

---

## Phase 5: Implementation — Lua

Strict dependency order: model layer → audio module → engine refactor → transport module → command layer → view layer → tab/focus wiring → persistence.

**TDD pair-completion rule** (applies to every task in Phase 5 and Phase 6): each implementation task names the specific Phase 1–3 test(s) it turns from RED to GREEN. A task is incomplete until: (1) its source edit lands; (2) `luajit tests/<named_test>.lua` (or `--test` mode invocation) exits 0 for each named test; (3) `luacheck` is clean for every edited Lua file. "I wrote the code" without "the named test now passes" is a 0.1 documentation-honesty violation — do not mark the checkbox until step (2) is observed.

**Logger-area binding rule** (applies to every Lua file edited in Phase 5): if the file emits log lines via `log.event` / `log.detail` / `log.warn` / `log.error`, it MUST bind the logger area exactly once at the top of the module via `local log = require("core.logger").for_area("<area>")`. Area choices for this feature: `"ticks"` (transport / playback hot path — playback_engine, transport, audio_playback), `"commands"` (command dispatchers in core/commands/), `"ui"` (sequence_monitor, source_viewer, timeline_panel, timeline_state, focus_manager), `"database"` (persistence helpers in core/database). No bare `print` in production code; bare `print` is permitted only inside `tests/` files at the title/done markers per CLAUDE.md.

### 5a — Audio module foundation (no callers yet)

- [ ] **T036** Refactor `/Users/joe/Local/jve-spec-kit-claude/src/lua/core/media/audio_playback.lua`. Add module-private `M._owning_engine` (initial nil). Add module-level named constants at top: `AUDIO_HALT_TIMEOUT_MS = 100`. Add public functions per `contracts/audio_handover.md`:
  - `audio_playback.current_owner() -> PlaybackEngine|nil`
  - `audio_playback.is_owner(engine) -> boolean`
  - `audio_playback.halt_current() -> nil` (no parameter; uses internal `AUDIO_HALT_TIMEOUT_MS`; asserts on timeout with elapsed + role of hung engine + its loaded_sequence_id)
  - `audio_playback.acquire_for(engine) -> nil` (reads engine.sequence; calls FFI helpers; asserts on failure)
  - `audio_playback._ffi_drain(timeout_ms) -> ok, err` (pure C++ wrapper, parameter validation only)
  - `audio_playback._ffi_acquire(rate_hz, channels) -> ok, err` (pure C++ wrapper)
  - `audio_playback._ffi_configure_silent() -> ok, err` (pure C++ wrapper)
  - `audio_playback._test_audio_stream_tap()` — registered only when `--test` mode flag set; returns recent samples tagged with `_owning_engine` for invariant tests

  **→ greens**: T009 cases 1, 6, 7 (idempotent re-play, contract-shape acquire); enables T013's halt_current call-counting stub; enables T023, T024, T025, T026 once engines call into the new functions.
- [ ] **T037** Delete from `audio_playback.lua`: any per-engine `activate_audio` / `deactivate_audio` plumbing that no longer fits the single-owner model. Run luacheck — must be clean. Run T036's contract test piece (test_contract_audio_handover.lua relevant assertions) and confirm those now pass. **→ greens**: removes dead code so T008 case 2 doesn't fail on lingering `_audio_owner` references.

### 5b — PlaybackEngine refactor

- [ ] **T038** Modify `/Users/joe/Local/jve-spec-kit-claude/src/lua/core/playback/playback_engine.lua`. Constructor signature changes to `PlaybackEngine.new(role)` where `role ∈ {"source", "record"}`. Add immutable fields `self.role`, `self._log_tag` (initialized to `role .. ":unloaded"`), `self._writeback_throttle_last_ts`. Rename `self.sequence_id` → `self.loaded_sequence_id`. Add module-level constant `LOG_TAG_ID_PREFIX_LEN = 8`. **→ greens**: T008 case 2 (`PlaybackEngine.new("source")` returns object with `role=="source"`, `loaded_sequence_id==nil`, `state=="stopped"`); T008 case 1 (`new("garbage")` asserts).
- [ ] **T039** In `playback_engine.lua`: implement `engine:load(sequence_id) -> nil` per `contracts/engine.md`. Reads playhead from Sequence Model, configures TMB + PlaybackController bounds, parks at saved playhead. Asserts: non-empty sequence_id; `Sequence.load(...)` returns non-nil; kind matches role; engine not currently playing. On entry, writes outgoing sequence's playhead back to its Model row before binding new (FR-007). Recomputes `self._log_tag = role .. ":" .. sequence_id:sub(1, LOG_TAG_ID_PREFIX_LEN)`. Pushes log tag to C++ via `qt_constants.PLAYBACK.SET_LOG_TAG(self._playback_controller, self._log_tag)` (binding from T056a). Delete the `seq.start_timecode_frame or 0` fallback. **→ greens**: T008 cases 4, 5, 6, 7, 8, 10; T017 (load-stops-previous, writes-playhead-back, rebinds, parks); T018 (resumes at saved playhead).
- [ ] **T040** In `playback_engine.lua`: implement `engine:unload() -> nil`. Writes playhead back; resets PlaybackController bounds; releases TMB; sets `loaded_sequence_id = nil`, `_log_tag = role .. ":unloaded"`. Asserts not playing. **→ greens**: T008 case 9 (double-unload asserts).
- [ ] **T041** In `playback_engine.lua`: refactor `engine:play()`. New body per `contracts/audio_handover.md` § "Engine play body": preconditions assert (with role + state + sequence id in messages); `self:_ensure_audio_ownership()`; mark playing; start transport loop. Add private helper `engine:_ensure_audio_ownership()` that consults `audio_playback.is_owner(self)` and `audio_playback.current_owner()` and calls `halt_current` then `acquire_for`. Reads must use public accessors only — never `audio_playback._owning_engine`. **→ greens**: T008 case 3 (`play()` before load asserts); enables T023, T024, T025, T026 (handover invariants), T004 (source plays with audio).
- [ ] **T042** In `playback_engine.lua`: refactor `engine:stop()`, `engine:shuttle()`, `engine:slow_play()`. Each must release audio device via `audio_playback.halt_current()` if `is_owner(self)`. Stop writes playhead to Model. Delete `self._audio_owner` field and all gated branches (`if self._audio_owner then ...`). **→ greens**: T019 (stop writes playhead to DB); contributes to T017 (audio-release on rebind).
- [ ] **T043** In `playback_engine.lua`: implement `_writeback_throttle_last_ts` cadence per FR-007a. Throttled writeback at ≤1 Hz during play/shuttle. Use `qt_monotonic_s` for the clock. Non-blocking — drop the write if same-second since last; never queue. **→ greens**: T020 (≤1s lag invariant under controlled-clock stub).
- [ ] **T044** In `playback_engine.lua`: delete `engine:activate_audio()` and `engine:deactivate_audio()`. luacheck must remain clean. **→ greens**: closes the dead-method legs in T008 (engine contract surface clean); enables T064's audit sweep to find zero residual references.

### 5c — Transport module (new)

- [ ] **T045** Create `/Users/joe/Local/jve-spec-kit-claude/src/lua/core/playback/transport.lua`. Module state: `M.source_engine`, `M.record_engine`, `M._target`, `M._project_id`. Public API per `contracts/transport.md`: `init(project_id)`, `shutdown()`, `get_target()`, `set_user_transport(role)`, `engine_for_role(role)`, `engine_for_target()`, `persist_target()`. `init` reads persisted target from `projects.settings` JSON or defaults to `"record"`; constructs both engines (one with role "source", one with role "record"). `set_user_transport` only updates `_target` — NEVER triggers handover. Every function asserts on bad input with explicit message (function name + bad value). **→ greens**: T007 cases 1–10 (transport contract); T010 (default-to-record on fresh project); T012 (empty-source-slot target=source half); T013 (structural coalescing — set_user_transport never fires handover); T014 (single accessor reads no other state).

### 5d — Command-layer routing

- [ ] **T046** Modify `/Users/joe/Local/jve-spec-kit-claude/src/lua/core/commands/playback.lua`. Delete `pick_playback_monitor` function entirely. `get_active_engine` becomes `transport.engine_for_target()`. `ensure_playback_initialized` becomes "loaded_sequence_id is non-nil on the target engine" check. `toggle_play_executor` calls `engine:play()` / `engine:stop()` on `transport.engine_for_target()`. Shuttle commands likewise. **→ greens**: T030 (Space acts on the side user just clicked); enables T004 (source-tab Space produces audio).
- [ ] **T047** Modify `/Users/joe/Local/jve-spec-kit-claude/src/lua/core/commands/playback.lua` (continued): for `TogglePlay` and shuttle commands, when target engine's `loaded_sequence_id == nil`, perform a clean no-op (FR-027) instead of routing to engine (engine would assert). **→ greens**: T033 (Space with nothing loaded is no-op); T012 (Space-no-op-from-empty-source half — completes the test that T045 starts).

### 5e — View layer (sequence_monitor, source_viewer)

- [ ] **T048** Refactor `/Users/joe/Local/jve-spec-kit-claude/src/lua/ui/sequence_monitor.lua`. SequenceMonitor no longer owns an engine. Constructor takes `{ view_id, role }`. View pulls frames from `transport.engine_for_role(self.role)`. Delete the per-monitor `self.engine` field. Connect to engine signals (`frame_delivered`, `transport_state_changed`) and re-pull state on rebind. **→ greens**: T016 (source and record each have their own playhead — views observe distinct engines); contributes to T027 (source-side views show same frame — both observe source-engine).
- [ ] **T049** Delete `resolve_output_audio_rate` helper from `sequence_monitor.lua` (FR-005, plan §3a). Engine now derives its own audio rate. **→ greens**: enables T025 (video-only master plays with no sound — clean handover path, no cross-monitor rate inheritance bug).
- [ ] **T050** Refactor `sequence_monitor.lua` `load_sequence` → it's now a view-update method (set sequence_id; rebind to whichever engine matches `self.role`; pull state). It does NOT call `engine.load` directly — that's transport's job, driven by user actions. **→ greens**: contributes to T021/T022 (active_sequence change views rebind correctly).
- [ ] **T051** Implement view-side frame cache per FR-016 case (b). On every `frame_delivered` signal where `engine.loaded_sequence_id == self.sequence_id`, update `self._cached_last_frame` and `self._cached_last_frame_for_seq`. On engine rebind-away, view continues showing the cached frame; if no cached frame exists, render the empty-state placeholder (FR-016 case c). **→ greens**: T028 (parked side keeps showing last frame); T029 (new sequence shows empty placeholder until played once).
- [ ] **T052** [P with T048–T051] Modify `/Users/joe/Local/jve-spec-kit-claude/src/lua/ui/source_viewer.lua`. `load_master_clip(clip_id)` calls `transport.engine_for_role("source"):load(master_seq_id)` and `transport.set_user_transport("source")`. Auto-opens Source tab in timeline panel (existing coupling preserved per resolved question #4). Different file from T048–T051 (`sequence_monitor.lua`), so parallelizable with them. **→ greens**: enables T004 (source plays with audio); contributes to T027 (source-side views show same frame — by ensuring source-engine is loaded with the right master).

### 5f — Tab strip + timeline_state wiring

- [ ] **T053** Modify `/Users/joe/Local/jve-spec-kit-claude/src/lua/ui/timeline/timeline_state.lua`. `switch_to_source_tab(seq_id)` calls `transport.set_user_transport("source")` at the end. `switch_to_record_tab(seq_id)` calls `transport.set_user_transport("record")` at the end. When `active_sequence_id` changes (mid-play or parked), trigger `record_engine:load(new_seq_id)` via FR-005a/005b — engine internally handles stop-if-playing + playhead-writeback. **→ greens**: T021 (active-seq change during play stops and rebinds); T022 (active-seq change while parked quiet rebind); contributes to T030 (Space targets the side just clicked).
- [ ] **T054** Modify `/Users/joe/Local/jve-spec-kit-claude/src/lua/ui/timeline/timeline_panel.lua`. Tab click handlers route to `transport.set_user_transport(...)`. The source-tab timeline view becomes a view bound to `transport.engine_for_role("source")`; the record-tab timeline view bound to `transport.engine_for_role("record")`. **→ greens**: T013 (rapid tab clicks coalesce structurally); T027 (source viewer + source-tab timeline view show same frame).

### 5g — Focus manager cleanup

- [ ] **T055** Modify `/Users/joe/Local/jve-spec-kit-claude/src/lua/ui/focus_manager.lua` (or `layout.lua` where the handler lives). Delete the entire `Signals.connect("focus_change", ...)` block that calls `source_monitor.engine:deactivate_audio()` / `timeline_monitor.engine:deactivate_audio()` / `new_mon.engine:activate_audio()`. Focus no longer affects audio ownership (FR-009). **→ greens**: T015 (focusing browser during play does not silence audio).

### 5h — C++ log tagging

- [ ] **T056a** Add the C++ binding `PLAYBACK.SET_LOG_TAG(pc, tag) -> nil`. **Locate the binding file**: `rg -lE "PLAYBACK\\.[A-Z_]+ = |register_playback" src/` — the .cpp/.mm file that already exposes other `PLAYBACK.*` constants. Do NOT assume `playback_bindings.cpp` exists; the file may be named differently (e.g., `qt_constants_playback.cpp`, `playback_bindings.mm`, inline in `main.cpp`). Add the new function in the same registration block as the existing `PLAYBACK.PLAY` / `PLAYBACK.PARK` / etc. The function takes a `PlaybackController*` userdata + a Lua string and assigns the string to `pc->m_log_tag` (which T056b adds). Parameter validation only — pure FFI, no business logic (rule 2.18). Expose under `qt_constants.PLAYBACK.SET_LOG_TAG`. **→ greens**: enables T038/T039 to call the binding without a runtime "missing function" error.

- [ ] **T056b** Add `std::string m_log_tag` member to `PlaybackController` in `/Users/joe/Local/jve-spec-kit-claude/src/playback_controller.mm` (and its header). Initialize to empty string. Provide a setter `void SetLogTag(const std::string& tag) { m_log_tag = tag; }` for the binding to call. Replace every `JVE_LOG_*(Ticks, fmt, ...)` call site INSIDE `playback_controller.mm` with the tagged variant: `JVE_LOG_*(Ticks, "%s " fmt, m_log_tag.c_str(), ...)`. Site count: confirm by `grep -cE "JVE_LOG_(EVENT|DETAIL|WARN|ERROR)\\(\\s*Ticks" src/playback_controller.mm`. **→ greens**: T009 case requiring tagged audio-stream samples (when combined with T056c); partial T006.

- [ ] **T056c** Sweep all other playback-path C++ files for `[ticks]` / `[audio]` / `[video]` log emissions. Run `rg -nE "JVE_LOG_(EVENT|DETAIL|WARN|ERROR)\\(\\s*(Ticks|Audio|Video)" src/ | grep -v playback_controller.mm`. For each hit, identify the owning C++ class (e.g., AOP, SSE, TMB, audio pump). Thread the log tag in via constructor-time injection — pass a `const std::string&` at construction; the class stores its OWN copy of the tag, NOT a back-pointer to the engine (rule 1.4: the consumer needs the string, not the engine). Per research R3, each engine instance owns its own AOP/SSE/TMB instances, so each instance gets one tag at construction. **Exit condition (binary)**: re-run the rg query and verify every remaining hit is on a tagged code path (i.e., the surrounding class has an `m_log_tag` member that's prefixed into the format string). Zero untagged playback-path lines. **→ greens**: T006 (every `[ticks]` line tagged); T009 case 1 (audio-stream tap can disambiguate samples by tag).

- [ ] **T057** Update Lua-side logger calls in `/Users/joe/Local/jve-spec-kit-claude/src/lua/core/playback/playback_engine.lua` and `/Users/joe/Local/jve-spec-kit-claude/src/lua/core/media/audio_playback.lua` for any `[ticks]` / `[audio]` lines emitted from playback code paths. Use `log.event("%s ...", self._log_tag, ...)` (engine self-tag) or `log.event("%s ...", audio_playback.current_owner()._log_tag, ...)` (audio module borrows the current owner's tag). Every line within these two files carries the tag. **Exit condition (binary)**: `rg -nE "log\\.(event|detail|warn|error)" src/lua/core/playback/playback_engine.lua src/lua/core/media/audio_playback.lua | rg -v "_log_tag"` returns zero hits. **→ greens**: T006 for Lua-emitted lines.

### 5i — Persistence

- [ ] **T058** In `transport.lua` `persist_target()`: write `_target` to `projects.settings` JSON. **First**: discover the existing project-settings API by `rg -nE "(set|get)_project_setting" src/lua/core/database.lua`. If the helper exists with signature `(project_id, key, value)`, use it. If it doesn't, the task SCOPE EXPANDS: add the helper to `database.lua` with explicit JSON merge semantics (read current `projects.settings`, parse, set the key, serialize, write — no silent overwrite of other keys; assert on parse failure per existing core.database invariants) BEFORE wiring `persist_target`. Do not paper over the gap with a parallel storage path — `projects.settings` is the canonical store. On project close, `transport.shutdown()` flushes the value. **→ greens**: T011 (project reopen restores last active side).
- [ ] **T059** Wire `transport.init(project_id)` into project-open path. Find the existing project-open handler in `src/lua/core/commands/open_project.lua` (or `core.signals "project_changed"` handlers) and add `transport.init(...)`. Wire `transport.shutdown()` into project-close path. **→ greens**: T010 (first-open project defaults to record); completes T011 (round-trip persistence).

### 5j — Keymap rewiring

- [ ] **T060** Update the keymap loader to support per-key `scope: "transport" | "global"` attribute, default `global` per research R6. **Locate the loader**: `rg -nE "loaded: '[^']+' → combo_key" src/lua/` — the file emitting those startup log lines is the loader (likely `src/lua/core/keymap_loader.lua` or similar; verify before editing). Tag the transport-class keys (Space, J, K, L, Home, End, arrow keys, K+J/K+L combos, I, O, Alt+I, Alt+O, Alt+X, GoToMarkIn, GoToMarkOut) with `scope = "transport"` in the loaded TOML/JSON keymap source (`keymaps/default.jvekeys` per CLAUDE.md). At dispatch time, transport-scope keys route through `transport.engine_for_target()` regardless of which monitor has focus; all other keys remain global (reachable from every focus context). **Also**: extend the command-dispatch layer's ambient-context injection (per CLAUDE.md memory "command_manager auto-injects sequence_id") so that movement-class commands receive the displayed sequence's id (`transport.engine_for_target().loaded_sequence_id`) rather than `active_sequence_id`. **→ greens**: T030, T031.

- [ ] **T061** Verify clip-context commands (`MatchFrame`/F, `RevealInFilesystem`/Shift+F, `FindMasterClipInBrowser`/Alt+F) and edit commands (Insert/F9, Overwrite/F10, Delete, Blade) dispatch correctly from EVERY focus context including `timeline_monitor` and source-side views. **Exit condition (binary)**: launch the editor in `--test` mode with a fixture project; simulate `focused_panel=timeline_monitor`; fire `F` (Qt key 70); assert `MatchFrame` executor was called (observable via the command log or a test hook). Repeat for Shift+F, Alt+F, F9, F10, Delete. **→ greens**: T005, T032.

---

## Phase 6: Implementation — C++

- [ ] **T062** [P] In `/Users/joe/Local/jve-spec-kit-claude/src/playback_controller.mm`, add `m_log_tag` setter binding. Re-verify all log lines emitted from playback code paths now carry the tag (search regex `\\[ticks\\]|\\[audio\\]` in test output to confirm). Tests T006 and T009-case-2 must pass.

---

## Phase 7: Migrate / delete obsolete tests

- [ ] **T063** Delete `/Users/joe/Local/jve-spec-kit-claude/tests/test_playback_routes_to_displayed_tab.lua` — exercises the deleted `pick_playback_monitor` redirect. Verify nothing else references it.
- [ ] **T064** Audit the existing test corpus for references to the deleted/renamed surface. **Sweep**: `rg -nE "_audio_owner|activate_audio\(|deactivate_audio\(|pick_playback_monitor|load_sequence\([^,]+,[^)]+\)" /Users/joe/Local/jve-spec-kit-claude/tests/`. For every hit:
  - If the test asserts on deleted behavior (e.g., that `_audio_owner` toggles on focus change), delete the assertion or the whole test if it was the sole subject.
  - If the test merely uses the old API as setup machinery, rewrite the setup to the new API (`PlaybackEngine.new(role)`, `engine:load(seq_id)`, `audio_playback.current_owner()`).
  - If the test rewrite would change what user-visible behavior it covers, leave it alone and add a NEW black-box test for the equivalent user behavior under the refactored model.

  **Exit condition (not a hint)**: `rg -nE "_audio_owner|activate_audio\(|deactivate_audio\(|pick_playback_monitor|load_sequence\([^,]+,[^)]+\)" /Users/joe/Local/jve-spec-kit-claude/tests/` returns ZERO hits AND `./tests/run_lua_tests_all.sh` passes 100% green.

---

## Phase 8: Validation

- [ ] **T065** Run `make -j4`. Must be 0 errors, 0 warnings (rule 2.4). Capture output to `/tmp/jve_017_make_output.txt`.
- [ ] **T066** Run `./tests/run_lua_tests_all.sh`. All 30 new tests from Phases 1–3 (3 regression + 3 contract + 24 behavior) must now be GREEN. Total pass count = baseline-PASSED (T002) + 30 + (any pre-existing failures resolved as side effects). Total FAILED count = 0. If any of the 30 is still red, the corresponding Phase-5 implementation task didn't satisfy its FR — do not advance to T067 until 30/30 green.
- [ ] **T067** Execute `quickstart.md` walkthrough manually on the live editor against `~/Documents/JVE Projects/anamnesis-gold-timeline.jvp`. All 14 walkthrough steps + 3 negative tests pass. Capture log output to `/tmp/jve_017_quickstart.log`. **Pre-step**: `pgrep -x JVEEditor || rm -f "$HOME/Documents/JVE Projects/anamnesis-gold-timeline.jvp-shm"`.
- [ ] **T068** Final audit pass: re-read the diff (`git diff master...HEAD --stat` then per-file) against ENGINEERING.md rules 1.4 / 1.5 / 1.9 / 1.10 / 1.14 / 2.5 / 2.6 / 2.13 / 2.15 / 2.16 / 2.17 / 2.18 / 2.20 / 2.21 / 2.32 / 2.34 / 3.0 / 3.14. Report rule → finding → fix in a `/tmp/jve_017_audit.txt` document, one section per finding. **Exit gate**: if ANY finding is non-trivial (anything stronger than a comment-wording nit), DO NOT advance to T069 — loop back to the relevant Phase-5/6/7 task, apply the fix as a new commit on this feature branch, re-run T065 and T066 (build clean + 30/30 green), then re-enter T068. The loop terminates only when an audit pass writes `/tmp/jve_017_audit.txt` containing "No rule violations found" — at which point T069 is unblocked.

---

## Phase 9: Commit & wrap

- [ ] **T069** Stage the cumulative diff with explicit file adds (NEVER `git add -A`). Verify no foreign sibling-session files included. Commit with attribution per rule 2.8: `Authored-By: Joe Shapiro <joe@shapiro.net> With-Help-From: Claude`. Commit message format: short top line `017: two-engine playback model — source / record`, body bullets per acceptance scenario, FR coverage, and ENGINEERING audit note.

---

## Dependency graph (critical paths)

```
T001 → T002 → T003  (setup)
            ↓
T004-T006 (regression tests — RED) ──┐
T007-T009 (contract tests — RED)    ─┼── T034 → T035 (runner integration + count)
T010-T033 (behavior tests — RED)    ─┘
            ↓
T036 → T037                  (audio module)
            ↓
T038 → T039 → T040 → T041 → T042 → T043 → T044   (engine refactor; all same file — sequential)
            ↓
T045                          (transport module)
            ↓
T046 → T047                   (command layer)
            ↓
T048 → T049 → T050 → T051     (view layer — sequence_monitor.lua, sequential same-file)
T052 [P with T048-T051]       (view layer — source_viewer.lua, different file)
            ↓
T053 → T054                   (tab strip + timeline_state)
            ↓
T055                          (focus manager cleanup)
            ↓
T056 → T057                   (C++ log tagging; T057 needs T056's binding)
            ↓
T058 → T059                   (persistence wiring)
            ↓
T060 → T061                   (keymap rewiring)
            ↓
T062                          (C++ verify)
            ↓
T063 → T064                   (delete obsolete tests)
            ↓
T065 → T066 → T067 → T068    (validation)
            ↓
T069                          (commit)
```

**Critical insight**: T038–T044 all modify `playback_engine.lua` and MUST be sequential — same file, no `[P]`. Same for T046–T047 (`playback.lua` commands). Same for T048–T051 (`sequence_monitor.lua`).

---

## Parallel execution examples

### Phase 1 (regression tests fail RED)
All three are different files and have no inter-dependencies:
```
Task: "T004 — Write failing regression test for FR-024 silent source-tab playback. File: tests/test_pressing_space_on_source_tab_makes_sound.lua. Verify red."
Task: "T005 — Write failing regression test for FR-021 F-key unhandled. File: tests/test_match_frame_works_from_every_clip_selecting_focus.lua. Verify red."
Task: "T006 — Write failing regression test for FR-022 untagged log lines. File: tests/test_log_line_identifies_which_side_produced_it.lua. Verify red."
```

### Phase 2 (contract tests fail RED)
All three are different files:
```
Task: "T007 — Write contract test for core.playback.transport. File: tests/test_contract_transport.lua."
Task: "T008 — Write contract test for refactored PlaybackEngine. File: tests/test_contract_engine.lua."
Task: "T009 — Write contract test for audio handover invariants. File: tests/test_contract_audio_handover.lua."
```

### Phase 3 (behavior tests fail RED)
T010–T033 are all different files. Can be launched as a single parallel batch (24 tasks). Sample of first 8:
```
Task: "T010 — Write test_first_open_project_defaults_to_record_side.lua. Verify red."
Task: "T011 — Write test_project_reopen_restores_last_active_side.lua. Verify red."
Task: "T012 — Write test_clicking_empty_source_viewer_still_targets_source.lua. Verify red."
Task: "T013 — Write test_rapid_tab_switching_settles_on_last_click.lua. Verify red."
Task: "T014 — Write test_one_question_answers_which_side_is_playing.lua. Verify red."
Task: "T015 — Write test_focusing_browser_during_play_does_not_silence_audio.lua. Verify red."
Task: "T016 — Write test_source_and_record_each_remember_their_own_playhead.lua. Verify red."
Task: "T017 — Write test_loading_a_new_master_stops_the_previous_one.lua. Verify red."
```

(Phase 5 implementation tasks are mostly sequential due to same-file constraints — see dependency graph.)

---

## Validation checklist

After completing T069:

- [ ] All 33 FRs in spec.md have at least one passing test in `tests/`.
- [ ] Every contract function in `contracts/{transport,engine,audio_handover}.md` is implemented and has a passing contract test.
- [ ] Acceptance scenarios 1–8 in spec.md pass when run manually via quickstart.md.
- [ ] Edge cases 1–8 in spec.md pass when run manually via quickstart.md.
- [ ] `make -j4` exits 0, zero warnings.
- [ ] No `[NEEDS CLARIFICATION]` / `TODO` / `FIXME` / placeholder asserts remain in 017-affected files.
- [ ] `git log --oneline master..HEAD` shows a clean linear history.

---

## Notes

- TDD strict: NEVER write implementation code before its corresponding test is shown red.
- Same-file tasks are sequential by necessity (rule: different files = `[P]`).
- C++ log tagging is split T056 (binding + macro edits) and T057 (Lua-side use of the binding) — they share semantic intent but touch different files; could be `[P]` but T057 depends on T056's binding existing.
- After each Phase-5 task, run targeted tests (NOT full suite) — per JVE memory rule "run targeted tests while iterating, full suite only at the end."
- Per rule 2.8, ONLY commit when Joe asks. T069 documents the commit shape but should not auto-execute.
- Per rule 0.1, mark T### `[x]` only after verifying the task's exit condition (test green, build clean, etc.). Do not pre-mark.
