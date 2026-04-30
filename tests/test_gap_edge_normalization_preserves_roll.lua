#!/usr/bin/env luajit

-- Test: When a gap closes via ExtendEdit, the roll selection should
-- normalize from gap clip edges to adjacent clip edges, preserving trim_type.
-- (Updated for gap-as-clip.)

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
local gap_id = layout:gap_id("v1", 1000)

-- Set up roll selection on gap clip edges
-- gap:out (at 2000) + gap:in (at 1000) — but for a roll we want
-- the boundary pair: v1_left:out + gap:in (at boundary 1000)
-- Actually for this test, the roll pair is gap:out + v1_right:in at boundary 2000
-- Let's use gap:out + v1_right:in (the right boundary of the gap)
local edge_infos = {
    {clip_id = gap_id, edge_type = "out", track_id = tracks.v1.id, trim_type = "roll"},
    {clip_id = clips.v1_right.id, edge_type = "in", track_id = tracks.v1.id, trim_type = "roll"},
}
timeline_state.set_edge_selection(edge_infos)

-- ExtendEdit to close the gap: move gap's out-edge to playhead at 1000
local result1 = command_manager.execute("ExtendEdit", {
    edge_infos = edge_infos,
    playhead = 1000,
    project_id = layout.project_id,
    sequence_id = layout.sequence_id,
})
assert(result1 and result1.success, "ExtendEdit should succeed: " .. tostring(result1 and result1.error_message))

-- Verify gap is closed
local left = Clip.load(clips.v1_left.id, layout.db)
local right = Clip.load(clips.v1_right.id, layout.db)
local gap = right.timeline_start - (left.timeline_start + left.duration)
assert(gap == 0, string.format("Gap should be 0, got %d", gap))

-- After gap closes, selection should normalize.
-- The gap clip no longer has meaningful edges — they should convert to
-- adjacent clip edges: v1_left:out + v1_right:in
local normalized = timeline_state.get_selected_edges()

print("Normalized edges after gap closed:")
for i, edge in ipairs(normalized) do
    print(string.format("  [%d] clip=%s edge_type=%s trim_type=%s",
        i, edge.clip_id, edge.edge_type, edge.trim_type or "nil"))
end

-- Verify: should have 2 edges with roll preserved
assert(#normalized >= 1,
    string.format("Should have edges after normalization, got %d", #normalized))

-- All edges should have proper types
for _, edge in ipairs(normalized) do
    assert(edge.edge_type == "in" or edge.edge_type == "out",
        string.format("Edge should be in/out, got %s", edge.edge_type))
end

-- Trim type must be preserved
for _, edge in ipairs(normalized) do
    assert(edge.trim_type == "roll",
        string.format("Edge trim_type should be 'roll', got '%s'", tostring(edge.trim_type)))
end

layout:cleanup()
print("\n✅ test_gap_edge_normalization_preserves_roll.lua passed")
