# Tasks: 025-Five Timeline UX Improvements

**Input**: `specs/025-five-timeline-ux/plan.md`, `research.md`, `data-model.md`
**Branch**: `025-five-timeline-ux`
**Gate**: `make -j4` green before marking any FR complete

---

## Phase 3.1: Tests First (TDD) ⚠️ WRITE AND CONFIRM FAILING BEFORE PHASE 3.3

Each test must be run with `cd tests && luajit test_harness.lua synthetic/lua/test_X.lua` to confirm it FAILS before any implementation begins.

- [ ] T001 [P] Write `tests/synthetic/lua/test_shuttle_speed_ladder.lua`
  - Covers FR-003 speed ladder: verify 1.0→1.25→1.5→1.75→2.0→4.0→8.0 up sequence; verify down sequence halts at 1.0 (returns nil); verify 2.0→4.0 power-of-2 transition; use non-trivial starting speeds (1.5, 4.0, 8.0)
  - **Rule 2.32 assert paths**: exercise `PlaybackEngine:shuttle()` with invalid `dir` (e.g., 0, nil) via `pcall()`; assert the error message includes the function name and the bad value — `pcall` must return false AND the error string must be non-trivially actionable (not just "assertion failed")
  - Derives expected values from FR-003 spec, not from tracing the implementation
  - No DB setup needed — pure function test

- [ ] T002 [P] Write `tests/synthetic/lua/test_join_through_edit.lua`
  - Covers FR-001: create sequence + two tracks + adjacent clips from same master with contiguous source range; execute JoinThroughEdit; verify one clip remains with combined duration and correct source_in/source_out; verify undo restores both clips exactly; verify JoinAllThroughEdits collapses a 3-clip chain in one undo step
  - **Direct predicate tests** (once `core/through_edit.lua` exists): call `through_edit.is_through_edit()` directly with: (a) same master + contiguous → true; (b) different masters → false; (c) same master but source gap → false; (d) same master + subframe mismatch → false; (e) non-adjacent (gap between clips) → false
  - **Rule 2.32 assert paths**: use `pcall()` to test: dispatching JoinThroughEdit against a non-through-edit pair → pcall returns false AND error message contains function name + clip IDs; dispatching against a locked track → pcall returns false AND error message contains function name + track_id; dispatching with missing `edit_frame` or `track_id` → pcall returns false AND error message is actionable
  - Use non-trivial source_in values (e.g., source_in=120, source_out=240, not zero)

- [ ] T003 [P] Write `tests/synthetic/lua/test_timecode_entry_commands.lua`
  - Covers FR-002 command dispatch: execute IncrementTimecode, DecrementTimecode, GoToTimecode on a live sequence; verify each emits `tc_entry_activate` signal with the correct prefix (`"+"`, `"-"`, `"="`); use `signals` module to register a listener and capture emissions
  - **`compute_action` pure function tests** (once T011 exposes `timecode_entry.compute_action(text, selected_ids, current_frame)`): test all branches — `"=0:01:00:00"` → `{command="SetPlayhead", frame=…}`; `"+10"` with empty selection → `{command="SetPlayhead", ...}`; `"+10"` with non-empty selection → `{command="Nudge", nudge_amount=10, ...}`; `"-5"` with selection → `{command="Nudge", nudge_amount=-5, ...}`; derive frame values from TC math (30fps: 1 second = 30 frames), not from code
  - **Rule 2.32 assert paths**: `pcall()` IncrementTimecode with missing `sequence_id` → returns false AND error message contains function name; `pcall()` with missing `project_id` → same; validate messages are actionable

