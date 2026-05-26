-- Regression: AOP must report the target buffer duration it was opened with.
--
-- Why: AOP sizes its ring buffer 3× target. PlaybackController/AudioPump
-- pumps audio toward a target that MUST fit inside that ring (otherwise
-- RingBuffer::write silently truncates and the pump-side return-ignoring
-- callsite drops PCM). We eliminate the bug class by making AOP the
-- canonical source — pump derives its target from AOP::TargetBufferMs().
-- This test pins that contract: open with X, get X back.
--
-- Run via: ./build/bin/jve --test tests/test_aop_target_buffer_ms.lua
require('test_env')

if not (qt_constants and qt_constants.AOP) then
    -- Qt bindings only exist inside the JVEEditor host process.
    -- Run via: ./build/bin/jve --test tests/test_aop_target_buffer_ms.lua
    print("✅ test_aop_target_buffer_ms.lua skipped (needs Qt bindings)")
    return
end
local AOP = qt_constants.AOP
assert(AOP.OPEN and AOP.CLOSE and AOP.TARGET_BUFFER_MS,
    "AOP.OPEN/CLOSE/TARGET_BUFFER_MS must be exposed")

-- Use a non-default value so a future hardcoded-100 default would mismatch.
local REQUESTED_MS = 175
local SAMPLE_RATE = 48000
local CHANNELS = 2

local aop, err = AOP.OPEN(SAMPLE_RATE, CHANNELS, REQUESTED_MS)
assert(aop, "AOP.OPEN failed: " .. tostring(err))

local reported = AOP.TARGET_BUFFER_MS(aop)
assert(reported == REQUESTED_MS,
    string.format("AOP.TARGET_BUFFER_MS expected %d, got %s", REQUESTED_MS, tostring(reported)))

AOP.CLOSE(aop)

-- Second open with a different value catches stuck-state bugs.
local aop2 = AOP.OPEN(SAMPLE_RATE, CHANNELS, 50)
assert(aop2, "second AOP.OPEN failed")
local reported2 = AOP.TARGET_BUFFER_MS(aop2)
assert(reported2 == 50,
    string.format("second AOP.TARGET_BUFFER_MS expected 50, got %s", tostring(reported2)))
AOP.CLOSE(aop2)

print("✅ test_aop_target_buffer_ms.lua passed")
