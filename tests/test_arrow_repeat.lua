require("test_env")

-- Override test_env's default timer stub BEFORE requiring arrow_repeat.
-- arrow_repeat chains timers (tick schedules next tick), so auto-firing
-- would cause infinite recursion. We capture callbacks instead.
local captured_timers = {}
_G.qt_create_single_shot_timer = function(ms, callback)
    table.insert(captured_timers, { ms = ms, callback = callback })
end

local arrow_repeat = require("ui.arrow_repeat")

local pass_count = 0
local fail_count = 0

local function check(label, condition)
    if condition then
        pass_count = pass_count + 1
    else
        fail_count = fail_count + 1
        print("FAIL: " .. label)
    end
end

local function expect_error(label, fn, pattern)
    local ok, err = pcall(fn)
    if not ok then
        if pattern and not tostring(err):match(pattern) then
            fail_count = fail_count + 1
            print("FAIL (wrong error): " .. label .. " got: " .. tostring(err))
        else
            pass_count = pass_count + 1
        end
    else
        fail_count = fail_count + 1
        print("FAIL (expected error): " .. label)
    end
end

--- Reset module state between tests.
local function reset()
    arrow_repeat.stop()
    captured_timers = {}
end

print("\n=== Arrow Repeat Tests ===")

-- ============================================================
-- start() calls fn immediately with direction and shift
-- ============================================================
print("\n--- immediate callback ---")
do
    reset()
    local calls = {}
    arrow_repeat.start(1, false, function(d, s)
        table.insert(calls, { dir = d, shift = s })
    end)
    check("fn called once immediately", #calls == 1)
    check("direction=1 passed", calls[1].dir == 1)
    check("shift=false passed", calls[1].shift == false)
    reset()
end

-- ============================================================
-- start() sets is_active() to true
-- ============================================================
print("\n--- is_active after start ---")
do
    reset()
    check("inactive before start", arrow_repeat.is_active() == false)
    arrow_repeat.start(1, false, function() end)
    check("active after start", arrow_repeat.is_active() == true)
    reset()
end

-- ============================================================
-- stop() sets is_active() to false
-- ============================================================
print("\n--- is_active after stop ---")
do
    reset()
    arrow_repeat.start(1, false, function() end)
    check("active after start", arrow_repeat.is_active() == true)
    arrow_repeat.stop()
    check("inactive after stop", arrow_repeat.is_active() == false)
    reset()
end

-- ============================================================
-- start() with nil fn asserts
-- ============================================================
print("\n--- nil fn asserts ---")
do
    reset()
    expect_error("nil fn", function()
        arrow_repeat.start(1, false, nil)
    end, "step_fn is required")
    reset()
end

-- ============================================================
-- Second start() overrides first (generation counter invalidates old timer)
-- ============================================================
print("\n--- second start overrides first ---")
do
    reset()
    local calls_a = {}
    local calls_b = {}

    arrow_repeat.start(1, false, function(d, s)
        table.insert(calls_a, { dir = d, shift = s })
    end)
    check("first fn called immediately", #calls_a == 1)

    -- Capture the initial-delay timer from first start
    local first_timer = captured_timers[#captured_timers]
    assert(first_timer, "expected timer from first start")

    -- Second start — bumps generation, invalidating first timer
    arrow_repeat.start(-1, true, function(d, s)
        table.insert(calls_b, { dir = d, shift = s })
    end)
    check("second fn called immediately", #calls_b == 1)

    -- Fire the OLD timer callback — should be a no-op (gen mismatch)
    first_timer.callback()
    check("old timer did not call first fn again", #calls_a == 1)
    check("old timer did not call second fn", #calls_b == 1)

    reset()
end

-- ============================================================
-- stop() then tick doesn't call fn (invalidation works)
-- ============================================================
print("\n--- stop invalidates pending timer ---")
do
    reset()
    local call_count = 0

    arrow_repeat.start(1, false, function()
        call_count = call_count + 1
    end)
    check("immediate call happened", call_count == 1)

    -- Grab the initial-delay timer
    local delay_timer = captured_timers[#captured_timers]
    assert(delay_timer, "expected initial delay timer")

    arrow_repeat.stop()
    check("stopped", arrow_repeat.is_active() == false)

    -- Fire the timer callback after stop — gen mismatch + not active
    delay_timer.callback()
    check("fn not called after stop", call_count == 1)

    reset()
end

-- ============================================================
-- start with direction=-1, shift=true passes correct values
-- ============================================================
print("\n--- direction=-1 shift=true ---")
do
    reset()
    local calls = {}
    arrow_repeat.start(-1, true, function(d, s)
        table.insert(calls, { dir = d, shift = s })
    end)
    check("fn called once", #calls == 1)
    check("direction=-1", calls[1].dir == -1)
    check("shift=true", calls[1].shift == true)
    reset()
end

-- ============================================================
-- Timer ms values are correct (initial delay vs step)
-- ============================================================
print("\n--- timer delay values ---")
do
    reset()
    arrow_repeat.start(1, false, function() end)

    check("one timer scheduled (initial delay)", #captured_timers == 1)
    check("initial delay = 200ms", captured_timers[1].ms == 200)

    -- Simulate initial delay firing — this calls tick, which schedules step timer
    captured_timers[1].callback()
    check("step timer scheduled after initial delay", #captured_timers == 2)
    check("step interval = 33ms", captured_timers[2].ms == 33)

    reset()
end

-- ============================================================
-- Tick calls fn and chains next timer
-- ============================================================
print("\n--- tick calls fn and chains ---")
do
    reset()
    local call_count = 0
    arrow_repeat.start(1, false, function()
        call_count = call_count + 1
    end)
    check("immediate call", call_count == 1)

    -- Fire initial delay
    captured_timers[1].callback()
    check("tick called fn", call_count == 2)
    check("tick scheduled next timer", #captured_timers == 2)

    -- Fire step timer
    captured_timers[2].callback()
    check("second tick called fn", call_count == 3)
    check("second tick scheduled next timer", #captured_timers == 3)

    reset()
end

-- ============================================================
-- Summary
-- ============================================================
print(string.format("\n=== Arrow Repeat: %d passed, %d failed ===", pass_count, fail_count))
if fail_count > 0 then
    os.exit(1)
end
print("✅ test_arrow_repeat.lua passed")