- [ ] T004 [P] Write `tests/synthetic/lua/test_exclusive_toggle_track_pref.lua`
  - Covers FR-005: create sequence with 3 audio tracks (A1 muted=false, A2 muted=true, A3 muted=false); execute ExclusiveToggleTrackPreference on A1 with property="muted"; verify A1 muted=true, A2 muted=false, A3 muted=false; verify undo does NOT exist (undoable=false); verify video tracks are unaffected; verify single-track-only edge case (no other tracks)
  - **Rule 2.32 assert paths**: `pcall()` with invalid `property` (e.g., `"volume"`) → returns false AND error message contains function name + the bad value; `pcall()` with missing `track_id` → returns false AND error message actionable; `pcall()` against locked track → returns false AND error message contains function name + track_id
  - Use non-trivial initial state (mixed mute states, not all-false)

---

## Phase 3.2: Data and Binding Prerequisites

These unblock multiple Phase 3.3 tasks and must complete before them.

- [ ] T005 [P] Add `THROUGH_EDIT_MARKER` color constant to `src/lua/ui/timeline/timeline_state.lua` colors table
  - Value: a vivid red that reads against `#548bb5` (video) and `#32986b` (audio) clip bodies; use `"#e83030"` as specified in research.md
  - Add as `THROUGH_EDIT_MARKER = "#e83030"` alongside existing color constants; follow the existing table format exactly

- [ ] T006 Add `GET_KEYBOARD_MODIFIERS` C++ binding to `src/qt_bindings/signal_bindings.cpp` and register in `src/qt_bindings.cpp`
  - Function signature: `int lua_get_keyboard_modifiers(lua_State* L)` — no parameters, returns `{alt=bool, shift=bool, ctrl=bool, meta=bool}` table
  - Implementation: `Qt::KeyboardModifiers mods = QApplication::keyboardModifiers(); lua_newtable(L); push alt/shift/ctrl/meta as booleans`
  - Register in `qt_bindings.cpp` under `INPUT.GET_KEYBOARD_MODIFIERS` alongside existing `INPUT.*` entries
  - No bitmask constants exposed to Lua — all decoding done in C++ (Rule 1.5, Rule 2.18)

- [ ] T007 Write `tests/integration/test_keyboard_modifiers_binding.lua` and confirm it fails, then build C++ change
  - Test: run via `./build/bin/jve.app/Contents/MacOS/jve --test tests/integration/test_keyboard_modifiers_binding.lua`; verify `qt_constants.INPUT.GET_KEYBOARD_MODIFIERS()` returns a table with boolean fields `alt`, `shift`, `ctrl`, `meta`; verify no field is nil; verify no error when called without modifiers held
  - After test confirmed failing: `cd build && make jve -j4` to build the C++ change
  - Confirm integration test passes after build

---

## Phase 3.3: Core Implementations (all [P] — different files)

⚠️ Only begin after Phase 3.1 tests are confirmed failing.

- [ ] T008 [P] Create `src/lua/core/through_edit.lua` — through-edit detection predicate
  - Export `M.is_through_edit(clip_a, clip_b)` — returns bool
  - Detection rule: same `master_id`, `clip_a.sequence_start + clip_a.duration == clip_b.sequence_start`, `clip_a.source_out == clip_b.source_in`, and subframe equality when both `source_out_subframe`/`source_in_subframe` are non-nil
  - Assert both clips are non-nil with module+callsite name in message
  - No DB access — pure computation on clip property objects
  - Module-local, returns `M`

- [ ] T009 [P] Refactor `src/lua/core/playback/playback_engine_transport.lua` — FR-003 shuttle speed ladder
  - Add module-local constants `local SHUTTLE_STEP = 0.25` and `local SHUTTLE_STEP_MAX = 2.0`
  - Add module-local `shuttle_step_up(speed)`: if speed < STEP_MAX, return `math.floor((speed + SHUTTLE_STEP) * 100 + 0.5) / 100`; else return `speed * 2`; assert speed > 0
  - Add module-local `shuttle_step_down(speed)`: if speed <= 1.0, return nil (signals stop); if speed <= STEP_MAX, return `math.floor((speed - SHUTTLE_STEP) * 100 + 0.5) / 100`; else return `speed / 2`; assert speed > 0
  - Replace the inline doubling/halving block in `PlaybackEngine:shuttle(dir)` with calls to these helpers; `nil` return from step_down triggers stop
  - Latch-resume, `was_stopped`, K+J/K+L slow-play paths are UNCHANGED

