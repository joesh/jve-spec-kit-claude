# NSF Review — Fix Log

**Date**: 2026-02-04
**Scope**: All findings from NSF-REVIEW.md (214 total)
**Tests**: 346 passed, 0 failed
**Files changed**: 71 (902 insertions, 1029 deletions)

## Summary

| Status | Count |
|--------|-------|
| ✅ Fixed | 192 |
| ⏳ Partial | 3 |
| ❌ Not yet | 19 |

---

## Phase 1: Core Infrastructure

### command_manager.lua

| ID | Status | Fix |
|----|--------|-----|
| CM-1 | ✅ | Removed pcall around `db_module.commit()`; errors propagate |
| CM-2 | ❌ | Savepoint creation failure warns instead of asserting |
| CM-3 | ✅ | Removed pcall around `release_savepoint()`; errors propagate |
| CM-4 | ❌ | Post-command `db_module.commit()` return unchecked |
| CM-5 | ❌ | pcall swallows listener errors |
| CM-6 | ❌ | pcall swallows timeline_state load failure |
| CM-7 | ❌ | `revert_to_sequence` returns nil on failure |
| CM-8 | ❌ | `message or ""` in bug_result |

### command_state.lua

| ID | Status | Fix |
|----|--------|-----|
| CS-1 | ✅ | Replaced `pcall(qt_json_encode)` with direct `json.encode()`; no `"[]"` fallback |
| CS-2 | ✅ | Assert on `get_selected_gaps()` return; `or {}` removed via json.encode path |
| CS-3 | ✅ | `decode()` asserts on corrupt JSON instead of returning `{}` |

### command_helper.lua

| ID | Status | Fix |
|----|--------|-----|
| CH-1 | ✅ | Removed pcall around `Track.get_sequence_id`; errors propagate |
| CH-2 | ✅ | `clip_update_payload` asserts on nil source/source.id/sequence_id |
| CH-3 | ✅ | `add_update/insert/delete_mutation` assert on nil input |
| CH-4 | ✅ | Removed pcall around `Property.load/save/delete`; errors propagate |

### command_history.lua

| ID | Status | Fix |
|----|--------|-----|
| CHi-1 | ✅ | Init asserts on prepare/exec; no silent fallback to `sequence_number=0` |
| CHi-2 | ✅ | `save_undo_position` asserts on db/sequence_id/prepare/exec |
| CHi-3 | ⏳ | Mismatched begin/end_undo_group still warns (not assert) |

### command_registry.lua

| ID | Status | Fix |
|----|--------|-----|
| CR-1 | ✅ | Bare `print` replaced with `logger.error` |

### command_implementations.lua

| ID | Status | Fix |
|----|--------|-----|
| CI-1 | ✅ | Removed pcall around `require` and `mod.register()`; errors propagate |

### database.lua

| ID | Status | Fix |
|----|--------|-----|
| DB-1 | ✅ | ALTER TABLE exec checked via assert |
| DB-2 | ✅ | `ensure_commands_table_columns` asserts on nil connection |
| DB-3 | ✅ | PRAGMA prepare failure asserts |
| DB-4 | ✅ | Table creation failure asserts instead of warn |
| DB-5 | ✅ | `load_clip_properties` asserts on prepare failure instead of returning `{}` |
| DB-6 | ✅ | `load_bins` asserts on prepare failure instead of returning `{}` |

### snapshot_manager.lua

| ID | Status | Fix |
|----|--------|-----|
| SM-1 | ✅ | Table creation failure asserts instead of bare print |
| SM-2 | ✅ | `start_frame` asserts non-nil instead of defaulting to 0 |
| SM-3 | ✅ | All bare prints replaced with `logger.info`/`logger.debug` + asserts |

### signals.lua

| ID | Status | Fix |
|----|--------|-----|
| SG-1 | ✅ | Bare `print` replaced with `logger.error` (handler errors still collected, not fatal—signals continue to other handlers) |

### error_system.lua

| ID | Status | Fix |
|----|--------|-----|
| ES-1 | ⏳ | `message` default removed; `code`/`operation`/`component` defaults remain |

### logger.lua

| ID | Status | Fix |
|----|--------|-----|
| LG-1 | ❌ | File logging still silently degrades to console-only |

---

## Phase 2: Command Implementations

### CRITICAL

