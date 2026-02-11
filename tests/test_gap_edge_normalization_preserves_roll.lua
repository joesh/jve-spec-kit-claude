#!/usr/bin/env luajit

-- Test: Gap edge normalization must preserve roll trim_type and convert to correct clip edges
-- Bug: normalize_edge_selection was deleting gap edges instead of converting them,
-- and/or losing the roll trim_type

require("test_env")

local command_manager = require("core.command_manager")
local timeline_state = require("ui.timeline.timeline_state")
local _selection_state = require("ui.timeline.state.selection_state")  -- luacheck: no unused
local Clip = require("models.clip")
local ripple_layout = require("tests.helpers.ripple_layout")

local TEST_DB = "/tmp/jve/test_gap_norm_roll.db"

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

-- Set up roll selection on gap edges
local edge_infos = {
    {clip_id = clips.v1_right.id, edge_type = "gap_before", track_id = tracks.v1.id, trim_type = "roll"},
    {clip_id = clips.v1_left.id, edge_type = "gap_after", track_id = tracks.v1.id, trim_type = "roll"},
}
timeline_state.set_edge_selection(edge_infos)

-- First extend: close the gap
local result1 = command_manager.execute("ExtendEdit", {
    edge_infos = edge_infos,
    playhead_frame = 1000,  -- Close gap completely
    project_id = layout.project_id,
    sequence_id = layout.sequence_id,
})
assert(result1 and result1.success, "First ExtendEdit should succeed")

-- Verify gap is closed
local left = Clip.load(clips.v1_left.id, layout.db)
local right = Clip.load(clips.v1_right.id, layout.db)
local gap = right.timeline_start - (left.timeline_start + left.duration)
assert(gap == 0, string.format("Gap should be 0, got %d", gap))

-- Check normalized selection
local normalized = timeline_state.get_selected_edges()

print("Normalized edges after gap closed:")
for i, edge in ipairs(normalized) do
    print(string.format("  [%d] clip=%s edge_type=%s trim_type=%s",
        i, edge.clip_id, edge.edge_type, edge.trim_type or "nil"))
end

-- CRITICAL ASSERTIONS:

-- 1. Should still have 2 edges (not deleted)
assert(#normalized == 2,
    string.format("Should have 2 edges after normalization, got %d", #normalized))

-- 2. Should have converted to clip edges (in/out), not gap edges
for _, edge in ipairs(normalized) do
    assert(edge.edge_type == "in" or edge.edge_type == "out",
        string.format("Edge should be in/out, got %s", edge.edge_type))
end

-- 3. CRITICAL: trim_type must still be "roll" (not converted to ripple)
for _, edge in ipairs(normalized) do
    assert(edge.trim_type == "roll",
        string.format("Edge trim_type should be 'roll', got '%s'", tostring(edge.trim_type)))
end

-- 4. The edges should be on the correct clips
-- gap_before on v1_right → in on v1_right
-- gap_after on v1_left → out on v1_left
local found_right_in = false
local found_left_out = false
for _, edge in ipairs(normalized) do
    if edge.clip_id == clips.v1_right.id and edge.edge_type == "in" then
        found_right_in = true
    end
    if edge.clip_id == clips.v1_left.id and edge.edge_type == "out" then
        found_left_out = true
    end
end
assert(found_right_in, "Should have 'in' edge on v1_right (converted from gap_before)")
assert(found_left_out, "Should have 'out' edge on v1_left (converted from gap_after)")

layout:cleanup()
print("\n✅ test_gap_edge_normalization_preserves_roll.lua passed")