- [ ] T010 [P] Create `src/lua/core/commands/join_through_edit.lua` — JoinThroughEdit + JoinAllThroughEdits
  - Follow `blade.lua` pattern exactly: SPEC table, `M.execute()`, `M.register()`
  - **JoinThroughEdit executor**: assert `edit_frame`, `track_id`, `sequence_id`; find left clip (ends at edit_frame) + right clip (starts at edit_frame); assert both exist; assert `through_edit.is_through_edit(left, right)`; assert track not locked; SAVEPOINT `"join_through_edit_atomic"`; snapshot right clip via `Clip.load_v13_row(right.id)` + left clip's `{duration_frames, source_out_frame}`; migrate markers/keyframes from right to left (within SAVEPOINT); `Clip.delete_one(right.id)`; `Clip.update_bounds(left.id, ...)` to extend; RELEASE SAVEPOINT; `command:set_parameter("__timeline_mutations", ...)` with updates + deletes; store snapshot via `command:set_parameter("_undo_state", ...)`
  - **JoinThroughEdit undoer**: re-insert right clip row from snapshot; `Clip.update_bounds(left)` to restore original bounds; emit inverse mutations
  - **JoinAllThroughEdits**: required args `sequence_id` (injected by command_manager); scan all tracks in sequence, collect through-edit pairs, process chains right-to-left in one SAVEPOINT `"join_all_through_edits_atomic"`; single combined mutations bucket
  - Register both in commands init

- [ ] T011 [P] Create `src/lua/core/commands/timecode_entry.lua` — IncrementTimecode, DecrementTimecode, GoToTimecode + compute_action helper
  - **`M.compute_action(text, selected_ids, current_frame)`** — pure exported function (no signals, no DB): strips prefix char from `text`; if prefix `"="` → `{command="SetPlayhead", frame=parsed_absolute}`; if prefix `"+"` or `"-"` and `#selected_ids > 0` → `{command="Nudge", nudge_amount=signed_offset, selected_clip_ids=selected_ids}`; if prefix `"+"` or `"-"` and no selection → `{command="SetPlayhead", frame=current_frame + signed_offset}`; assert prefix is one of `{"+", "-", "="}` with function name in message; assert `current_frame` is not nil when needed
  - Three non-undoable commands (`SPEC.undoable = false`), each:
    1. Assert `project_id`, `sequence_id`
    2. `signals.emit("request_stop_playback")`
    3. `signals.emit("tc_entry_activate", prefix)` where prefix is `"+"`, `"-"`, `"="`
  - No move logic in the commands — actual move dispatched by `apply_timecode_entry_text()` via `compute_action`
  - Register all three in commands init; keybinding wiring comes in T018

- [ ] T012 [P] Create `src/lua/core/commands/exclusive_toggle_track_preference.lua` — ExclusiveToggleTrackPreference
  - Non-undoable (`SPEC.undoable = false`)
  - Executor: assert `track_id`, `property`, `project_id`, `sequence_id`; assert `property == "muted" or property == "soloed"`; assert clicked track's track is not locked; load clicked track; `new_state = not track[property]`; load all tracks of same type (`VIDEO`/`AUDIO`) in sequence; set clicked track property to `new_state`; set all others to `not new_state`; emit `track_preference_changed` for each modified track
  - Uses the same DB write path as `ToggleTrackPreference` (not recursive command dispatch — direct model writes for atomicity)
  - Register in commands init

---

## Phase 3.4: Renderer and Input (parallel — different files; depend on T005, T008)

