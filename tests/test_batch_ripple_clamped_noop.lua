#!/usr/bin/env luajit

require("test_env")

local database = require("core.database")
local command_manager = require("core.command_manager")
local Command = require("command")
local SCHEMA_SQL = require("import_schema")

local TEST_DB = "/tmp/jve/test_batch_ripple_clamped_noop.db"
os.remove(TEST_DB)

assert(database.init(TEST_DB))
local db = database.get_connection()
assert(db:exec(SCHEMA_SQL))

local now = os.time()
local seed = string.format([[
    INSERT INTO projects (id, name, created_at, modified_at)
    VALUES ('default_project', 'Default Project', %d, %d);

    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, audio_rate, width, height,
                          playhead_frame, view_start_frame, view_duration_frames, created_at, modified_at)
    VALUES ('default_sequence', 'default_project', 'Timeline', 'timeline', 30, 1, 48000, 1920, 1080, 0, 0, 240, %d, %d);

    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
    VALUES ('track_v1', 'default_sequence', 'Video 1', 'VIDEO', 1, 1);

    INSERT INTO media (id, project_id, name, file_path, duration_frames, fps_numerator, fps_denominator, width, height, audio_channels, codec, created_at, modified_at)
    VALUES ('media1', 'default_project', 'Media', 'synthetic://media1', 1000, 30, 1, 1920, 1080, 0, 'raw', %d, %d);

    -- Track V1: left/right with gap
    -- 2000ms @ 30fps = 60 frames. 5000ms = 150 frames.
    -- Left: 0-30 (1000ms)
    -- Right: 30-60 (1000ms)
    INSERT INTO clips (id, project_id, clip_kind, name, track_id, media_id, owner_sequence_id,
                       timeline_start_frame, duration_frames, source_in_frame, source_out_frame, fps_numerator, fps_denominator, enabled, offline,
                       created_at, modified_at)
    VALUES
        ('clip_left', 'default_project', 'timeline', 'Left', 'track_v1', 'media1', 'default_sequence',
         0, 30, 0, 30, 30, 1, 1, 0, %d, %d),
        ('clip_right', 'default_project', 'timeline', 'Right', 'track_v1', 'media1', 'default_sequence',
         30, 30, 0, 30, 30, 1, 1, 0, %d, %d);
]], now, now, now, now, now, now, now, now, now, now)
assert(db:exec(seed))

-- Minimal timeline_state stubs
local timeline_state = require("ui.timeline.timeline_state")
timeline_state.capture_viewport = function()
    return {start_value = 0, duration_value = 240, timebase_type = "video_frames", timebase_rate = 30.0}
end
timeline_state.push_viewport_guard = function() end
timeline_state.pop_viewport_guard = function() end
timeline_state.restore_viewport = function(_) end
timeline_state.set_selection = function(_) end
timeline_state.set_edge_selection = function(_) end
timeline_state.set_gap_selection = function(_) end
timeline_state.get_selected_clips = function() return {} end
timeline_state.get_selected_edges = function() return {} end
timeline_state.set_playhead_position = function(_) end
timeline_state.get_playhead_position = function() return 0 end
timeline_state.get_project_id = function() return "default_project" end
timeline_state.get_sequence_id = function() return "default_sequence" end
timeline_state.reload_clips = function(_) end
timeline_state.consume_mutation_failure = function() return nil end
timeline_state.apply_mutations = function(_, _) return true end

command_manager.init(db, "default_sequence", "default_project")

local function fetch_clip_start(clip_id)
    local stmt = db:prepare("SELECT timeline_start_frame FROM clips WHERE id = ?")
    stmt:bind_value(1, clip_id)
    assert(stmt:exec() and stmt:next(), "clip not found: " .. tostring(clip_id))
    local value = tonumber(stmt:value(0)) or 0
    stmt:finalize()
    -- Convert ticks back to approx MS for assertion consistency
    return math.floor(value / 30.0 * 1000.0 + 0.5)
end

local function fetch_clip_duration(clip_id)
    local stmt = db:prepare("SELECT duration_frames FROM clips WHERE id = ?")
    stmt:bind_value(1, clip_id)
    assert(stmt:exec() and stmt:next(), "clip not found: " .. tostring(clip_id))
    local value = tonumber(stmt:value(0)) or 0
    stmt:finalize()
    return math.floor(value / 30.0 * 1000.0 + 0.5)
end

-- Adjacent clips roll edit: Left Out moves Right, Right In moves Right.
-- Delta = 500ms (15 frames).
-- Left: 30 -> 45 frames (1500ms).
-- Right: Start 30 -> 45 frames (1500ms). Duration 30 -> 15 frames (500ms).

local edges = {
    {clip_id = "clip_left", edge_type = "out", track_id = "track_v1", trim_type = "roll"},
    {clip_id = "clip_right", edge_type = "in", track_id = "track_v1", trim_type = "roll"},
}

local cmd = Command.create("BatchRippleEdit", "default_project")
cmd:set_parameter("edge_infos", edges)
cmd:set_parameter("delta_frames", 15) -- 500ms @30fps
cmd:set_parameter("sequence_id", "default_sequence")

local result = command_manager.execute(cmd)
assert(result.success, result.error_message or "BatchRippleEdit should succeed")

-- Check values
local left_dur = fetch_clip_duration("clip_left")
local right_start = fetch_clip_start("clip_right")
local right_dur = fetch_clip_duration("clip_right")

assert(left_dur == 1500, "left clip extended to 1500ms (was " .. tostring(left_dur) .. ")")
assert(right_start == 1500, "right clip moved to 1500ms (was " .. tostring(right_start) .. ")")
assert(right_dur == 500, "right clip shrank to 500ms (was " .. tostring(right_dur) .. ")")

local undo_result = command_manager.undo()
assert(undo_result.success, undo_result.error_message or "Undo should succeed")
assert(fetch_clip_start("clip_left") == 0, "left clip start unchanged after undo")
assert(fetch_clip_duration("clip_left") == 1000, "left clip duration unchanged after undo")
assert(fetch_clip_start("clip_right") == 1000, "right clip start unchanged after undo")

os.remove(TEST_DB)
print("✅ BatchRippleEdit Roll Edit behavior verified")