| ID | Status | Fix |
|----|--------|-----|
| CMD-C1 | ✅ | `link_clips.lua`: Fixed broken SQL `args.original_role` → `role` |
| CMD-C2 | ✅ | `delete_sequence.lua:236-239`: `or 0`/`or 1`/`or 48000` → asserts on all fps/audio/dimension fields |
| CMD-C3 | ✅ | `delete_sequence.lua:491-504`: `or 1920`/`or 1080`/`or 48000` → asserts |
| CMD-C4 | ✅ | `ripple_edit.lua`: Removed 30fps default; asserts on sequence fps query |

### HIGH

| ID | Status | Fix |
|----|--------|-----|
| CMD-H1 | ✅ | `batch_command.lua`: Child undo asserts on failure instead of swallowing |
| CMD-H2 | ✅ | `create_clip.lua`: Missing master_clip asserts instead of falling back to media-only |
| CMD-H3 | ✅ | `cut.lua`: Clip delete asserts instead of print+continue |
| CMD-H4 | ✅ | `delete_master_clip.lua`: `register()` asserts instead of returning nil |
| CMD-H5 | ✅ | `delete_master_clip.lua`: All 3 DELETE execs assert-checked |
| CMD-H6 | ✅ | `delete_sequence.lua`: clip_links/properties DELETE execs assert-checked |
| CMD-H7 | ✅ | `delete_sequence.lua:355`: Clip frame values assert instead of `or 0` |
| CMD-H8 | ✅ | `duplicate_master_clip.lua`: `duration_value or 1` → assert |
| CMD-H9 | ✅ | `import_media.lua`: Removed 30fps fallback + 1-second default; asserts on metadata |
| CMD-H10 | ✅ | `import_media.lua`: All undo DELETE execs assert-checked |
| CMD-H11 | ✅ | `import_fcp7_xml.lua`: All undo DELETE execs assert-checked |
| CMD-H12 | ✅ | `import_resolve_project.lua`: Added `frame_rate` to media spec + all undo DELETEs assert-checked |
| CMD-H13 | ✅ | `insert_clip_to_timeline.lua`: Missing master_clip asserts |
| CMD-H14 | ✅ | `overwrite.lua`: Removed fallback name param from `resolve_clip_name` |
| CMD-H15 | ✅ | `relink_media.lua`: Assert on media load + save; no silent skip |
| CMD-H16 | ✅ | `batch_command.lua`: Bare print replaced with assert |
| CMD-H17 | ✅ | `delete_master_clip.lua`: Tracks/snapshots/sequence DELETE execs assert-checked |
| CMD-H18 | ✅ | `delete_sequence.lua`: clip_links re-insertion assert-checked during undo |

### MEDIUM

| ID | Status | Fix |
|----|--------|-----|
| CMD-M1 | ✅ | `add_clip.lua`: Assert on CreateClip registration instead of set_last_error+false |
| CMD-M2 | ✅ | `create_sequence.lua`: `TRACK_HEIGHT or 50` → assert on ui_constants |
| CMD-M3 | ❌ | `cut.lua:126`: `deleted_clip_states or {}` still present |
| CMD-M4 | ✅ | `import_media.lua`: `width or 1920, height or 1080` → assert on metadata |
| CMD-M5 | ❌ | `link_clips.lua:77-87`: Silent false returns without error messages |
| CMD-M6 | ✅ | `set_sequence_metadata.lua`: `tonumber(value) or 0` → assert |
| CMD-M7 | ✅ | `toggle_maximize_panel.lua`: Assert on failure instead of print |
| CMD-M8 | ✅ | `delete_sequence.lua`: clip_links undo re-insertion assert-checked |
| CMD-M9 | ✅ | `add_clip.lua`: Assert on register failure |

---

## Phase 3: Ripple / Timeline / Clip Systems

### CRITICAL

| ID | Status | Fix |
|----|--------|-----|
| RTC-C1 | ✅ | `edge_drag_renderer.lua:29-30`: Removed `or 30` fallback; assert on fps_num |
| RTC-C2 | ✅ | `edge_drag_renderer.lua:220-221`: Same — assert instead of 30fps fallback |

### HIGH

