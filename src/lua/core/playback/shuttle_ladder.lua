--- core/playback/shuttle_ladder.lua — the JKL shuttle speed ladder
--- (spec 025 FR-003). Pure speed arithmetic, no engine/controller state.
---
--- Ladder (NLE convention, FCP7/Resolve-style quarter steps to 2x, then
--- geometric, capped at 32x):
---
---     1.0 → 1.25 → 1.5 → 1.75 → 2.0 → 4.0 → 8.0 → 16.0 → 32.0 (max)
---
--- The 32x ceiling (FCP7 convention) is a hard limit, not cosmetic: above
--- ~32x the video decoder + clip prefetch cannot keep the playhead's frame
--- in cache, so deliverFrame starves — video freezes/goes black while the
--- audio pump and the position counter (separate threads) keep running.
--- An uncapped climb is the freeze in spec 025 FR-003.
---
--- step_up   advances one rung (same-direction shuttle press, faster).
--- step_down retreats one rung; at the 1.0x base it returns nil, the
---           signal to STOP (the opposite-direction key at 1x stops
---           playback rather than reversing — the J/K/L unwinding rule).
---
--- The 0.5x slow-play (K+J / K+L) lives below the ladder. A same-direction
--- step from 0.5x rejoins the ladder at its base (1.0x); an opposite step
--- from 0.5x stops. Both match the pre-025 slow-play exit.
---
--- All ladder values are exact in IEEE-754 (multiples of 0.25 below 2x,
--- powers of two above), so no rounding is needed to avoid drift.

local M = {}

local STEP     = 0.25  -- increment between 1.0x and 2.0x
local STEP_MAX = 2.0   -- above this the ladder goes geometric (×2)
local BASE     = 1.0   -- bottom rung of the ladder
local MAX      = 32.0  -- top rung (FCP7 convention); above this the decoder
                       -- + prefetch can't service the playhead and video
                       -- starves. Must match PlaybackController::SetSpeed's
                       -- abs_speed ceiling in playback_controller.mm.

--- Next speed up the ladder from `speed`.
function M.step_up(speed)
    assert(type(speed) == "number" and speed > 0,
        "shuttle_ladder.step_up: speed must be positive, got " .. tostring(speed))
    if speed < BASE then return BASE end      -- rejoin ladder from slow-play
    if speed >= MAX then return MAX end       -- ceiling: hold at top rung
    if speed < STEP_MAX then return speed + STEP end
    return math.min(speed * 2, MAX)
end

--- Next speed down the ladder from `speed`; nil means STOP.
function M.step_down(speed)
    assert(type(speed) == "number" and speed > 0,
        "shuttle_ladder.step_down: speed must be positive, got " .. tostring(speed))
    if speed <= BASE then return nil end      -- at/below base → stop
    if speed <= STEP_MAX then return speed - STEP end
    return speed / 2
end

return M
