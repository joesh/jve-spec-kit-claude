--- Test: clip_mutator.resolve_occlusions/resolve_ripple fail-fast on missing required fields.
-- Per rule 2.13 / 1.14: callers must supply complete params; the previous
-- "nil params/track_id → silent noop" behavior masked bugs. Now every
-- missing required field asserts loud.
require("test_env")

local passed, failed = 0, 0
local function check(label, cond)
    if cond then passed = passed + 1
    else failed = failed + 1; print("FAIL: " .. label) end
end

-- Stub krono
package.loaded["core.krono"] = nil

local ClipMutator = require("core.clip_mutator")

-- resolve_occlusions: every missing required input asserts loud.
local ok1 = pcall(function()
    ClipMutator.resolve_occlusions(nil, { track_id = nil, sequence_start = 0, duration = 10 })
end)
check("resolve_occlusions asserts on nil track_id", not ok1)

local ok2 = pcall(function()
    ClipMutator.resolve_occlusions(nil, { track_id = "t1", sequence_start = 0, duration = nil })
end)
check("resolve_occlusions asserts on nil duration", not ok2)

local ok5 = pcall(function()
    ClipMutator.resolve_occlusions(nil, nil)
end)
check("resolve_occlusions asserts on nil params", not ok5)

-- resolve_ripple: same contract.
local ok3 = pcall(function()
    ClipMutator.resolve_ripple(nil, { track_id = nil, sequence_start_frame = 0, shift_amount = 5 })
end)
check("resolve_ripple asserts on nil track_id", not ok3)

local ok4 = pcall(function()
    ClipMutator.resolve_ripple(nil, { track_id = "t1", sequence_start_frame = 0, shift_amount = nil })
end)
check("resolve_ripple asserts on nil shift_amount", not ok4)

local ok6 = pcall(function()
    ClipMutator.resolve_ripple(nil, nil)
end)
check("resolve_ripple asserts on nil params", not ok6)

if failed > 0 then
    print(string.format("❌ test_clip_mutator_missing_fields.lua: %d passed, %d FAILED", passed, failed))
    os.exit(1)
end
print(string.format("✅ test_clip_mutator_missing_fields.lua passed (%d assertions)", passed))
