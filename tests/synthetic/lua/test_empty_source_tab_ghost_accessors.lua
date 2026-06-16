#!/usr/bin/env luajit
--- Display-aware source accessors must tolerate the empty source tab.
---
--- Live symptom (TSO 2026-06-16): right after opening a project the source
--- side holds nothing loaded — the empty source tab (kind=source,
--- sequence_id=nil). The timeline ruler's render cycle (driven through a
--- debounced single_shot_timer) pulls ghost-mark + source-fps display state,
--- which reached `Sequence.load(source_tab.sequence_id)` with a nil id and
--- tripped `Sequence.load: id is required` four times at startup.
---
--- Domain: nothing loaded in the source ⇒ no source frame-rate to report and
--- no ghost mark to draw. Both accessors must return nil, never assert. This
--- mirrors TimelineTab:get_marks(), which already blanks on is_empty_source().
---
--- Black-box: drive only the public state-layer accessors against a strip
--- whose displayed tab is the empty source tab.

require("test_env")

_G.qt_create_single_shot_timer = function() end

print("=== test_empty_source_tab_ghost_accessors.lua ===")

local database = require("core.database")
local timeline_state = require("ui.timeline.timeline_state")

local DB = "/tmp/jve/test_empty_source_tab_ghost_accessors.db"
os.remove(DB); os.remove(DB .. "-wal"); os.remove(DB .. "-shm")
os.execute("mkdir -p /tmp/jve")
database.init(DB)
local db = database.get_connection()
db:exec(require("import_schema"))

local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at)
    VALUES ('proj', 'P', 'resample', %d, %d);

    INSERT INTO sequences (id, project_id, name, kind, fps_numerator,
        fps_denominator, audio_sample_rate, width, height,
        start_timecode_frame, playhead_frame, view_start_frame,
        view_duration_frames, created_at, modified_at)
    VALUES ('rec1', 'proj', 'Rec 1', 'sequence', 25, 1, 48000, 1920, 1080,
            0, 0, 0, 300, %d, %d);
]], now, now, now, now))

-- A record sequence is displayed, and the source side is the EMPTY source tab
-- (nothing loaded in the source monitor) — the post-open startup state.
local strip = timeline_state.get_tab_strip()
strip:open_record_tab("rec1")
local empty_source = strip:ensure_empty_source_tab()
strip:switch_displayed(empty_source)

assert(strip:get_source_tab():is_empty_source(),
    "fixture: source tab must be the empty source tab")
print("  ✓ fixture: empty source tab displayed over a record sequence")

-- Ghost-mark display state: nothing loaded in source ⇒ no ghost mark.
-- Pre-fix this asserts "Sequence.load: id is required".
local ghost = timeline_state.get_ghost_mark()
assert(ghost == nil, string.format(
    "empty source tab: get_ghost_mark must return nil (nothing loaded), got %s",
    tostring(ghost)))
print("  ✓ get_ghost_mark returns nil with an empty source tab")

-- Source frame-rate display state: no loaded source sequence ⇒ no fps.
local fps = timeline_state.get_source_sequence_fps()
assert(fps == nil, string.format(
    "empty source tab: get_source_sequence_fps must return nil, got %s",
    tostring(fps)))
print("  ✓ get_source_sequence_fps returns nil with an empty source tab")

print("\n✅ test_empty_source_tab_ghost_accessors.lua passed")
