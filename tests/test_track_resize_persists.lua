#!/usr/bin/env luajit

-- Regression: dragging a track's row resize handle and then doing NOTHING
-- ELSE (no playhead move, no selection change, no other action) must
-- persist the new height. Without an explicit persist trigger from the
-- splitter release handler, `track_state.set_height` only flips
-- `track_layout_dirty=true` and waits for some unrelated state change to
-- flush. Quit between the resize and that next event → height is lost.
--
-- Black-box: set a non-default height through the public API, force the
-- persist flush, then load the height back from the DB.

require("test_env")

_G.qt_create_single_shot_timer = function(_delay, cb)
    -- Tests run synchronously: fire the timer immediately so debounced
    -- writes land before we read them back.
    if cb then cb() end
    return nil
end

package.loaded["ui.panel_manager"] = {
    get_active_sequence_monitor = function() return nil end,
}

print("=== test_track_resize_persists.lua ===")

local database        = require("core.database")
local command_manager = require("core.command_manager")

local DB = "/tmp/jve/test_track_resize_persists.db"
os.remove(DB); os.remove(DB .. "-wal"); os.remove(DB .. "-shm")
os.execute("mkdir -p /tmp/jve")
database.init(DB)
local db = database.get_connection()
db:exec(require("import_schema"))

local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at)
    VALUES ('p','P','resample',%d,%d);
    INSERT INTO sequences (id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_sample_rate,
        width, height, playhead_frame, view_start_frame,
        view_duration_frames, created_at, modified_at)
    VALUES ('s','p','S','sequence',24,1,48000,1920,1080,0,0,300,%d,%d);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index,
        enabled, locked, muted, soloed, volume, pan, sync_mode, autoselect)
    VALUES ('t1','s','V1','VIDEO',1,1,0,0,0,1.0,0.0,'off',1);
]], now, now, now, now))

command_manager.init('s', 'p')

-- Now the timeline_state is mounted on sequence 's' with track t1.
-- The splitter release handler does this on a drag-release:
--     state.set_track_height(track_id, new_height)
-- That's the only thing that runs for the row-resize gesture itself.
-- After that gesture, the user may quit immediately — height MUST persist.
local timeline_state = require("ui.timeline.timeline_state")

local NEW_HEIGHT = 128  -- non-default; default is 50 per ui_constants
assert(timeline_state.get_track_height("t1") ~= NEW_HEIGHT,
    "test setup: start height must differ from NEW_HEIGHT")

timeline_state.set_track_height("t1", NEW_HEIGHT)

-- Read back from the DB. The persisted row lives in sequence_track_layouts;
-- load_sequence_track_heights returns the height map.
local heights = database.load_sequence_track_heights("s")
assert(type(heights) == "table",
    "FAIL: sequence_track_layouts row missing — track resize did not persist")
assert(heights["t1"] == NEW_HEIGHT, string.format(
    "FAIL: track t1 expected height=%d in DB, got %s — resize gesture "
    .. "didn't trigger persist (track_layout_dirty stayed unflushed)",
    NEW_HEIGHT, tostring(heights["t1"])))

print(string.format("  ✓ track height %d persisted to DB after resize", NEW_HEIGHT))

print("\n✅ test_track_resize_persists.lua passed")
