# Tasks: 025-Five Timeline UX Improvements

**Input**: `specs/025-five-timeline-ux/plan.md`, `research.md`, `data-model.md`
**Branch**: `025-five-timeline-ux`
**Gate**: `make -j4` green before marking any FR complete

> **Field naming:** FR-001 detection (T008) uses the **current** columns `master_layer_track_id` (video) / `master_audio_track_id` (audio). Spec 021 later renames them to `source_video_track_id` / `source_audio_track_id` and sweeps 025's code with everything else — 025 does not perform the rename.

---

## Phase 3.1: Tests First (TDD) ⚠️ WRITE AND CONFIRM FAILING BEFORE PHASE 3.3

Each test must be run with `cd tests && luajit test_harness.lua synthetic/lua/test_X.lua` to confirm it FAILS before any implementation begins.

- [x] T001 [P] Write `tests/synthetic/lua/test_shuttle_speed_ladder.lua`
  - Covers FR-003 speed ladder: verify 1.0→1.25→1.5→1.75→2.0→4.0→8.0 up sequence; verify down sequence halts at 1.0 (returns nil); verify 2.0→4.0 power-of-2 transition; use non-trivial starting speeds (1.5, 4.0, 8.0)
  - **Rule 2.32 assert paths**: exercise `PlaybackEngine:shuttle()` with invalid `dir` (e.g., 0, nil) via `pcall()`; assert the error message includes the function name and the bad value — `pcall` must return false AND the error string must be non-trivially actionable (not just "assertion failed")
  - Derives expected values from FR-003 spec, not from tracing the implementation
  - No DB setup needed — pure function test

- [x] T002 [P] Write `tests/synthetic/lua/test_join_through_edit.lua`
  - Covers FR-001: create sequence + two tracks + adjacent clips from same master track with contiguous source range; execute JoinThroughEdit; verify one clip remains with combined duration and correct source_in/source_out; verify undo restores both clips exactly; verify JoinAllThroughEdits collapses a 3-clip chain in one undo step
  - **Marker migration**: give the right clip a `clip_markers` row; after join, assert the marker now belongs to the left (surviving) clip and was not lost to CASCADE; after undo, assert it is back on the (restored) right clip
  - **Direct predicate tests** (once `core/through_edit.lua` exists): call `through_edit.is_through_edit(a, b, kind)` directly with: (a) same master track + contiguous → true; (b) **different master track, same master sequence** (multicam/split-channel) → false; (c) same master track but source gap → false; (d) same master track + subframe mismatch → false; (e) non-adjacent (gap between clips) → false; (f) master-less clip (gap/generator, nil master track id) → false
  - **Rule 2.32 assert paths**: use `pcall()` to test: dispatching JoinThroughEdit against a non-through-edit pair → pcall returns false AND error message contains function name + clip IDs; dispatching with missing `edit_frame` or `track_id` → pcall returns false AND error message is actionable
  - **Locked track is a graceful refusal, NOT an assert** (decision: locked = no-op via `track_lock_guard`): dispatching JoinThroughEdit against a locked track returns a non-crashing failure (command result false / guard error string) and leaves BOTH clips unchanged — assert no mutation occurred. Do NOT assert a crash here.
  - Use non-trivial source_in values (e.g., source_in=120, source_out=240, not zero)