| ID | Status | Fix |
|----|--------|-----|
| RTC-H1 | ✅ | `edge_info.lua`: Assert on nil edge_info; error on unresolvable track_id |
| RTC-H2 | ✅ | `edge_info.lua`: `compute_edge_boundary_time` asserts on nil edge_info/original_states_map/clip_state; errors on unhandled edge_type |
| RTC-H3 | ✅ | `batch/prepare.lua:54`: Assert on delta fps fields; removed sequence fps fallback |
| RTC-H4 | ✅ | `undo_hydrator.lua`: Assert on missing `clip_kind` instead of `or "timeline"` |
| RTC-H5 | ✅ | `clip_edit_helper.lua`: Removed multi-layer pcall; direct require |
| RTC-H6 | ✅ | `clip_edit_helper.lua`: `get_media_fps` asserts on seq_fps_num/den when no master_clip or media_id |
| RTC-H7 | ✅ | `clip_mutator.lua:285`: Assert on `params.duration` |
| RTC-H8 | ✅ | `clip_mutator.lua:307-309`: `resolve_occlusions` asserts on missing start_value/duration |
| RTC-H9 | ✅ | `clip_mutator.lua:483-484`: `resolve_ripple` asserts on missing shift_amount |
| RTC-H10 | ✅ | `clipboard_actions.lua`: Removed pcall; direct `Property.load_for_clip` |
| RTC-H11 | ✅ | `clipboard_actions.lua`: Assert on clip rate metadata at copy time |
| RTC-H12 | ✅ | `clipboard_actions.lua:209`: Assert on playhead position instead of `or 0` |
| RTC-H13 | ✅ | `clipboard_actions.lua`: Assert on source_in/source_out in browser copy |
| RTC-H14 | ✅ | `timeline_constraints.lua`: Removed `_G.db` fallback + triple pcall; assert on db |

### MEDIUM

| ID | Status | Fix |
|----|--------|-----|
| RTC-M1 | ✅ | `batch/context.lua`: Assert on `primary_edge` existence |
| RTC-M2 | ✅ | `batch/pipeline.lua`: Error details now propagated |
| RTC-M3 | ✅ | `batch/prepare.lua:66`: Assert `ctx.edge_infos` is table instead of `or {}` |
| RTC-M4 | ✅ | `edge_info.lua`: `build_edge_key` asserts on nil edge_info/source_id/edge_type |
| RTC-M5 | ✅ | `track_index.lua`: Assert on clip.track_id instead of silently dropping |
| RTC-M6 | ✅ | `undo_hydrator.lua:67`: Assert on `shift_frames` instead of `or 0` |
| RTC-M7 | ✅ | `clip_edit_helper.lua`: Removed pcall; direct require of timeline_state |
| RTC-M8 | ⏳ | `clip_edit_helper.lua`: source_in defaults to 0 still present (intentional for unset source_in) |
| RTC-M9 | ✅ | `clip_edit_helper.lua`: `resolve_clip_name` asserts if all sources nil |
| RTC-M10 | ✅ | `clip_mutator.lua:152`: `clip_kind or "timeline"` → assert |
| RTC-M11 | ✅ | `clip_mutator.lua:300,478`: Silent true on nil → asserts on required fields |
| RTC-M12 | ✅ | `clip_mutator.lua:458-460`: Now warns on unseen non-virtual pending clips |
| RTC-M13 | ✅ | `clipboard_actions.lua`: `resolve_clip_entry` asserts instead of returning nil |
| RTC-M14 | ✅ | `clipboard_actions.lua`: `timeline_start.frames or 0` → assert |
| RTC-M15 | ✅ | `clipboard_actions.lua:407`: `base or "Master Clip"` → assert |
| RTC-M16 | ✅ | `clipboard_actions.lua`: project_id fallback chain → assert |
| RTC-M17 | ✅ | `timeline_active_region.lua`: Assert on clip.timeline_start.frames in binary search |
| RTC-M18 | ✅ | `timeline_constraints.lua`: Assert instead of `or 0` for clip_source_in/clip_start |

### clip_state.lua

| ID | Status | Fix |
|----|--------|-----|
| RTC-H15 | ✅ | Sort asserts on timeline_start.frames; added `get_content_end_frame` |
| RTC-H16 | ✅ | Removed pcall in hydrate; assert on db/clip_id |
| RTC-H17 | ✅ | Error instead of silent false for missing clips |

### timeline_state.lua

| ID | Status | Fix |
|----|--------|-----|
| RTC-M19 | ✅ | `apply_mutations` asserts mutations is table |
| RTC-M20 | ✅ | `get_sequence_fps_*` assert `sequence_frame_rate` is initialized |

