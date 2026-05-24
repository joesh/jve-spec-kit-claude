--- Audio quality-mode selection: pure speed → mode mapping.
---
--- Extracted from audio_playback.lua so the speed-to-mode policy can
--- be tested without instantiating the SSE/AOP/EMP Qt bindings. The
--- mode constants match the SSE C++ enum (sse.h).
---
--- Bands (by abs(speed)):
---   • > MAX_SPEED_STRETCHED (4.0) → Q3_DECIMATE (sample-skip; no pitch
---     correction, no time stretch — pitch climbs naturally).
---   • >= 1.0 and <= MAX_SPEED_STRETCHED → Q1 (editor mode; WSOLA-style
---     pitch-corrected stretch, low latency).
---   • >= 0.25 and < 1.0 → Q3_DECIMATE (varispeed; natural pitch drop,
---     no time stretch).
---   • < 0.25 → Q2 (extreme slomo; pitch-corrected, higher latency).
---
--- The 0.25 threshold matches the practical lower bound where Q1's
--- WSOLA quality stays acceptable; below that Q2's longer-window
--- algorithm is needed.

local M = {}

M.Q1          = 1
M.Q2          = 2
M.Q3_DECIMATE = 3

M.MAX_SPEED_STRETCHED = 4.0   -- upper bound for pitch-corrected playback
M.MAX_SPEED_DECIMATE  = 16.0  -- upper bound for decimate mode (UI clamp)

function M.pick(abs_speed)
    assert(type(abs_speed) == "number",
        "audio_quality_mode.pick: abs_speed must be number")
    assert(abs_speed >= 0,
        "audio_quality_mode.pick: abs_speed must be >= 0")
    assert(abs_speed <= M.MAX_SPEED_DECIMATE,
        string.format(
            "audio_quality_mode.pick: abs_speed %.3f exceeds MAX_SPEED_DECIMATE (%.1f)",
            abs_speed, M.MAX_SPEED_DECIMATE))
    if abs_speed > M.MAX_SPEED_STRETCHED then return M.Q3_DECIMATE end
    if abs_speed < 0.25 then return M.Q2 end
    if abs_speed < 1.0 then return M.Q3_DECIMATE end
    return M.Q1
end

return M
