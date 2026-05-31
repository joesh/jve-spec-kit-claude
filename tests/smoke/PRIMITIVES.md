# Smoke test primitives — what you can call

Reference for authoring `tests/smoke/cases/test_*.py`. Every primitive
listed here goes through real OS input or read-only state introspection —
none of them mutate JVE via direct calls.

## Real-OS input (mutators)

| Method | What it does |
|---|---|
| `self.key("Cmd+Z")` | OS keystroke (osascript) — fires QShortcut if JVE is foregrounded |
| `self.click_clip(clip_id)` | Click on the visual center of a clip on the displayed sequence |
| `self.right_click_clip(clip_id)` | Right-click for context menu |
| `self.double_click_clip(clip_id)` | Double-click (open in source viewer, etc.) |
| `self.move_playhead_to(frame)` | Click on the ruler at the pixel column for `frame` |
| `self.ensure_record_tab()` | If source tab is displayed, press Grave to swap back |
| `self.menu_pick("File > Import > Resolve Project (.drp)...")` | Click a menu item via System Events |
| `self.pick_file_in_open_dialog(path)` | After triggering an Open/Import: Cmd+Shift+G → type → Return → Return |
| `self.runner.type_text("hello")` | Type a string via osascript keystroke |
| `self.runner.click(gx, gy, right=False, double=False)` | Raw screen-coords click |
| `self.focus_panel("timeline")` | Force keyboard focus to a named panel (Lua-side; use sparingly) |

## State introspection (read-only)

All via `self.eval_*` calling into `core.debug_helpers`:

| Lua query | Returns |
|---|---|
| `require('core.debug_helpers').active_project_id()` | current project id |
| `…active_sequence_id()` | edit-target sequence id |
| `…displayed_sequence_id()` | which sequence is rendered |
| `…displayed_tab_kind()` | `"record"` / `"source"` / nil |
| `…sequence_count()` | rows in sequences |
| `…media_count()` | rows in media |
| `…clip_count_on_sequence(id)` | clips owned by sequence (via tab cache) |
| `…sequence_clip_count(id)` | clips owned by sequence (raw DB count) |
| `…displayed_clips_count()` | clips on the displayed tab |
| `…open_tabs_count()` | open tabs in the strip |
| `…mark_in()` / `mark_out()` | display marks |
| `…playhead()` | playhead frame on displayed sequence |
| `…playhead_of(seq_id)` | playhead frame on specific sequence |
| `…sequence_start_tc(seq_id)` | sequence start_timecode_frame |
| `…sequence_field(seq_id, field)` | generic Sequence column getter |
| `…selection_count()` | selected clips on displayed sequence |
| `…focused_panel()` | id of focused panel |
| `…clip_enabled(id)` | clip.enabled bool |
| `…clip_exists(id)` | true if Clip.load_optional returns row |
| `…clip_field(id, field)` | generic Clip column getter |
| `…source_viewer_mode()` | `"neutral"` / `"staged_sequence"` / `"live_bound_clip"` |
| `…source_viewer_sequence_id()` | source viewer's loaded sequence id |
| `…source_viewer_clip_id()` | source viewer's loaded clip id (live-bound) |
| `…transport_target()` | `"source"` / `"record"` |
| `…record_engine_sequence_id()` | record engine's loaded seq |
| `…source_engine_sequence_id()` | source engine's loaded seq |
| `…first_armed_video_clip([min_frames])` | `"id\|track_id\|seq_start\|duration\|rec_seq\|master_seq_id"` or `""` |
| `…clip_global_center(id)` | `"gx,gy"` for runner.click — used internally by click_clip |
| `…ruler_global_point(frame)` | `"gx,gy"` for ruler seek — used internally by move_playhead_to |

## Synchronization

```python
self.wait_for("return require('core.debug_helpers').sequence_count() >= 2",
              timeout=10.0)
```

Use after `menu_pick` for an importer — the import runs async; the
predicate is the only reliable post-condition.

## Class lifecycle (recap)

- `JVESmokeCase.setUpClass` opens ONE fresh anamnesis-template copy.
- Methods within a class share state (alphabetical order). Name methods
  `test_NN_<verb>` (zero-padded) when order matters.
- For a brand-new copy mid-class: override `setUp` and call
  `self._reset_to_template()`. Use SPARINGLY — shared state is the
  intentional cross-command contamination surface Joe wants exercised.

## Anti-patterns (will be rejected)

| Bad | Right |
|---|---|
| `self.eval("require('core.command_manager').execute('SelectClips', ...)")` | `self.click_clip(id)` |
| `self.eval("require('core.command_manager').execute('SetPlayhead', ...)")` | `self.move_playhead_to(frame)` |
| `self.eval("require('models.clip').load(id):save{enabled=false}")` | press `D` |
| `self.eval("require('ui.source_viewer').load_clip(...)")` | press `Shift+F` (after positioning playhead) |
| `package.loaded[...] = stub` | drive via real input |
| `db:exec("INSERT INTO ...")` | act on the anamnesis substrate |
| `os.exit()` in a test | `error(msg)` or `assertTrue` |