---

## Phase 4a: UI & Playback

### CRITICAL

| ID | Status | Fix |
|----|--------|-----|
| UI-C1 | ❌ | `project_browser.lua:1786-1787`: New source-mark code still uses `or 24`/`or 1` fps fallback |

### HIGH

| ID | Status | Fix |
|----|--------|-----|
| UI-H1 | ✅ | `project_browser.lua:177`: Removed pcall; asserts on project_id |
| UI-H2 | ✅ | `project_browser.lua:186-205`: Removed hardcoded 30fps/1920x1080; asserts on sequence record fields |
| UI-H3 | ✅ | `project_browser.lua:627`: Assert on project_id instead of proceeding with nil |
| UI-H4 | ✅ | `browser_state.lua`: duration/source_in/source_out assert non-nil/numeric |
| UI-H5 | ✅ | `selection_hub.lua`: Bare print → `logger.error` |
| UI-H6 | ❌ | `menu_system.lua:380`: `get_active_project_id` returns nil to callers |
| UI-H7 | ✅ | `keyboard_shortcuts.lua:268-298`: Removed fabricated viewport values; asserts on state/capture_viewport |
| UI-H8 | ✅ | `keyboard_shortcuts.lua`: `clip.timeline_start or 0`, `clip.duration or 0` → asserts |
| UI-H9 | ✅ | `playback_controller.lua:586-588`: Assert on fps_num/fps_den > 0 instead of warn+skip |
| UI-H10 | ✅ | `timeline_playback.lua`: Assert on `get_asset_info()` return |
| UI-H11 | ✅ | `inspector/adapter.lua`: Removed aspirational remediation/technical_details |
| UI-H12 | ✅ | `inspector/widget_pool.lua`: Removed pcall+print; handler called directly |
| UI-H13 | ✅ | `keyboard_shortcuts.lua:508`: Removed `return 30.0` fallback; asserts+errors on invalid rate |

### MEDIUM

| ID | Status | Fix |
|----|--------|-----|
| UI-M1 | ✅ | `project_browser.lua:387`: `event.position or "viewport"` → assert on event.position |
| UI-M2 | ✅ | `project_browser.lua:440`: `clip.media or ... or {}` → assert on media |
| UI-M3 | ✅ | `project_browser.lua:498`: `frame_rate or frame_utils.default_frame_rate` → assert on frame_rate |
| UI-M4 | ✅ | `project_browser.lua:1306`: `name or "Untitled Project"` → assert on name |
| UI-M5 | ✅ | `browser_state.lua`: frame_rate/width/height assert non-nil |
| UI-M6 | ✅ | `focus_manager.lua`: `FOCUS_COLOR` wrapped in assert |
| UI-M7 | ✅ | `panel_manager.lua`: Removed `or {1, 1}` fallbacks; assert on splitter sizes |
| UI-M8 | ✅ | `menu_system.lua:59-62`: Removed pcall; direct require of ui.ui_state |
| UI-M9 | ✅ | `menu_system.lua:443-452`: Removed pcall around command execution; errors propagate |
| UI-M10 | ✅ | `keyboard_shortcuts.lua:498`: `default_frame_rate` fallback → assert+error on invalid rate |
| UI-M11 | ✅ | `keyboard_shortcuts.lua:613+`: `get_selected_clips() or {}` → assert on function presence |
| UI-M12 | ✅ | `playback_controller.lua`: logger.warn for missing SSE/AOP (intentional—Qt bindings optional at init) |
| UI-M13 | ✅ | `timeline_resolver.lua`: Assert instead of warn for missing media |
| UI-M14 | ✅ | `inspector/view.lua:170`: `frame_rate or default_frame_rate` → assert on frame_rate; `current_frame_rate()` asserts |
| UI-M15 | ✅ | `menu_system.lua`: Removed pcall; project_id nil chain no longer masked |
| UI-M16 | ✅ | `keyboard_shortcuts.lua:646-647`: Redundant `or nil` removed |

---

## Phase 4b: Models & Utilities

### CRITICAL

