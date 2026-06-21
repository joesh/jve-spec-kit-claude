# Research: 025-Five Timeline UX Improvements

## FR-001: Through-Edit Detection and Rendering

### Right-click hit detection
**Finding:** `timeline_view_input.lua` → `show_clip_context_menu()` currently calls `find_clip_under_cursor()`, which returns a clip or nil. No edit-point proximity detection exists.  
**Decision:** Add `find_edit_under_cursor(view, x, y, width, height)` that returns `{frame, track_id, left_clip_id, right_clip_id}` when the cursor is within `EDIT_HIT_TOLERANCE_PX` pixels of a cut boundary on any visible track, else nil. `EDIT_HIT_TOLERANCE_PX = 4` — named constant in `timeline_view_input.lua` (Rule 1.5). Right-click dispatch checks edit-point first, clip second.  
**Why 4px:** Standard NLE edit-point hit tolerance; matches FCP7 and Resolve.

### Through-edit rendering pass
**Finding:** `draw_visible_clips()` is a single forward pass over `track_clips[i]` with `i` and `#track_clips` in scope. `track_clips` is an ordered array by `sequence_start`.  
**Decision:** Collect through-edit boundary positions during the main clip-draw pass (checking `track_clips[i-1]` adjacency for each clip). After the clip pass, draw chevrons in a second micro-pass over the collected positions. This avoids a full second iteration and keeps the hot path structure intact.

### Through-edit detection logic
Both `source_out` (left clip) and `source_in` (right clip) are available from the clip data (`clip.source_in`, `clip.source_out`). `source_out` is **exclusive** (one-past-last frame; verified via `split_clip.lua` — split sets `left.source_out == right.source_in`), so contiguous means `left.source_out == right.source_in`, not off-by-one. Same-source detection uses the **master track** reference — `master_layer_track_id` (video clips) / `master_audio_track_id` (audio clips), NOT a single `master_id` (no such field). Same master *sequence* but different master track (multicam/split-channel) is NOT a through-edit. The predicate takes the shared timeline-track `kind` to pick the right field. Subframe precision: `clip.source_out_subframe` / `clip.source_in_subframe` (nil when not applicable). Spec 021 later renames these columns to `source_video_track_id` / `source_audio_track_id`; 025 uses the current names.

### Color constant
Add `THROUGH_EDIT_MARKER = "#e83030"` to `timeline_state.lua` colors table (vivid red, readable against `#548bb5` video and `#32986b` audio clip bodies, and against the `#ff8c42` selected-clip orange).

### JoinThroughEdit command — blueprint
- Args: `sequence_id` (required, injected), `edit_frame` (required), `track_id` (required).
- Persisted for undo: full `Clip.load_v13_row` snapshot of the right clip + `{source_out_frame, duration_frames}` of the left clip before mutation.
- Execute: `Clip.delete_one(right.id)` → `Clip.update_bounds(left.id, left.sequence_start, left.duration + right.duration, left.source_in, right.source_out)`.
- Mutations: `updates = {mutation_entry(left)}`, `deletes = {clip_id = right.id}`.
- Undo: re-insert right clip row (all columns from snapshot), `Clip.update_bounds(left)` to restore original bounds. Mutations: `inserts = {mutation_entry(right)}`, `updates = {mutation_entry(left)}`.
- SAVEPOINT: `"join_through_edit_atomic"`.
- `clip_markers` on right clip: reassigned to left clip during execute (same SAVEPOINT), **before** the delete — `clip_markers.clip_id` is `ON DELETE CASCADE`, so they'd be lost otherwise. Reassigned ids recorded for undo. (No keyframe table exists; nothing else to migrate.)
- Locked track: NOT asserted in the command. The menu grays the item on locked tracks; the Clip-model writes route through `track_lock_guard`, which refuses gracefully (no crash) as a backstop.

### JoinAllThroughEdits command — blueprint
- Shared detection logic with JoinThroughEdit, iterated over all tracks.
- Wraps all joins in one SAVEPOINT → single undo step.
- Collects all through-edit pairs, processes chains right-to-left (avoids ID drift from earlier deletions).

---

## FR-002: ±nnn Timecode Offset Entry

### TC field state
**Finding:** The TC `QLineEdit` already exists and already handles relative input (`+10`, `-5`, `+00:00:01:00`) via `timecode_input.parse()` with `base_time = current_playhead`. `apply_timecode_entry_text()` fires on `editing_finished`, always dispatches `SetPlayhead`.  
**Decision:** Extend `apply_timecode_entry_text()` to:  
1. Detect prefix character (`=` → absolute mode, `+`/`-` → offset mode).  
2. In offset mode, check `timeline_state.get_selected_clip_ids()` / `get_selected_edges()` (the same source the keyboard Nudge path reads — NOT `selection_hub`). If either is non-empty → dispatch `Nudge` (moves clips and edges). If both empty → dispatch `SetPlayhead` (arg `playhead_position`).  
3. In absolute mode → always `SetPlayhead` (ignore selection).

