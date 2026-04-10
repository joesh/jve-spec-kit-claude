#!/usr/bin/env luajit

-- T006: Bounded clip access — verify edit operations don't load all clips.
--
-- Domain behavior: a roll edit on 2 clips should load only those clips
-- plus their neighbors, not the entire sequence. A ripple edit should
-- load only the edit region clips and use bulk shift for downstream.
--
-- These tests verify the bounded access invariant by checking that
-- the pipeline operates on a small subset of clips.
--
-- NOTE: Until the implementation bounds build_clip_cache, these tests
-- may pass vacuously (the current code loads everything but the tests
-- only check positions). The key assertions are on clip ACCESS COUNTS
-- which require instrumentation added in T007.

require("test_env")
local runner = require("tests.helpers.ripple_test_runner")

-- These tests use the DSL runner to verify correctness of bounded edits.
-- The bounded access counting will be added as asserts inside the
-- implementation (T007) and verified via integration test (T014).

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
