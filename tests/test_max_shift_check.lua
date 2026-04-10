#!/usr/bin/env luajit

-- Multitrack max-shift clamp regression guard (feature 008).
--
-- Domain behavior: when rippling on one track, all tracks shift by the
-- same delta. The constraint is only meaningful for NEGATIVE ripples —
-- downstream clips shifting LEFT can collide with their upstream neighbors.
-- Positive ripples always have unlimited rightward room and don't clamp.
--
-- On a "straight cut" (all tracks split at the same frame, zero-length
-- gaps), positive ripple propagates cleanly — implicit gap edges get
-- injected and the downstream shifts. Negative ripple on a straight cut
-- has zero leftward room on every track and must clamp to 0.

require("test_env")
local runner = require("tests.helpers.ripple_test_runner")

local _, failed = runner.run_all({
    -- Negative ripple: the most constrained track determines max delta.
    -- A2's F has only 10 frames of room to its upstream neighbor E
    -- (E ends at 100, F starts at 110). Delta -30 must clamp to -10.
    {
        name = "multitrack_negative_ripple_clamped_by_tightest_track",
        before = [[
            V1: [A 0-100][B 100-400]
            A1: [C 0-40][D 120-300]
            A2: [E 0-100][F 110-300]
        ]],
        drag = "A out -30",
        after = [[
            V1: [A 0-90][B 90-390]
            A1: [C 0-40][D 110-290]
            A2: [E 0-100][F 100-290]
        ]],
    },

    -- Negative ripple fits within every track's upstream room.
    -- |−20| < min(F-E=60, D-C=80, B-A=0[source]). V1's A shrinks to 80,
    -- downstream shifts left by 20 on every track.
    {
        name = "multitrack_negative_ripple_fits_all_upstreams",
        before = [[
            V1: [A 0-100][B 100-400]
            A1: [C 0-40][D 120-300]
            A2: [E 0-50][F 110-300]
        ]],
        drag = "A out -20",
        after = [[
            V1: [A 0-80][B 80-380]
            A1: [C 0-40][D 100-280]
            A2: [E 0-50][F 90-280]
        ]],
    },

    -- Zero upstream space on A2 (E and F adjacent). Any negative ripple
    -- clamps to 0 globally — the tightest track has zero leftward room.
    {
        name = "multitrack_zero_upstream_space_clamps_all",
        before = [[
            V1: [A 0-100][B 100-400]
            A1: [C 0-50][D 130-300]
            A2: [E 0-100][F 100-300]
        ]],
        drag = "A out -10",
        after = [[
            V1: [A 0-100][B 100-400]
            A1: [C 0-50][D 130-300]
            A2: [E 0-100][F 100-300]
        ]],
    },

    -- Single track positive ripple — no multitrack constraint, full delta.
    {
        name = "single_track_positive_unconstrained",
        before = [[
            V1: [A 0-100][B 100-400]
        ]],
        drag = "A out 50",
        after = [[
            V1: [A 0-150][B 150-450]
        ]],
    },

    -- Straight cut across all tracks (zero-length gaps at frame 100 on
    -- A1/A2). Positive ripple +50 on V1 injects implicit gap edges on
    -- A1 and A2, growing each zero-length gap to 50 and shifting D, F
    -- right by 50. This is the most common multitrack ripple in real
    -- editing and must work.
    {
        name = "straight_cut_positive_ripple_propagates_all_tracks",
        before = [[
            V1: [A 0-100][B 100-400]
            A1: [C 0-100][D 100-400]
            A2: [E 0-100][F 100-400]
        ]],
        drag = "A out 50",
        after = [[
            V1: [A 0-150][B 150-450]
            A1: [C 0-100][D 150-450]
            A2: [E 0-100][F 150-450]
        ]],
    },

    -- Straight cut, negative ripple: every track has 0 upstream room
    -- at the cut. Global clamp = 0.
    {
        name = "straight_cut_negative_ripple_clamped_to_zero",
        before = [[
            V1: [A 0-100][B 100-400]
            A1: [C 0-100][D 100-400]
            A2: [E 0-100][F 100-400]
        ]],
        drag = "A out -30",
        after = [[
            V1: [A 0-100][B 100-400]
            A1: [C 0-100][D 100-400]
            A2: [E 0-100][F 100-400]
        ]],
    },
})

assert(failed == 0, string.format("test_max_shift_check: %d tests failed", failed))
print("✅ test_max_shift_check.lua passed")
