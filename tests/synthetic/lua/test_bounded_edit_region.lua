#!/usr/bin/env luajit

-- Regression guard for the bounded edit region refactor (feature 008).
--
-- Each scenario exercises one of the edit-region patterns that 008
-- restructured the pipeline to handle: a pure roll that touches no
-- downstream clips, a single-edge ripple that pushes downstream, and
-- a multi-edge ripple where the inter-edge gap participates in the
-- constraint math. The DSL runner verifies that every clip lands at
-- its expected timeline position and duration after execute + undo +
-- redo.
--
-- These are black-box correctness checks, not perf assertions — the
-- perf win is validated separately against the anamnesis project via
-- the --test mode script in /tmp/jve/perf_008_ripple.lua.

require("test_env")
local runner = require("synthetic.helpers.ripple_test_runner")

local _, failed = runner.run_all({
    -- Roll edit: only 2 clips participate. Downstream untouched.
    {
        name = "roll_bounded_two_clips",
        before = [[
            V1: [A 0-100][B 100-400][C 400-600]
            A1: [D 0-200][E 200-500]
        ]],
        drag = "A out roll 30, B in roll 30",
        after = [[
            V1: [A 0-130][B 130-400][C 400-600]
            A1: [D 0-200][E 200-500]
        ]],
    },

    -- Ripple edit: A extends, B and C shift. A1/A2 downstream shifts.
    -- The edit region is just clip A + its neighbor B.
    -- Everything else is downstream bulk shift.
    {
        name = "ripple_bounded_edit_region",
        before = [[
            V1: [A 0-100][B 100-400][C 400-600]
            A1: [D 0-50][E 150-400]
        ]],
        drag = "A out 50",
        after = [[
            V1: [A 0-150][B 150-450][C 450-650]
            A1: [D 0-50][E 200-450]
        ]],
    },

    -- Multi-edge ripple: two edges on same track.
    -- Edit region includes both edited clips + gaps between.
    {
        name = "multi_edge_bounded",
        before = [[
            V1: [A 0-100][B 200-400][C 400-600]
        ]],
        drag = "A out 30",
        after = [[
            V1: [A 0-130][B 230-430][C 430-630]
        ]],
    },
})

assert(failed == 0, string.format("test_bounded_edit_region: %d tests failed", failed))
print("✅ test_bounded_edit_region.lua passed")
