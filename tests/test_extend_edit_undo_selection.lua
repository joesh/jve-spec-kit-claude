#!/usr/bin/env luajit

-- Regression test: ExtendEdit undo must restore edge selection
-- Bug: Nested BatchRippleEdit had nil parent_sequence_number, so undo only
-- undid the nested command and restored its empty selection instead of
-- ExtendEdit's pre-selection (which had the edges).

require("test_env")

local database = require("core.database")
local command_manager = require("core.command_manager")
local Command = require("command")
local SCHEMA_SQL = require("import_schema")

local TEST_DB = "/tmp/jve/test_extend_edit_undo_selection.db"
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

-- Pre-select both out-edges (this triggers BatchRippleEdit, not RippleEdit)
local pre_selected_edges = {
    {clip_id = "clip_v1", edge_type = "out", track_id = "track_v1", trim_type = "ripple"},
    {clip_id = "clip_v2", edge_type = "out", track_id = "track_v2", trim_type = "ripple"},
}

timeline_state.get_selected_clips = function() return {} end
timeline_state.get_selected_edges = function() return pre_selected_edges end
timeline_state.get_selected_gaps = function() return {} end
timeline_state.set_playhead_position = function(_) end
timeline_state.get_playhead_position = function() return 150 end  -- extend to frame 150
timeline_state.get_project_id = function() return "default_project" end
timeline_state.get_sequence_id = function() return "default_sequence" end
timeline_state.get_sequence_frame_rate = function() return {fps_numerator = 30, fps_denominator = 1} end
timeline_state.reload_clips = function(_) end
timeline_state.consume_mutation_failure = function() return nil end
timeline_state.apply_mutations = function(_, _) return true end

command_manager.init("default_sequence", "default_project")

-- Execute ExtendEdit (spawns nested BatchRippleEdit for 2 edges)
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
local clip_v2 = Clip.load("clip_v2")
assert(clip_v1.duration == 150, "clip_v1 should extend to 150 frames, got " .. tostring(clip_v1.duration))
assert(clip_v2.duration == 150, "clip_v2 should extend to 150 frames, got " .. tostring(clip_v2.duration))

-- Undo should restore the original edge selection (both out-edges)
local undo_ok = command_manager.undo()
assert(undo_ok.success, undo_ok.error_message or "Undo failed")

-- Verify clips reverted
clip_v1 = Clip.load("clip_v1")
clip_v2 = Clip.load("clip_v2")
assert(clip_v1.duration == 100, "clip_v1 should revert to 100 frames, got " .. tostring(clip_v1.duration))
assert(clip_v2.duration == 100, "clip_v2 should revert to 100 frames, got " .. tostring(clip_v2.duration))

-- KEY ASSERTION: Undo must restore edge selection, not clear it
local sel = last_edge_selection or {}
assert(#sel == 2, string.format("expected 2 selected edges after undo, got %d", #sel))

local found_v1 = false
local found_v2 = false
for _, edge in ipairs(sel) do
    if edge.clip_id == "clip_v1" and edge.edge_type == "out" then found_v1 = true end
    if edge.clip_id == "clip_v2" and edge.edge_type == "out" then found_v2 = true end
end
assert(found_v1, "clip_v1 out-edge should be in selection after undo")
assert(found_v2, "clip_v2 out-edge should be in selection after undo")

-- Now test redo selection
last_edge_selection = nil
local redo_ok = command_manager.redo()
assert(redo_ok.success, redo_ok.error_message or "Redo failed")

-- Verify clips extended again
clip_v1 = Clip.load("clip_v1")
clip_v2 = Clip.load("clip_v2")
assert(clip_v1.duration == 150, "clip_v1 should extend to 150 after redo, got " .. tostring(clip_v1.duration))
assert(clip_v2.duration == 150, "clip_v2 should extend to 150 after redo, got " .. tostring(clip_v2.duration))

-- KEY ASSERTION: Redo must restore edge selection (post-execution selection)
sel = last_edge_selection or {}
assert(#sel == 2, string.format("expected 2 selected edges after redo, got %d", #sel))

found_v1 = false
found_v2 = false
for _, edge in ipairs(sel) do
    if edge.clip_id == "clip_v1" and edge.edge_type == "out" then found_v1 = true end
    if edge.clip_id == "clip_v2" and edge.edge_type == "out" then found_v2 = true end
end
assert(found_v1, "clip_v1 out-edge should be in selection after redo")
assert(found_v2, "clip_v2 out-edge should be in selection after redo")

print("✅ test_extend_edit_undo_selection.lua passed")
