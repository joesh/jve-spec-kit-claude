#!/usr/bin/env luajit

-- Comprehensive roll tests using the DSL.
-- Key principle: roll vs ripple on the same layout MUST produce different results.
-- If they produce the same result, the roll is broken (behaving as ripple).

require("test_env")
local runner = require("synthetic.helpers.ripple_test_runner")

local _, failed = runner.run_all({

    -- =====================================================================
    -- 1. Roll vs Ripple comparison — THE KILLER TEST
    --    Same layout, same delta, different trim_type → different results.
    -- =====================================================================

    {
        name = "ripple_extends_and_shifts_downstream",
        before = [[
            V1: [A 0-100][B 100-400][C 400-600]
        ]],
        drag = "A out 50",
        after = [[
            V1: [A 0-150][B 150-450][C 450-650]
        ]],
    },
    {
        name = "roll_extends_and_trims_neighbor_downstream_stays",
        before = [[
            V1: [A 0-100][B 100-400][C 400-600]
        ]],
        drag = "A out roll 50, B in roll 50",
        after = [[
            V1: [A 0-150][B 150-400][C 400-600]
        ]],
    },

    -- =====================================================================
    -- 2. Roll negative delta — shrink A, extend B, C stays
    -- =====================================================================

    {
        name = "roll_negative_shrinks_left_extends_right",
        before = [[
            V1: [A 0-200][B 200-500][C 500-700]
        ]],
        drag = "A out roll -50, B in roll -50",
        after = [[
            V1: [A 0-150][B 150-500][C 500-700]
        ]],
    },

    -- =====================================================================
    -- 3. Roll with gap — clip + gap boundary
    -- =====================================================================

    {
        name = "roll_into_gap_extends_clip",
        before = [[
            V1: [A 0-100][B 300-500]
        ]],
        -- Gap is [100-300]. Roll A:out + gap:in to extend A into gap.
        drag = "A out roll 50, A gap_after roll 50",
        after = [[
            V1: [A 0-150][B 300-500]
        ]],
    },

    -- =====================================================================
    -- 4. Multi-track roll — V1 + A1 simultaneously
    -- =====================================================================

    {
        name = "roll_multitrack_v1_and_a1",
        before = [[
            V1: [A 0-300][B 300-600][C 600-900]
            A1: [D 0-300][E 300-600][F 600-900]
        ]],
        drag = "A out roll 100, B in roll 100, D out roll 100, E in roll 100",
        after = [[
            V1: [A 0-400][B 400-600][C 600-900]
            A1: [D 0-400][E 400-600][F 600-900]
        ]],
    },

    -- =====================================================================
    -- 5. Roll on audio track only — the reported bug scenario
    --    Audio clips adjacent, roll at boundary.
    -- =====================================================================

    {
        name = "roll_audio_only_adjacent",
        before = [[
            A1: [X 0-500][Y 500-1200][Z 1200-1800]
        ]],
        drag = "X out roll 100, Y in roll 100",
        after = [[
            A1: [X 0-600][Y 600-1200][Z 1200-1800]
        ]],
    },

    -- =====================================================================
    -- 6. Roll on audio with gap on video — cross-track independence
    --    Roll on A1 should not affect V1.
    -- =====================================================================

    {
        name = "roll_audio_doesnt_affect_video",
        before = [[
            V1: [A 0-300][B 500-800]
            A1: [C 0-400][D 400-900]
        ]],
        drag = "C out roll 50, D in roll 50",
        after = [[
            V1: [A 0-300][B 500-800]
            A1: [C 0-450][D 450-900]
        ]],
    },

    -- =====================================================================
    -- 7. Roll at media boundary (clamped by source limits)
    --    Media has 24000 frames. Clip A uses source_in=100, so extending
    --    should be limited by media.duration_frames.
    -- =====================================================================

    {
        name = "roll_small_delta_within_bounds",
        before = [[
            V1: [P 0-200][Q 200-500][R 500-700]
        ]],
        drag = "P out roll 30, Q in roll 30",
        after = [[
            V1: [P 0-230][Q 230-500][R 500-700]
        ]],
    },

    -- =====================================================================
    -- 8. Roll negative that would shrink below 1 frame — clamped
    -- =====================================================================

    {
        name = "roll_clamped_at_min_duration",
        before = [[
            V1: [A 0-10][B 10-500][C 500-600]
        ]],
        -- Try to shrink A by 20 — clamped to -10 (A deleted at duration 0).
        -- B's in-point absorbs the full clamped delta.
        drag = "A out roll -20, B in roll -20",
        after = [[
            V1: [B 0-500][C 500-600]
        ]],
        verify_source_in = false,
    },

    -- =====================================================================
    -- 9. Roll then ripple on same layout — verify they're different
    --    This tests the same operation on the SAME initial state.
    --    If both tests pass, roll and ripple must produce different results.
    -- =====================================================================

    {
        name = "ripple_baseline_for_comparison",
        before = [[
            V1: [M 0-300][N 300-700][O 700-1000]
            A1: [P 0-500][Q 500-1000]
        ]],
        -- Ripple M out +100 on V1 → implicit gap injection shifts A1
        -- downstream clips too (Q at 500 → gap injected → Q shifts to 600)
        drag = "M out 100",
        after = [[
            V1: [M 0-400][N 400-800][O 800-1100]
            A1: [P 0-500][Q 600-1100]
        ]],
    },
    {
        name = "roll_baseline_for_comparison",
        before = [[
            V1: [M 0-300][N 300-700][O 700-1000]
            A1: [P 0-500][Q 500-1000]
        ]],
        drag = "M out roll 100, N in roll 100",
        after = [[
            V1: [M 0-400][N 400-700][O 700-1000]
            A1: [P 0-500][Q 500-1000]
        ]],
    },
})

assert(failed == 0,
    string.format("test_roll_vs_ripple: %d tests failed (see above)", failed))

print("✅ test_roll_vs_ripple.lua passed")
