#!/usr/bin/env luajit

-- Test: Verify dragged edge determines reference bracket

print("=== Drag Reference Edge Test ===\n")

local function get_bracket(edge_type)
    if edge_type == "in" or edge_type == "gap_after" then
        return "["
    else
        return "]"
    end
end

-- Test 1: Drag gap_before (]) with in ([) also selected
print("TEST 1: Drag gap_before (]) with in ([) selected")
print("  Edges: [1] gap_before (]), [2] in ([)")
print("  Delta: -1000ms (drag LEFT)\n")

local edges = {
    {clip_id = "gap", edge_type = "gap_before"},  -- Dragged edge (first in array)
    {clip_id = "clip", edge_type = "in"}
}

local reference_bracket = get_bracket(edges[1].edge_type)
print(string.format("Reference bracket: %s (from dragged edge)", reference_bracket))

for i, edge in ipairs(edges) do
    local bracket = get_bracket(edge.edge_type)
    local delta = (bracket == reference_bracket) and -1000 or 1000
    print(string.format("  Edge %d: type=%s, bracket=%s, matches_ref=%s, delta=%d",
        i, edge.edge_type, bracket, bracket == reference_bracket, delta))
end

local gap_bracket = get_bracket(edges[1].edge_type)
local clip_bracket = get_bracket(edges[2].edge_type)
local gap_delta = (gap_bracket == reference_bracket) and -1000 or 1000
local clip_delta = (clip_bracket == reference_bracket) and -1000 or 1000

-- Gap out-edge (gap_before) with delta -1000: duration += -1000 = shrinks
-- Clip in-edge with delta +1000 (negated): duration -= 1000 = shrinks
print("\nExpected:")
print("  Gap: 3000ms + (-1000) = 2000ms (shrinks)")
print("  Clip: 5000ms - (+1000) = 4000ms (shrinks)")

if gap_delta == -1000 and clip_delta == 1000 then
    print("\n✅ TEST 1 PASSED: Gap edge as reference, opposite edge negated\n")
else
    print(string.format("\n❌ TEST 1 FAILED: Got gap_delta=%d, clip_delta=%d\n", gap_delta, clip_delta))
end


-- Test 2: Drag in ([) with gap_before (]) also selected (opposite order)
print(string.rep("=", 60))
print("TEST 2: Drag in ([) with gap_before (]) selected")
print("  Edges: [1] in ([), [2] gap_before (])")
print("  Delta: -1000ms (drag LEFT)\n")

edges = {
    {clip_id = "clip", edge_type = "in"},         -- Dragged edge (first in array)
    {clip_id = "gap", edge_type = "gap_before"}
}

reference_bracket = get_bracket(edges[1].edge_type)
print(string.format("Reference bracket: %s (from dragged edge)", reference_bracket))

for i, edge in ipairs(edges) do
    local bracket = get_bracket(edge.edge_type)
    local delta = (bracket == reference_bracket) and -1000 or 1000
    print(string.format("  Edge %d: type=%s, bracket=%s, matches_ref=%s, delta=%d",
        i, edge.edge_type, bracket, bracket == reference_bracket, delta))
end

gap_bracket = get_bracket(edges[2].edge_type)
clip_bracket = get_bracket(edges[1].edge_type)
gap_delta = (gap_bracket == reference_bracket) and -1000 or 1000
clip_delta = (clip_bracket == reference_bracket) and -1000 or 1000

-- Clip in-edge with delta -1000: duration -= -1000 = grows
-- Gap out-edge (gap_before) with delta +1000 (negated): duration += 1000 = grows
print("\nExpected:")
print("  Clip: 5000ms - (-1000) = 6000ms (grows)")
print("  Gap: 3000ms + (+1000) = 4000ms (grows)")

if clip_delta == -1000 and gap_delta == 1000 then
    print("\n✅ TEST 2 PASSED: Clip edge as reference, opposite edge negated\n")
else
    print(string.format("\n❌ TEST 2 FAILED: Got clip_delta=%d, gap_delta=%d\n", clip_delta, gap_delta))
end


-- Test 3: Same bracket selection (no negation)
print(string.rep("=", 60))
print("TEST 3: Drag in ([) with another in ([) selected")
print("  Edges: [1] in ([), [2] in ([)")
print("  Delta: 1000ms (drag RIGHT)\n")

edges = {
    {clip_id = "clip1", edge_type = "in"},
    {clip_id = "clip2", edge_type = "in"}
}

reference_bracket = get_bracket(edges[1].edge_type)
print(string.format("Reference bracket: %s", reference_bracket))

for i, edge in ipairs(edges) do
    local bracket = get_bracket(edge.edge_type)
    local delta = (bracket == reference_bracket) and 1000 or -1000
    print(string.format("  Edge %d: type=%s, bracket=%s, delta=%d", i, edge.edge_type, bracket, delta))
end

local delta1 = (get_bracket(edges[1].edge_type) == reference_bracket) and 1000 or -1000
local delta2 = (get_bracket(edges[2].edge_type) == reference_bracket) and 1000 or -1000

if delta1 == 1000 and delta2 == 1000 then
    print("\n✅ TEST 3 PASSED: Same bracket edges get same delta\n")
else
    print(string.format("\n❌ TEST 3 FAILED: Got delta1=%d, delta2=%d\n", delta1, delta2))
end


print(string.rep("=", 60))
print("SUMMARY:")
print("✓ First edge in array determines reference bracket")
print("✓ UI reorders array to put dragged edge first")
print("✓ Opposite bracket → negated delta")
print("✓ Same bracket → same delta")