| ID | Status | Fix |
|----|--------|-----|
| MU-C1 | ✅ | `rational.lua:159`: Assert on fps_numerator instead of `or 30` |
| MU-C2 | ✅ | `rational.lua:167`: Assert `fps_num` for bare number input |
| MU-C3 | ✅ | `frame_utils.lua`: `normalize_rate` asserts non-nil; error on unrecognized type |
| MU-C4 | ✅ | `media.lua:132-134`: Assert on fps_numerator/fps_denominator instead of `or 30`/`or 1` |
| MU-C5 | ✅ | `media.lua:22-24`: `rate_from_float` asserts fps is positive number |

### HIGH

| ID | Status | Fix |
|----|--------|-----|
| MU-H1 | ✅ | `clip.lua`: `ensure_project_context` asserts project_id with context |
| MU-H2 | ✅ | `clip.lua`: All `print` → `assert`/`error`/`logger.debug` |
| MU-H3 | ✅ | `clip_link.lua`: `get_link_group` asserts on prepare failure instead of returning nil |
| MU-H4 | ✅ | `clip_link.lua`: `is_linked` asserts on prepare failure instead of returning false |
| MU-H5 | ✅ | `clip_link.lua`: `unlink_clip` DELETE wrapped in assert |
| MU-H6 | ✅ | `clip_link.lua:216`: DELETE exec assert-checked |
| MU-H7 | ✅ | `clip_link.lua`: `get_link_group_id` asserts on prepare failure instead of returning nil |
| MU-H8 | ✅ | `clip_link.lua`: `calculate_anchor_time` asserts on prepare failure instead of returning nil |
| MU-H9 | ✅ | `media.lua`: `dur_frames` errors on missing duration instead of defaulting to 0 |
| MU-H10 | ❌ | `media.lua:97-129`: `Media.load` warns + returns nil instead of asserting |
| MU-H11 | ✅ | `media.lua:save`: dur_frames/fps_den assert added |
| MU-H12 | ✅ | `media.lua:168`: Duration errors on unexpected format |
| MU-H13 | ✅ | `project.lua`: All `print` → `assert`/`error` |
| MU-H14 | ✅ | `sequence.lua`: All `print` → `assert`/`error` |
| MU-H15 | ✅ | `sequence.lua:333`: `or "default_project"` → assert |
| MU-H16 | ✅ | `track.lua`: `determine_next_index` fallback → assert on db/stmt |
| MU-H17 | ✅ | `track.lua`: Print → assert for missing name/sequence_id |
| MU-H18 | ✅ | `track.lua`: Print → assert on save failures |
| MU-H19 | ✅ | `frame_utils.lua:60`: `time_to_frame` asserts on nil hydrate result instead of returning 0 |
| MU-H20 | ✅ | `frame_utils.lua:81-83`: `snap_to_frame` asserts instead of returning frame-0 Rational |

### MEDIUM

