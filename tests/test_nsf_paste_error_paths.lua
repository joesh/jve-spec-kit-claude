#!/usr/bin/env luajit

-- NSF: Paste command error paths and boundary conditions.
-- Tests empty clipboard, no clips in range, LiftRange on empty sequence.

local test_env = require('test_env')

_G.qt_create_single_shot_timer = function() end
package.loaded["ui.panel_manager"] = {
    get_active_sequence_monitor = function() return nil end,
}
package.loaded["ui.project_browser"] = false

local database = require("core.database")
local command_manager = require("core.command_manager")
local clipboard = require('core.clipboard')
local timeline_state = require("ui.timeline.timeline_state")
local focus_manager = require("ui.focus_manager")
local clipboard_actions = require('core.clipboard_actions')
local Command = require("command")

local SCHEMA_SQL = require("import_schema")

local now = os.time()
local BASE_SQL = string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at) VALUES ('proj', 'Test', 'resample', %d, %d);
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, audio_sample_rate,
        width, height, playhead_frame, view_start_frame, view_duration_frames, created_at, modified_at)
    VALUES ('seq', 'proj', 'TL', 'sequence', 25, 1, 48000, 1920, 1080, 0, 0, 8000, %d, %d);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
    VALUES ('v1', 'seq', 'V1', 'VIDEO', 1, 1);
]], now, now, now, now)

local function setup(path)
    os.remove(path)
    os.remove(path .. "-wal")
    os.remove(path .. "-shm")
    assert(database.init(path))
    local conn = database.get_connection()
    assert(conn:exec(SCHEMA_SQL))
    assert(conn:exec([[
        CREATE TABLE IF NOT EXISTS properties (
            id TEXT PRIMARY KEY, clip_id TEXT NOT NULL,
            property_name TEXT NOT NULL, property_value TEXT,
            property_type TEXT, default_value TEXT
        );
    ]]))
    assert(conn:exec(BASE_SQL))
    command_manager.init('seq', 'proj')
    timeline_state.set_playhead_position(0)
    timeline_state.set_selection({})
    clipboard.clear()
end

----------------------------------------------------------------------
-- Test 1: Paste with empty clipboard fails cleanly (not assert crash)
----------------------------------------------------------------------
print("\n--- Test 1: Paste with empty clipboard ---")
setup("/tmp/jve/test_nsf_paste_empty.db")
focus_manager.set_focused_panel("timeline")

clipboard.clear()
local paste_ok, paste_err = clipboard_actions.paste()
assert(not paste_ok, "paste with empty clipboard should return false")
assert(paste_err, "paste should provide error message")
print("✓ Paste with empty clipboard returns false + error: " .. paste_err)

----------------------------------------------------------------------
-- Test 2: Paste command with empty clipboard returns error (not crash)
----------------------------------------------------------------------
print("\n--- Test 2: Paste command with empty clipboard ---")
setup("/tmp/jve/test_nsf_paste_cmd_empty.db")

clipboard.clear()
local result = command_manager.execute("Paste", {
    project_id = "proj",
    sequence_id = "seq",
})
assert(not result.success, "Paste command with empty clipboard should fail")
print("✓ Paste command fails gracefully with empty clipboard")

----------------------------------------------------------------------
-- Test 3: LiftRange on empty sequence (no clips) succeeds with 0 mutations
----------------------------------------------------------------------
print("\n--- Test 3: LiftRange on empty sequence ---")
setup("/tmp/jve/test_nsf_lift_empty.db")

local result3 = command_manager.execute("LiftRange", {
    project_id = "proj", sequence_id = "seq",
    mark_in = 100, mark_out = 200,
})
assert(result3.success, "LiftRange on empty sequence should succeed: " .. (result3.error_message or ""))
print("✓ LiftRange on empty sequence is a no-op success")

----------------------------------------------------------------------
-- Test 4: ExtractRange on empty sequence (no clips) succeeds with 0 mutations
----------------------------------------------------------------------
print("\n--- Test 4: ExtractRange on empty sequence ---")
setup("/tmp/jve/test_nsf_extract_empty.db")

local result4 = command_manager.execute("ExtractRange", {
    project_id = "proj", sequence_id = "seq",
    mark_in = 50, mark_out = 150,
})
assert(result4.success, "ExtractRange on empty sequence should succeed: " .. (result4.error_message or ""))
print("✓ ExtractRange on empty sequence is a no-op success")

----------------------------------------------------------------------
-- Test 5: copy_mark_range with no clips in range returns false
----------------------------------------------------------------------
print("\n--- Test 5: Copy mark range with no clips ---")
setup("/tmp/jve/test_nsf_copy_empty_range.db")

-- Set marks but there are no clips at all
assert(command_manager.execute("SetMarkIn", {
    project_id = "proj", sequence_id = "seq", frame = 100,
}).success)
assert(command_manager.execute("SetMarkOut", {
    project_id = "proj", sequence_id = "seq", frame = 200,
}).success)
focus_manager.set_focused_panel("timeline")

local copy_ok, copy_err = clipboard_actions.copy()
assert(not copy_ok, "copy with no clips in mark range should return false")
assert(copy_err, "copy should provide error: " .. tostring(copy_err))
print("✓ Copy with marks but no clips returns false: " .. copy_err)

----------------------------------------------------------------------
-- Test 6: Copy mark range with clips entirely outside range returns false
----------------------------------------------------------------------
print("\n--- Test 6: Copy mark range with clips outside range ---")
setup("/tmp/jve/test_nsf_copy_outside_range.db")

-- Create a clip at [500, 600)
local masterclip_cache = {}
local function create_mc(media_id, dur)
    if masterclip_cache[media_id] then return masterclip_cache[media_id] end
    local Media = require('models.media')
    local m = Media.create({
        id = media_id, project_id = 'proj',
        file_path = '/tmp/jve/' .. media_id .. '.mov',
        name = media_id, duration_frames = dur,
        fps_numerator = 25, fps_denominator = 1,
        width = 1920, height = 1080,
        audio_channels = 0,
    })
    m:save(database.get_connection())
    local mc = test_env.create_test_masterclip_sequence('proj', media_id..' MC', 25, 1, dur, media_id)
    masterclip_cache[media_id] = mc
    return mc
end

local mc = create_mc("med_outside", 500)
local cmd = Command.create("Overwrite", "proj")
cmd:set_parameters({
    source_sequence_id = mc, target_video_track_id = "v1", sequence_id = "seq",
    sequence_start_frame = 500,
    advance_playhead = false,
})
do
    local r = command_manager.execute(cmd)
    assert(r.success, "Overwrite failed: " .. tostring(r.error_message))
end

-- Marks at [100, 200) — clip is at [500, 600), no overlap
assert(command_manager.execute("SetMarkIn", {
    project_id = "proj", sequence_id = "seq", frame = 100,
}).success)
assert(command_manager.execute("SetMarkOut", {
    project_id = "proj", sequence_id = "seq", frame = 200,
}).success)
focus_manager.set_focused_panel("timeline")

local copy_ok2, copy_err2 = clipboard_actions.copy()
assert(not copy_ok2, "copy with clips outside mark range should return false")
print("✓ Copy with marks but clips outside range returns false: " .. tostring(copy_err2))

print("✅ test_nsf_paste_error_paths.lua passed")
