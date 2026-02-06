# NSF (No Silent Failures) Codebase Review

**Date**: 2026-02-03
**Scope**: All Lua source files (~150 files)
**Method**: Exhaustive file-by-file review across 5 parallel phases

---

## Executive Summary

| Severity | Count | Description |
|----------|-------|-------------|
| **CRITICAL** | 13 | Data corruption, wrong math, broken SQL |
| **HIGH** | 73 | Silent failures hiding real errors, unchecked DB ops |
| **MEDIUM** | 88 | Fallback values, pcall swallowing, missing asserts |
| **LOW** | 40 | Minor defaults, cosmetic fallbacks |
| **TOTAL** | **214** | |

### Top 10 Most Dangerous Findings

| # | File | Issue | Why Dangerous |
|---|------|-------|---------------|
| 1 | `rational.lua:159,167` | `Rational.hydrate` falls back to 30fps | Foundation of entire time system; all downstream math wrong |
| 2 | `frame_utils.lua:28` | `normalize_rate` falls back to 30fps | Called by every timecode/frame function; cascading wrong results |
| 3 | `media.lua:132-134` | `Media.load` fps falls back to `or 30` | Every loaded media item gets wrong timing |
| 4 | `link_clips.lua:185` | SQL column `args.original_role` literal in query | Undo is permanently broken — SQL always fails |
| 5 | `command_manager.lua:1953` | `end_undo_group` commit failure swallowed | Caller believes data committed when it didn't |
| 6 | `delete_sequence.lua:491-504` | Undo restore uses `or 1920`, `or 1080`, `or 48000` | Restored sequences get wrong dimensions/audio rate |
| 7 | `clip.lua:283-321` | `ensure_project_context` swallows all errors | Clips saved with NULL project_id |
| 8 | `batch_command.lua:238-242` | Child undo failure swallowed, parent returns true | Partial undo leaves data inconsistent |
| 9 | `edge_drag_renderer.lua:29-30,220-221` | Preview geometry falls back to 30fps | Visual feedback shows wrong positions |
| 10 | `ripple_edit.lua:194-204` | Sequence fps falls back to 30 | All Rational math in ripple edit wrong |

---

## Phase 1: Core Infrastructure

### command_manager.lua

**[CM-1] CRITICAL — end_undo_group commit failure swallowed** `:1953-1958`
```lua
local commit_ok, commit_err = pcall(function()
    db_module.commit()
end)
if not commit_ok then
    logger.error("command_manager", string.format("Failed to commit undo group transaction: %s", tostring(commit_err)))
end
```
Caller believes undo group committed. Data lost.

**[CM-2] HIGH — Savepoint creation failure proceeds without protection** `:1931-1934`
```lua
local ok = db_module.savepoint(savepoint_name)
if not ok then
    logger.warn("command_manager", "Failed to create savepoint for undo group: " .. savepoint_name)
end
```
Undo group runs without rollback safety. Should assert.

**[CM-3] HIGH — Release savepoint failure returns nil** `:1943-1949`
```lua
local ok, err = pcall(function()
    db_module.release_savepoint(savepoint_name)
end)
if not ok then
    logger.error(...)
    return  -- nil return, caller doesn't check
end
```

**[CM-4] HIGH — db_module.commit() unchecked** `:1075`
```lua
db_module.commit()
```
Post-command commit result ignored.

**[CM-5] MEDIUM — pcall swallows listener errors** `:143-147`
```lua
local ok, err = pcall(listener, event)
if not ok then
    logger.warn("command_manager", string.format("Command listener failed: %s", tostring(err)))
end
```

**[CM-6] MEDIUM — pcall swallows timeline_state load failure** `:574-577`
```lua
local ok_ts, timeline_state = pcall(require, "ui.timeline.timeline_state")
if ok_ts and timeline_state and type(timeline_state.init) == "function" then
    timeline_state.init(sequence_id, project_id)
end
```

**[CM-7] MEDIUM — revert_to_sequence returns nil on failure** `:1709-1718`

**[CM-8] LOW — bug_result uses `message or ""`** `:58-59`