- [x] T003 [P] Write `tests/synthetic/lua/test_timecode_entry_commands.lua`
  - Covers FR-002 command dispatch: execute IncrementTimecode, DecrementTimecode, GoToTimecode on a live sequence; verify each emits `tc_entry_activate` signal with the correct prefix (`"+"`, `"-"`, `"="`); use `signals` module to register a listener and capture emissions
  - **`compute_action` pure function tests** (once T011 exposes `timecode_entry.compute_action(prefix, value_frames, has_selection, current_frame)` — decision B: takes already-parsed `value_frames` + a `has_selection` boolean, not raw text or selection arrays): test all branches — `("=", 1800, true)` → `{command="SetPlayhead", args.playhead_position=1800}` (1800 = 60s × 30fps, derived from TC math not code; ignores selection); `("+", 10, false, current)` → `{command="SetPlayhead", args.playhead_position=current+10}`; `("+", 10, true)` → `{command="NudgeSelection", args.direction=1, args.magnitude=10}`; `("+", 30, true)` → `magnitude=30` (1 second); `("-", -5, true)` → `{command="NudgeSelection", args.direction=-1, args.magnitude=5}`; `("-", -5, false, current)` → `playhead_position=current-5`; `("+", 0, true)` → **nil** (bare-prefix no-op); assert arg is `playhead_position` not `frame`. (TC-string→frame parsing is tested at the panel layer via `core.timecode_input`, already covered.)
  - **Rule 2.32 assert paths**: `pcall()` IncrementTimecode with missing `sequence_id` → returns false AND error message contains function name; `pcall()` with missing `project_id` → same; validate messages are actionable

- [x] T004 [P] Write `tests/synthetic/lua/test_exclusive_toggle_track_pref.lua`
  - **As-built (2026-06-21):** covers FR-005 isolate semantics for M/S/lock —
    exclusive MUTE on A1 = "mute everything except A1" (A1 un-muted, A2/A3 muted);
    re-click clears all mutes (reversible); exclusive SOLO = "solo only this";
    exclusive LOCK = "lock everything except this"; video/audio populations
    independent; undoable=false; single-track solo-isolate solos the lone track.
  - **Rule 2.32 assert paths**: `pcall()` with invalid `property` (e.g., `"volume"`) → returns false AND error message contains function name + the bad value; `pcall()` with missing `track_id` → returns false AND error message actionable
  - **Mute/Solo on a locked clicked track is a graceful no-op, NOT an assert** (decision 2): command succeeds with no effect — assert state unchanged. The LOCK gesture itself is always allowed (isolate-lock even a locked track).
  - Use non-trivial initial state (mixed mute states, not all-false)

---

## Phase 3.2: Data and Binding Prerequisites

These unblock multiple Phase 3.3 tasks and must complete before them.

- [x] T005 [P] Add `THROUGH_EDIT_MARKER` color constant to `src/lua/ui/timeline/timeline_state.lua` colors table
  - Value: a vivid red that reads against `#548bb5` (video) and `#32986b` (audio) clip bodies; use `"#e83030"` as specified in research.md
  - **As-built:** done via the 3-tier token system (no call-site hex, per the design-token rule). `ui_constants` semantic token `THROUGH_EDIT_MARKER = CORAL` (`#ff6b6b`, reads on both `#548bb5` video + `#32986b` audio bodies) → exported in `ui_constants.COLORS` → aliased `through_edit_marker = C.THROUGH_EDIT_MARKER` in `timeline_state.M.colors`; renderer reads `state_module.colors.through_edit_marker`.

