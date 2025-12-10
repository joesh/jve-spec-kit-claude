#!/usr/bin/env luajit

package.path = "./?.lua;./src/lua/?.lua;" .. package.path

require("test_env")

local command_manager = require("core.command_manager")
local Command = require("command")
local timeline_state = require("ui.timeline.timeline_state")
local timeline_core_state = require("ui.timeline.state.timeline_core_state")
local ripple_layout = require("tests.helpers.ripple_layout")

local TEST_DB = "/tmp/jve/test_timeline_reload_gap_selection.db"
local layout = ripple_layout.create({
    db_path = TEST_DB,
    selected_edge_infos = string.format('[{"clip_id":"%s","edge_type":"gap_after","trim_type":"ripple"}]', "clip_v1_left"),
    clips = {
        v1_left = {timeline_start = 0, duration = 1500},
        v1_right = {timeline_start = 2500, duration = 1200},
        v2 = {timeline_start = 1800, duration = 700}
    }
})
local clips = layout.clips
local tracks = layout.tracks

timeline_core_state.init(layout.sequence_id)

local sel = timeline_state.get_selected_edges()
assert(sel and sel[1] and sel[1].edge_type == "gap_after", "Initial selection should load gap_after")

local cmd = Command.create("BatchRippleEdit", layout.project_id)
cmd:set_parameter("sequence_id", layout.sequence_id)
cmd:set_parameter("edge_infos", {
    {clip_id = clips.v1_left.id, edge_type = "gap_after", track_id = tracks.v1.id, trim_type = "ripple"},
    {clip_id = clips.v2.id, edge_type = "out", track_id = tracks.v2.id, trim_type = "ripple"}
})
cmd:set_parameter("lead_edge", {clip_id = clips.v2.id, edge_type = "out", track_id = tracks.v2.id, trim_type = "ripple"})
cmd:set_parameter("delta_frames", -200)

local result = command_manager.execute(cmd)
assert(result.success, result.error_message or "BatchRippleEdit failed")

timeline_state.set_edge_selection({
    {clip_id = clips.v1_left.id, edge_type = "gap_after", track_id = tracks.v1.id, trim_type = "ripple"},
    {clip_id = clips.v2.id, edge_type = "out", track_id = tracks.v2.id, trim_type = "ripple"}
})

timeline_state.persist_state_to_db(true)

timeline_core_state.init(layout.sequence_id)

local reloaded = timeline_state.get_selected_edges()
assert(reloaded and reloaded[1], "Selection should still exist after reload")
assert(reloaded[1].clip_id == clips.v1_left.id, string.format("Expected v1_left after reload, got %s", tostring(reloaded[1].clip_id)))
assert(reloaded[1].edge_type == "gap_after", string.format("Expected gap_after after reload, got %s", tostring(reloaded[1].edge_type)))

layout:cleanup()
print("✅ Gap edge selection survives timeline reloads")
