#!/usr/bin/env luajit

-- Regression test: ExtendEdit on gap_after, when gap closes, selection becomes stale.
-- After first ExtendEdit closes the gap, the selection still holds "gap_after" but
-- there's no gap anymore. Second ExtendEdit should still work (selection normalized).

require("test_env")

local command_manager = require("core.command_manager")
local timeline_state = require("ui.timeline.timeline_state")
local Command = require("command")
local Clip = require("models.clip")
local ripple_layout = require("tests.helpers.ripple_layout")

local TEST_DB = "/tmp/jve/test_extend_gap_closes.db"

-- Layout: v1_left [0..1000) gap [1000..2000) v1_right [2000..3000)
-- Gap is 1000 frames. We'll close it with ExtendEdit.
-- Give clips source handles so roll edits aren't blocked by media limits
local layout = ripple_layout.create({
    db_path = TEST_DB,
    clips = {
        order = {"v1_left", "v1_right"},
        v1_left = {
            timeline_start = 0,
            duration = 1000,
            source_in = 1000,  -- Handle: can extend into earlier source
        },
        v1_right = {
            timeline_start = 2000,
            duration = 1000,
            source_in = 1000,  -- Handle: can extend into earlier source
        },
    }
})

-- Initialize timeline_state so selection normalization can work
layout:init_timeline_state()

local clips = layout.clips
local tracks = layout.tracks

-- To CLOSE the gap via roll:
-- - Lead edge: gap_before on v1_right (at position 2000)
-- - Partner: gap_after on v1_left (at position 1000)
-- - Playhead at 1000 (end of left clip)
-- - Delta = 1000 - 2000 = -1000 (move gap_before edge left to close gap)
local playhead_target = 1000

-- Build edge_infos: gap_before on v1_right (lead) + gap_after on v1_left (partner)
local edge_infos = {
    {clip_id = clips.v1_right.id, edge_type = "gap_before", track_id = tracks.v1.id, trim_type = "roll"},
    {clip_id = clips.v1_left.id, edge_type = "gap_after", track_id = tracks.v1.id, trim_type = "roll"},
}

-- Set the selection in timeline_state (simulates user selecting the edges)
timeline_state.set_edge_selection(edge_infos)

-- First ExtendEdit: close the gap
print("--- First ExtendEdit: closing the gap ---")
local result1 = command_manager.execute("ExtendEdit", {
    edge_infos = edge_infos,
    playhead_frame = playhead_target,
    project_id = layout.project_id,
    sequence_id = layout.sequence_id,
})

assert(result1 and result1.success, "First ExtendEdit should succeed: " .. tostring(result1 and result1.error_message))

-- Verify gap is closed
local left = Clip.load(clips.v1_left.id, layout.db)
local right = Clip.load(clips.v1_right.id, layout.db)

local gap_after_edit = right.timeline_start - (left.timeline_start + left.duration)
assert(gap_after_edit == 0, string.format("Gap should be closed, got %d frames", gap_after_edit))

-- Verify selection was normalized: gap_before/gap_after → in/out
local current_selection = timeline_state.get_selected_edges()
assert(#current_selection == 2, "Selection should have 2 edges")
local has_in = false
local has_out = false
for _, edge in ipairs(current_selection) do
    if edge.edge_type == "in" then has_in = true end
    if edge.edge_type == "out" then has_out = true end
    assert(edge.edge_type ~= "gap_before" and edge.edge_type ~= "gap_after",
        "Gap edges should be normalized to clip edges after gap closed")
end
assert(has_in and has_out, "Should have both in and out edges after normalization")

-- Now move playhead further left and try second ExtendEdit
-- This should NOT be blocked. If selection was normalized, gap_after/gap_before
-- should have been converted to out/in edges.
-- After first edit: edges are at 1000, move them to 800
local playhead_target2 = 800  -- Move 200 more frames left

print("\n--- Second ExtendEdit: extending further (should not be blocked) ---")

-- Re-read edge_infos from timeline_state (selection may have been normalized)
local current_edges = timeline_state.get_selected_edges()
assert(#current_edges > 0, "Selection should not be empty")

-- Add track_id to edges (required by ExtendEdit)
for _, edge in ipairs(current_edges) do
    if not edge.track_id then
        local clip = Clip.load(edge.clip_id, layout.db)
        if clip then
            edge.track_id = clip.track_id
        end
    end
end

local result2 = command_manager.execute("ExtendEdit", {
    edge_infos = current_edges,
    playhead_frame = playhead_target2,
    project_id = layout.project_id,
    sequence_id = layout.sequence_id,
})

assert(result2 and result2.success,
    "Second ExtendEdit should NOT be blocked: " .. tostring(result2 and result2.error_message))

-- Verify the edit happened
left = Clip.load(clips.v1_left.id, layout.db)
right = Clip.load(clips.v1_right.id, layout.db)


-- Expected: left clip end and right clip start both moved to playhead (800)
local left_end = left.timeline_start + left.duration
assert(left_end == playhead_target2,
    string.format("Left clip should end at playhead %d, got %d", playhead_target2, left_end))
assert(right.timeline_start == playhead_target2,
    string.format("Right clip should start at playhead %d, got %d", playhead_target2, right.timeline_start))

layout:cleanup()
print("\n✅ test_extend_edit_gap_closes_selection_stale.lua passed")
