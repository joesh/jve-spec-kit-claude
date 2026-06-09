#!/usr/bin/env luajit

-- Test: Bracket-based negation logic
-- Rule: If dragging [ edge, all ] edges get negated delta
--       If dragging ] edge, all [ edges get negated delta

print("=== Bracket-Based Delta Negation Test ===\n")

-- Helper function to simulate edge delta calculation
local function calculate_edge_delta(edge_type, delta_ms, reference_edge_type)
    -- Bracket mapping
    local function get_bracket(et)
        if et == "in" or et == "gap_after" then
            return "["
        else  -- "out" or "gap_before"
            return "]"
        end
    end

    local edge_bracket = get_bracket(edge_type)
    local reference_bracket = get_bracket(reference_edge_type)

    local edge_delta = (edge_bracket == reference_bracket) and delta_ms or -delta_ms

    return edge_delta, edge_bracket, reference_bracket
end

-- Helper to simulate apply_edge_ripple duration change
local function calculate_new_duration(original_duration, edge_type, edge_delta)
    local actual_edge = (edge_type == "gap_after") and "in" or ((edge_type == "gap_before") and "out" or edge_type)

    if actual_edge == "in" then
        return original_duration - edge_delta
    else  -- "out"
        return original_duration + edge_delta
    end
end

print("TEST 1: Canonical bug - Drag RIGHT +1000ms")
print("  V2 clip in-edge + V1 gap_before (gap out-edge)\n")

local delta_ms = 1000
local v2_type = "in"
local v1_type = "gap_before"
local ref_type = v2_type  -- First edge

local v2_delta, v2_bracket, ref_bracket = calculate_edge_delta(v2_type, delta_ms, ref_type)
print(string.format("Reference bracket: %s (from edge type: %s)", ref_bracket, ref_type))
print(string.format("\nEdge 1 (V2 clip in-edge):"))
print(string.format("  bracket=%s, matches_ref=%s", v2_bracket, v2_bracket == ref_bracket))
print(string.format("  edge_delta=%d", v2_delta))

local v2_new_dur = calculate_new_duration(5000, v2_type, v2_delta)
print(string.format("  duration: 5000 → %d (change: %d)", v2_new_dur, v2_new_dur - 5000))

local v1_delta, v1_bracket = calculate_edge_delta(v1_type, delta_ms, ref_type)
print(string.format("\nEdge 2 (V1 gap_before = gap out-edge):"))
print(string.format("  bracket=%s, matches_ref=%s", v1_bracket, v1_bracket == ref_bracket))
print(string.format("  edge_delta=%d", v1_delta))

local v1_new_dur = calculate_new_duration(3000, v1_type, v1_delta)
print(string.format("  duration: 3000 → %d (change: %d)", v1_new_dur, v1_new_dur - 3000))

local downstream_shift = v2_new_dur - 5000  -- First edge's duration change
print(string.format("\nDownstream shift: %d", downstream_shift))
print(string.format("Clip B final position: 3000 + %d = %d", downstream_shift, 3000 + downstream_shift))

if v2_new_dur == 4000 and v1_new_dur == 2000 and (3000 + downstream_shift) == 2000 then
    print("\n✅ TEST 1 PASSED: Drag right works correctly\n")
else
    print(string.format("\n❌ TEST 1 FAILED: Expected V2=4000, V1=2000, ClipB=2000"))
    print(string.format("                  Got V2=%d, V1=%d, ClipB=%d\n", v2_new_dur, v1_new_dur, 3000 + downstream_shift))
end


print(string.rep("=", 60))
print("TEST 2: Canonical bug - Drag LEFT -1000ms")
print("  V2 clip in-edge + V1 gap_before (gap out-edge)\n")

delta_ms = -1000
v2_type = "in"
v1_type = "gap_before"
ref_type = v2_type

v2_delta, v2_bracket, ref_bracket = calculate_edge_delta(v2_type, delta_ms, ref_type)
print(string.format("Reference bracket: %s (from edge type: %s)", ref_bracket, ref_type))
print(string.format("\nEdge 1 (V2 clip in-edge):"))
print(string.format("  bracket=%s, matches_ref=%s", v2_bracket, v2_bracket == ref_bracket))
print(string.format("  edge_delta=%d", v2_delta))

v2_new_dur = calculate_new_duration(5000, v2_type, v2_delta)
print(string.format("  duration: 5000 → %d (change: %d)", v2_new_dur, v2_new_dur - 5000))

v1_delta, v1_bracket = calculate_edge_delta(v1_type, delta_ms, ref_type)
print(string.format("\nEdge 2 (V1 gap_before = gap out-edge):"))
print(string.format("  bracket=%s, matches_ref=%s", v1_bracket, v1_bracket == ref_bracket))
print(string.format("  edge_delta=%d", v1_delta))

v1_new_dur = calculate_new_duration(3000, v1_type, v1_delta)
print(string.format("  duration: 3000 → %d (change: %d)", v1_new_dur, v1_new_dur - 3000))

downstream_shift = v2_new_dur - 5000
print(string.format("\nDownstream shift: %d", downstream_shift))
print(string.format("Clip B final position: 3000 + %d = %d", downstream_shift, 3000 + downstream_shift))

if v2_new_dur == 6000 and v1_new_dur == 4000 and (3000 + downstream_shift) == 4000 then
    print("\n✅ TEST 2 PASSED: Drag left works correctly (ignoring constraints)\n")
else
    print(string.format("\n❌ TEST 2 FAILED: Expected V2=6000, V1=4000, ClipB=4000"))
    print(string.format("                  Got V2=%d, V1=%d, ClipB=%d\n", v2_new_dur, v1_new_dur, 3000 + downstream_shift))
end


print(string.rep("=", 60))
print("TEST 3: Same-bracket selection (both [ edges)")
print("  V2 clip in-edge + V1 clip in-edge\n")

delta_ms = 1000
v2_type = "in"
v1_type = "in"
ref_type = v2_type

v2_delta, v2_bracket, ref_bracket = calculate_edge_delta(v2_type, delta_ms, ref_type)
print(string.format("Reference bracket: %s", ref_bracket))
print(string.format("Edge 1: bracket=%s, edge_delta=%d", v2_bracket, v2_delta))

v1_delta, v1_bracket = calculate_edge_delta(v1_type, delta_ms, ref_type)
print(string.format("Edge 2: bracket=%s, edge_delta=%d", v1_bracket, v1_delta))

print(string.format("\nBoth edges same bracket → both get SAME delta=%d", delta_ms))

if v2_delta == delta_ms and v1_delta == delta_ms then
    print("✅ TEST 3 PASSED: Same-bracket edges get same delta\n")
else
    print("❌ TEST 3 FAILED\n")
end


print(string.rep("=", 60))
print("TEST 4: Opposite-bracket selection (both ] edges)")
print("  V2 clip out-edge + V1 gap_before (gap out-edge)\n")

delta_ms = 1000
v2_type = "out"
v1_type = "gap_before"
ref_type = v2_type

v2_delta, v2_bracket, ref_bracket = calculate_edge_delta(v2_type, delta_ms, ref_type)
print(string.format("Reference bracket: %s", ref_bracket))
print(string.format("Edge 1: bracket=%s, edge_delta=%d", v2_bracket, v2_delta))

v1_delta, v1_bracket = calculate_edge_delta(v1_type, delta_ms, ref_type)
print(string.format("Edge 2: bracket=%s, edge_delta=%d", v1_bracket, v1_delta))

print(string.format("\nBoth edges same bracket → both get SAME delta=%d", delta_ms))

if v2_delta == delta_ms and v1_delta == delta_ms then
    print("✅ TEST 4 PASSED: Same-bracket edges get same delta\n")
else
    print("❌ TEST 4 FAILED\n")
end


print(string.rep("=", 60))
print("SUMMARY:")
print("✓ Bracket mapping: in/gap_after → [, out/gap_before → ]")
print("✓ Reference bracket comes from first edge")
print("✓ Opposite bracket → negated delta")
print("✓ Same bracket → same delta")
