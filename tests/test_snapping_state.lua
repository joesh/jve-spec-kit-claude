require('test_env')

-- Test snapping_state XOR logic: effective = baseline XOR drag_inverted

print("=== Test Snapping State ===")

local snapping = require("ui.timeline.state.snapping_state")

--------------------------------------------------------------------------------
-- Test 1: Default state — enabled
--------------------------------------------------------------------------------
print("\nTest 1: Default state is enabled")
-- Module just loaded: baseline=true, drag_inverted=false
assert(snapping.is_enabled() == true, "default should be enabled")
print("  ok")

--------------------------------------------------------------------------------
-- Test 2: toggle_baseline ON->OFF->ON
--------------------------------------------------------------------------------
print("\nTest 2: toggle_baseline cycles ON->OFF->ON")
-- State: baseline=true
snapping.toggle_baseline()  -- baseline=false
assert(snapping.is_enabled() == false, "after first toggle should be OFF")

snapping.toggle_baseline()  -- baseline=true
assert(snapping.is_enabled() == true, "after second toggle should be ON")
print("  ok")

--------------------------------------------------------------------------------
-- Test 3: invert_drag when baseline ON -> effectively OFF
--------------------------------------------------------------------------------
print("\nTest 3: invert_drag when baseline ON -> OFF")
-- State: baseline=true, drag_inverted=false
assert(snapping.is_enabled() == true, "precondition: enabled")

snapping.invert_drag()  -- drag_inverted=true, XOR -> false
assert(snapping.is_enabled() == false, "invert while ON should give OFF")

snapping.reset_drag()  -- cleanup for next test
print("  ok")

--------------------------------------------------------------------------------
-- Test 4: invert_drag when baseline OFF -> effectively ON
--------------------------------------------------------------------------------
print("\nTest 4: invert_drag when baseline OFF -> ON")
-- State: baseline=true, drag_inverted=false
snapping.toggle_baseline()  -- baseline=false
assert(snapping.is_enabled() == false, "precondition: disabled")

snapping.invert_drag()  -- drag_inverted=true, XOR -> true
assert(snapping.is_enabled() == true, "invert while OFF should give ON")

snapping.reset_drag()       -- drag_inverted=false
snapping.toggle_baseline()  -- baseline=true (restore)
print("  ok")

--------------------------------------------------------------------------------
-- Test 5: reset_drag clears inversion
--------------------------------------------------------------------------------
print("\nTest 5: reset_drag clears inversion")
-- State: baseline=true, drag_inverted=false
snapping.invert_drag()  -- drag_inverted=true
assert(snapping.is_enabled() == false, "precondition: inverted")

snapping.reset_drag()  -- drag_inverted=false
assert(snapping.is_enabled() == true, "after reset should match baseline")
print("  ok")

--------------------------------------------------------------------------------
-- Test 6: Double invert_drag returns to original state
--------------------------------------------------------------------------------
print("\nTest 6: Double invert_drag is identity")
-- State: baseline=true, drag_inverted=false
local before = snapping.is_enabled()

snapping.invert_drag()  -- drag_inverted=true
snapping.invert_drag()  -- drag_inverted=false (toggled back)
assert(snapping.is_enabled() == before, "double invert should be identity")

-- Also test with baseline OFF
snapping.toggle_baseline()  -- baseline=false
before = snapping.is_enabled()
assert(before == false, "precondition: OFF")

snapping.invert_drag()
snapping.invert_drag()
assert(snapping.is_enabled() == before, "double invert identity with baseline OFF")

snapping.toggle_baseline()  -- baseline=true (restore)
print("  ok")

--------------------------------------------------------------------------------
-- Test 7: toggle_baseline + invert_drag combo (full XOR truth table)
--------------------------------------------------------------------------------
print("\nTest 7: XOR truth table")
-- State: baseline=true, drag_inverted=false

-- baseline=true, drag=false -> true
assert(snapping.is_enabled() == true, "T xor F = T")

-- baseline=true, drag=true -> false
snapping.invert_drag()
assert(snapping.is_enabled() == false, "T xor T = F")
snapping.reset_drag()

-- baseline=false, drag=false -> false
snapping.toggle_baseline()  -- baseline=false
assert(snapping.is_enabled() == false, "F xor F = F")

-- baseline=false, drag=true -> true
snapping.invert_drag()
assert(snapping.is_enabled() == true, "F xor T = T")

snapping.reset_drag()
snapping.toggle_baseline()  -- baseline=true (restore)
print("  ok")

print("\n\xE2\x9C\x85 test_snapping_state.lua passed")