### command_state.lua

**[CS-1] HIGH — JSON encode failure replaced with "[]"** `:199-206,221-223`
```lua
local success_clips, clips_json = pcall(qt_json_encode, clip_ids)
if not success_clips then
    clips_json = "[]"
end
```
Selection data corrupted in undo record. Pattern repeats 3x (clips, edges, gaps).

**[CS-2] MEDIUM — `get_selected_clips() or {}`** `:174`
```lua
local selected_clips = timeline_state.get_selected_clips() or {}
```
Nil from uninitialized timeline masked. Same at `:182` for edges.

**[CS-3] MEDIUM — decode() returns {} on corrupt JSON** `:256-260`

### command_helper.lua

**[CH-1] MEDIUM — pcall swallows Track.get_sequence_id error** `:30-33`
```lua
local ok, result = pcall(Track.get_sequence_id, track_id)
if not ok then return nil end
```

**[CH-2] MEDIUM — Silent nil returns from clip_update_payload** `:115-122`
Callers skip mutation recording without knowing why.

**[CH-3] MEDIUM — Silent early returns on nil update/clip/clip_ids** `:200-273`
`add_update_mutation`, `add_insert_mutation`, `add_delete_mutation` all silently skip when given nil.

**[CH-4] MEDIUM — pcall swallows Property.load/save/delete errors** `:452-527`
6 functions return `{}` or `false` on pcall failure, discarding error messages.

### command_history.lua

**[CHi-1] HIGH — Init silently continues with sequence_number=0 on query failure** `:72-78`
```lua
local query = db:prepare("SELECT MAX(sequence_number) FROM commands")
if query then ... end
```
If prepare fails, `last_sequence_number = 0`. Causes sequence number collisions.

**[CHi-2] MEDIUM — save_undo_position returns false, callers never check** `:291-306`

**[CHi-3] MEDIUM — Mismatched begin/end_undo_group warns instead of asserting** `:379-381`

### command_registry.lua

**[CR-1] HIGH — Bare print on module load failure** `:196`
```lua
print(string.format("ERROR: %s", err or ("Unable to load " .. primary_path)))
return false
```
Violates no-print rule. Caller gets nil executor with no real diagnostic.

### command_implementations.lua

**[CI-1] MEDIUM — pcall swallows mod.register() errors** `:61`

### database.lua

**[DB-1] HIGH — ALTER TABLE return unchecked** `:639`
```lua
db_connection:exec("ALTER TABLE commands ADD COLUMN " .. col .. " TEXT DEFAULT '[]'")
```
Schema migration silently fails on disk-full/locked.

**[DB-2] MEDIUM — ensure_commands_table_columns silently skips on nil connection** `:619`

**[DB-3] MEDIUM — PRAGMA prepare failure aborts migration silently** `:629`

**[DB-4] MEDIUM — Table creation failure logged as warning** `:224-226`

**[DB-5] MEDIUM — load_clip_properties returns {} on prepare failure** `:921-922`

**[DB-6] MEDIUM — load_bins returns {} on prepare failure** `:1769-1771`

### snapshot_manager.lua

**[SM-1] HIGH — Bare print on table creation failure** `:44-46`
```lua
print("WARNING: snapshot_manager: Failed to ensure snapshots table")
```

**[SM-2] HIGH — start_frame defaults to 0 on missing Rational** `:174`
```lua
if not start_frame then start_frame = 0 end -- Error?
```
Code's own comment acknowledges the bug.

**[SM-3] MEDIUM — Bare prints throughout** `:384-489`
8+ bare `print` calls for errors/warnings instead of logger/assert.

### signals.lua

**[SG-1] MEDIUM — Handler errors printed and swallowed** `:226-246`

### error_system.lua

**[ES-1] MEDIUM — Defaults for missing error metadata** `:187-188`
`code = "UNKNOWN_ERROR"`, `operation = "unknown_operation"`, etc.

### logger.lua

**[LG-1] LOW — File logging silently degrades to console-only** `:121-126`

---

## Phase 2: Command Implementations

### CRITICAL

