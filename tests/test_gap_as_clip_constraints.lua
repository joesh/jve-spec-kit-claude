#!/usr/bin/env luajit

-- T003: Gap-as-clip in roll constraint computation.
--
-- Domain behavior: when rolling the boundary between a real clip and a gap
-- clip, the gap's duration constrains how far the boundary can roll. The
-- gap cannot go below 0 duration. These tests verify that gaps participate
-- in compute_shift_bounds as first-class clips — after the refactor,
-- prime_neighbor_bounds_cache will include gaps (currently excludes them).
--
-- Scenario: V1: [A 0-100][gap 100-150][B 150-400]
-- Rolling the A/gap boundary (A.out + gap.in) moves the boundary, growing
-- A and shrinking the gap. The roll is bounded by the gap's duration (50).

require("test_env")
local runner = require("tests.helpers.ripple_test_runner")

local _, failed = runner.run_all({
    -- Roll the A/gap boundary right by 30: A grows 100→130, gap shrinks 50→20.
    {
        name = "roll_at_a_gap_boundary_within_bounds",
        before = [[
            V1: [A 0-100][B 150-400]
        ]],
        drag = "A out roll 30, A gap_after roll 30",
        after = [[
            V1: [A 0-130][B 150-400]
        ]],
    },

    -- Roll the A/gap boundary right by 80: clamped to +50 (gap fully consumed).
    {
        name = "roll_at_a_gap_boundary_clamps_to_gap_size",
        before = [[
            V1: [A 0-100][B 150-400]
        ]],
        drag = "A out roll 80, A gap_after roll 80",
        after = [[
            V1: [A 0-150][B 150-400]
        ]],
    },

    -- Roll the gap/B boundary left by 30: gap shrinks 50→20, B grows leftward.
    {
        name = "roll_at_gap_b_boundary_grows_b_leftward",
        before = [[
            V1: [A 0-100][B 150-400]
        ]],
        drag = "B gap_before roll -30, B in roll -30",
        after = [[
            V1: [A 0-100][B 120-400]
        ]],
    },

    -- Roll the gap/B boundary left by 80: clamped to -50 (gap fully consumed).
    {
        name = "roll_at_gap_b_boundary_clamps_to_gap_size",
        before = [[
            V1: [A 0-100][B 150-400]
        ]],
        drag = "B gap_before roll -80, B in roll -80",
        after = [[
            V1: [A 0-100][B 100-400]
        ]],
    },
})

assert(failed == 0, string.format("test_gap_as_clip_constraints: %d tests failed", failed))
print("✅ test_gap_as_clip_constraints.lua passed")
