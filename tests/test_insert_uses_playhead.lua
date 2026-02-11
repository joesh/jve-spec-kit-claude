#!/usr/bin/env luajit

-- Regression test: Insert command should use playhead position when insert_time not specified
-- Bug: insert_time had default=0 in SPEC, so it was never nil, and playhead was never consulted

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
local test_env = require('test_env')

local database = require('core.database')
local Clip = require('models.clip')
local Media = require('models.media')
local Command = require('command')
local command_manager = require('core.command_manager')
local Rational = require('core.rational')

-- Mock Qt timer
_G.qt_create_single_shot_timer = function(delay, cb) cb(); return nil end

print("=== Insert Uses Playhead Position Test ===\n")

-- Setup DB
local db_path = "/tmp/jve/test_insert_uses_playhead.db"
os.remove(db_path)
os.execute("mkdir -p /tmp/jve")
database.init(db_path)
local db = database.get_connection()
db:exec(require('import_schema'))

-- Disable overlap triggers for cleaner testing
db:exec("DROP TRIGGER IF EXISTS trg_prevent_video_overlap_insert;")
db:exec("DROP TRIGGER IF EXISTS trg_prevent_video_overlap_update;")

-- Insert Project/Sequence (30fps)
local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, created_at, modified_at) VALUES ('project', 'Test Project', %d, %d);
]], now, now))
db:exec(string.format([[
    INSERT INTO sequences (id, project_id, name, fps_numerator, fps_denominator, audio_rate, width, height, created_at, modified_at)
    VALUES ('sequence', 'project', 'Test Sequence', 30, 1, 48000, 1920, 1080, %d, %d);
]], now, now))
db:exec([[
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
    VALUES ('track_v1', 'sequence', 'V1', 'VIDEO', 1, 1);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
    VALUES ('track_a1', 'sequence', 'A1', 'AUDIO', 1, 1);
]])

command_manager.init('sequence', 'project')

-- Create Media (100 frames @ 30fps)
local media = Media.create({
    id = "media_video",
    project_id = "project",
    file_path = "/tmp/jve/video.mov",
    name = "Video",
    duration_frames = 100,
    fps_numerator = 30,
    fps_denominator = 1
})
media:save(db)

-- Create masterclip sequence for this media (required for Insert)
local master_clip_id = test_env.create_test_masterclip_sequence(
    "project", "Video Master", 30, 1, 100, "media_video")

-- Mock timeline_state to provide playhead position
local mock_playhead = 150  -- Playhead at frame 150

package.loaded["ui.timeline.timeline_state"] = {
    get_playhead_position = function()
        return mock_playhead
    end,
    get_sequence_id = function()
        return "sequence"
    end,
    get_sequence_frame_rate = function()
        return Rational.new(1, 30, 1)  -- 30fps
    end,
    set_playhead_position = function(pos)
        mock_playhead = pos
    end,
    get_selected_clip_ids = function()
        return {}
    end,
    get_selected_edge_infos = function()
        return {}
    end,
    get_selected_gap_infos = function()
        return {}
    end,
    get_selected_clips = function()
        return {}
    end,
    get_selected_edges = function()
        return {}
    end,
    get_selected_gaps = function()
        return {}
    end,
    reload_clips = function() end
}

-- Helper: execute command by name (goes through schema validation which applies defaults)
local function execute_insert(params)
    command_manager.begin_command_event("script")
    local result = command_manager.execute("Insert", params)
    command_manager.end_command_event()
    return result
end

-- Helper: get clip position
local function get_clip_position(clip_id)
    local stmt = db:prepare("SELECT timeline_start_frame, duration_frames FROM clips WHERE id = ?")
    stmt:bind_value(1, clip_id)
    stmt:exec()
    if stmt:next() then
        local start = stmt:value(0)
        local dur = stmt:value(1)
        stmt:finalize()
        return start, dur
    end
    stmt:finalize()
    return nil, nil
end

-- Helper: find clip by start position
local function find_clip_at(start_frame)
    local stmt = db:prepare("SELECT id, timeline_start_frame FROM clips WHERE track_id = 'track_v1' AND timeline_start_frame = ?")
    stmt:bind_value(1, start_frame)
    stmt:exec()
    if stmt:next() then
        local id = stmt:value(0)
        stmt:finalize()
        return id
    end
    stmt:finalize()
    return nil
end

-- =============================================================================
-- TEST: Insert without insert_time should use playhead position (frame 150)
-- =============================================================================
print("Test: Insert without insert_time uses playhead position")

-- NOTE: insert_time is NOT provided - should use playhead (frame 150)
local result = execute_insert({
    master_clip_id = master_clip_id,
    track_id = "track_v1",
    sequence_id = "sequence",
    project_id = "project",
    duration = 50,
    source_in = 0,
    source_out = 50,
})
assert(result.success, "Insert should succeed: " .. tostring(result.error_message))

-- Verify clip was inserted at playhead position (150), NOT at 0
local clip_at_0 = find_clip_at(0)
local clip_at_150 = find_clip_at(150)

assert(clip_at_0 == nil, "Should NOT have clip at frame 0 (was wrongly defaulting insert_time to 0)")
assert(clip_at_150 ~= nil, "Should have clip at frame 150 (playhead position)")

local start, dur = get_clip_position(clip_at_150)
assert(start == 150, string.format("Clip should start at 150, got %s", tostring(start)))
assert(dur == 50, string.format("Clip should have duration 50, got %s", tostring(dur)))

print("  ✓ Clip correctly inserted at playhead position (frame 150)")

print("\n✅ test_insert_uses_playhead.lua passed")
