#!/usr/bin/env luajit
--- Test: multiple ripple edges on same track accumulate downstream shift.
--
-- Scenario: V1 has clips A(0-300) and B(300-600), abutted.
-- Select both out-edges, drag left 50.
-- Each clip shortens by 50. Downstream shift should be -100 (cumulative).
--
-- Expected: A(0-250), B(250-450). Timeline shortened by 100.
-- Bug: only shifted by 50 (first seed wins per track).

require("test_env")

local runner = require("tests.helpers.ripple_test_runner")

local tests = {

-- ─────────────────────────────────────────────────────────────────────────────
-- SAME-TRACK: two out-edges ripple, shift must accumulate
-- ─────────────────────────────────────────────────────────────────────────────

{
    name = "two out-edges same track: cumulative shift",
    -- A and B abutted on V1. Both out-edges trimmed left 50.
    -- A: trim out -50 → dur 250. B: trim out -50 → dur 250, shift -50 (A's ripple).
    -- C: no trim, shift -100 (A's + B's cumulative).
    before = [[
        V1: [A 0-300][B 300-600][C 600-900]
    ]],
    drag = "A out -50, B out -50",
    after = [[
        V1: [A 0-250][B 250-500][C 500-800]
    ]],
},


{
    name = "two out-edges same track with other tracks: sync shift",
    -- V1 has two out-edges. A1 has no edges but has a gap before the ripple
    -- boundary so E and F can shift. D ends at 200, gap 200-300, E starts at 300.
    -- E and F shift left by cumulative -100.
    before = [[
        V1: [A 0-300][B 300-600][C 600-900]
        A1: [D 0-200][E 300-600][F 600-900]
    ]],
    drag = "A out -50, B out -50",
    after = [[
        V1: [A 0-250][B 250-500][C 500-800]
        A1: [D 0-200][E 200-500][F 500-800]
    ]],
},

{
    name = "two out-edges same track: audio predecessor blocks correctly",
    -- V1: A(0-35) B(35-66). Audio tracks have clips before and after boundary.
    -- A1: D(0-28) E(35-59). Gap D→E = 7 frames.
    -- Select both V1 out-edges, trim left 7. Each clip shrinks 7.
    -- B shifts left 7 (A's ripple). Downstream shift on V1 = -14.
    -- But A1 clips only shift by as much as the gap allows (7 frames).
    -- Audio should NOT be blocked by the V1 cumulative shift.
    before = [[
        V1: [A 0-35][B 35-66]
        A1: [D 0-28][E 35-59]
    ]],
    drag = "A out -7, B out -7",
    after = [[
        V1: [A 0-28][B 28-52]
        A1: [D 0-28][E 28-52]
    ]],
},

{
    name = "two out-edges same track: close gap completely",
    -- Same as above but gap is exactly the size of one edge's trim.
    -- V1: A(0-30) B(30-55). A1: D(0-25) E(30-55). Gap D→E = 5 frames.
    -- Trim both out-edges left by 5.
    -- A: 0-25, B shifts left 5 → 25-45. V1 total shift = -10.
    -- A1: E shifts left 5 (gap absorbed), E: 25-50.
    before = [[
        V1: [A 0-30][B 30-55]
        A1: [D 0-25][E 30-55]
    ]],
    drag = "A out -5, B out -5",
    after = [[
        V1: [A 0-25][B 25-45]
        A1: [D 0-25][E 25-50]
    ]],
},

}

runner.run_all(tests)
print("✅ test_ripple_multi_edge_same_track.lua passed")