**[CMD-C1] link_clips.lua:185 — Broken SQL column name**
```lua
INSERT INTO clip_links (link_group_id, clip_id, args.original_role, time_offset, enabled)
```
Literal `args.original_role` in SQL. UnlinkClip undo is permanently broken.

**[CMD-C2] delete_sequence.lua:236-239 — fps_numerator or 0**
```lua
fps_numerator = tonumber(stmt:value(4)) or 0,
fps_denominator = tonumber(stmt:value(5)) or 1,
audio_sample_rate = ... or 48000,
```
`fps_numerator = 0` causes divide-by-zero. Invented 48kHz/1920x1080 during undo.

**[CMD-C3] delete_sequence.lua:491-504 — Massive fallback cluster in undo restore**
```lua
insert_sequence_stmt:bind_value(8, sequence_row.width or 1920)
insert_sequence_stmt:bind_value(9, sequence_row.height or 1080)
```
12+ fallback values corrupting restored sequences.

**[CMD-C4] ripple_edit.lua:194-204 — Fallback 30fps for sequence**
```lua
local seq_fps_num = 30
local seq_fps_den = 1
```
All Rational math in ripple edit uses wrong rate if DB query fails.

### HIGH (18 findings)

**[CMD-H1] batch_command.lua:238-242** — Child undo failure swallowed, parent returns true
**[CMD-H2] create_clip.lua:93-95** — Missing master_clip silently falls back to media-only
**[CMD-H3] cut.lua:94-95** — Clip delete failure ignored, command returns true
**[CMD-H4] delete_master_clip.lua:30-32** — `register()` returns nil instead of asserting
**[CMD-H5] delete_master_clip.lua:38-49** — Unchecked `exec()` on 3 DELETE statements
**[CMD-H6] delete_sequence.lua:86-103** — Unchecked `exec()` on clip_links/properties DELETE
**[CMD-H7] delete_sequence.lua:355** — Clip frame values `or 0` in snapshot
**[CMD-H8] duplicate_master_clip.lua:62** — `duration_value or 1` invents 1-frame duration
**[CMD-H9] import_media.lua:78-94** — Fallback 30fps and 1-second duration
**[CMD-H10] import_media.lua:402-487** — All undo DELETE execs unchecked
**[CMD-H11] import_fcp7_xml.lua:427-461** — All undo DELETE execs unchecked
**[CMD-H12] import_resolve_project.lua:284-523** — All undo DELETE execs unchecked
**[CMD-H13] insert_clip_to_timeline.lua:79-81** — Same master_clip fallback
**[CMD-H14] overwrite.lua:90-92** — Same master_clip fallback
**[CMD-H15] relink_media.lua:123-127** — Batch save failure skipped, returns success
**[CMD-H16] batch_command.lua:95-97** — Bare print on JSON parse error
**[CMD-H17] delete_master_clip.lua:129-148** — 3 unchecked DELETE execs for tracks/snapshots
**[CMD-H18] delete_sequence.lua:629** — Unchecked clip_links re-insertion during undo

### MEDIUM (9 findings)

**[CMD-M1] add_clip.lua:40-44** — set_last_error + return false for missing command (should assert)
**[CMD-M2] create_sequence.lua:37** — `TRACK_HEIGHT or 50`
**[CMD-M3] cut.lua:126** — `deleted_clip_states or {}`
**[CMD-M4] import_media.lua:103-104** — `width or 1920, height or 1080`
**[CMD-M5] link_clips.lua:77-87** — Silent false returns without error messages
**[CMD-M6] set_sequence_metadata.lua:54** — `tonumber(value) or 0`
**[CMD-M7] toggle_maximize_panel.lua:37-39** — Always returns true even on failure
**[CMD-M8] delete_sequence.lua:22** — Unchecked exec for clip_links undo re-insertion
**[CMD-M9] add_clip.lua:31-37** — Silent swallow if register fails

---

## Phase 3: Ripple / Timeline / Clip Systems

### CRITICAL

