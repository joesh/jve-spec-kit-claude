#!/usr/bin/env luajit

-- T003: Gap-as-clip in constraint computation.
--
-- Domain behavior: when rolling multiple edges, the gap between them
-- constrains how far you can roll. Gaps participate as clips in
-- compute_shift_bounds — they have position and duration that limit
-- movement.
--
-- These tests verify that gaps constrain multi-edge rolls correctly.
-- After the refactor, prime_neighbor_bounds_cache will include gaps
-- (currently it excludes them).

require("test_env")
local runner = require("tests.helpers.ripple_test_runner")

local _, failed = runner.run_all({
    -- Roll A out + B in by +60. Gap between A and B is 50 frames.
    -- Should clamp to +50.
    {
        name = "gap_constrains_roll_outward",
        before = [[
            V1: [A 0-100][B 150-400]
        ]],
        drag = "A out roll 60, B in roll 60",
        after = [[
            V1: [A 0-150][B 150-400]
        ]],
    },

    -- Roll A out + B in by +50. Gap is exactly 50. Should fit.
    {
        name = "gap_constrains_roll_exact_fit",
        before = [[
            V1: [A 0-100][B 150-400]
        ]],
        drag = "A out roll 50, B in roll 50",
        after = [[
            V1: [A 0-150][B 150-400]
        ]],
    },

    -- Roll A out + B in by -10. Gap grows from 50 to 60.
    {
        name = "gap_grows_on_inward_roll",
        before = [[
            V1: [A 0-100][B 150-400]
        ]],
        drag = "A out roll -10, B in roll -10",
        after = [[
            V1: [A 0-90][B 160-400]
        ]],
    },

    -- Adjacent clips (no gap). Roll by +10 should clamp to 0.
    {
        name = "adjacent_clips_zero_gap_clamps_roll",
        before = [[
            V1: [A 0-100][B 100-400]
        ]],
        drag = "A out roll 10, B in roll 10",
        after = [[
            V1: [A 0-100][B 100-400]
        ]],
    },
})

assert(failed == 0, string.format("test_gap_as_clip_constraints: %d tests failed", failed))
print("✅ test_gap_as_clip_constraints.lua passed")
