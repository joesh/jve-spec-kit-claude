#!/usr/bin/env luajit

package.path = "./?.lua;./src/lua/?.lua;" .. package.path

require("test_env")

local command_manager = require("core.command_manager")
local Command = require("command")
local ripple_layout = require("tests.helpers.ripple_layout")

local timeline_state = require("ui.timeline.timeline_state")
local last_edge_selection = nil
local current_edges = nil

timeline_state.set_edge_selection = function(edges)
    last_edge_selection = edges
    current_edges = edges
end
timeline_state.set_edge_selection_raw = function(edges)
    last_edge_selection = edges
    current_edges = edges
end
timeline_state.clear_edge_selection = function() end
timeline_state.clear_gap_selection = function() end
timeline_state.set_gap_selection = function() end
timeline_state.normalize_edge_selection = function(edges) return edges end
timeline_state.get_selected_clips = function() return {} end
timeline_state.get_selected_edges = function() return current_edges or {} end
timeline_state.get_project_id = function() return "default_project" end
timeline_state.get_sequence_id = function() return "default_sequence" end
timeline_state.get_sequence_frame_rate = function() return {fps_numerator = 30, fps_denominator = 1} end
timeline_state.reload_clips = function() end
timeline_state.consume_mutation_failure = function() return nil end
timeline_state.apply_mutations = function() return true end

local TEST_DB = "/tmp/jve/test_batch_ripple_gap_undo_selection.db"
local layout = ripple_layout.create({
    db_path = TEST_DB,
    fps_numerator = 30,
    fps_denominator = 1,
    media = {
        main = {
            duration_frames = 7200,
            fps_numerator = 30,
            fps_denominator = 1
        }
    },
    clips = {
        v1_left = {duration = 900, fps_numerator = 30, fps_denominator = 1},
        v1_right = {timeline_start = 1500, duration = 900, fps_numerator = 30, fps_denominator = 1},
        v2 = {timeline_start = 900, duration = 900, fps_numerator = 30, fps_denominator = 1}
    }
})
local db = layout.db
local clips = layout.clips
local tracks = layout.tracks

local pre_selected = {
    {clip_id = clips.v1_left.id, edge_type = "gap_after", track_id = tracks.v1.id, trim_type = "ripple"},
    {clip_id = clips.v2.id, edge_type = "out", track_id = tracks.v2.id, trim_type = "ripple"}
}
last_edge_selection = pre_selected
current_edges = pre_selected

local cmd = Command.create("BatchRippleEdit", layout.project_id)
cmd:set_parameter("sequence_id", layout.sequence_id)
cmd:set_parameter("edge_infos", pre_selected)
cmd:set_parameter("delta_frames", -150)

local result = command_manager.execute(cmd)
assert(result.success, result.error_message or "BatchRippleEdit failed")

local undo_result = command_manager.undo()
assert(undo_result.success, undo_result.error_message or "Undo failed")

assert(last_edge_selection, "Undo should restore edge selection")
assert(#last_edge_selection == #pre_selected, string.format("expected %d selection entries, got %d", #pre_selected, #last_edge_selection))
for i, edge in ipairs(pre_selected) do
    assert(last_edge_selection[i].clip_id == edge.clip_id,
        string.format("Undo should restore clip_id for entry %d (expected %s, got %s)", i, edge.clip_id, tostring(last_edge_selection[i].clip_id)))
    assert(last_edge_selection[i].edge_type == edge.edge_type,
        string.format("Undo should restore edge_type for entry %d (expected %s, got %s)", i, edge.edge_type, tostring(last_edge_selection[i].edge_type)))
end

layout:cleanup()
print("✅ Undo restores gap edge selection after BatchRippleEdit")
