#!/usr/bin/env luajit

-- Test: gap clip edge selection survives timeline reloads.
-- (Updated for gap-as-clip: uses gap clip ID with in/out edge.)

package.path = "./?.lua;./src/lua/?.lua;" .. package.path

require("test_env")

local command_manager = require("core.command_manager")
local Command = require("command")
local timeline_state = require("ui.timeline.timeline_state")
local timeline_core_state = require("ui.timeline.state.timeline_core_state")
local ripple_layout = require("synthetic.helpers.ripple_layout")

local TEST_DB = "/tmp/jve/test_timeline_reload_gap_selection.db"
local layout = ripple_layout.create({
    db_path = TEST_DB,
    clips = {
        v1_left = {sequence_start = 0, duration = 1500},
        v1_right = {sequence_start = 2500, duration = 1200},
        v2 = {sequence_start = 1800, duration = 700}
    }
})
local clips = layout.clips
local tracks = layout.tracks
local gap_id = layout:gap_id("v1", 1500)

timeline_core_state.init(layout.sequence_id)

-- Verify gap clip exists
local gap_clip = timeline_state.get_tab_strip():clip_by_id(gap_id)
assert(gap_clip, "Gap clip should exist at position 1500 on V1")

-- Execute a ripple with gap + media edges
local cmd = Command.create("BatchRippleEdit", layout.project_id)
cmd:set_parameter("sequence_id", layout.sequence_id)
cmd:set_parameter("edge_infos", {
    {clip_id = gap_id, edge_type = "in", track_id = tracks.v1.id, trim_type = "ripple"},
    {clip_id = clips.v2.id, edge_type = "out", track_id = tracks.v2.id, trim_type = "ripple"}
})
cmd:set_parameter("lead_edge", {clip_id = clips.v2.id, edge_type = "out", track_id = tracks.v2.id, trim_type = "ripple"})
cmd:set_parameter("delta_frames", -200)

local result = command_manager.execute(cmd)
assert(result.success, result.error_message or "BatchRippleEdit failed")

-- Set selection with the media clip edge (gap clip ID may change after edit)
timeline_state.set_edge_selection({
    {clip_id = clips.v2.id, edge_type = "out", track_id = tracks.v2.id, trim_type = "ripple"}
})

timeline_state.persist_state_to_db(true)

timeline_core_state.init(layout.sequence_id)

local reloaded = timeline_state.get_selected_edges()
assert(reloaded and reloaded[1], "Selection should still exist after reload")
assert(reloaded[1].clip_id == clips.v2.id, string.format("Expected v2 after reload, got %s", tostring(reloaded[1].clip_id)))
assert(reloaded[1].edge_type == "out", string.format("Expected out after reload, got %s", tostring(reloaded[1].edge_type)))

layout:cleanup()
print("✅ Edge selection survives timeline reloads")
