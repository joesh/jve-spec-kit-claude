--- Test: clip_mutator.resolve_occlusions/resolve_ripple assert on missing required fields
-- nil params/track_id → noop (valid "nothing to do")
-- nil duration/start_value/shift_amount within valid params → assert (invariant violation)
require("test_env")

local passed, failed = 0, 0
local function check(label, cond)
    if cond then passed = passed + 1
    else failed = failed + 1; print("FAIL: " .. label) end
end

-- Stub krono
package.loaded["core.krono"] = nil

local ClipMutator = require("core.clip_mutator")

-- Test 1: resolve_occlusions with nil track_id → noop (true)
local ok1 = pcall(function()
    return ClipMutator.resolve_occlusions(nil, { track_id = nil, timeline_start = 0, duration = 10 })
end)
check("resolve_occlusions noops on nil track_id", ok1)

-- Test 2: resolve_occlusions with nil duration should assert
local ok2 = pcall(function()
    ClipMutator.resolve_occlusions(nil, { track_id = "t1", timeline_start = 0, duration = nil })
end)
check("resolve_occlusions asserts on nil duration", not ok2)

-- Test 3: resolve_ripple with nil track_id → noop (true)
local ok3 = pcall(function()
    return ClipMutator.resolve_ripple(nil, { track_id = nil, insert_time = 0, shift_amount = 5 })
end)
check("resolve_ripple noops on nil track_id", ok3)

-- Test 4: resolve_ripple with nil shift_amount should assert
local ok4 = pcall(function()
    ClipMutator.resolve_ripple(nil, { track_id = "t1", insert_time = 0, shift_amount = nil })
end)
check("resolve_ripple asserts on nil shift_amount", not ok4)

-- Test 5: nil params → noop (true), not crash
local ok5, _ = pcall(function()
    return ClipMutator.resolve_occlusions(nil, nil)
end)
check("resolve_occlusions noops on nil params", ok5)

local ok6, _ = pcall(function()
    return ClipMutator.resolve_ripple(nil, nil)
end)
check("resolve_ripple noops on nil params", ok6)

if failed > 0 then
    print(string.format("❌ test_clip_mutator_missing_fields.lua: %d passed, %d FAILED", passed, failed))
    os.exit(1)
end
print(string.format("✅ test_clip_mutator_missing_fields.lua passed (%d assertions)", passed))
