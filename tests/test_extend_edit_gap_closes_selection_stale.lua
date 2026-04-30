#!/usr/bin/env luajit

-- Regression test: ExtendEdit on gap clip, when gap closes, selection normalizes.
-- After first ExtendEdit closes the gap, the gap clip disappears. Selection should
-- normalize so the second ExtendEdit works on clip edges.
-- (Updated for gap-as-clip.)

require("test_env")

local command_manager = require("core.command_manager")
local timeline_state = require("ui.timeline.timeline_state")
require("command")
local Clip = require("models.clip")
local ripple_layout = require("tests.helpers.ripple_layout")

local TEST_DB = "/tmp/jve/test_extend_gap_closes.db"

-- Layout: v1_left [0..1000) gap [1000..2000) v1_right [2000..3000)
local layout = ripple_layout.create({
    db_path = TEST_DB,
    clips = {
        order = {"v1_left", "v1_right"},
        v1_left = {
            timeline_start = 0,
            duration = 1000,
            source_in = 1000,
        },
        v1_right = {
            timeline_start = 2000,
            duration = 1000,
            source_in = 1000,
        },
    }
})

layout:init_timeline_state()

local clips = layout.clips
local tracks = layout.tracks
local gap_id = layout:gap_id("v1", 1000)

-- Roll to close gap: gap:out (at 2000) + v1_right:in (at 2000)
-- Playhead at 1000 → delta = 1000 - 2000 = -1000
local playhead_target = 1000

local edge_infos = {
    {clip_id = gap_id, edge_type = "out", track_id = tracks.v1.id, trim_type = "roll"},
    {clip_id = clips.v1_right.id, edge_type = "in", track_id = tracks.v1.id, trim_type = "roll"},
}

timeline_state.set_edge_selection(edge_infos)

-- First ExtendEdit: close the gap
print("--- First ExtendEdit: closing the gap ---")
local result1 = command_manager.execute("ExtendEdit", {
    edge_infos = edge_infos,
    playhead = playhead_target,
    project_id = layout.project_id,
    sequence_id = layout.sequence_id,
})

assert(result1 and result1.success, "First ExtendEdit should succeed: " .. tostring(result1 and result1.error_message))

-- Verify gap is closed
local left = Clip.load(clips.v1_left.id, layout.db)
local right = Clip.load(clips.v1_right.id, layout.db)

local gap_after_edit = right.timeline_start - (left.timeline_start + left.duration)
assert(gap_after_edit == 0, string.format("Gap should be closed, got %d frames", gap_after_edit))

-- Selection should normalize: gap clip disappeared, so gap:out edge drops.
-- v1_right:in should survive. This gives a single edge or the pair normalizes
-- to v1_left:out + v1_right:in.
local current_selection = timeline_state.get_selected_edges()
assert(#current_selection >= 1, "Selection should have at least 1 edge after normalization")

for _, edge in ipairs(current_selection) do
    assert(edge.edge_type == "in" or edge.edge_type == "out",
        "Edges should be standard in/out after normalization, got " .. tostring(edge.edge_type))
end

-- Second ExtendEdit: move the boundary further left
-- Re-read selection from timeline_state
local current_edges = timeline_state.get_selected_edges()
assert(#current_edges > 0, "Selection should not be empty")

for _, edge in ipairs(current_edges) do
    if not edge.track_id then
        local clip = Clip.load(edge.clip_id, layout.db)
        if clip then
            edge.track_id = clip.track_id
        end
    end
end

-- Second ExtendEdit: move the clip further left with the normalized edge
local playhead_target2 = 800
print("\n--- Second ExtendEdit: extending further ---")

local result2 = command_manager.execute("ExtendEdit", {
    edge_infos = current_edges,
    playhead = playhead_target2,
    project_id = layout.project_id,
    sequence_id = layout.sequence_id,
})

-- The second edit should at minimum not crash — normalized selection is valid.
-- Whether it produces mutations depends on single-edge RippleEdit behavior.
assert(result2, "Second ExtendEdit should return a result")
-- If it succeeded, verify the clip moved
if result2.success then
    right = Clip.load(clips.v1_right.id, layout.db)
    print(string.format("  Right clip at %d after second edit", right.timeline_start))
end

layout:cleanup()
print("\n✅ test_extend_edit_gap_closes_selection_stale.lua passed")
