#!/usr/bin/env luajit

require("test_env")

local timeline_state = require("ui.timeline.timeline_state")
local timeline_core_state = require("ui.timeline.state.timeline_core_state")
local ripple_layout = require("tests.helpers.ripple_layout")

local TEST_DB = "/tmp/jve/test_timeline_restart_edge_selection.db"
local layout = ripple_layout.create({
    db_path = TEST_DB,
    clips = {
        v1_left = {timeline_start = 0, duration = 1500},
        v1_right = {timeline_start = 3500, duration = 1200},
        v2 = {timeline_start = 2000, duration = 900}
    }
})
local clips = layout.clips
local tracks = layout.tracks

timeline_core_state.init(layout.sequence_id)

timeline_state.set_edge_selection({
    {clip_id = clips.v1_left.id, edge_type = "gap_after", track_id = tracks.v1.id, trim_type = "ripple"},
    {clip_id = clips.v2.id, edge_type = "out", track_id = tracks.v2.id, trim_type = "ripple"}
})

timeline_state.reset()
timeline_core_state.init(layout.sequence_id)

local restored_edges = timeline_state.get_selected_edges()
assert(restored_edges and restored_edges[1],
    "Edge selection should persist automatically across timeline reloads")

layout:cleanup()
print("✅ Edge selection persists across restart without manual persistence")
