#!/usr/bin/env luajit

-- Tests for SetTrackHeights command (non-undoable, scriptable)
-- Uses REAL timeline_state — no mock.

require('test_env')

-- No-op timer: prevent debounced persistence from firing mid-command
_G.qt_create_single_shot_timer = function() end

-- Only mock needed: panel_manager (Qt widget management)
package.loaded["ui.panel_manager"] = {
    get_active_sequence_monitor = function() return nil end,
}

local database = require('core.database')
local command_manager = require('core.command_manager')
local Command = require('command')
local uuid = require('uuid')

local TEST_DB = "/tmp/jve/test_set_track_heights.db"
os.remove(TEST_DB)
os.remove(TEST_DB .. "-wal")
os.remove(TEST_DB .. "-shm")

database.init(TEST_DB)
local db = database.get_connection()

db:exec(require('import_schema'))

local now = os.time()
local sequence_id = uuid.generate()

db:exec(string.format([[
    INSERT INTO projects (id, name, created_at, modified_at)
    VALUES ('test_project', 'Track Heights Test Project', %d, %d);

    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, audio_rate, width, height,
        view_start_frame, view_duration_frames, playhead_frame, selected_clip_ids, selected_edge_infos,
        selected_gap_infos, current_sequence_number, created_at, modified_at)
    VALUES ('%s', 'test_project', 'Test Seq', 'timeline',
        30, 1, 48000, 1920, 1080, 0, 240, 0, '[]', '[]', '[]', 0, %d, %d);
]], now, now, sequence_id, now, now))

-- Init with REAL timeline_state
command_manager.init(sequence_id, "test_project")

print("=== SetTrackHeights Command Tests ===")

-- Test 1: Set track heights
print("Test 1: Set track heights")
local track_heights = {
    ["track-1"] = 50,
    ["track-2"] = 75,
    ["track-3"] = 100
}

local cmd = Command.create("SetTrackHeights", "test_project")
cmd:set_parameter("project_id", "test_project")
cmd:set_parameter("sequence_id", sequence_id)
cmd:set_parameter("track_heights", track_heights)

local result = command_manager.execute(cmd)
assert(result.success, "SetTrackHeights should succeed: " .. tostring(result.error_message))

-- Verify heights were persisted
local loaded = database.load_sequence_track_heights(sequence_id)
assert(loaded, "Should be able to load track heights")
assert(loaded["track-1"] == 50, "Track 1 height should be 50, got: " .. tostring(loaded["track-1"]))
assert(loaded["track-2"] == 75, "Track 2 height should be 75")
assert(loaded["track-3"] == 100, "Track 3 height should be 100")

-- Test 2: Update track heights
print("Test 2: Update track heights")
local updated_heights = {
    ["track-1"] = 80,
    ["track-4"] = 120
}

local update_cmd = Command.create("SetTrackHeights", "test_project")
update_cmd:set_parameter("project_id", "test_project")
update_cmd:set_parameter("sequence_id", sequence_id)
update_cmd:set_parameter("track_heights", updated_heights)

result = command_manager.execute(update_cmd)
assert(result.success, "Update should succeed")

loaded = database.load_sequence_track_heights(sequence_id)
assert(loaded["track-1"] == 80, "Track 1 should be updated to 80")
assert(loaded["track-4"] == 120, "Track 4 should be 120")

-- Test 3: Invalid track_heights type fails
print("Test 3: Invalid track_heights type fails (expect error)")
local bad_cmd = Command.create("SetTrackHeights", "test_project")
bad_cmd:set_parameter("project_id", "test_project")
bad_cmd:set_parameter("sequence_id", sequence_id)
bad_cmd:set_parameter("track_heights", "not a table")

result = command_manager.execute(bad_cmd)
assert(not result.success, "Non-table track_heights should fail")

print("✅ test_set_track_heights.lua passed")