- [x] T006 Add `GET_KEYBOARD_MODIFIERS` C++ binding to `src/qt_bindings/signal_bindings.cpp` and register in `src/qt_bindings.cpp`
  - Function signature: `int lua_get_keyboard_modifiers(lua_State* L)` — no parameters, returns `{alt=bool, shift=bool, ctrl=bool, meta=bool}` table
  - Implementation: `Qt::KeyboardModifiers mods = QApplication::keyboardModifiers(); lua_newtable(L); push alt/shift/ctrl/meta as booleans`
  - Register in `qt_bindings.cpp` under `INPUT.GET_KEYBOARD_MODIFIERS` alongside existing `INPUT.*` entries
  - No bitmask constants exposed to Lua — all decoding done in C++ (Rule 1.5, Rule 2.18)
  - **As-built:** binding lives in cross-platform `src/lua/qt_bindings/view_bindings.cpp` as `qt_keyboard_modifiers` (NOT signal_bindings — that file is macOS-synthetic-input only), registered in `qt_bindings.cpp`, exposed as `qt_constants.INPUT.GET_KEYBOARD_MODIFIERS`. Returns `{alt,shift,cmd,ctrl}` (named by physical key: on macOS Qt swaps Control/Meta, so `cmd`=Qt::ControlModifier, `ctrl`=Qt::MetaModifier — matches input_bindings' documented convention). `alt` is the field FR-005 consumes.

- [x] T007 Write `tests/integration/test_keyboard_modifiers_binding.lua` and confirm it fails, then build C++ change
  - Test: run via `./build/bin/jve.app/Contents/MacOS/jve --test tests/integration/test_keyboard_modifiers_binding.lua`; verify `qt_constants.INPUT.GET_KEYBOARD_MODIFIERS()` returns a table with boolean fields `alt`, `shift`, `ctrl`, `meta`; verify no field is nil; verify no error when called without modifiers held
  - After test confirmed failing: `cd build && make jve -j4` to build the C++ change
  - Confirm integration test passes after build
  - **As-built:** test at `tests/synthetic/binding/test_keyboard_modifiers_binding.lua` (binding dir, run under `--test`); pins the `{alt,shift,cmd,ctrl}` boolean contract, all false at rest. GREEN.

---

## Phase 3.3: Core Implementations (all [P] — different files)

⚠️ Only begin after Phase 3.1 tests are confirmed failing.

- [x] T008 [P] Create `src/lua/core/through_edit.lua` — through-edit detection predicate
  - Export `M.is_through_edit(clip_a, clip_b, kind)` — returns bool; `kind` is the shared timeline-track kind (`"video"`/`"audio"`)
  - Same-source identity = the kind-appropriate **master track**: `master_layer_track_id` for video, `master_audio_track_id` for audio (current column names; 021 renames later). A module-local `master_track_id(clip, kind)` helper asserts on unknown kind.
  - Master-less clips (gap/generator, nil master track id) → return false (never a through-edit) — NOT an assert (legitimate domain case)
  - Detection rule: same master track id, `clip_a.sequence_start + clip_a.duration == clip_b.sequence_start`, `clip_a.source_out == clip_b.source_in` (`source_out` is exclusive, so equality = contiguous), and subframe equality when both `source_out_subframe`/`source_in_subframe` are non-nil
  - Assert both clips are non-nil with module+callsite name in message
  - No DB access — pure computation on clip property objects
  - Module-local, returns `M`
  - **As-built correction (2026-06-21):** the master-track identity above was WRONG — `master_layer_track_id`/`master_audio_track_id` are NULL on every ordinary media clip (0 of 3603 clips across all real projects carry one), so that keying made the feature inert. Source identity is **`clip.sequence_id`** (the master sequence, the "source tape" resolved through `media_refs`→`media`); the master-layer ids are NULL-tolerant *angle* discriminators that only exclude a different **explicit** layer (multicam/split-channel). Predicate now: both `sequence_id` present + equal, master-layer match (NULL==NULL ok), flush, contiguous source, subframe. Gap/generator = nil `sequence_id` → false. Spec.md FR-001 §Detection Rule updated to match. Also fixed `split_clip.lua` dropping `master_audio_track_id` on the right half. The chevrons render vertically centered in the track band.

- [x] T009 [P] Refactor `src/lua/core/playback/playback_engine_transport.lua` — FR-003 shuttle speed ladder
  - Add module-local constants `local SHUTTLE_STEP = 0.25` and `local SHUTTLE_STEP_MAX = 2.0`
  - Add module-local `shuttle_step_up(speed)`: if speed < STEP_MAX, return `math.floor((speed + SHUTTLE_STEP) * 100 + 0.5) / 100`; else return `speed * 2`; assert speed > 0
  - Add module-local `shuttle_step_down(speed)`: if speed <= 1.0, return nil (signals stop); if speed <= STEP_MAX, return `math.floor((speed - SHUTTLE_STEP) * 100 + 0.5) / 100`; else return `speed / 2`; assert speed > 0
  - Replace the inline doubling/halving block in `PlaybackEngine:shuttle(dir)` with calls to these helpers; `nil` return from step_down triggers stop
  - Latch-resume, `was_stopped`, K+J/K+L slow-play paths are UNCHANGED
  - **As-built:** the ladder math was extracted into a reusable pure module `src/lua/core/playback/shuttle_ladder.lua` (`step_up`/`step_down`, nil=stop) rather than module-local helpers — `playback_engine_transport.lua:shuttle()` delegates to it; `playback_engine.lua:get_status()` formats quarter-step rungs (1.25/1.75). All ladder values are exact in IEEE-754 (multiples of 0.25 below 2×, powers of two above) so no rounding is needed.

- [x] T010 [P] Create `src/lua/core/commands/join_through_edit.lua` — JoinThroughEdit + JoinAllThroughEdits
  - Follow `blade.lua` pattern exactly: SPEC table, `M.execute()`, `M.register()`
  - **JoinThroughEdit executor**: assert `edit_frame`, `track_id`, `sequence_id`; load `track_id` → derive `kind`; find left clip (ends at edit_frame) + right clip (starts at edit_frame); assert both exist; assert `through_edit.is_through_edit(left, right, kind)`; **do NOT assert track-unlocked** — the menu grays locked tracks and the Clip-model writes route through `track_lock_guard` (graceful refusal, no crash); SAVEPOINT `"join_through_edit_atomic"`; snapshot right clip via `Clip.load_v13_row(right.id)` + left clip's `{duration_frames, source_out_frame}` + the right clip's `clip_markers` ids; reassign right clip's `clip_markers.clip_id` → `left.id` **before delete** (within SAVEPOINT; no keyframe table exists); `Clip.delete_one(right.id)`; `Clip.update_bounds(left.id, ...)` to extend; RELEASE SAVEPOINT; `command:set_parameter("__timeline_mutations", ...)` with updates + deletes; store snapshot (incl. `migrated_marker_ids`) via `command:set_parameter("_undo_state", ...)`
  - **JoinThroughEdit undoer**: re-insert right clip row from snapshot; reassign `migrated_marker_ids` back to the right clip; `Clip.update_bounds(left)` to restore original bounds; emit inverse mutations
  - **JoinAllThroughEdits**: required args `sequence_id` (injected by command_manager); scan all tracks in sequence, collect through-edit pairs (passing each track's `kind` to the predicate), **skip locked tracks**, process chains right-to-left in one SAVEPOINT `"join_all_through_edits_atomic"`; single combined mutations bucket
  - Register both in commands init
  - **As-built:** mirrors `split_clip.lua` (its inverse), not blade.lua. JoinThroughEdit takes `clip_id` = the LEFT clip and derives the flush right neighbor (the edit point uniquely identifies the pair); JoinAll takes only `sequence_id`. Undo persists `records`; each record restores the right clip via `Clip.capture/restore_v13_state` (row + channel overrides + link group) PLUS grade (`ClipGrade.copy_to`) and markers (`ClipMarker.reassign` by id, frame shifted by the left clip's pre-join duration). Multi-command module registered style-B; aliases in `command_registry`, `join_through_edit` added to `command_implementations`.

- [x] T011 [P] Create `src/lua/core/commands/timecode_entry.lua` — IncrementTimecode, DecrementTimecode, GoToTimecode + compute_action helper
  - **`M.compute_action(prefix, value_frames, has_selection, current_frame)`** — pure exported function (no signals, no DB, **no parsing**). Per the interactive decision **B** (panel pre-parses with `core.timecode_input`, which resolves fps + sign; this stays fps-free): the panel passes `prefix` ∈ `{"+","-","="}`, an already-resolved integer `value_frames` (for `"="` the ABSOLUTE target frame; for `"+"`/`"-"` the SIGNED offset in frames), and a `has_selection` boolean (panel computes it from `timeline_state.get_selected_clips()` / `get_selected_edges()` — note the real accessor is `get_selected_clips`, returning clip OBJECTS; there is no `get_selected_clip_ids`). Branches: prefix `"="` → `{command="SetPlayhead", args={playhead_position=value_frames}}`; prefix `"+"`/`"-"` and `has_selection` → `{command="NudgeSelection", args={direction=±1, magnitude=abs(value_frames)}}` (the canonical selection-aware dispatcher comma/period use — it reads the live selection itself and routes edges→`BatchRippleEdit` (ripple) / clips→`Nudge`, owning undo; we do NOT re-extract clip ids or hand `Nudge` raw edges); prefix `"+"`/`"-"` and **not** `has_selection` → `{command="SetPlayhead", args={playhead_position=current_frame + value_frames}}`. Bare `"+"`/`"-"` (value_frames == 0) over a selection returns **nil** (no-op — NudgeSelection requires positive magnitude). Assert prefix valid (function name in message); assert `value_frames` integer; assert `has_selection` boolean; assert `current_frame` not nil for the relative-no-selection branch. **Arg name is `playhead_position` (not `frame`)** — verified against `set_playhead.lua`. (The TC-string→frame math, incl. `+00:00:01:00`@30fps=30, lives in the panel's `core.timecode_input.parse` call — already a tested utility — NOT here.)
  - Three non-undoable commands (`SPEC.undoable = false`), each:
    1. Assert `project_id`, `sequence_id`
    2. `signals.emit("request_stop_playback")`
    3. `signals.emit("tc_entry_activate", prefix)` where prefix is `"+"`, `"-"`, `"="`
  - No move logic in the commands — actual move dispatched by `apply_timecode_entry_text()` via `compute_action`
  - Register all three in commands init; keybinding wiring comes in T018

- [x] T012a [P] Create `src/lua/core/track_preference.lua` — shared write chokepoint (DRY, Rule #4 / 2.16)
  - Export `M.set(track, property, value)`: `track[property] = value`; `assert(track:save(), ...)`; `signals.emit("track_preference_changed", {track_id, property})`
  - Refactor `src/lua/core/commands/toggle_track_preference.lua` to call `track_preference.set` for its per-track write (behavior unchanged; its existing regression test guards the refactor — Rule 2.31)

- [x] T012 [P] Create `src/lua/core/commands/exclusive_toggle_track_preference.lua` — ExclusiveToggleTrackPreference
  - Depends on T012a (shared `track_preference.set`)
  - Non-undoable (`SPEC.undoable = false`)
  - **As-built (2026-06-21):** executor asserts `track_id`/`property`/`project_id`/`sequence_id` and `ISOLATE_TARGET[property] ~= nil` (property ∈ {muted, soloed, locked}). Per-property isolate target — `{soloed=true, muted=false, locked=false}` — so clicked→target, others→`not target` ("solo only this" / "mute|lock everything except this"). If already isolated (clicked==target AND every other==`not target`, compared via a `flag()` 0/1↔bool normalizer), clear the whole population to false (reversible). **Mute/Solo on a locked clicked track → no-op return**; the **lock** gesture is always allowed. Writes via shared `track_preference.set`. NB: `is_already_isolated` uses explicit if/else (not `cond and target or …`, which mis-evaluates when target is false).
  - Direct model writes via the shared helper (not recursive command dispatch — atomic, no nested command_manager invocations)
  - Register in commands init

---

## Phase 3.4: Renderer and Input (parallel — different files; depend on T005, T008)

- [x] T013 [P] Add through-edit chevron rendering to `src/lua/ui/timeline/view/timeline_view_renderer.lua` (FR-001)
  - Depends on T005 (`THROUGH_EDIT_MARKER` constant in timeline_state) and T008 (`core/through_edit.lua`)
  - After the clip draw loop for each track, add `collect_through_edit_positions(track_clips, track_kind)` → list of cut pixel-x positions (passes the track's kind to `is_through_edit`)
  - Add `draw_through_edit_chevrons_at(ctx, cut_xs, track_y, track_h, colors.THROUGH_EDIT_MARKER)` — draws two small inward-pointing triangles via `timeline.add_triangle` at each cut position
  - Detection runs only on the Record tab (skip when displayed tab is Source)
  - Both helpers are module-local; main render function reads like a high-level algorithm (ENGINEERING.md §2.5)

- [x] T014 [P] Add edit-point hit detection and context menu to `src/lua/ui/timeline/view/timeline_view_input.lua` (FR-001)
  - Depends on T008 (`core/through_edit.lua`) and T010 (`join_through_edit.lua` commands registered)
  - Add module-local constant `local EDIT_HIT_TOLERANCE_PX = 4`
  - Add `find_edit_under_cursor(view, x, y, width, height)` → `{frame, track_id, left_clip_id, right_clip_id}` or nil; iterate visible track clip pairs, check `|cursor_x - cut_x| <= EDIT_HIT_TOLERANCE_PX` and cursor y within track vertical bounds
  - Add `show_edit_context_menu(view, edit_info)` — builds actions table with: existing left-clip actions (Reveal, Match Frame, Split, Delete…), separator, "Join Through Edit" (enabled iff `through_edit.is_through_edit(left, right, kind)` **and the track is unlocked**; tooltip "Not a through-edit" or "Track is locked" when grayed), "Join All Through Edits" (enabled when at least one joinable/unlocked through-edit exists in the sequence)
  - In the existing right-click handler: call `find_edit_under_cursor()` first; if found → `show_edit_context_menu()`; else → existing `find_clip_under_cursor()` → `show_clip_context_menu()` (unchanged path)
  - **As-built:** `find_edit_point_at_cursor` reuses the existing edge-trim hit test (`pick_edges_for_track` → `edge_picker` boundary within `EDGE_ZONE_PX`, both sides non-gap) — no new tolerance constant. Enablement is pure + unit-tested: `M.join_one_state` (locked → 'Track is locked'; not-through-edit → 'Not a through-edit') and `M.any_through_edit_joinable`. Disabled-item tooltips via `qt_constants.PROPERTIES.SET_TOOLTIP`.
  - **As-built revision (2026-06-21, Joe):** the original "append the two Join items to the clip menu" was WRONG — right-clicking an edit selected one of the adjacent clips and showed the clip menu. A right-clicked edit is now its OWN gesture: detected FIRST in the right-click branch, it shows a dedicated `show_edit_context_menu` (Join Through Edit + Join All only) and does NOT select/act on a clip. Clip menu only when the cursor is not on an edit point. Popup plumbing factored into shared `resolve_popup_xy` + `present_actions_menu` helpers. PLUS: select-an-edit-and-Delete now joins (see T014b below).

- [x] T014b Select-an-edit + Delete → JoinThroughEdit (FR-001 §Select-and-Delete; added 2026-06-21, Joe) — `src/lua/core/commands/delete_selection.lua`
  - Conventional NLE through-edit removal: select the cut (roll, both sides) and press Delete. New `join_selected_through_edit` helper in the `DeleteSelection` priority chain (after mark-range, before clip/gap delete): reads `get_selected_edges()`, recognizes a single roll cut (exactly two `trim_type=="roll"` edges, one `out` + one `in`), finds the LEFT clip (the `out` edge), gates on `through_edit.is_through_edit(left, right, kind)`, and dispatches one undoable `JoinThroughEdit`. A roll over a genuine cut falls through untouched (the predicate gate keeps it away from JoinThroughEdit's assert). Both Delete and Shift+Delete join. TDD `test_delete_joins_through_edit.lua` (join + undo + genuine-cut-untouched).

---

## Phase 3.5: Panel Integration (sequential — same file: `timeline_panel.lua`)

These tasks modify the same file and must run in order.

- [x] T015 `src/lua/ui/timeline/timeline_panel.lua` FR-004: expand M/S button size
  - Changed `HDR.SM = 16` → `HDR.SM = 24`; width flows through `SET_MIN_WIDTH`/`SET_MAX_WIDTH`
  - Test hook `get_track_header_layout_for_test` now reports `sm_width` so the
    click-zone width is black-box assertable without coupling to private Qt state
  - Regression test: `tests/synthetic/binding/test_025_sm_button_click_zone.lua`
    (spec-derived `sm_width >= 24` on both a video and an audio row; verified RED
    at 16, GREEN at 24). Existing header layout/alignment tests unaffected.
  - **As-built revision (2026-06-21, Joe) — FINAL:** the buttons are stacked
    top/bottom, so the easy miss is VERTICAL, not horizontal, and widening them is
    explicitly unwanted. Two wrong turns first (both reverted): (1) widening to
    24px — wrong axis, "didn't want them wider"; (2) a QSS `margin` and then a
    transparent **halo** wrapper — the margin is dead on a QPushButton, and the
    halo's bare `QWidget` didn't paint its region → graphic artifacts. CORRECT
    FIX: ordinary QPushButtons, width kept compact (`HDR.SM=16`, NOT widened), but
    given `SET_WIDGET_SIZE_POLICY("Fixed","Expanding")` so the VBox splits the full
    header height 50/50 — M = top half, S = bottom half, each a big vertical click
    target. `sm_container` is also `Expanding` vertically so it fills the header.
    No halo, no artifacts; visible button == click zone (a plain QPushButton).
    `build_sm_button()` helper; snapshot reports `sm_width` (compact); test asserts
    `sm_width <= 16` (no widget-height getter exists, so the vertical fill is a
    visual check). Spec FR-004 reworded: enlarge vertically, never widen.

- [x] T016 `src/lua/ui/timeline/timeline_panel.lua` FR-002: TC entry field activation + apply extension
  - Depends on T011 (timecode_entry commands registered and emitting `tc_entry_activate` signal)
  - **As-built (reconciled with decision B — the pre-decision-B prose below was abandoned):**
  - Entry-mode border uses the new `STATE_ENTRY` semantic token in `ui_constants` (red), NOT a call-site hex constant. `build_timecode_field_stylesheet(entry_active)` paints the red border (field + focus) when `entry_active`, else the normal hairline/focus colors.
  - Transient state is a single `timecode_entry.entry_active` boolean (no `"offset"`/`"goto"` mode enum). `enter_timecode_entry_mode(prefix)` prefills the prefix, paints the red border, focuses the field; re-arming while already active swaps the leading prefix char without stacking. `exit_timecode_entry_mode()` drops the border.
  - Subscribe to `tc_entry_activate` → `enter_timecode_entry_mode(prefix)` (commands emit; the view arms — MVC).
  - `apply_timecode_entry_text()`: `resolve_timecode_offset(raw)` → `(prefix, value_frames, current_frame)` (delegates TC parse to `core.timecode_input`); compute `has_selection = #get_selected_clips() > 0 or #get_selected_edges() > 0`; `compute_action(prefix, value_frames, has_selection, current_frame)`; dispatch the returned `{command, args}` via `command_manager.execute_interactive` (merging `project_id`/`sequence_id`); `exit_timecode_entry_mode()`. No inline prefix/selection logic (Rule 2.5). Accessors are `get_selected_clips()` (clip objects) / `get_selected_edges()` — NOT the nonexistent `get_selected_clip_ids`, NOT `selection_hub`.
  - Cancel path (Escape) `M.cancel_timecode_entry`: also calls `exit_timecode_entry_mode()`.
  - Added `M.is_timecode_entry_active()` accessor so the L3 keymap smoke can assert the field armed before typing.

- [x] T017 `src/lua/ui/timeline/timeline_panel.lua` FR-005: wire_toggle_preference modifier check
  - Depends on T007 (C++ binding built) and T012 (ExclusiveToggleTrackPreference command registered)
  - Modify `wire_toggle_preference(btn, track_id, property, _active_color)`:
    - Inside the click handler, call `qt_constants.INPUT.GET_KEYBOARD_MODIFIERS()` → `mods`
    - `local cmd = mods.alt and "ExclusiveToggleTrackPreference" or "ToggleTrackPreference"`
    - Dispatch to the selected command with `{track_id, property, project_id}` via `command_dispatch.execute_or_fail`
  - Plain click (no Alt) → same behavior as before (backwards-compatible dispatch to ToggleTrackPreference)

---

## Phase 3.6: Keybindings

- [x] T018 `keymaps/default.jvekeys`: add TC entry and timecode keybindings (FR-002)
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

- [x] T019 `make -j4` — full build + test suite green
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
T012a      (track_preference)→  unblocks T012
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
T012a core/track_preference.lua + toggle_track_preference.lua refactor
T012  core/commands/exclusive_toggle_track_preference.lua   (after T012a)

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
