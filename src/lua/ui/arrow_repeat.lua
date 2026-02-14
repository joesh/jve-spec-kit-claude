--- Arrow key repeat timer.
--
-- Bypasses macOS key repeat rate (~12/sec) with our own timer at ~30fps.
-- Detects keyDown → start timer, keyUp → stop.
-- The step_fn callback is provided by the caller (keyboard dispatch).
--
-- @file arrow_repeat.lua
local M = {}

local STEP_MS = 33            -- ~30fps stepping (matches NLE convention)
local INITIAL_DELAY_MS = 200  -- delay before repeat starts

local active = false
local dir = 0                 -- 1=right, -1=left
local shift = false           -- shift held = 1-second jumps
local gen = 0                 -- generation counter for timer invalidation
local step_fn = nil           -- callback: step_fn(dir, shift)

--- Chained single-shot timer callback.
-- Schedules next tick BEFORE doing work so decode latency doesn't inflate interval.
local function tick(tick_gen)
    if tick_gen ~= gen or not active then return end

    -- Schedule next tick first — keeps cadence steady regardless of decode cost
    if qt_create_single_shot_timer then
        qt_create_single_shot_timer(STEP_MS, function()
            tick(tick_gen)
        end)
    end

    if step_fn then
        step_fn(dir, shift)
    end
end

--- Start arrow key repeat.
-- @param direction 1=right, -1=left
-- @param shift_held true for 1-second jumps
-- @param fn callback function(dir, shift) called each tick
function M.start(direction, shift_held, fn)
    assert(fn, "arrow_repeat.start: step_fn is required")

    active = true
    dir = direction
    shift = shift_held
    step_fn = fn
    gen = gen + 1
    local current_gen = gen

    -- Immediate first step
    fn(direction, shift_held)

    -- Start repeat after initial delay
    if qt_create_single_shot_timer then
        qt_create_single_shot_timer(INITIAL_DELAY_MS, function()
            tick(current_gen)
        end)
    end
end

--- Stop arrow key repeat (call on key release).
function M.stop()
    active = false
    gen = gen + 1  -- invalidate pending timer
end

--- Check if repeat is currently active.
function M.is_active()
    return active
end

return M
