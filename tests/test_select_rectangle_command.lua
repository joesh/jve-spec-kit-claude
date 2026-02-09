-- Test SelectRectangle command
require("test_env")

local database = require("core.database")
local command_manager = require("core.command_manager")
local timeline_state = require("ui.timeline.timeline_state")

local db_path = "/tmp/jve/test_select_rectangle_command.db"
os.remove(db_path)
assert(database.init(db_path))
local db = database.get_connection()
db:exec(require("import_schema"))

local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, created_at, modified_at)
    VALUES ('proj1', 'Test', %d, %d);
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator,
        audio_rate, width, height, view_start_frame, view_duration_frames,
        playhead_frame, selected_clip_ids, selected_edge_infos, created_at, modified_at)
    VALUES ('seq1', 'proj1', 'Seq', 'timeline', 24000, 1001, 48000,
        1920, 1080, 0, 240, 0, '[]', '[]', %d, %d);
]], now, now, now, now))

command_manager.init("seq1", "proj1")

-- Mock clips
local mock_clips = {
    { id = "clip_a", track_id = "trk_v1", timeline_start = 0, duration = 100 },
    { id = "clip_b", track_id = "trk_v1", timeline_start = 150, duration = 100 },
    { id = "clip_c", track_id = "trk_v2", timeline_start = 50, duration = 100 },
    { id = "clip_d", track_id = "trk_a1", timeline_start = 0, duration = 200 },
}

local mock_selection = {}

timeline_state.get_clips = function() return mock_clips end
timeline_state.get_selected_clips = function() return mock_selection end
timeline_state.set_selection = function(clips) mock_selection = clips or {} end

-- Test 1: Select clips in time range on single track
print("\n--- Test 1: SelectRectangle single track ---")
mock_selection = {}
local result = command_manager.execute("SelectRectangle", {
    project_id = "proj1",
    sequence_id = "seq1",
    time_start = 0,
    time_end = 120,
    track_ids = { "trk_v1" },
    modifiers = {},
})
assert(result.success, "SelectRectangle should succeed")
assert(#mock_selection == 1, string.format("Should have 1 clip, got %d", #mock_selection))
assert(mock_selection[1].id == "clip_a", "Should be clip_a")
print("✓ Single track: correct clip selected")

-- Test 2: Select clips across multiple tracks
print("\n--- Test 2: SelectRectangle multiple tracks ---")
mock_selection = {}
result = command_manager.execute("SelectRectangle", {
    project_id = "proj1",
    sequence_id = "seq1",
    time_start = 50,
    time_end = 160,
    track_ids = { "trk_v1", "trk_v2" },
    modifiers = {},
})
assert(result.success, "SelectRectangle should succeed")
assert(#mock_selection == 3, string.format("Should have 3 clips, got %d", #mock_selection))
print("✓ Multiple tracks: clips from both tracks selected")

-- Test 3: Cmd-click toggles
print("\n--- Test 3: SelectRectangle Cmd toggle ---")
-- First select clip_a
mock_selection = { mock_clips[1] }  -- clip_a
result = command_manager.execute("SelectRectangle", {
    project_id = "proj1",
    sequence_id = "seq1",
    time_start = 140,
    time_end = 260,
    track_ids = { "trk_v1" },
    modifiers = { command = true },
})
assert(result.success, "SelectRectangle should succeed")
assert(#mock_selection == 2, string.format("Should have 2 clips, got %d", #mock_selection))
print("✓ Cmd-click: new clip added, existing preserved")

-- Test 4: Cmd-click on already-selected removes
print("\n--- Test 4: SelectRectangle Cmd removes selected ---")
result = command_manager.execute("SelectRectangle", {
    project_id = "proj1",
    sequence_id = "seq1",
    time_start = 0,
    time_end = 50,
    track_ids = { "trk_v1" },
    modifiers = { command = true },
})
assert(result.success, "SelectRectangle should succeed")
assert(#mock_selection == 1, string.format("Should have 1 clip, got %d", #mock_selection))
assert(mock_selection[1].id == "clip_b", "Should be clip_b remaining")
print("✓ Cmd-click on selected: clip removed")

-- Test 5: Empty rectangle clears selection
print("\n--- Test 5: SelectRectangle empty area ---")
mock_selection = { mock_clips[1], mock_clips[2] }
result = command_manager.execute("SelectRectangle", {
    project_id = "proj1",
    sequence_id = "seq1",
    time_start = 1000,
    time_end = 1100,
    track_ids = { "trk_v1" },
    modifiers = {},
})
assert(result.success, "SelectRectangle should succeed")
assert(#mock_selection == 0, "Should have 0 clips after selecting empty area")
print("✓ Empty area: selection cleared")

print("\n✅ test_select_rectangle_command.lua passed")
