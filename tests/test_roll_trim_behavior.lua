#!/usr/bin/env luajit

require("test_env")

local database = require("core.database")
local command_manager = require("core.command_manager")
local timeline_state = require("ui.timeline.timeline_state")
local Command = require("command")
local SCHEMA_SQL = require("import_schema")

local TEST_DB = "/tmp/jve/test_roll_trim_behavior.db"
os.remove(TEST_DB)

assert(database.init(TEST_DB))
local db = database.get_connection()

assert(db:exec(SCHEMA_SQL))

local now = os.time()

local seed = string.format([[
    INSERT INTO projects (id, name, created_at, modified_at)
    VALUES ('default_project', 'Default Project', %d, %d);

    INSERT INTO sequences (
        id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_rate,
        width, height, view_start_frame, view_duration_frames, playhead_frame,
        created_at, modified_at
    )
    VALUES ('default_sequence', 'default_project', 'Timeline', 'timeline', 1000, 1, 48000, 1920, 1080, 0, 240, 0, %d, %d);

    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
    VALUES ('track_v1', 'default_sequence', 'Video 1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);

    INSERT INTO media (id, project_id, name, file_path, duration_frames, fps_numerator, fps_denominator, width, height, audio_channels, codec, metadata, created_at, modified_at)
    VALUES ('media1', 'default_project', 'Media', 'synthetic://media1', 5000, 1000, 1, 1920, 1080, 0, 'raw', '{}', %d, %d);

    INSERT INTO clips (id, project_id, clip_kind, name, track_id, media_id, owner_sequence_id,
                       timeline_start_frame, duration_frames, source_in_frame, source_out_frame, fps_numerator, fps_denominator, enabled, offline,
                       created_at, modified_at)
    VALUES
        ('clip_left', 'default_project', 'timeline', 'Left', 'track_v1', 'media1', 'default_sequence',
         0, 1000, 0, 1000, 1000, 1, 1, 0, %d, %d),
        ('clip_right', 'default_project', 'timeline', 'Right', 'track_v1', 'media1', 'default_sequence',
         1000, 1000, 0, 1000, 1000, 1, 1, 0, %d, %d),
        ('clip_downstream', 'default_project', 'timeline', 'Downstream', 'track_v1', 'media1', 'default_sequence',
         2000, 1000, 0, 1000, 1000, 1, 1, 0, %d, %d);
]], now, now, now, now, now, now, now, now, now, now, now, now)

assert(db:exec(seed))

-- Minimal timeline_state stubs (command_manager expects these callbacks)
timeline_state.get_project_id = function() return "default_project" end
timeline_state.get_sequence_id = function() return "default_sequence" end
timeline_state.reload_clips = function() end
timeline_state.set_playhead_position = function(_) end
timeline_state.capture_viewport = function() return {start_value = 0, duration_value = 3000, timebase_type = "video_frames", timebase_rate = 1000.0} end
timeline_state.push_viewport_guard = function() end
timeline_state.pop_viewport_guard = function() end
timeline_state.restore_viewport = function(_) end
timeline_state.set_selection = function(_) end
timeline_state.set_edge_selection = function(_) end
timeline_state.set_gap_selection = function(_) end
timeline_state.get_sequence_frame_rate = function() return {fps_numerator = 1000, fps_denominator = 1} end

command_manager.init("default_sequence", "default_project")

local function fetch_start(clip_id)
    local stmt = db:prepare("SELECT timeline_start_frame FROM clips WHERE id = ?")
    stmt:bind_value(1, clip_id)
    assert(stmt:exec() and stmt:next(), "missing clip " .. tostring(clip_id))
    local value = tonumber(stmt:value(0))
    stmt:finalize()
    return value
end

local function fetch_duration(clip_id)
    local stmt = db:prepare("SELECT duration_frames FROM clips WHERE id = ?")
    stmt:bind_value(1, clip_id)
    assert(stmt:exec() and stmt:next(), "missing clip " .. tostring(clip_id))
    local value = tonumber(stmt:value(0))
    stmt:finalize()
    return value
end

local roll_edges = {
    {clip_id = "clip_left", edge_type = "out", track_id = "track_v1", trim_type = "roll"},
    {clip_id = "clip_right", edge_type = "in", track_id = "track_v1", trim_type = "roll"},
}

local cmd = Command.create("BatchRippleEdit", "default_project")
cmd:set_parameter("edge_infos", roll_edges)
cmd:set_parameter("delta_frames", 120) -- 120ms at 1000fps == 120 frames
cmd:set_parameter("sequence_id", "default_sequence")

local result = command_manager.execute(cmd)
assert(result.success, result.error_message or "BatchRippleEdit execution failed")

-- Expected roll behaviour: downstream clip stays anchored, combined boundary shifts locally.
assert(fetch_start("clip_downstream") == 2000, "Roll edit should not ripple downstream clips")
assert(fetch_duration("clip_left") == 1120, "Roll edit should extend left clip duration")
assert(fetch_start("clip_right") == 1120, "Roll edit should adjust right clip start")

local undo_result = command_manager.undo()
assert(undo_result.success, undo_result.error_message or "Undo failed after roll edit")
assert(fetch_start("clip_downstream") == 2000, "Undo should restore downstream clip position")
assert(fetch_duration("clip_left") == 1000, "Undo should restore left clip duration")
assert(fetch_start("clip_right") == 1000, "Undo should restore right clip start")

os.remove(TEST_DB)
print("✅ Roll trim regression fixed")
