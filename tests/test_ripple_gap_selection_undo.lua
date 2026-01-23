#!/usr/bin/env luajit

require("test_env")

local database = require("core.database")
local command_manager = require("core.command_manager")
local Command = require("command")
local SCHEMA_SQL = require("import_schema")

local TEST_DB = "/tmp/jve/test_ripple_gap_selection_undo.db"
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
    VALUES ('track_v1', 'default_sequence', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);

    INSERT INTO media (id, project_id, name, file_path, duration_frames, fps_numerator, fps_denominator, width, height, audio_channels, codec, metadata, created_at, modified_at)
    VALUES ('media1', 'default_project', 'Media', 'synthetic://media1', 10000, 30, 1, 1920, 1080, 0, 'raw', '{}', %d, %d);

    -- Two clips with a 1000ms gap between them (left ends at 3000, right starts at 4000)
    INSERT INTO clips (id, project_id, clip_kind, name, track_id, media_id, owner_sequence_id,
                       timeline_start_frame, duration_frames, source_in_frame, source_out_frame,
                       fps_numerator, fps_denominator, enabled, offline,
                       created_at, modified_at)
    VALUES ('clip_left', 'default_project', 'timeline', 'Left', 'track_v1', 'media1', 'default_sequence',
            0, 3000, 0, 3000, 30, 1, 1, 0, %d, %d),
           ('clip_right', 'default_project', 'timeline', 'Right', 'track_v1', 'media1', 'default_sequence',
            4000, 2000, 3000, 5000, 30, 1, 1, 0, %d, %d);
]], now, now, now, now, now, now, now, now, now, now)))

local timeline_state = require("ui.timeline.timeline_state")

-- Stub timeline state functions needed by command_manager
timeline_state.capture_viewport = function()
    return {start_value = 0, duration_value = 600, timebase_type = "video_frames", timebase_rate = 30.0}
end
timeline_state.push_viewport_guard = function() end
timeline_state.pop_viewport_guard = function() end
timeline_state.restore_viewport = function(_) end
timeline_state.set_selection = function(_) end

local last_edge_selection = nil
timeline_state.set_edge_selection = function(edges)
    last_edge_selection = edges
end
timeline_state.restore_edge_selection = function(edges)
    last_edge_selection = edges
end
timeline_state.set_gap_selection = function(_) end
timeline_state.clear_edge_selection = function() end
timeline_state.clear_gap_selection = function() end
timeline_state.normalize_edge_selection = function() end

local pre_selected_edges = {
    {clip_id = "clip_right", edge_type = "gap_before", track_id = "track_v1"}
}

timeline_state.get_selected_clips = function() return {} end
timeline_state.get_selected_edges = function() return pre_selected_edges end
timeline_state.set_playhead_position = function(_) end
timeline_state.get_playhead_position = function() return 0 end
timeline_state.get_project_id = function() return "default_project" end
timeline_state.get_sequence_id = function() return "default_sequence" end
timeline_state.get_sequence_frame_rate = function() return {fps_numerator = 30, fps_denominator = 1} end
timeline_state.reload_clips = function(_) end
timeline_state.consume_mutation_failure = function() return nil end
timeline_state.apply_mutations = function(_, _) return true end

command_manager.init("default_sequence", "default_project")

local ripple_cmd = Command.create("RippleEdit", "default_project")
ripple_cmd:set_parameter("edge_info", {clip_id = "clip_right", edge_type = "gap_before", track_id = "track_v1"})
ripple_cmd:set_parameter("delta_frames", -30) -- close the 1s gap at 30fps
ripple_cmd:set_parameter("sequence_id", "default_sequence")

local result = command_manager.execute(ripple_cmd)
assert(result.success, result.error_message or "RippleEdit failed")

-- Undo should restore the original gap edge selection, not a downstream clip edge
local undo_ok = command_manager.undo()
assert(undo_ok.success, undo_ok.error_message or "Undo failed")

local sel = last_edge_selection or {}
assert(#sel == #pre_selected_edges, string.format("expected %d selected edge(s), got %d", #pre_selected_edges, #sel))
assert(sel[1].clip_id == pre_selected_edges[1].clip_id, "selection should stay on original gap clip_id")
assert(sel[1].edge_type == pre_selected_edges[1].edge_type, "selection should stay on gap_before edge")

os.remove(TEST_DB)
print("✅ Undo restores gap edge selection after ripple close")
