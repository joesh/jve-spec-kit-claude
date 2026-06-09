#!/usr/bin/env luajit
--- Comprehensive multitrack ripple trim tests using ASCII timeline DSL.
--
-- Format:
--   before: [ClipName start-end] per track, gaps are implicit
--   drag:   "ClipName edge delta" (comma-separated for multi-edge)
--   after:  expected positions after ripple

require("test_env")

local runner = require("synthetic.helpers.ripple_test_runner")

local tests = {

-- ─────────────────────────────────────────────────────────────────────────────
-- MULTITRACK: upstream clips must not move
-- ─────────────────────────────────────────────────────────────────────────────

{
    name = "in-edge multitrack: upstream V1 clips stable when audio starts at 0",
    -- Audio starts at frame 0, pulling ripple point early.
    -- C285 and Small are upstream of C284 — must not move.
    before = [[
        V1: [Small 0-100][C285 100-400][C284v 400-800]
        A1: [C284a 0-800]
    ]],
    drag = "C284v in 50, C284a in 50",
    after = [[
        V1: [Small 0-100][C285 100-400][C284v 400-750]
        A1: [C284a 0-750]
    ]],
},

{
    name = "in-edge multitrack: upstream clip not consumed by shift",
    -- Same idea but with a large delta that could overwrite upstream clips
    before = [[
        V1: [X 0-50][Y 50-200][Z 200-600]
        A1: [W 0-600]
    ]],
    drag = "Z in 100, W in 100",
    after = [[
        V1: [X 0-50][Y 50-200][Z 200-500]
        A1: [W 0-500]
    ]],
},

-- ─────────────────────────────────────────────────────────────────────────────
-- SINGLE-TRACK EDGE: audio downstream must shift implicitly
-- ─────────────────────────────────────────────────────────────────────────────

{
    name = "out-edge V1 only: blocked by adjacent audio (Eo, Go red)",
    -- Only V1 edge selected. A1/A2 have zero gap — shift blocked.
    -- E out-edge and G out-edge are the blockers (shown red in UI).
    -- Whole operation blocked: nothing moves.
    before = [[
        V1: [A 0-100][B 100-350][C 350-500][D 500-700]
        A1: [E 0-500][F 500-700]
        A2: [G 0-500][H 500-700]
    ]],
    drag = "C out -30",
    after = [[
        V1: [A 0-100][B 100-350][C 350-500][D 500-700]
        A1: [E 0-500][F 500-700]
        A2: [G 0-500][H 500-700]
    ]],
},

{
    name = "in-edge V1 only: co-located audio co-trims (Do ripple)",
    -- 015 'ripple' semantics: B and D are co-located (same start 200, same end 500).
    -- When V1.B's in-edge shrinks by +40, A1.D (co-located) is co-trimmed too.
    -- In-edge ripple: sequence_start stays fixed (200), end moves left by 40.
    -- Both B and D become 200-460 (duration 260); downstream E and F shift to 460.
    before = [[
        V1: [A 0-200][B 200-500][E 500-700]
        A1: [C 0-200][D 200-500][F 500-700]
    ]],
    drag = "B in 40",
    after = [[
        V1: [A 0-200][B 200-460][E 460-660]
        A1: [C 0-200][D 200-460][F 460-660]
    ]],
},

{
    name = "out-edge extend V1 only: audio downstream shifts right",
    before = [[
        V1: [A 0-300][B 300-500]
        A1: [C 0-300][D 300-500]
    ]],
    drag = "A out 60",
    after = [[
        V1: [A 0-360][B 360-560]
        A1: [C 0-300][D 360-560]
    ]],
},

{
    name = "in-edge extend V1: spanning leading gap doesn't drag boundary to 0",
    -- A3 has only a content clip starting at frame 1500 — a LEADING
    -- gap [0, 1500) spans the V1 in-edge boundary 100. Before the
    -- fix, inject_implicit_gap_edges injected a synthetic "in" edge
    -- for that spanning gap; compute_ripple_point returned the gap's
    -- sequence_start = 0, collapsing earliest_ripple_time to 0 and
    -- sweeping the entire timeline into the GLOBAL shift block.
    -- Result: every clip on every other track (including A2.Upstream
    -- at frame 30) would shift +50 (Joe's "long stereo mix moves
    -- with a V4 trim" bug). A3.LateClip should still ripple +50
    -- because it IS downstream of the boundary.
    before = [[
        V1: [A 100-400][B 400-600]
        A2: [Upstream 30-90]
        A3: [LateClip 1500-2000]
    ]],
    drag = "A in -50",
    after = [[
        V1: [A 100-450][B 450-650]
        A2: [Upstream 30-90]
        A3: [LateClip 1550-2050]
    ]],
},

{
    name = "in-edge extend V1: A1 clip at the boundary ripples too",
    -- A's in-edge dragged upstream by 50. Everything at-or-past the OLD
    -- in-edge boundary (frame 100) on ripple tracks shifts +50. That
    -- includes A1.C which starts exactly at the boundary — the existing
    -- ripple-boundary code computed the boundary as the clip's OUT edge
    -- regardless of edge_type, which excluded boundary-coincident clips
    -- from the shift (Joe's V4-extends-but-V1-clip-doesn't-ripple bug).
    --
    -- A2.LongMix SPANS the boundary (starts at 0, ends at 700) — this
    -- is the long stereo-mix pattern in real projects. Its timeline
    -- start is upstream of the boundary, so the ripple shift must NOT
    -- move it. Without this case the test would pass even if the impl
    -- erroneously dragged the spanning clip along with the shift.
    before = [[
        V1: [A 100-400][B 400-600]
        A1: [C 100-400][D 400-600]
        A2: [LongMix 0-700]
    ]],
    drag = "A in -50",
    after = [[
        V1: [A 100-450][B 450-650]
        A1: [C 150-450][D 450-650]
        A2: [LongMix 0-700]
    ]],
},

-- ─────────────────────────────────────────────────────────────────────────────
-- BOUNDARY ADJACENCY: adjacent clips block the operation
-- ─────────────────────────────────────────────────────────────────────────────

{
    name = "boundary adjacency: co-located audio co-trims (Co ripple)",
    -- 015 'ripple' semantics: A and C are co-located (same start 0, same end 500).
    -- When V1.A's out-edge shrinks by -100, A1.C (co-located) is co-trimmed too.
    -- Both A and C become 0-400; downstream B and D shift left to 400.
    before = [[
        V1: [A 0-500][B 500-800]
        A1: [C 0-500][D 500-800]
    ]],
    drag = "A out -100",
    after = [[
        V1: [A 0-400][B 400-700]
        A1: [C 0-400][D 400-700]
    ]],
},

-- ─────────────────────────────────────────────────────────────────────────────
-- UPSTREAM CLIPS ON UNSELECTED TRACKS: must NOT shift
-- ─────────────────────────────────────────────────────────────────────────────

{
    name = "unselected track: upstream audio clip stays put",
    -- C ends at 200, well before A's right edge (400). Must not move.
    -- D starts at 600, past A's right edge. Must shift.
    before = [[
        V1: [A 0-400][B 400-700]
        A1: [C 0-200][D 600-800]
    ]],
    drag = "A out -50",
    after = [[
        V1: [A 0-350][B 350-650]
        A1: [C 0-200][D 550-750]
    ]],
},

-- ─────────────────────────────────────────────────────────────────────────────
-- GAP EDGES: closing a gap shifts all tracks
-- ─────────────────────────────────────────────────────────────────────────────

{
    name = "gap_before on V1: audio clips shift too",
    before = [[
        V1: [A 0-200][B 500-700]
        A1: [C 0-200][D 500-700]
    ]],
    drag = "B gap_before -200",
    after = [[
        V1: [A 0-200][B 300-500]
        A1: [C 0-200][D 300-500]
    ]],
},

-- ─────────────────────────────────────────────────────────────────────────────
-- STAGGERED / REALISTIC LAYOUTS: clips at different positions across tracks
-- ─────────────────────────────────────────────────────────────────────────────

{
    name = "staggered: V2 clip spans V1 edit boundary — stays put",
    -- V2 clip starts before and ends after V1's edit point.
    -- It starts BEFORE the boundary, so it must NOT shift (no splits).
    before = [[
        V1: [A 0-200][B 200-500][C 500-700]
        V2: [D 100-600]
    ]],
    drag = "B out -50",
    after = [[
        V1: [A 0-200][B 200-450][C 450-650]
        V2: [D 100-600]
    ]],
},

{
    name = "staggered: V2 clip starts after boundary — shifts",
    -- V2 clip starts past B's right edge — must shift.
    before = [[
        V1: [A 0-200][B 200-500][C 500-700]
        V2: [D 550-750]
    ]],
    drag = "B out -50",
    after = [[
        V1: [A 0-200][B 200-450][C 450-650]
        V2: [D 500-700]
    ]],
},

{
    name = "staggered: audio spans V1 gap, starts before boundary",
    -- A1 clip spans from 0 to 800, covering V1's gap between B and C.
    -- Starts at 0 which is before B's right edge (400). Must NOT shift.
    before = [[
        V1: [A 0-200][B 200-400][C 600-800]
        A1: [D 0-800]
    ]],
    drag = "B out -50",
    after = [[
        V1: [A 0-200][B 200-350][C 550-750]
        A1: [D 0-800]
    ]],
},

{
    name = "staggered: multiple tracks with different gap patterns",
    -- Realistic layout inspired by image 6:
    -- V1 has clips with a gap, V2 has a clip offset differently,
    -- A1 has two clips with a gap, A2 has one clip spanning midrange
    before = [[
        V1: [Sm 0-50][C285 50-250][C284v 350-550]
        V2: [Over 100-400]
        A1: [Au1 0-350][Au2 550-750]
        A2: [Au3 200-500]
    ]],
    drag = "C284v in 40",
    -- C284v shrinks head: 350-510. Right edge was 550, now 510.
    -- Downstream of 550: Au2 at 550 shifts left 40 to 510.
    -- Over at 100 (before 550): stays. Au3 at 200 (before 550): stays.
    -- Sm, C285: upstream, stay. Au1 at 0: stays.
    after = [[
        V1: [Sm 0-50][C285 50-250][C284v 350-510]
        V2: [Over 100-400]
        A1: [Au1 0-350][Au2 510-710]
        A2: [Au3 200-500]
    ]],
},

{
    name = "staggered: out-edge shrink with gap, clip on A2 starts at boundary",
    -- C284v out edge at 550. Au3 starts at 550 exactly — must shift.
    -- Au1 ends at 400 (before 550) — stays.
    -- Over on V2 starts at 100 — stays.
    before = [[
        V1: [Sm 0-50][C285 50-250][C284v 350-550]
        V2: [Over 100-400]
        A1: [Au1 0-400]
        A2: [Au3 550-750]
    ]],
    drag = "C284v out -60",
    after = [[
        V1: [Sm 0-50][C285 50-250][C284v 350-490]
        V2: [Over 100-400]
        A1: [Au1 0-400]
        A2: [Au3 490-690]
    ]],
},

{
    name = "staggered: clip on V2 ends exactly at boundary — not downstream, stays",
    -- V2 clip ends at 500 = A's right edge. Its START is 300 < 500. Must NOT shift.
    before = [[
        V1: [A 0-500][B 500-700]
        V2: [C 300-500]
    ]],
    drag = "A out -80",
    after = [[
        V1: [A 0-420][B 420-620]
        V2: [C 300-500]
    ]],
},

{
    name = "staggered: realistic 5-track layout, out-edge shrink",
    -- Mirrors image 6 structure approximately:
    -- V2 has clip overlapping V1 region, A1 has gap, A2 offset, A3 early
    before = [[
        V1: [Sm 0-30][C285 30-200][C284a 250-420][C284b 420-550]
        V2: [VOver 80-320]
        A1: [Aud1 0-380][Aud2 420-650]
        A2: [Aud3 250-500]
        A3: [Aud4 0-380]
    ]],
    drag = "C284a out -40",
    -- C284a shrinks: 250-380. Right edge was 420, now 380.
    -- Downstream of 420: C284b at 420 shifts to 380. Aud2 at 420 shifts to 380.
    -- VOver at 80 (before 420): stays. Aud3 at 250 (before 420): stays.
    -- Aud4 at 0 (before 420): stays. Aud1 at 0 (before 420): stays.
    -- Sm, C285: before 420, stay.
    after = [[
        V1: [Sm 0-30][C285 30-200][C284a 250-380][C284b 380-510]
        V2: [VOver 80-320]
        A1: [Aud1 0-380][Aud2 380-610]
        A2: [Aud3 250-500]
        A3: [Aud4 0-380]
    ]],
},

-- ─────────────────────────────────────────────────────────────────────────────
-- GAP AT BOUNDARY: audio has gap at the edit position (images 7-8 scenario)
-- ─────────────────────────────────────────────────────────────────────────────

{
    name = "in-edge with gap on A1 at edit boundary: downstream audio shifts",
    -- V1: [Sm 0-50][C285 50-250] gap [C284 350-600][Tail 600-800]
    -- A1: [Au1 0-400] gap(400-500) [Au2 500-800]
    -- Drag: C284 in +40 (shrink head)
    -- C284 right edge = 600. Au2 starts at 500 (< 600). Tail at 600 (= right edge).
    -- Au2 should shift left by 40 to 460. Tail to 560.
    -- Au1 stays (ends at 400, before 600). Sm, C285 stay.
    before = [[
        V1: [Sm 0-50][C285 50-250][C284 350-600][Tail 600-800]
        A1: [Au1 0-400][Au2 500-800]
    ]],
    drag = "C284 in 40",
    after = [[
        V1: [Sm 0-50][C285 50-250][C284 350-560][Tail 560-760]
        A1: [Au1 0-400][Au2 460-760]
    ]],
},

{
    name = "out-edge with gap on A1: downstream audio past gap shifts",
    -- V1: [A 0-300][B 300-500]
    -- A1: [C 0-200] gap(200-500) [D 500-700]
    -- Drag: A out -50
    -- A right edge = 300. D starts at 500 (> 300, downstream). D should shift to 450.
    -- C stays (0-200, before 300). B shifts to 250.
    before = [[
        V1: [A 0-300][B 300-500]
        A1: [C 0-200][D 500-700]
    ]],
    drag = "A out -50",
    after = [[
        V1: [A 0-250][B 250-450]
        A1: [C 0-200][D 450-650]
    ]],
},

{
    name = "split then in-extend: audio shifts right (images 9-11)",
    -- Simplest case: single clip split in half, all tracks aligned.
    -- Drag B's in edge LEFT to extend. Audio B must shift RIGHT.
    before = [[
        V1: [A 0-24][B 24-53]
        A1: [C 0-24][D 24-53]
        A2: [E 0-24][F 24-53]
    ]],
    drag = "B in -6",
    after = [[
        V1: [A 0-24][B 24-59]
        A1: [C 0-24][D 30-59]
        A2: [E 0-24][F 30-59]
    ]],
},

-- ─────────────────────────────────────────────────────────────────────────────
-- ASYMMETRIC TRIM: different edges on different tracks, same drag
-- ─────────────────────────────────────────────────────────────────────────────

{
    name = "asymmetric: V1 out + A1 in — J-cut, positive delta",
    -- V1 "out" +50: A extends tail to 350. V1 downstream shifts RIGHT +50.
    -- A1 "in" negated → applied -50: C extends head to 550. A1 downstream shifts LEFT -50.
    -- Tracks shift in opposite directions — classic J/L-cut.
    before = [[
        V1: [A 0-300][B 300-500]
        A1: [C 200-500][D 500-700]
    ]],
    drag = "A out 50, C in 50",
    after = [[
        V1: [A 0-350][B 350-550]
        A1: [C 200-550][D 450-650]
    ]],
},

{
    name = "asymmetric: V1 out + A1 in — negative delta",
    -- V1 "out" -40: A shrinks tail to 260. V1 downstream shifts LEFT -40.
    -- A1 "in" negated → applied +40: C shrinks head to 260. A1 downstream shifts RIGHT +40.
    -- Opposite shifts.
    before = [[
        V1: [A 0-300][B 300-500]
        A1: [C 200-500][D 500-700]
    ]],
    drag = "A out -40, C in -40",
    after = [[
        V1: [A 0-260][B 260-460]
        A1: [C 200-460][D 540-740]
    ]],
},

{
    name = "asymmetric: V1 out + A1 out at different positions",
    -- Both out edges, same delta, but clips end at different times.
    -- V1 edge at 400, A1 edge at 300. Per-track ripple points differ.
    before = [[
        V1: [A 0-400][B 400-600]
        A1: [C 0-300][D 300-600]
    ]],
    drag = "A out -50, C out -50",
    -- A: 0-350. B shifts to 350.
    -- C: 0-250. D shifts to 250.
    after = [[
        V1: [A 0-350][B 350-550]
        A1: [C 0-250][D 250-550]
    ]],
},

-- ─────────────────────────────────────────────────────────────────────────────
-- SINGLE-TRACK BASICS: verify core ripple on one track still works
-- ─────────────────────────────────────────────────────────────────────────────

{
    name = "single track out-edge shrink: downstream shifts left",
    before = [[
        V1: [A 0-300][B 300-600][C 600-900]
    ]],
    drag = "A out -80",
    after = [[
        V1: [A 0-220][B 220-520][C 520-820]
    ]],
},

{
    name = "single track in-edge shrink: downstream shifts left",
    before = [[
        V1: [A 0-200][B 200-500][C 500-700]
    ]],
    drag = "B in 60",
    after = [[
        V1: [A 0-200][B 200-440][C 440-640]
    ]],
},

{
    name = "single track out-edge extend: downstream shifts right",
    before = [[
        V1: [A 0-300][B 300-500]
    ]],
    drag = "A out 100",
    after = [[
        V1: [A 0-400][B 400-600]
    ]],
},

{
    name = "single track in-edge extend: downstream shifts right",
    before = [[
        V1: [A 100-400][B 400-600]
    ]],
    drag = "A in -80",
    after = [[
        V1: [A 100-480][B 480-680]
    ]],
},

-- ─────────────────────────────────────────────────────────────────────────────
-- UNDO: restore after multitrack ripple
-- ─────────────────────────────────────────────────────────────────────────────
-- (Undo tested separately below since it needs special handling)

}

-- Run all declarative tests
local passed, failed = runner.run_all(tests)

-- ─────────────────────────────────────────────────────────────────────────────
-- UNDO TEST (procedural — needs undo call)
-- ─────────────────────────────────────────────────────────────────────────────
do
    local command_manager = require("core.command_manager")
    local Clip = require("models.clip")
    local ripple_layout = require("synthetic.helpers.ripple_layout")

    local layout = ripple_layout.create({
        db_path = "/tmp/jve/ripple_dsl_undo.db",
        tracks = {
            order = {"v1", "a1"},
            v1 = {id = "track_v1", name = "V1", track_type = "VIDEO", track_index = 1, enabled = 1},
            a1 = {id = "track_a1", name = "A1", track_type = "AUDIO", track_index = 2, enabled = 1},
        },
        clips = {
            order = {"v1_a", "v1_b", "a1_c", "a1_d"},
            v1_a = {id = "clip_A", name = "A", track_key = "v1", media_key = "main",
                     sequence_start = 0, duration = 300, source_in = 0},
            v1_b = {id = "clip_B", name = "B", track_key = "v1", media_key = "main",
                     sequence_start = 300, duration = 200, source_in = 400},
            a1_c = {id = "clip_C", name = "C", track_key = "a1", media_key = "main",
                     sequence_start = 0, duration = 300, source_in = 0},
            a1_d = {id = "clip_D", name = "D", track_key = "a1", media_key = "main",
                     sequence_start = 300, duration = 200, source_in = 400},
        },
    })

    local result = command_manager.execute("BatchRippleEdit", {
        project_id = layout.project_id,
        sequence_id = layout.sequence_id,
        edge_infos = {
            {clip_id = "clip_A", edge_type = "out", trim_type = "ripple", track_id = "track_v1"},
            {clip_id = "clip_C", edge_type = "out", trim_type = "ripple", track_id = "track_a1"},
        },
        delta_frames = -50,
    })
    assert(result.success, "undo test execute: " .. tostring(result.error_message))

    -- Verify change happened
    local b = Clip.load("clip_B")
    assert(b.sequence_start == 250, "undo test: B should be at 250 after trim")

    -- Undo
    local undo_result = command_manager.undo()
    assert(undo_result.success, "undo test: " .. tostring(undo_result.error_message))

    -- All clips restored
    local function check(id, exp_start, exp_dur)
        local c = Clip.load(id)
        assert(c.sequence_start == exp_start and c.duration == exp_dur,
            string.format("undo: %s expected %d-%d, got %d-%d",
                id, exp_start, exp_start + exp_dur, c.sequence_start, c.sequence_start + c.duration))
    end
    check("clip_A", 0, 300)
    check("clip_B", 300, 200)
    check("clip_C", 0, 300)
    check("clip_D", 300, 200)

    layout:cleanup()
    passed = passed + 1
    print("  undo restores all clips — passed")
end

print(string.format("\n=== %d passed, %d failed ===", passed, failed))
if failed > 0 then
    error(string.format("%d test(s) failed", failed))
end
print("✅ test_ripple_in_multitrack_upstream_stable.lua passed")