### New commands — minimal footprint
`IncrementTimecode`, `DecrementTimecode`, `GoToTimecode` are **UI-layer commands** only — they stop playback if running, then activate the TC field with the appropriate prefix character. They do not encode move logic themselves. The actual move fires from `apply_timecode_entry_text()` when the user presses Enter.

### Red border
Add a module-local `tc_entry_active` flag in `timeline_panel.lua`. When a prefix-activation command fires, set `tc_entry_active = true` and apply `build_timecode_field_stylesheet(active=true)` (border color via named constant `TC_ENTRY_ACTIVE_COLOR` — hex value chosen at implementation time, not hardcoded here per Rule 1.5). On `editing_finished` (commit or cancel), clear flag and restore normal stylesheet.

### Keybindings
`+`, `Num+` → `IncrementTimecode @timeline`; `-`, `Num-` → `DecrementTimecode @timeline`; `=` → `GoToTimecode @timeline`. All confirmed unbound in `default.jvekeys`.

---

## FR-003: JKL Shuttle Speed Algorithm

### Current implementation
`PlaybackEngine:shuttle(dir)` in `playback_engine_transport.lua`. Speed state: `self.speed` (number), `self.direction` (1 or -1). Same-direction doubles (max 8×); opposite-direction halves, stops at 1×.

### New algorithm
Replace inline speed arithmetic with two pure helper functions:

```lua
-- next speed up from current (same-direction press)
local function shuttle_step_up(speed)
    if speed < 2.0 then return speed + 0.25 end
    return speed * 2
end

-- next speed down from current (opposite-direction press); nil = stop
local function shuttle_step_down(speed)
    if speed <= 1.0 then return nil end           -- stop
    if speed <= 2.0 then return speed - 0.25 end
    return speed / 2
end
```

The `shuttle()` body replaces its current doubling/halving block with calls to these helpers. The latch-resume, slow-play (0.5×), and from-stopped logic are unchanged.

---

## FR-004: M/S Button Size

**Finding:** `HDR.SM = 16` in `timeline_panel.lua:1172`. Applied as both `SET_MIN_WIDTH` and `SET_MAX_WIDTH` on M and S buttons.  
**Decision:** Change `HDR.SM = 16` → `HDR.SM = 24`. No other changes needed; all sizing flows from this constant.

---

## FR-005: Option+Click Exclusive M/S Toggle

### Modifier detection gap
`SET_BUTTON_CLICK_HANDLER` (`signal_bindings.cpp:601`) passes zero args — no modifier info reaches Lua.

**Decision:** Add a minimal C++ binding `GET_KEYBOARD_MODIFIERS()` → `QApplication::keyboardModifiers()`. Returns `{alt=bool, shift=bool, ctrl=bool, meta=bool}` — Qt bitmask decoded in C++, no magic numbers in Lua (Rule 1.5, Rule 2.18). Safe to call synchronously from within a click handler. Register as `qt_constants.INPUT.GET_KEYBOARD_MODIFIERS`. One function, no change to the handler wire-up infrastructure.  
**Alternatives rejected:** Using `SET_WIDGET_CLICK_HANDLER` (which does pass modifiers as int bitmask) would require replacing `QAbstractButton::clicked` with a generic mouse-event filter, losing the button's press/release visual feedback and accessibility semantics. Also still exposes bitmask to Lua.

### ExclusiveToggleTrackPreference command
Non-undoable. Args: `track_id`, `property`, `project_id`, `sequence_id`.  
Executor:
1. Load clicked track. **If `track.locked` → no-op return** (graceful refusal per FR-005; no crash, no other tracks touched).
2. Compute `new_state = not track[property]`.
3. Load all tracks of same type (`VIDEO`/`AUDIO`) in the sequence.
4. Set clicked track property to `new_state`; set all others to `not new_state`.
5. Emit `track_preference_changed` for each modified track.

**Decision (resolves earlier "reuse vs direct" ambiguity):** extract a shared `core/track_preference.lua` → `set(track, property, value)` (mutate field → `track:save()` → emit), and have **both** `ToggleTrackPreference` and `ExclusiveToggleTrackPreference` call it. One write chokepoint (Rule #4 / 2.16), no recursive command dispatch. `Track:save()` is the only track-preference write path in the model (no `set_muted()` helper exists), so the shared function wraps it.

### wire_toggle_preference modification
After the modifier check is available:
```lua
local mods = qt_constants.INPUT.GET_KEYBOARD_MODIFIERS()
local cmd = mods.alt and "ExclusiveToggleTrackPreference" or "ToggleTrackPreference"
command_dispatch.execute_or_fail(cmd, {track_id = track_id, property = property, project_id = project_id}, ...)
```
`mods.alt` is a boolean from the named-field table — no Qt bitmask constants in Lua (Rule 1.5, Rule 2.18).