**[RTC-C1] edge_drag_renderer.lua:29-30 — 30fps fallback in negate_delta**
```lua
local fps_num = delta.fps_numerator or (delta.rate and delta.rate.fps_numerator) or 30
local fps_den = delta.fps_denominator or (delta.rate and delta.rate.fps_denominator) or 1
```
Preview geometry uses wrong frame rate.

**[RTC-C2] edge_drag_renderer.lua:220-221 — Same 30fps fallback in compute_preview_geometry**

### HIGH (14 findings)

**[RTC-H1] ripple/edge_info.lua:21-34** — `get_edge_track_id` returns nil silently (track_id required for edge ops)
**[RTC-H2] ripple/edge_info.lua:37-63** — `compute_edge_boundary_time` returns nil for unrecognized edge types
**[RTC-H3] ripple/batch/prepare.lua:54** — Fallback to sequence fps when delta is missing rate
**[RTC-H4] ripple/undo_hydrator.lua:111-113** — `clip_kind or "timeline"` hardcoded default
**[RTC-H5] clip_edit_helper.lua:33-45** — Multi-layer pcall swallowing in media_id resolution
**[RTC-H6] clip_edit_helper.lua:322-323** — Returns sequence rate as "media" rate when unknown
**[RTC-H7] clip_mutator.lua:285** — `item.duration or 0` in overlap detection
**[RTC-H8] clip_mutator.lua:307-309** — `resolve_occlusions` returns true on missing required fields
**[RTC-H9] clip_mutator.lua:483-484** — `resolve_ripple` returns true on missing required fields
**[RTC-H10] clipboard_actions.lua:89-98** — pcall swallows Property.load_for_clip errors
**[RTC-H11] clipboard_actions.lua:143-144** — Nil fps deferred from copy-time to paste-time crash
**[RTC-H12] clipboard_actions.lua:209** — Playhead position `or 0` (paste at wrong location)
**[RTC-H13] clipboard_actions.lua:444-445** — `source_in or 0, source_out or duration`
**[RTC-H14] timeline_constraints.lua:178-199** — Global `_G.db` fallback + triple nested pcall

### MEDIUM (18 findings)

**[RTC-M1]** ripple/batch/context.lua:98 — primary_edge can be nil
**[RTC-M2]** ripple/batch/pipeline.lua:39-41 — Error details discarded
**[RTC-M3]** ripple/batch/prepare.lua:66 — `edge_infos or {}`
**[RTC-M4]** ripple/edge_info.lua:66-72 — `build_edge_key` returns "::" for nil edge
**[RTC-M5]** ripple/track_index.lua:22-26 — Clips without track_id silently dropped
**[RTC-M6]** ripple/undo_hydrator.lua:67 — `shift_frames or 0`
**[RTC-M7]** clip_edit_helper.lua:15-22 — pcall swallows timeline_state require
**[RTC-M8]** clip_edit_helper.lua:153,170 — source_in defaults to 0
**[RTC-M9]** clip_edit_helper.lua:203-208 — 4-level fallback chain for clip name
**[RTC-M10]** clip_mutator.lua:152 — `clip_kind or "timeline"`
**[RTC-M11]** clip_mutator.lua:300,478 — Silent true on nil params
**[RTC-M12]** clip_mutator.lua:458-460 — All pending clips marked seen unconditionally
**[RTC-M13]** clipboard_actions.lua:101-112 — resolve_clip_entry returns nil silently
**[RTC-M14]** clipboard_actions.lua:169,173 — `timeline_start.frames or 0`
**[RTC-M15]** clipboard_actions.lua:407 — `base or "Master Clip"`
**[RTC-M16]** clipboard_actions.lua:465,498 — project_id fallback chain
**[RTC-M17]** timeline_active_region.lua:30 — nil in binary search comparator
**[RTC-M18]** timeline_constraints.lua:38,52 — `clip_source_in or 0`, `clip_start or 0`

### clip_state.lua

**[RTC-H15] clip_state.lua:208-214** — `get_content_end_frame` uses `or 0` for start/duration
**[RTC-H16] clip_state.lua:270-272** — pcall swallows database errors in hydrate
**[RTC-H17] clip_state.lua:436-439** — Silent false for missing clips with no error message

