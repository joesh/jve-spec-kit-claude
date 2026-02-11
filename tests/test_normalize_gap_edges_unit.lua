#!/usr/bin/env luajit

-- Unit test for gap edge normalization in selection_state
-- Tests the normalization logic directly, not through commands

require("test_env")

require("ui.timeline.timeline_state") -- luacheck: ignore 411 (side-effect require)
local selection_state = require("ui.timeline.state.selection_state")
local clip_state = require("ui.timeline.state.clip_state")
local data = require("ui.timeline.state.timeline_state_data")
local ripple_layout = require("tests.helpers.ripple_layout")

local TEST_DB = "/tmp/jve/test_norm_gap_unit.db"

-- Create layout with ADJACENT clips (no gap) - simulates state after gap closed
local layout = ripple_layout.create({
    db_path = TEST_DB,
    clips = {
        order = {"v1_left", "v1_right"},
        v1_left = {
            id = "clip_left",
            timeline_start = 0,
            duration = 1000,
            source_in = 500,
        },
        v1_right = {
            id = "clip_right",
            timeline_start = 1000,  -- Adjacent to left (no gap)
            duration = 1000,
            source_in = 500,
        },
    }
})

layout:init_timeline_state()

-- Verify clips are adjacent
local all_clips = clip_state.get_all()
print("Clip layout (adjacent, no gap):")
for _, c in ipairs(all_clips) do
    print(string.format("  %s: [%d..%d)", c.id, c.timeline_start, c.timeline_start + c.duration))
end

local left_clip = clip_state.get_by_id("clip_left")
local right_clip = clip_state.get_by_id("clip_right")
assert(left_clip and right_clip, "Both clips should exist")
assert(right_clip.timeline_start == left_clip.timeline_start + left_clip.duration,
    "Clips should be adjacent")

-- ═══════════════════════════════════════════════════════════════════════════
-- TEST 1: gap_after on left becomes in on right (adjacent clip)
-- ═══════════════════════════════════════════════════════════════════════════
print("\n--- Test 1: gap_after → in on adjacent clip ---")

-- Set stale selection: gap_after on left (but there's no gap!)
data.state.selected_edges = {
    {clip_id = "clip_left", edge_type = "gap_after", trim_type = "roll"},
}

selection_state.normalize_edge_selection()
local result = data.state.selected_edges

print("After normalization:")
for i, e in ipairs(result) do
    print(string.format("  [%d] clip=%s edge=%s trim=%s", i, e.clip_id, e.edge_type, e.trim_type or "nil"))
end

assert(#result == 1, "Should have 1 edge")
assert(result[1].clip_id == "clip_right", "gap_after on left should become edge on RIGHT (adjacent)")
assert(result[1].edge_type == "in", "Should convert to 'in' edge")
assert(result[1].trim_type == "roll", "trim_type should be preserved")

-- ═══════════════════════════════════════════════════════════════════════════
-- TEST 2: gap_before on right becomes out on left (adjacent clip)
-- ═══════════════════════════════════════════════════════════════════════════
print("\n--- Test 2: gap_before → out on adjacent clip ---")

data.state.selected_edges = {
    {clip_id = "clip_right", edge_type = "gap_before", trim_type = "roll"},
}

selection_state.normalize_edge_selection()
result = data.state.selected_edges

print("After normalization:")
for i, e in ipairs(result) do
    print(string.format("  [%d] clip=%s edge=%s trim=%s", i, e.clip_id, e.edge_type, e.trim_type or "nil"))
end

assert(#result == 1, "Should have 1 edge")
assert(result[1].clip_id == "clip_left", "gap_before on right should become edge on LEFT (adjacent)")
assert(result[1].edge_type == "out", "Should convert to 'out' edge")
assert(result[1].trim_type == "roll", "trim_type should be preserved")

-- ═══════════════════════════════════════════════════════════════════════════
-- TEST 3: Full roll selection with deduplication
-- ═══════════════════════════════════════════════════════════════════════════
print("\n--- Test 3: Full roll selection normalizes and deduplicates ---")

-- Simulate what UI creates for roll at gap boundary, but gap is now closed
data.state.selected_edges = {
    {clip_id = "clip_left", edge_type = "out", trim_type = "roll"},
    {clip_id = "clip_left", edge_type = "gap_after", trim_type = "roll"},
    {clip_id = "clip_right", edge_type = "gap_before", trim_type = "roll"},
    {clip_id = "clip_right", edge_type = "in", trim_type = "roll"},
}

print("Before normalization: 4 edges")

selection_state.normalize_edge_selection()
result = data.state.selected_edges

print("After normalization:")
for i, e in ipairs(result) do
    print(string.format("  [%d] clip=%s edge=%s trim=%s", i, e.clip_id, e.edge_type, e.trim_type or "nil"))
end

-- gap_after on left → in on right (duplicate of existing)
-- gap_before on right → out on left (duplicate of existing)
-- After dedup: left:out + right:in
assert(#result == 2, string.format("Should have 2 edges after dedup, got %d", #result))

local has_left_out = false
local has_right_in = false
for _, e in ipairs(result) do
    if e.clip_id == "clip_left" and e.edge_type == "out" then has_left_out = true end
    if e.clip_id == "clip_right" and e.edge_type == "in" then has_right_in = true end
    assert(e.trim_type == "roll", "trim_type should be preserved")
end
assert(has_left_out, "Should have left:out")
assert(has_right_in, "Should have right:in")

layout:cleanup()
print("\n✅ test_normalize_gap_edges_unit.lua passed")