- [ ] T013 [P] Add through-edit chevron rendering to `src/lua/ui/timeline/view/timeline_view_renderer.lua` (FR-001)
  - Depends on T005 (`THROUGH_EDIT_MARKER` constant in timeline_state) and T008 (`core/through_edit.lua`)
  - After the clip draw loop for each track, add `collect_through_edit_positions(track_clips)` → list of cut pixel-x positions
  - Add `draw_through_edit_chevrons_at(ctx, cut_xs, track_y, track_h, colors.THROUGH_EDIT_MARKER)` — draws two small inward-pointing triangles via `timeline.add_triangle` at each cut position
  - Detection runs only on the Record tab (skip when displayed tab is Source)
  - Both helpers are module-local; main render function reads like a high-level algorithm (ENGINEERING.md §2.5)

- [ ] T014 [P] Add edit-point hit detection and context menu to `src/lua/ui/timeline/view/timeline_view_input.lua` (FR-001)
  - Depends on T008 (`core/through_edit.lua`) and T010 (`join_through_edit.lua` commands registered)
  - Add module-local constant `local EDIT_HIT_TOLERANCE_PX = 4`
  - Add `find_edit_under_cursor(view, x, y, width, height)` → `{frame, track_id, left_clip_id, right_clip_id}` or nil; iterate visible track clip pairs, check `|cursor_x - cut_x| <= EDIT_HIT_TOLERANCE_PX` and cursor y within track vertical bounds
  - Add `show_edit_context_menu(view, edit_info)` — builds actions table with: existing left-clip actions (Reveal, Match Frame, Split, Delete…), separator, "Join Through Edit" (enabled iff `through_edit.is_through_edit(left, right)`; tooltip "Not a through-edit" when grayed), "Join All Through Edits" (always enabled)
  - In the existing right-click handler: call `find_edit_under_cursor()` first; if found → `show_edit_context_menu()`; else → existing `find_clip_under_cursor()` → `show_clip_context_menu()` (unchanged path)

---

## Phase 3.5: Panel Integration (sequential — same file: `timeline_panel.lua`)

These tasks modify the same file and must run in order.

- [ ] T015 `src/lua/ui/timeline/timeline_panel.lua` FR-004: expand M/S button size
  - Change `HDR.SM = 16` → `HDR.SM = 24` (one line; line ~1172 per research.md)
  - No other changes; width flows through `SET_MIN_WIDTH`/`SET_MAX_WIDTH` automatically
  - Visual verify: launch JVE, confirm M and S buttons are visibly wider

- [ ] T016 `src/lua/ui/timeline/timeline_panel.lua` FR-002: TC entry field activation + apply extension
  - Depends on T011 (timecode_entry commands registered and emitting `tc_entry_activate` signal)
  - Add module-local constant `local TC_ENTRY_ACTIVE_COLOR = "#cc3333"`
  - Add module-local `tc_entry_mode` flag (`nil` | `"offset"` | `"goto"`)
  - Add `build_timecode_field_stylesheet(active)` → returns normal or red-border stylesheet using `TC_ENTRY_ACTIVE_COLOR`
  - Subscribe to `tc_entry_activate` signal: insert prefix into line_edit text, set `tc_entry_mode`, apply `build_timecode_field_stylesheet(true)`, set focus on line_edit
  - Add `clear_tc_entry_mode()`: clears `tc_entry_mode`, applies `build_timecode_field_stylesheet(false)`
  - Extend `apply_timecode_entry_text()`: call `timecode_entry.compute_action(text, selection_hub.get_selected_clip_ids(sequence_id), current_frame)` → dispatch the returned `{command, args}` via `command_manager.execute`; call `clear_tc_entry_mode()` on commit or cancel; no inline prefix/selection logic here — that lives in `compute_action` (Rule 2.5)
  - Cancel path (Escape): also calls `clear_tc_entry_mode()`

- [ ] T017 `src/lua/ui/timeline/timeline_panel.lua` FR-005: wire_toggle_preference modifier check
  - Depends on T007 (C++ binding built) and T012 (ExclusiveToggleTrackPreference command registered)
  - Modify `wire_toggle_preference(btn, track_id, property, _active_color)`:
    - Inside the click handler, call `qt_constants.INPUT.GET_KEYBOARD_MODIFIERS()` → `mods`
    - `local cmd = mods.alt and "ExclusiveToggleTrackPreference" or "ToggleTrackPreference"`
    - Dispatch to the selected command with `{track_id, property, project_id}` via `command_dispatch.execute_or_fail`
  - Plain click (no Alt) → same behavior as before (backwards-compatible dispatch to ToggleTrackPreference)

