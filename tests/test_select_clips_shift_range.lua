#!/usr/bin/env luajit

-- Shift+Click range select: box selection from anchor to target (Resolve-style).
-- Tests anchor tracking, time×track box, and same-type-only constraint.

require("test_env")

local database = require("core.database")
local command_manager = require("core.command_manager")
local timeline_state = require("ui.timeline.timeline_state")

local db_path = "/tmp/jve/test_select_clips_shift_range.db"
os.remove(db_path)
assert(database.init(db_path))
local db = database.get_connection()
db:exec(require("import_schema"))

local now = os.time()

db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
    VALUES ('proj', 'Test', 'resample', '{"master_clock_hz":192000,"default_fps":{"num":24,"den":1}}', %d, %d);
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator,
        audio_sample_rate, width, height, view_start_frame, view_duration_frames,
        playhead_frame, selected_clip_ids, selected_edge_infos, created_at, modified_at)
    VALUES ('seq', 'proj', 'Seq', 'sequence', 25, 1, 48000,
        1920, 1080, 0, 8000, 0, '[]', '[]', %d, %d);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index,
        enabled, locked, muted, soloed, volume, pan)
    VALUES ('v1', 'seq', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index,
        enabled, locked, muted, soloed, volume, pan)
    VALUES ('v2', 'seq', 'V2', 'VIDEO', 2, 1, 0, 0, 0, 1.0, 0.0);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index,
        enabled, locked, muted, soloed, volume, pan)
    VALUES ('a1', 'seq', 'A1', 'AUDIO', 1, 1, 0, 0, 0, 1.0, 0.0);
]], now, now, now, now))

command_manager.init("seq", "proj")

-- Mock clips across 2 video tracks and 1 audio track
local mock_clips = {
    { id = "v1_a", track_id = "v1", sequence_start = 0,   duration = 100 },
    { id = "v1_b", track_id = "v1", sequence_start = 200, duration = 100 },
    { id = "v2_a", track_id = "v2", sequence_start = 50,  duration = 150 },
    { id = "v2_b", track_id = "v2", sequence_start = 300, duration = 100 },
    { id = "a1_a", track_id = "a1", sequence_start = 0,   duration = 200 },
}

local mock_tracks = {
    v1 = { id = "v1", track_type = "VIDEO", track_index = 1 },
    v2 = { id = "v2", track_type = "VIDEO", track_index = 2 },
    a1 = { id = "a1", track_type = "AUDIO", track_index = 1 },
}

local mock_selection = {}

timeline_state.get_selected_clips = function() return mock_selection end
timeline_state.set_selection = function(clips) mock_selection = clips end
timeline_state.get_clip_by_id = function(clip_id)
    for _, c in ipairs(mock_clips) do if c.id == clip_id then return c end end
    return nil
end
timeline_state.get_clips = function() return mock_clips end
timeline_state.get_track_by_id = function(track_id) return mock_tracks[track_id] end
timeline_state.get_track_index = function(track_id)
    return mock_tracks[track_id] and mock_tracks[track_id].track_index
end
timeline_state.clear_edge_selection = function() end

----------------------------------------------------------------------
-- Test 1: Click v1_a (no shift) to set anchor, then Shift+Click v2_b
-- Box: time [0,400), tracks [1,2] → should select v1_a, v1_b, v2_a, v2_b
----------------------------------------------------------------------
print("\n--- Test 1: Shift+Click range select across two video tracks ---")

-- First click: establish anchor on v1_a
mock_selection = {}
local r1 = command_manager.execute("SelectClips", {
    project_id = "proj", sequence_id = "seq",
    target_clip_ids = { "v1_a" },
    modifiers = {},
})
assert(r1.success, "anchor click should succeed: " .. (r1.error_message or ""))

-- Shift+Click on v2_b
local r2 = command_manager.execute("SelectClips", {
    project_id = "proj", sequence_id = "seq",
    target_clip_ids = { "v2_b" },
    modifiers = { shift = true },
})
assert(r2.success, "shift+click should succeed: " .. (r2.error_message or ""))

-- Expect: all 4 video clips in the time×track box
local ids = {}
for _, c in ipairs(mock_selection) do ids[c.id] = true end
assert(ids["v1_a"], "v1_a should be in range selection")
assert(ids["v1_b"], "v1_b should be in range selection")
assert(ids["v2_a"], "v2_a should be in range selection")
assert(ids["v2_b"], "v2_b should be in range selection")
assert(not ids["a1_a"], "audio clip a1_a should NOT be in video range selection")
print("✓ Shift+Click selects box of video clips across tracks")

----------------------------------------------------------------------
-- Test 2: Same-type constraint — anchor on audio, shift to audio
----------------------------------------------------------------------
print("\n--- Test 2: Shift+Click stays within same track type ---")

mock_selection = {}
assert(command_manager.execute("SelectClips", {
    project_id = "proj", sequence_id = "seq",
    target_clip_ids = { "a1_a" },
    modifiers = {},
}).success)

-- Shift+Click on a1_a itself (trivial range)
assert(command_manager.execute("SelectClips", {
    project_id = "proj", sequence_id = "seq",
    target_clip_ids = { "a1_a" },
    modifiers = { shift = true },
}).success)

assert(#mock_selection == 1, string.format("should select 1 audio clip, got %d", #mock_selection))
assert(mock_selection[1].id == "a1_a", "should be a1_a")
print("✓ Audio anchor + audio target selects only audio clips")

----------------------------------------------------------------------
-- Test 3: Shift+Click without prior anchor falls through to normal select
----------------------------------------------------------------------
print("\n--- Test 3: Shift+Click without anchor = normal select ---")

-- Reset module to clear anchor (re-require won't work, but we can test
-- that clicking with shift when anchor has no position data still works)
mock_selection = {}

-- Click a clip with no sequence_start to clear anchor, then shift+click
local clip_no_pos = { id = "phantom", track_id = "v1" }
table.insert(mock_clips, clip_no_pos)
assert(command_manager.execute("SelectClips", {
    project_id = "proj", sequence_id = "seq",
    target_clip_ids = { "phantom" },
    modifiers = {},
}).success)
table.remove(mock_clips, #mock_clips)  -- remove phantom

-- Now shift+click on v1_b — anchor has no position data, should fall through
local r3 = command_manager.execute("SelectClips", {
    project_id = "proj", sequence_id = "seq",
    target_clip_ids = { "v1_b" },
    modifiers = { shift = true },
})
assert(r3.success, "shift without valid anchor should succeed: " .. (r3.error_message or ""))
-- Should fall through to normal select — v1_b should be selected
assert(#mock_selection >= 1, "should have at least one clip selected")
print("✓ Shift+Click without valid anchor falls through to normal select")

print("✅ test_select_clips_shift_range.lua passed")
