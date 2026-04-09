#!/usr/bin/env luajit

-- Smoke test: verify the DSL supports roll syntax and undo round-trip.

require("test_env")
local runner = require("tests.helpers.ripple_test_runner")

runner.run_all({
    -- Basic ripple (existing behavior, backward compat)
    -- Ripple A out +50: A extends, B and C shift right by 50 (durations unchanged)
    {
        name = "ripple_backward_compat",
        before = [[
            V1: [A 0-100][B 100-400][C 400-600]
        ]],
        drag = "A out 50",
        after = [[
            V1: [A 0-150][B 150-450][C 450-650]
        ]],
    },

    -- Roll: downstream must NOT move
    {
        name = "roll_basic",
        before = [[
            V1: [A 0-100][B 100-400][C 400-600]
        ]],
        drag = "A out roll 50, B in roll 50",
        after = [[
            V1: [A 0-150][B 150-400][C 400-600]
        ]],
    },
})

print("✅ test_dsl_roll_smoke.lua passed")