### timeline_state.lua

**[RTC-M19]** `:139-141` — apply_mutations returns false for non-table, callers don't check
**[RTC-M20]** `:217-218` — get_sequence_fps_* crash with unhelpful error before init

---

## Phase 4a: UI & Playback

### CRITICAL

**[UI-C1] project_browser.lua:1789 — Fabricated 24fps rate**
```lua
local rate = clip.rate or {fps_numerator = clip.fps_numerator or 24, fps_denominator = clip.fps_denominator or 1}
```
Source mark calculations use wrong frame rate.

### HIGH (13 findings)

**[UI-H1] project_browser.lua:177** — `current_project_id()` swallows pcall errors, returns nil
**[UI-H2] project_browser.lua:186-205** — Hardcoded 30fps/1920x1080 defaults
**[UI-H3] project_browser.lua:627-628** — `populate_tree` proceeds with nil project_id
**[UI-H4] browser_state.lua:72-74** — Duration/source_in/source_out `or 0`
**[UI-H5] selection_hub.lua:37-39** — Listener errors swallowed via pcall + bare print
**[UI-H6] menu_system.lua:380** — `get_active_project_id` returns nil to callers
**[UI-H7] keyboard_shortcuts.lua:268-298** — Fabricated viewport values (0, 10000)
**[UI-H8] keyboard_shortcuts.lua:1080-1099** — `clip.timeline_start or 0`, `clip.duration or 0`
**[UI-H9] playback_controller.lua:586-588** — Timeline mode without fps warns instead of asserting
**[UI-H10] timeline_playback.lua:113-114** — Unchecked `get_asset_info()` return
**[UI-H11] inspector/adapter.lua:34-46** — Returns error table instead of asserting
**[UI-H12] inspector/widget_pool.lua:290-294** — Signal handler errors swallowed + bare print
**[UI-H13] keyboard_shortcuts.lua:508** — Hardcoded `return 30.0` fps fallback

### MEDIUM (16 findings)

**[UI-M1]** project_browser.lua:387 — `event.position or "viewport"`
**[UI-M2]** project_browser.lua:440 — `clip.media or ... or {}`
**[UI-M3]** project_browser.lua:498 — `frame_rate or frame_utils.default_frame_rate`
**[UI-M4]** project_browser.lua:1306 — `name or "Untitled Project"`
**[UI-M5]** browser_state.lua:95-96,139,148-149 — Multiple `or 0` for frame_rate/width/height
**[UI-M6]** focus_manager.lua:33 — `FOCUS_COLOR or "#0078d4"`
**[UI-M7]** panel_manager.lua:68-74 — Fabricated splitter sizes `or {1, 1}`
**[UI-M8]** menu_system.lua:59-62 — pcall swallows ui.ui_state load
**[UI-M9]** menu_system.lua:443-452 — pcall swallows command execution errors
**[UI-M10]** keyboard_shortcuts.lua:498 — `default_frame_rate` fallback
**[UI-M11]** keyboard_shortcuts.lua:613+ — `get_selected_clips() or {}` (8 occurrences)
**[UI-M12]** playback_controller.lua:155-156 — Silent return if SSE/AOP bindings missing
**[UI-M13]** timeline_resolver.lua:63-67 — Missing media warns instead of assert
**[UI-M14]** inspector/view.lua:170 — `frame_rate or default_frame_rate`
**[UI-M15]** menu_system.lua:443 — `project_id or project_id` nil chain
**[UI-M16]** keyboard_shortcuts.lua:646-647 — Redundant `or nil`

---

## Phase 4b: Models & Utilities

### CRITICAL

**[MU-C1] rational.lua:159 — Rational.hydrate falls back to 30fps**
```lua
return Rational.new(val.frames, val.fps_numerator or fps_num or 30, val.fps_denominator or fps_den or 1)
```
Foundation of entire time system. Every deserialized Rational with missing fps gets 30fps.

**[MU-C2] rational.lua:167 — Same for number input**
```lua
return Rational.new(val, fps_num or 30, fps_den or 1)
```

