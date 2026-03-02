--- Test: command_state JSON encode errors propagate instead of falling back to "[]"
-- Regression: pcall swallowed encode errors, replacing selection data with empty array
-- Uses REAL timeline_state — no mock.

require("test_env")

-- No-op timer: prevent debounced persistence from firing mid-command
_G.qt_create_single_shot_timer = function() end

-- Only mock needed: panel_manager (Qt widget management)
package.loaded["ui.panel_manager"] = {
    get_active_sequence_monitor = function() return nil end,
}

local passed, failed = 0, 0
local function check(label, cond)
    if cond then passed = passed + 1
    else failed = failed + 1; print("FAIL: " .. label) end
end

local database = require("core.database")
local command_manager = require("core.command_manager")
local timeline_state = require("ui.timeline.timeline_state")
local command_state = require("core.command_state")

-- Set up database with real schema
local TEST_DB = "/tmp/jve/test_command_state_json_no_fallback.db"
os.remove(TEST_DB)
os.remove(TEST_DB .. "-wal")
os.remove(TEST_DB .. "-shm")
assert(database.init(TEST_DB))
local db = database.get_connection()
db:exec(require("import_schema"))

local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, created_at, modified_at)
    VALUES ('proj1', 'Test', %d, %d);
    INSERT INTO sequences (
        id, project_id, name, kind, fps_numerator, fps_denominator, audio_rate,
        width, height, view_start_frame, view_duration_frames, playhead_frame,
        selected_clip_ids, selected_edge_infos, selected_gap_infos,
        current_sequence_number, created_at, modified_at
    ) VALUES (
        'seq1', 'proj1', 'Seq', 'timeline', 30, 1, 48000,
        1920, 1080, 0, 240, 0, '[]', '[]', '[]', 0, %d, %d
    );
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index,
        enabled, locked, muted, soloed, volume, pan)
    VALUES ('track_v1', 'seq1', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
    INSERT INTO clips (
        id, project_id, clip_kind, track_id, owner_sequence_id,
        timeline_start_frame, duration_frames, source_in_frame, source_out_frame,
        fps_numerator, fps_denominator, enabled, offline, created_at, modified_at
    ) VALUES
        ('clip1', 'proj1', 'timeline', 'track_v1', 'seq1',
         0, 30, 0, 30, 30, 1, 1, 0, %d, %d),
        ('clip2', 'proj1', 'timeline', 'track_v1', 'seq1',
         30, 30, 0, 30, 30, 1, 1, 0, %d, %d);
]], now, now, now, now, now, now, now, now))

-- Init with REAL timeline_state
command_manager.init('seq1', 'proj1')

-- Select clips via real timeline_state
local c1 = timeline_state.get_clip_by_id("clip1")
local c2 = timeline_state.get_clip_by_id("clip2")
assert(c1, "clip1 should exist in timeline cache")
assert(c2, "clip2 should exist in timeline cache")
timeline_state.set_selection({c1, c2})

-- Test with working JSON encoder — should succeed
local clips_json = command_state.capture_selection_snapshot()
check("valid clips JSON not empty", clips_json ~= "[]")
check("clips JSON contains clip1", clips_json:find("clip1") ~= nil)

-- Now break the JSON encoder to verify error propagation
-- command_state uses dkjson (json.encode), not qt_json_encode
local json = require("dkjson")
local original_encode = json.encode
json.encode = function()
    error("JSON encode explosion")
end

local ok, err = pcall(function()
    command_state.capture_selection_snapshot()
end)
check("broken encoder propagates error", not ok)
check("error mentions JSON", err and tostring(err):find("JSON") ~= nil)

-- Restore
json.encode = original_encode

if failed > 0 then
    print(string.format("❌ test_command_state_json_no_fallback.lua: %d passed, %d FAILED", passed, failed))
    os.exit(1)
end
print(string.format("✅ test_command_state_json_no_fallback.lua passed (%d assertions)", passed))
