#!/usr/bin/env luajit
--- Black-box tests for audio_quality_mode.pick(abs_speed).
---
--- Verifies the speed→mode bands as a pure function. No SSE/AOP/EMP,
--- no audio_playback state machine. The slomo/decimate integration
--- tests still exercise the broader set_speed flow (reanchor on speed
--- change, mode transitions while playing); this file pins the
--- band-boundary contract that those tests depend on.
---
--- Bands (by abs(speed)):
---   > 4.0          → Q3_DECIMATE  (sample-skip; pitch climbs)
---   1.0 .. 4.0     → Q1           (editor, pitch-corrected stretch)
---   0.25 .. 1.0    → Q3_DECIMATE  (varispeed; pitch drops)
---   0 .. 0.25      → Q2           (extreme slomo; pitch-corrected)

require("test_env")

local qm = require("core.media.audio_quality_mode")

print("=== test_audio_quality_mode.lua ===")

local function expect(abs_speed, expected_mode, label)
    local got = qm.pick(abs_speed)
    assert(got == expected_mode, string.format(
        "pick(%g) → expected %d (%s), got %d",
        abs_speed, expected_mode, label, got))
end

-- Editor band: pitch-corrected stretch covers 1.0..MAX_SPEED_STRETCHED.
expect(1.0,  qm.Q1, "Q1 (1.0x lower edge)")
expect(2.0,  qm.Q1, "Q1 (2.0x mid)")
expect(4.0,  qm.Q1, "Q1 (4.0x upper edge — equals MAX_SPEED_STRETCHED)")

-- Decimate above MAX_SPEED_STRETCHED.
expect(4.001, qm.Q3_DECIMATE, "Q3_DECIMATE (just above 4x)")
expect(8.0,   qm.Q3_DECIMATE, "Q3_DECIMATE (8x)")
expect(16.0,  qm.Q3_DECIMATE, "Q3_DECIMATE (16x — equals MAX_SPEED_DECIMATE)")

-- Varispeed band: 0.25..1.0 drops pitch naturally.
expect(0.25, qm.Q3_DECIMATE, "Q3_DECIMATE (0.25x — lower edge of varispeed)")
expect(0.5,  qm.Q3_DECIMATE, "Q3_DECIMATE (0.5x)")
expect(0.99, qm.Q3_DECIMATE, "Q3_DECIMATE (just below 1.0x)")

-- Extreme slomo: < 0.25 swaps to Q2 for pitch correction.
expect(0.249, qm.Q2, "Q2 (just below 0.25x)")
expect(0.15,  qm.Q2, "Q2 (0.15x)")
expect(0.1,   qm.Q2, "Q2 (extreme slomo)")

-- Boundary: zero is allowed (stopped state).
expect(0.0, qm.Q2, "Q2 (0.0x — stopped, falls into <0.25 band)")

-- ---- Error paths ----------------------------------------------------

local function expect_error(fn, pattern_label)
    local ok, err = pcall(fn)
    assert(not ok, "expected error: " .. pattern_label)
    assert(type(err) == "string" and err ~= "",
        "error message must be a non-empty string for " .. pattern_label)
end

expect_error(function() qm.pick(nil) end,
    "nil abs_speed must assert")
expect_error(function() qm.pick("fast") end,
    "string abs_speed must assert")
expect_error(function() qm.pick(-0.5) end,
    "negative abs_speed must assert")
expect_error(function() qm.pick(qm.MAX_SPEED_DECIMATE + 0.001) end,
    "speed above MAX_SPEED_DECIMATE must assert")

print("  bands + boundaries + error paths verified")
print("\nPASS test_audio_quality_mode.lua")
