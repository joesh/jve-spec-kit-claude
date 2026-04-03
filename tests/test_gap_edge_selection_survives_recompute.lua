#!/usr/bin/env luajit

-- Regression: after a roll at a clip-gap boundary, recompute_gap_clips
-- destroys the old gap clip and creates a new one at a different position.
-- The edge selection referencing the old gap clip ID becomes stale and
-- gets dropped, turning a roll selection into a single ripple edge.

require("test_env")

local command_manager = require("core.command_manager")
local ripple_layout = require("tests.helpers.ripple_layout")
local Command = require("command")

local TEST_DB = "/tmp/jve/test_gap_edge_survives_recompute.db"
local layout = ripple_layout.create({
    db_path = TEST_DB,
    clips = {
        order = {"v1_left", "v1_right"},
        v1_left = { timeline_start = 0, duration = 500, source_in = 200 },
        v1_right = { timeline_start = 1000, duration = 500, source_in = 200 },
    }
})
local ts = layout:init_timeline_state()
local tracks = layout.tracks
local gap_id = layout:gap_id("v1", 500)

-- Set up a roll selection: clip:out + gap:in
local roll_edges = {
    {clip_id = layout.clips.v1_left.id, edge_type = "out", track_id = tracks.v1.id, trim_type = "roll"},
    {clip_id = gap_id, edge_type = "in", track_id = tracks.v1.id, trim_type = "roll"},
}
ts.set_edge_selection(roll_edges)

-- Verify: 2 roll edges selected
local sel_before = ts.get_selected_edges()
assert(#sel_before == 2, string.format("Should have 2 edges before roll, got %d", #sel_before))

-- Execute the roll: clip extends +100, gap shrinks from left
local cmd = Command.create("BatchRippleEdit", layout.project_id)
cmd:set_parameter("sequence_id", layout.sequence_id)
cmd:set_parameter("edge_infos", roll_edges)
cmd:set_parameter("delta_frames", 100)

local result = command_manager.execute(cmd)
assert(result.success, "Roll should succeed: " .. tostring(result.error_message))

-- Simulate what the app does: reload_clips (which calls recompute_gap_clips
-- and normalize_edge_selection). This is the path that destroys gap edges.
local core_state = require("ui.timeline.state.timeline_core_state")
core_state.reload_clips(layout.sequence_id)

-- After roll, gap moved from [500,1000] to [600,1000].
-- recompute_gap_clips created gap_track_v1_600, destroyed gap_track_v1_500.
-- The edge selection MUST still have 2 edges (the gap edge should migrate
-- to the new gap clip).
local sel_after = ts.get_selected_edges()
assert(#sel_after == 2,
    string.format("Should still have 2 edges after roll (gap edge must survive recompute), got %d", #sel_after))

-- Both should be roll
for _, edge in ipairs(sel_after) do
    assert(edge.trim_type == "roll",
        string.format("Edge %s:%s should still be roll, got %s",
            edge.clip_id, edge.edge_type, tostring(edge.trim_type)))
end

-- One should be the clip, one should be the NEW gap
local found_clip = false
local found_gap = false
for _, edge in ipairs(sel_after) do
    if edge.clip_id == layout.clips.v1_left.id then
        found_clip = true
    end
    if edge.clip_id:find("^gap_") then
        found_gap = true
    end
end
assert(found_clip, "Clip edge should survive recompute")
assert(found_gap, "Gap edge should migrate to new gap clip after recompute")

layout:cleanup()
print("✅ Gap edge selection survives recompute_gap_clips")