**[MU-C3] frame_utils.lua:28-37 — normalize_rate falls back to default_frame_rate (30fps)**
```lua
function M.normalize_rate(rate)
    if not rate then return M.default_frame_rate end
    ...
    return M.default_frame_rate
end
```
Called by every timecode/frame function.

**[MU-C4] media.lua:132-134 — Media.load fps falls back to 30/1**
```lua
local num = query:value(5) or 30
local den = query:value(6) or 1
```

**[MU-C5] media.lua:22-24 — rate_from_float invents 30fps**
```lua
if not fps or fps <= 0 then return 30, 1 end
```

### HIGH (20 findings)

**[MU-H1] clip.lua:283-321** — `ensure_project_context` swallows ALL errors silently
**[MU-H2] clip.lua:329,408,452,481** — `print` instead of error/assert on save/delete failures
**[MU-H3] clip_link.lua:32-34,56-57** — `get_link_group` returns nil on DB error (same as "not linked")
**[MU-H4] clip_link.lua:84-85** — `is_linked` returns false on DB error
**[MU-H5] clip_link.lua:190-191** — `unlink_clip` returns false silently
**[MU-H6] clip_link.lua:216** — `exec()` return unchecked on DELETE
**[MU-H7] clip_link.lua:288-293** — `get_link_group_id` nil on DB error (causes duplicate groups)
**[MU-H8] clip_link.lua:317-318** — `calculate_anchor_time` nil on DB error (A/V sync drift)
**[MU-H9] media.lua:68,71** — `dur_frames or 0` creates zero-duration media
**[MU-H10] media.lua:97-129** — `Media.load` warns + returns nil instead of asserting
**[MU-H11] media.lua:162-226** — `Media:save` uses print, not assert on DB failures
**[MU-H12] media.lua:168** — Duration falls back to 0 on unexpected format
**[MU-H13] project.lua:30,43-46** — Print instead of assert on missing name/DB
**[MU-H14] sequence.lua:29,47-52** — Print instead of assert on missing name/project_id
**[MU-H15] sequence.lua:333** — `project_id or "default_project"` — invented project reference
**[MU-H16] track.lua:39-51** — `determine_next_index` returns 1 on DB failure (track overlap)
**[MU-H17] track.lua:67-72** — Print instead of assert on missing name/sequence_id
**[MU-H18] track.lua:246-252** — Print instead of assert on save
**[MU-H19] frame_utils.lua:60** — `time_to_frame` returns 0 on nil input
**[MU-H20] frame_utils.lua:81-83** — `snap_to_frame` returns frame-0 Rational on nil

### MEDIUM (18 findings)

**[MU-M1]** clip.lua:193 — `clip_kind or DEFAULT_CLIP_KIND` in create
**[MU-M2]** clip.lua:349 — `clip_kind or DEFAULT_CLIP_KIND` at save time
**[MU-M3]** clip.lua:521-524 — logger never imported (accidental crash)
**[MU-M4]** clip_link.lua:124 — `time_offset or 0`
**[MU-M5]** clip_link.lua:155-160 — Fallback roles `or "video"`, `or "audio"`
**[MU-M6]** clip_link.lua:224-225 — Returns true on cleanup failure
**[MU-M7]** clip_link.lua:244,258-276 — Unchecked exec, silent false returns
**[MU-M8]** media.lua:82-88 — `width or 0`, `height or 0`, `codec or ""`
**[MU-M9]** media.lua:179 — `fps_denominator or 1` in save
**[MU-M10]** sequence.lua:57-61 — Width/height silently default to 1920x1080
**[MU-M11]** sequence.lua:170 — `viewport_duration or 240` magic number
**[MU-M12]** sequence.lua:226 — `audio_sample_rate or 48000`
**[MU-M13]** track.lua:52,100 — `name or "Video Track"`, `name or "Audio Track"`
**[MU-M14]** track.lua:309 — `count_for_sequence` returns 0 on nil sequence_id
**[MU-M15]** project.lua:165-166 — `Project.count` returns 0 on DB failure
**[MU-M16]** frame_utils.lua:192,215-222 — pcall in format_duration, get_fps_float returns 0
**[MU-M17]** timecode.lua:93-95 — Unknown types become Rational(0)
**[MU-M18]** utils/track_resolver.lua:11-12 — `track_index or 0`

