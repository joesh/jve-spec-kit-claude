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

    INSERT INTO sequences (id, project_id, name, kind, frame_rate, width, height, viewport_duration)
    VALUES ('default_sequence', 'default_project', 'Timeline', 'timeline', 30.0, 1920, 1080, 10000);

    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
    VALUES ('track_v1', 'default_sequence', 'Video 1', 'VIDEO', 1, 1);

    INSERT INTO media (id, project_id, name, duration, frame_rate, width, height)
    VALUES ('media1', 'default_project', 'Media', 1000, 30.0, 1920, 1080);

    INSERT INTO clips (id, project_id, clip_kind, name, track_id, media_id, source_sequence_id, parent_clip_id, owner_sequence_id,
                       start_time, duration, source_in, source_out, enabled, offline,
                       created_at, modified_at)
    VALUES
        ('clip_left', 'default_project', 'timeline', 'Left', 'track_v1', 'media1', 'default_sequence', NULL, 'default_sequence',
         0, 1000, 0, 1000, 1, 0, %d, %d),
        ('clip_right', 'default_project', 'timeline', 'Right', 'track_v1', 'media1', 'default_sequence', NULL, 'default_sequence',
         1000, 1000, 0, 1000, 1, 0, %d, %d);
]], now, now, now, now, now, now, now, now)
assert(db:exec(seed))

-- Minimal timeline_state stubs
local timeline_state = require("ui.timeline.timeline_state")
timeline_state.capture_viewport = function() return {start_time = 0, duration = 10000} end
timeline_state.push_viewport_guard = function() end
timeline_state.pop_viewport_guard = function() end
timeline_state.restore_viewport = function(_) end
timeline_state.set_selection = function(_) end
timeline_state.set_edge_selection = function(_) end
timeline_state.set_gap_selection = function(_) end
timeline_state.get_selected_clips = function() return {} end
timeline_state.get_selected_edges = function() return {} end
timeline_state.set_playhead_time = function(_) end
timeline_state.get_playhead_time = function() return 0 end
timeline_state.get_project_id = function() return "default_project" end
timeline_state.get_sequence_id = function() return "default_sequence" end
timeline_state.reload_clips = function(_) end
timeline_state.consume_mutation_failure = function() return nil end
timeline_state.apply_mutations = function(_, _) return true end

command_manager.init(db, "default_sequence", "default_project")

local function fetch_clip_start(clip_id)
    local stmt = db:prepare("SELECT start_time FROM clips WHERE id = ?")
    stmt:bind_value(1, clip_id)
    assert(stmt:exec() and stmt:next(), "clip not found: " .. tostring(clip_id))
    local value = tonumber(stmt:value(0)) or 0
    stmt:finalize()
    return value
end

local function fetch_clip_duration(clip_id)
    local stmt = db:prepare("SELECT duration FROM clips WHERE id = ?")
    stmt:bind_value(1, clip_id)
    assert(stmt:exec() and stmt:next(), "clip not found: " .. tostring(clip_id))
    local value = tonumber(stmt:value(0)) or 0
    stmt:finalize()
    return value
end

-- Adjacent clips: out edge of left cannot move right (constraint max 0), in edge of right cannot move left.
local edges = {
    {clip_id = "clip_left", edge_type = "out", track_id = "track_v1"},
    {clip_id = "clip_right", edge_type = "in", track_id = "track_v1"},
}

local cmd = Command.create("BatchRippleEdit", "default_project")
cmd:set_parameter("edge_infos", edges)
cmd:set_parameter("delta_ms", 500) -- would overlap, should clamp to 0 and no-op
cmd:set_parameter("sequence_id", "default_sequence")

local result = command_manager.execute(cmd)
assert(result.success, result.error_message or "BatchRippleEdit should succeed as a no-op when fully clamped")
assert(fetch_clip_start("clip_left") == 0, "left clip start unchanged")
assert(fetch_clip_duration("clip_left") == 1000, "left clip duration unchanged")
assert(fetch_clip_start("clip_right") == 1000, "right clip start unchanged")

local undo_result = command_manager.undo()
assert(undo_result.success, undo_result.error_message or "Undo should succeed after clamped no-op")
assert(fetch_clip_start("clip_left") == 0, "left clip start unchanged after undo")
assert(fetch_clip_start("clip_right") == 1000, "right clip start unchanged after undo")

os.remove(TEST_DB)
print("✅ BatchRippleEdit no longer fails replay when clamped to no-op")
