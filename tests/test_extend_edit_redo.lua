#!/usr/bin/env luajit

-- Regression test: ExtendEdit redo must work
-- Bug: During redo, ExtendEdit executor ran and tried to call command_manager.execute()
-- which failed because there was no active command event during redo.

require("test_env")

local database = require("core.database")
local command_manager = require("core.command_manager")
local Command = require("command")
local SCHEMA_SQL = require("import_schema")

local TEST_DB = "/tmp/jve/test_extend_edit_redo.db"
os.remove(TEST_DB)

assert(database.init(TEST_DB))
local db = database.get_connection()
assert(db:exec(SCHEMA_SQL))

local now = os.time()
assert(db:exec(string.format([[
    INSERT INTO projects (id, name, created_at, modified_at)
    VALUES ('default_project', 'Default Project', %d, %d);

    INSERT INTO sequences (
        id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_rate,
        width, height, view_start_frame, view_duration_frames, playhead_frame,
        created_at, modified_at
    )
    VALUES ('default_sequence', 'default_project', 'Timeline', 'timeline', 30, 1, 48000, 1920, 1080, 0, 600, 0, %d, %d);

    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
    VALUES ('track_v1', 'default_sequence', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0),
           ('track_v2', 'default_sequence', 'V2', 'VIDEO', 2, 1, 0, 0, 0, 1.0, 0.0);

    INSERT INTO media (id, project_id, name, file_path, duration_frames, fps_numerator, fps_denominator, width, height, audio_channels, codec, metadata, created_at, modified_at)
    VALUES ('media1', 'default_project', 'Media', 'synthetic://media1', 10000, 30, 1, 1920, 1080, 0, 'raw', '{}', %d, %d);

    -- Two clips on separate tracks: out-points at frame 100
    INSERT INTO clips (id, project_id, clip_kind, name, track_id, media_id, owner_sequence_id,
                       timeline_start_frame, duration_frames, source_in_frame, source_out_frame,
                       fps_numerator, fps_denominator, enabled, offline,
                       created_at, modified_at)
    VALUES ('clip_v1', 'default_project', 'timeline', 'ClipV1', 'track_v1', 'media1', 'default_sequence',
            0, 100, 0, 100, 30, 1, 1, 0, %d, %d),
           ('clip_v2', 'default_project', 'timeline', 'ClipV2', 'track_v2', 'media1', 'default_sequence',
            0, 100, 0, 100, 30, 1, 1, 0, %d, %d);
]], now, now, now, now, now, now, now, now, now, now)))

local timeline_state = require("ui.timeline.timeline_state")

-- Stub timeline state functions
timeline_state.capture_viewport = function()
    return {start_value = 0, duration_value = 600, timebase_type = "video_frames", timebase_rate = 30.0}
end
timeline_state.push_viewport_guard = function() end
timeline_state.pop_viewport_guard = function() end
timeline_state.restore_viewport = function(_) end
timeline_state.set_selection = function(_) end
timeline_state.set_edge_selection = function(_) end
timeline_state.restore_edge_selection = function(_) end
timeline_state.set_gap_selection = function(_) end
timeline_state.clear_edge_selection = function() end
timeline_state.clear_gap_selection = function() end
timeline_state.normalize_edge_selection = function() end

-- Pre-select both out-edges (triggers BatchRippleEdit)
local pre_selected_edges = {
    {clip_id = "clip_v1", edge_type = "out", track_id = "track_v1", trim_type = "ripple"},
    {clip_id = "clip_v2", edge_type = "out", track_id = "track_v2", trim_type = "ripple"},
}

timeline_state.get_selected_clips = function() return {} end
timeline_state.get_selected_edges = function() return pre_selected_edges end
timeline_state.get_selected_gaps = function() return {} end
timeline_state.set_playhead_position = function(_) end
timeline_state.get_playhead_position = function() return 150 end
timeline_state.get_project_id = function() return "default_project" end
timeline_state.get_sequence_id = function() return "default_sequence" end
timeline_state.get_sequence_frame_rate = function() return {fps_numerator = 30, fps_denominator = 1} end
timeline_state.reload_clips = function(_) end
timeline_state.consume_mutation_failure = function() return nil end
timeline_state.apply_mutations = function(_, _) return true end

command_manager.init("default_sequence", "default_project")

-- Execute ExtendEdit (spawns nested BatchRippleEdit)
local extend_cmd = Command.create("ExtendEdit", "default_project")
extend_cmd:set_parameter("edge_infos", pre_selected_edges)
extend_cmd:set_parameter("playhead_frame", 150)
extend_cmd:set_parameter("sequence_id", "default_sequence")
extend_cmd:set_parameter("project_id", "default_project")

local result = command_manager.execute(extend_cmd)
assert(result.success, result.error_message or "ExtendEdit failed")

-- Verify clips extended
local Clip = require("models.clip")
local clip_v1 = Clip.load("clip_v1")
assert(clip_v1.duration == 150, "clip_v1 should extend to 150 frames")

-- Undo
local undo_result = command_manager.undo()
assert(undo_result.success, undo_result.error_message or "Undo failed")

-- Verify clips reverted
clip_v1 = Clip.load("clip_v1")
assert(clip_v1.duration == 100, "clip_v1 should revert to 100 frames after undo")

-- REDO - this is the key test
local redo_result = command_manager.redo()
assert(redo_result.success, redo_result.error_message or "Redo failed")

-- Verify clips extended again
clip_v1 = Clip.load("clip_v1")
assert(clip_v1.duration == 150, "clip_v1 should extend to 150 frames after redo, got " .. tostring(clip_v1.duration))

print("✅ test_extend_edit_redo.lua passed")