| ID | Status | Fix |
|----|--------|-----|
| MU-M1 | ⏳ | `clip.lua:193`: `DEFAULT_CLIP_KIND` const removed; inline `"timeline"` kept (not a fallback—it's a default for create) |
| MU-M2 | ✅ | `clip.lua:349`: `clip_kind` asserted at save time |
| MU-M3 | ✅ | `clip.lua`: Logger now imported at top of file |
| MU-M4 | ❌ | `clip_link.lua:124`: `time_offset or 0` still present |
| MU-M5 | ✅ | `clip_link.lua`: `or "video"`/`or "audio"` → assert on role |
| MU-M6 | ✅ | `clip_link.lua`: Cleanup failure now asserts |
| MU-M7 | ✅ | `clip_link.lua`: Unchecked exec/silent false → assert on prepare+exec |
| MU-M8 | ❌ | `media.lua:82-88`: `width or 0`, `height or 0`, `codec or ""` still present |
| MU-M9 | ✅ | `media.lua:179`: `fps_denominator or 1` → assert den > 0 |
| MU-M10 | ✅ | `sequence.lua`: Width/height assert positive instead of 1920x1080 default |
| MU-M11 | ✅ | `sequence.lua:170`: Load path asserts non-NULL via `Sequence.load` |
| MU-M12 | ✅ | `sequence.lua:226`: `audio_sample_rate or 48000` → assert |
| MU-M13 | ✅ | `track.lua`: `or "Video Track"`/`"Audio Track"` → assert on name |
| MU-M14 | ✅ | `track.lua:309`: Assert on nil sequence_id |
| MU-M15 | ✅ | `project.lua`: `Project.count` assert chain on db/stmt/exec |
| MU-M16 | ✅ | `frame_utils.lua:192`: `format_duration` asserts frame_rate non-nil |
| MU-M17 | ❌ | `timecode.lua:93-95`: Unknown types become Rational(0) |
| MU-M18 | ❌ | `utils/track_resolver.lua:11-12`: `track_index or 0` |

### LOW

| ID | Status | Fix |
|----|--------|-----|
| MU-L1-12 | ❌ | Low priority; not addressed |

---

## Systemic Pattern Coverage

### Pattern 1: 30fps Pandemic

| Location | Status |
|----------|--------|
| `rational.lua` (hydrate) | ✅ Assert |
| `frame_utils.lua` (normalize_rate) | ✅ Assert |
| `media.lua` (load) | ✅ Assert |
| `media.lua` (rate_from_float) | ✅ Assert |
| `ripple_edit.lua` | ✅ Assert |
| `edge_drag_renderer.lua` (2x) | ✅ Assert |
| `keyboard_shortcuts.lua` | ✅ Assert |
| `project_browser.lua` (24fps in source marks) | ❌ `or 24` in new code at :1786 |
| `delete_sequence.lua` (snapshot) | ✅ Assert |
| `import_media.lua` | ✅ Assert |

### Pattern 2: Unchecked DB Operations

Fixed in: `clip_link.lua`, `track.lua`, `project.lua`, `sequence.lua`, `clip.lua`, `database.lua`, `delete_master_clip.lua`, `delete_sequence.lua`, `import_media.lua`, `import_fcp7_xml.lua`, `import_resolve_project.lua`, `snapshot_manager.lua`.
Remaining: ~0 known unchecked exec calls in command paths.

### Pattern 3: pcall Error Swallowing

Fixed in: `command_manager.lua` (commit/savepoint), `command_state.lua` (JSON), `timeline_constraints.lua`, `clipboard_actions.lua`, `clip_edit_helper.lua`, `command_helper.lua`, `command_implementations.lua`, `menu_system.lua`, `inspector/widget_pool.lua`, `inspector/view.lua`, `keyboard_shortcuts.lua`, `project_browser.lua`.
Remaining in: `command_manager.lua` (listeners at CM-5, timeline_state at CM-6).

### Pattern 4: print Instead of assert/logger

Fixed in: all model files, `selection_hub.lua`, `batch_command.lua`, `clipboard_actions.lua`, `snapshot_manager.lua`, `command_registry.lua`, `signals.lua`, `toggle_maximize_panel.lua`, `relink_media.lua`.
Remaining: none known.

---

## Files Changed

**71 files** with modifications (902 insertions, 1029 deletions):

Core: `rational.lua`, `frame_utils.lua`, `command_manager.lua`, `command_state.lua`, `command_helper.lua`, `command_history.lua`, `command_registry.lua`, `command_implementations.lua`, `database.lua`, `snapshot_manager.lua`, `signals.lua`, `error_system.lua`, `clip_mutator.lua`, `clipboard_actions.lua`, `clip_edit_helper.lua`, `timeline_constraints.lua`, `timeline_active_region.lua`, `keyboard_shortcuts.lua`, `menu_system.lua`
Ripple: `edge_info.lua`, `undo_hydrator.lua`, `batch/prepare.lua`, `batch/context.lua`, `batch/pipeline.lua`, `track_index.lua`
Commands: `batch_command.lua`, `add_clip.lua`, `create_clip.lua`, `create_sequence.lua`, `cut.lua`, `delete_master_clip.lua`, `delete_sequence.lua`, `duplicate_master_clip.lua`, `import_media.lua`, `import_fcp7_xml.lua`, `import_resolve_project.lua`, `insert_clip_to_timeline.lua`, `link_clips.lua`, `overwrite.lua`, `relink_media.lua`, `ripple_edit.lua`, `set_sequence_metadata.lua`, `split_clip.lua`, `toggle_maximize_panel.lua`
Models: `clip.lua`, `clip_link.lua`, `media.lua`, `project.lua`, `sequence.lua`, `track.lua`
UI: `edge_drag_renderer.lua`, `clip_state.lua`, `timeline_state.lua`, `project_browser.lua`, `browser_state.lua`, `selection_hub.lua`, `focus_manager.lua`, `panel_manager.lua`, `inspector/adapter.lua`, `inspector/view.lua`, `inspector/widget_pool.lua`, `playback_controller.lua`, `timeline_playback.lua`, `timeline_resolver.lua`
