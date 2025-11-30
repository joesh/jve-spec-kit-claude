#!/usr/bin/env luajit

require("test_env")

local database = require("core.database")
local command_manager = require("core.command_manager")
local Command = require("command")
local SCHEMA_SQL = require("import_schema")

local TEST_DB = "/tmp/jve/test_ripple_temp_gap_sanitize.db"
os.remove(TEST_DB)

assert(database.init(TEST_DB))
local db = database.get_connection()
assert(db:exec(SCHEMA_SQL))

local now = os.time()
local seed = string.format([[
    INSERT INTO projects (id, name, created_at, modified_at)
    VALUES ('default_project', 'Default Project', %d, %d);

    INSERT INTO sequences (id, project_id, name, kind, frame_rate, audio_sample_rate, width, height, timecode_start_frame, playhead_value, viewport_start_value, viewport_duration_frames_value)
    VALUES ('default_sequence', 'default_project', 'Timeline', 'timeline', 30.0, 48000, 1920, 1080, 0, 0, 0, 300);

    INSERT INTO tracks (id, sequence_id, name, track_type, timebase_type, timebase_rate, track_index, enabled)
    VALUES ('track_v1', 'default_sequence', 'Video 1', 'VIDEO', 'video_frames', 30.0, 1, 1);

    INSERT INTO media (id, project_id, name, duration_value, timebase_type, timebase_rate, frame_rate, width, height)
    VALUES ('media1', 'default_project', 'Media', 2000, 'video_frames', 30.0, 30.0, 1920, 1080);

    INSERT INTO clips (id, project_id, clip_kind, name, track_id, media_id, owner_sequence_id,
                       start_value, duration_value, source_in_value, source_out_value, timebase_type, timebase_rate, enabled, offline,
                       created_at, modified_at)
    VALUES
        ('clip_left', 'default_project', 'timeline', 'Left', 'track_v1', 'media1', 'default_sequence',
         0, 1000, 0, 1000, 'video_frames', 30.0, 1, 0, %d, %d),
        ('clip_right', 'default_project', 'timeline', 'Right', 'track_v1', 'media1', 'default_sequence',
         2000, 1000, 0, 1000, 'video_frames', 30.0, 1, 0, %d, %d);
]], now, now, now, now, now, now, now, now)
assert(db:exec(seed))

local timeline_state = require("ui.timeline.timeline_state")
timeline_state.capture_viewport = function() return {start_value = 0, duration_value = 300, timebase_type = "video_frames", timebase_rate = 30} end
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

local function fetch_start(id)
    local stmt = db:prepare("SELECT start_value FROM clips WHERE id = ?")
    stmt:bind_value(1, id)
    assert(stmt:exec() and stmt:next(), "clip not found " .. tostring(id))
    local v = tonumber(stmt:value(0)) or 0
    stmt:finalize()
    return v
end

-- edge_info comes in with temp_gap_ prefix; execute + undo must succeed
local cmd = Command.create("RippleEdit", "default_project")
cmd:set_parameter("edge_info", {clip_id = "temp_gap_clip_left", edge_type = "gap_after", track_id = "track_v1"})
cmd:set_parameter("delta_ms", 500)
cmd:set_parameter("sequence_id", "default_sequence")

local result = command_manager.execute(cmd)
assert(result.success, result.error_message or "RippleEdit failed with temp_gap edge id")
assert(fetch_start("clip_right") == 1500, "right clip should shift when gap closes")

local undo_result = command_manager.undo()
assert(undo_result.success, undo_result.error_message or "Undo failed for temp_gap ripple")
assert(fetch_start("clip_right") == 2000, "right clip restored after undo")

os.remove(TEST_DB)
print("✅ RippleEdit sanitizes temp_gap edge ids for execute and undo")
