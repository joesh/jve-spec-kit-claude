#!/usr/bin/env luajit

-- Regression test: Multi-track roll should use per-edge constraints independently.
-- Bug: Roll constraints from one track were limiting edits on other tracks.
-- Fix: Roll edges don't contribute to global constraints; each track extends independently.

require("test_env")

local database = require("core.database")
local command_manager = require("core.command_manager")
local Command = require("command")
local timeline_state = require("ui.timeline.timeline_state")

print("\n=== BatchRippleEdit: Multi-track roll with independent constraints ===")

local TEST_DB = "/tmp/jve/test_batch_ripple_roll_multitrack_independent.db"
os.remove(TEST_DB)

assert(database.init(TEST_DB))
local db = database.get_connection()
db:exec(require('import_schema'))

local now = os.time()

-- Setup: Two video tracks with clips at [0..100)
-- Track 1: clip_a has no next neighbor (space to extend)
-- Track 2: clip_b has blocking_clip immediately at 100 (no space)
local seed = string.format([[
    INSERT INTO projects (id, name, created_at, modified_at)
    VALUES ('proj', 'Test Project', %d, %d);

    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, audio_rate, width, height, playhead_frame, selected_clip_ids, selected_edge_infos, view_start_frame, view_duration_frames, created_at, modified_at)
    VALUES ('seq', 'proj', 'Timeline', 'timeline', 30, 1, 48000, 1920, 1080, 0, '[]', '[]', 0, 240, %d, %d);

    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
    VALUES ('track1', 'seq', 'Video 1', 'VIDEO', 0, 1),
           ('track2', 'seq', 'Video 2', 'VIDEO', 1, 1);

    INSERT INTO media (id, project_id, name, file_path, duration_frames, fps_numerator, fps_denominator, width, height, audio_channels, codec, metadata, created_at, modified_at)
    VALUES ('media1', 'proj', 'Stub', '/tmp/test.mp4', 200, 30, 1, 1920, 1080, 2, 'prores', '{}', %d, %d);

    INSERT INTO clips (id, project_id, clip_kind, name, track_id, owner_sequence_id, media_id,
                       timeline_start_frame, duration_frames, source_in_frame, source_out_frame, fps_numerator, fps_denominator, enabled, offline,
                       created_at, modified_at)
    VALUES
        -- Track 1: [0..100), no next clip (can extend)
        ('clip_a', 'proj', 'timeline', 'A', 'track1', 'seq', 'media1',
         0, 100, 0, 100, 30, 1, 1, 0, %d, %d),
        -- Track 2: [0..100), has blocking clip at 100
        ('clip_b', 'proj', 'timeline', 'B', 'track2', 'seq', 'media1',
         0, 100, 0, 100, 30, 1, 1, 0, %d, %d),
        -- Blocking clip at [100..150)
        ('blocking', 'proj', 'timeline', 'Block', 'track2', 'seq', 'media1',
         100, 50, 0, 50, 30, 1, 1, 0, %d, %d);
]], now, now, now, now, now, now, now, now, now, now, now, now)

assert(db:exec(seed))

-- Stub timeline_state
timeline_state.capture_viewport = function()
    return {start_value = 0, duration_value = 240, timebase_type = "video_frames", timebase_rate = 30}
end
timeline_state.push_viewport_guard = function() end
timeline_state.pop_viewport_guard = function() end
timeline_state.get_selected_clips = function() return {} end
timeline_state.set_selection = function() end
timeline_state.clear_selection = function() end
timeline_state.get_sequence_id = function() return "seq" end
timeline_state.get_project_id = function() return "proj" end

command_manager.init("seq", "proj")
command_manager.begin_command_event("test")

-- Test: Roll both out edges with delta_frames = 50
-- Track 1 should get full 50 (has space)
-- Track 2 should get 0 (blocked by adjacent clip)
local result = command_manager.execute("BatchRippleEdit", {
    edge_infos = {
        { clip_id = "clip_a", edge_type = "out", track_id = "track1", trim_type = "roll" },
        { clip_id = "clip_b", edge_type = "out", track_id = "track2", trim_type = "roll" },
    },
    delta_frames = 50,
    sequence_id = "seq",
    project_id = "proj",
})

command_manager.end_command_event()

assert(result.success, "BatchRippleEdit should succeed: " .. tostring(result.error_message))

-- Reload clips to check final state
local Clip = require("models.clip")
local clip_a_reloaded = Clip.load("clip_a", db)
local clip_b_reloaded = Clip.load("clip_b", db)

assert(clip_a_reloaded, "clip_a should exist after edit")
assert(clip_b_reloaded, "clip_b should exist after edit")

local clip_a_dur = clip_a_reloaded.duration
local clip_b_dur = clip_b_reloaded.duration

local passed = true

-- Track 1: should extend by 50 frames (100 + 50 = 150)
if clip_a_dur ~= 150 then
    print(string.format("FAIL: Track 1 clip should extend to 150, got %s", tostring(clip_a_dur)))
    passed = false
else
    print("PASS: Track 1 extended to 150 (has space)")
end

-- Track 2: should stay at 100 (blocked by adjacent clip, roll constraint = 0)
if clip_b_dur ~= 100 then
    print(string.format("FAIL: Track 2 clip should stay at 100 (blocked), got %s", tostring(clip_b_dur)))
    passed = false
else
    print("PASS: Track 2 stayed at 100 (blocked by adjacent clip)")
end

if not passed then
    print("\nFAIL: Multi-track roll constraints not independent")
    os.exit(1)
end

print("\n" .. string.char(0xe2, 0x9c, 0x85) .. " test_batch_ripple_roll_multitrack_independent.lua passed")
