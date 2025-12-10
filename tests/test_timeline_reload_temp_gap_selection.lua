#!/usr/bin/env luajit

package.path = "./?.lua;./src/lua/?.lua;" .. package.path

require("test_env")

local timeline_state = require("ui.timeline.timeline_state")
local timeline_core_state = require("ui.timeline.state.timeline_core_state")
local ripple_layout = require("tests.helpers.ripple_layout")

local TEST_DB = "/tmp/jve/test_timeline_reload_temp_gap_selection.db"
local gap_id = "temp_gap_track_v1_1500_3500"
local layout = ripple_layout.create({
    db_path = TEST_DB,
    selected_edge_infos = string.format('[{"clip_id":"%s","edge_type":"gap_after","trim_type":"ripple"}]', gap_id),
    clips = {
        v1_left = {timeline_start = 0, duration = 1500},
        v1_right = {timeline_start = 3500, duration = 1200}
    }
})

timeline_core_state.init(layout.sequence_id)

local edges = timeline_state.get_selected_edges()
assert(#edges == 1, "Gap edge should reload from temp_gap selection")
assert(edges[0] == nil, "table is 1-indexed")
assert(edges[1].edge_type == "gap_after", string.format("Expected gap_after, got %s", tostring(edges[1].edge_type)))
assert(edges[1].clip_id == layout.clips.v1_left.id, string.format("Expected clip_v1_left, got %s", tostring(edges[1].clip_id)))

layout:cleanup()
print("✅ temp_gap edge selections reload as real gap edges")