### Additional LOW findings (tag_service, pipe, etc.)

**[MU-L1-12]** Various acceptable defaults: clipboard version, volume=1.0, pan=0.0, display strings, timestamps, etc.

---

## Systemic Patterns

### Pattern 1: The 30fps Pandemic 🔴
The most dangerous pattern in the codebase. At least **10 separate locations** fall back to 30fps when frame rate data is missing:
- `rational.lua` (hydrate) — foundation layer
- `frame_utils.lua` (normalize_rate) — called everywhere
- `media.lua` (load + create)
- `ripple_edit.lua`
- `edge_drag_renderer.lua` (2x)
- `keyboard_shortcuts.lua`
- `project_browser.lua` (24fps variant)
- `delete_sequence.lua`
- `import_media.lua`

**Impact**: Any clip/sequence/media with missing fps metadata silently gets wrong timing. Cuts land on wrong frames, ripple trims shift wrong amounts, undo restores wrong durations.

**Fix**: `assert(fps_num and fps_num > 0, "missing fps_numerator")` at every location. No fallbacks.

### Pattern 2: Unchecked DB Operations 🔴
**~30 locations** where `stmt:exec()` return values are ignored, primarily in:
- `delete_master_clip.lua` (5 DELETEs)
- `delete_sequence.lua` (4 DELETEs)
- `import_*.lua` undo paths (10+ DELETEs)
- `clip_link.lua` (3 DELETE/UPDATE)

**Impact**: Failed DELETEs leave orphaned data. Failed INSERTs during undo leave incomplete restoration.

**Fix**: Wrap in `assert(stmt:exec(), "DELETE failed: " .. context)` or check return value.

### Pattern 3: pcall Error Swallowing 🟡
**~25 locations** use pcall to catch errors and either:
- Log a warning and continue
- Return nil/false/empty table
- Silently degrade functionality

Worst offenders: `command_manager.lua` (commit/savepoint), `command_state.lua` (JSON encode), `timeline_constraints.lua` (triple-nested pcall), `clipboard_actions.lua`.

### Pattern 4: print Instead of assert/logger 🟡
**~20 locations** use bare `print()` for error reporting instead of:
- `assert()` for invariant violations
- `logger.error()` for runtime errors
- `error()` for unrecoverable states

Worst offenders: All model files (`clip.lua`, `media.lua`, `project.lua`, `sequence.lua`, `track.lua`), `snapshot_manager.lua`, `command_registry.lua`.

### Pattern 5: `or {}` Masking Missing Data 🟡
**~15 locations** use `or {}` to silently convert nil results to empty tables, hiding DB errors, missing state, and broken function calls.

---

## Recommended Fix Priority

### Tier 1 — Fix Immediately (data corruption risk)
1. `link_clips.lua:185` — broken SQL (undo permanently broken)
2. `rational.lua:159,167` — 30fps fallback in hydrate
3. `frame_utils.lua:28` — 30fps fallback in normalize_rate
4. `media.lua:22-24,132-134` — 30fps fallback in load/create
5. `command_manager.lua:1953` — commit failure swallowed
6. `clip.lua:283-321` — ensure_project_context swallows errors
7. `delete_sequence.lua:491-504` — invented defaults during undo

### Tier 2 — Fix Soon (silent failures causing wrong behavior)
8. All unchecked `stmt:exec()` calls (~30 locations)
9. `command_state.lua` — JSON encode `"[]"` fallbacks
10. `batch_command.lua:238` — child undo swallowed
11. `clip_mutator.lua:307-309,483-484` — success on missing fields
12. `edge_drag_renderer.lua` — 30fps preview fallbacks
13. Model files — print→assert conversion

### Tier 3 — Fix When Touched (code quality)
14. pcall swallowing patterns
15. `or {}` / `or 0` patterns
16. Bare print → logger conversion