---

## Phase 3.6: Keybindings

- [ ] T018 `keymaps/default.jvekeys`: add TC entry and timecode keybindings (FR-002)
  - Depends on T011 (commands registered)
  - Add under timeline context (match existing @timeline scoping):
    ```
    "Plus"    = "IncrementTimecode @timeline"
    "Num+"    = "IncrementTimecode @timeline"
    "Minus"   = "DecrementTimecode @timeline"
    "Num-"    = "DecrementTimecode @timeline"
    "Equal"   = "GoToTimecode @timeline"
    ```
  - Confirm no conflict with existing `Cmd+Plus`/`Cmd+Minus` zoom bindings (different modifier)

---

## Phase 3.7: Validation Gate

- [ ] T019 `make -j4` — full build + test suite green
  - Run from repo root: `make -j4 > /tmp/make_025.log 2>&1; grep -E "error:|FAILED|passed|failed" /tmp/make_025.log`
  - All 4 new synthetic Lua tests (T001–T004) must pass
  - T007 integration test must pass
  - No luacheck warnings on any new/modified Lua file
  - C++ compile clean

---

## Dependencies

```
T001–T004  (tests)           →  must fail before T008–T017
T005       (color constant)  →  unblocks T013
T006       (C++ binding)     →  unblocks T007, T017
T007       (build + int.test)→  unblocks T017
T008       (through_edit.lua)→  unblocks T010, T013, T014
T010       (join commands)   →  unblocks T014
T011       (TC commands)     →  unblocks T016, T018
T012       (excl.toggle cmd) →  unblocks T017
T013, T014                   →  no downstream deps (renderer/input, independent)
T015–T017  (panel changes)   →  sequential (same file), in order: T015 → T016 → T017
T018       (keybindings)     →  after T011
T019       (gate)            →  after all above
```

## Parallel Execution Groups

```
# Group 1 — Tests (run concurrently)
T001  tests/synthetic/lua/test_shuttle_speed_ladder.lua
T002  tests/synthetic/lua/test_join_through_edit.lua
T003  tests/synthetic/lua/test_timecode_entry_commands.lua
T004  tests/synthetic/lua/test_exclusive_toggle_track_pref.lua

# Group 2 — Prerequisites (run concurrently after Group 1 confirmed failing)
T005  timeline_state.lua THROUGH_EDIT_MARKER
T006  C++ GET_KEYBOARD_MODIFIERS binding

# Group 3 — Core (run concurrently after Group 2)
T008  core/through_edit.lua
T009  playback_engine_transport.lua shuttle refactor
T010  core/commands/join_through_edit.lua
T011  core/commands/timecode_entry.lua
T012  core/commands/exclusive_toggle_track_preference.lua

# Group 4 — Renderer + Input (run concurrently after T008, T010 complete)
T013  timeline_view_renderer.lua chevrons
T014  timeline_view_input.lua edit-point detection + menu

# Sequential — Panel (T015 → T016 → T017)
T015  HDR.SM 16→24
T016  TC field activation + apply extension
T017  wire_toggle_preference modifier check
```

## Validation Checklist

- [x] All test tasks precede their implementation counterparts
- [x] Parallel tasks operate on different files (no index conflicts)
- [x] Each task specifies exact file path(s)
- [x] C++ build step (T007) gates C++ binding usage in T017
- [x] Panel tasks (T015–T017) are sequential (same file)
- [x] Named constants used everywhere (no magic numbers in implementation tasks)
- [x] TDD ordering: test → confirm failing → implement → confirm passing
- [x] `make -j4` is the single validation gate (T019)
