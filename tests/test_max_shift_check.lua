#!/usr/bin/env luajit

-- T002: Max-shift check across multiple tracks.
--
-- Domain behavior: when rippling on one track, all tracks shift by the
-- same delta. The most constrained track (smallest gap at boundary)
-- determines the global max shift. If any track has zero space, the
-- entire ripple is clamped to zero.
--
-- These tests verify the CLAMPING behavior — the delta gets reduced
-- when it would cause a collision on any track. The current implementation
-- may pass some of these via existing constraint logic; the goal is to
-- ensure they continue to pass after the refactor to bulk shifts.

require("test_env")
local runner = require("tests.helpers.ripple_test_runner")

local _, failed = runner.run_all({
    -- A1 gap at boundary = 50, A2 gap at boundary = 20.
    -- Ripple V1 by +80 → clamped to +20 (A2 is most constrained).
    {
        name = "multitrack_clamped_by_tightest_gap",
        before = [[
            V1: [A 0-100][B 100-400]
            A1: [C 0-50][D 150-300]
            A2: [E 0-80][F 120-300]
        ]],
        drag = "A out 80",
        after = [[
            V1: [A 0-120][B 120-420]
            A1: [C 0-50][D 170-320]
            A2: [E 0-80][F 140-320]
        ]],
    },

    -- Ripple fits within all gaps.
    -- V1 boundary at 100. A1 gap = 50. A2 gap = 20.
    -- Ripple by +15 → fits everywhere (15 < 20).
    {
        name = "multitrack_fits_all_gaps",
        before = [[
            V1: [A 0-100][B 100-400]
            A1: [C 0-50][D 150-300]
            A2: [E 0-80][F 120-300]
        ]],
        drag = "A out 15",
        after = [[
            V1: [A 0-115][B 115-415]
            A1: [C 0-50][D 165-315]
            A2: [E 0-80][F 135-315]
        ]],
    },

    -- Zero-space: A2 clip starts exactly at boundary (no gap).
    -- Ripple by +10 → clamped to 0.
    {
        name = "multitrack_zero_space_clamps_all",
        before = [[
            V1: [A 0-100][B 100-400]
            A1: [C 0-50][D 150-300]
            A2: [E 0-80][F 100-300]
        ]],
        drag = "A out 10",
        after = [[
            V1: [A 0-100][B 100-400]
            A1: [C 0-50][D 150-300]
            A2: [E 0-80][F 100-300]
        ]],
    },

    -- Single track ripple (no multitrack constraint).
    -- V1 only — no other tracks to constrain.
    {
        name = "single_track_unconstrained",
        before = [[
            V1: [A 0-100][B 100-400]
        ]],
        drag = "A out 50",
        after = [[
            V1: [A 0-150][B 150-450]
        ]],
    },
})

assert(failed == 0, string.format("test_max_shift_check: %d tests failed", failed))
print("✅ test_max_shift_check.lua passed")
