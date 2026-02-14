require('test_env')

-- Regression: execute_ui injects 'playhead' param from active sequence monitor.
-- Commands that don't declare 'playhead' in their spec must not crash.
-- Bug: command_schema rejected 'playhead' as unknown param for TogglePlay.

print("=== Test execute_ui playhead injection ===")

local command_schema = require("core.command_schema")

-- TogglePlay spec: only declares project_id, no playhead
local NON_UNDOABLE_SPEC = { undoable = false, args = { project_id = {} } }

-- Test 1: playhead is globally allowed in command_schema
print("\nTest 1: playhead globally allowed in schema validation")
local ok, _, err = command_schema.validate_and_normalize(
    "TogglePlay", NON_UNDOABLE_SPEC,
    { project_id = "proj", playhead = 42 },
    { is_ui_context = true }
)
assert(ok ~= false, "playhead should be globally allowed: " .. tostring(err))
print("  ✓ TogglePlay with playhead=42 accepted")

-- Test 2: sequence_id also globally allowed
print("\nTest 2: sequence_id globally allowed in schema validation")
ok, _, err = command_schema.validate_and_normalize(
    "TogglePlay", NON_UNDOABLE_SPEC,
    { project_id = "proj", sequence_id = "seq", playhead = 42 },
    { is_ui_context = true }
)
assert(ok ~= false, "sequence_id should be globally allowed: " .. tostring(err))
print("  ✓ TogglePlay with sequence_id + playhead accepted")

-- Test 3: truly unknown params still rejected
print("\nTest 3: unknown params still rejected")
ok, _, err = command_schema.validate_and_normalize(
    "TogglePlay", NON_UNDOABLE_SPEC,
    { project_id = "proj", bogus_param = "nope" },
    { is_ui_context = true, asserts_enabled = false }
)
assert(ok == false, "unknown param should be rejected")
assert(err:match("unknown param.*bogus_param"), "error should mention bogus_param: " .. tostring(err))
print("  ✓ bogus_param correctly rejected")

-- Test 4: playhead allowed even when no other args declared
print("\nTest 4: playhead with minimal spec (empty args)")
local EMPTY_SPEC = { undoable = false, args = {} }
ok, _, err = command_schema.validate_and_normalize(
    "MinimalCommand", EMPTY_SPEC,
    { project_id = "proj", playhead = 100 },
    { is_ui_context = true }
)
assert(ok ~= false, "playhead should work with empty args spec: " .. tostring(err))
print("  ✓ minimal spec with playhead accepted")

-- Test 5: ephemeral __keys pass through (boundary — schema must not reject these)
print("\nTest 5: ephemeral __keys pass through alongside playhead")
ok, _, err = command_schema.validate_and_normalize(
    "TogglePlay", NON_UNDOABLE_SPEC,
    { project_id = "proj", playhead = 42, __scratch = "temp" },
    { is_ui_context = true }
)
assert(ok ~= false, "ephemeral __keys should pass: " .. tostring(err))
print("  ✓ __scratch + playhead both accepted")

-- Test 6: multiple unknown params — error mentions one of them
print("\nTest 6: multiple unknown params rejected")
ok, _, err = command_schema.validate_and_normalize(
    "TogglePlay", NON_UNDOABLE_SPEC,
    { project_id = "proj", foo = 1, bar = 2 },
    { is_ui_context = true, asserts_enabled = false }
)
assert(ok == false, "multiple unknown params should be rejected")
assert(err:match("unknown param"), "error should say 'unknown param': " .. tostring(err))
print("  ✓ multiple unknown params correctly rejected")

print("\n✅ test_execute_ui_playhead_injection.lua passed")
