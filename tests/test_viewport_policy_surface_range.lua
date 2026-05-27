require('test_env')

-- Surface-range viewport scroll: given a time range to reveal and the
-- current playhead, decide the new viewport start. Rules (Joe 2026-04-17):
--   1. If the union of the range and the playhead fits in the viewport,
--      center that union's midpoint.
--   2. If only the range fits but the playhead doesn't (or the range is
--      wider than the viewport), put the upstream edge of the range at
--      the left side of the viewport with a bit of padding.
-- Pure behavior — no DB, no UI rendering. Uses viewport_state directly.

-- Pre-require timeline_state so its module-load strip_holder.set runs
-- BEFORE our stub install (spec 022 Phase 1.3f: viewport_state pulls
-- content_length from displayed.cache via strip_holder).
require("ui.timeline.timeline_state")
local viewport_state = require("ui.timeline.state.viewport_state")
local data = require("ui.timeline.state.timeline_state_data")
local strip_holder = require("ui.timeline.state.strip_holder")

local function reset(viewport_start, viewport_duration, playhead, content_end)
    -- Stub the displayed tab so compute_sequence_content_length sees the
    -- desired extent — the viewport can scroll freely up to content_end.
    strip_holder.set({
        get_displayed = function()
            return { sequence_id = "test_seq",
                     cache = { content_length = content_end } }
        end,
    })
    data.state.playhead_position = playhead
    data.state.viewport_start_time = viewport_start
    data.state.viewport_duration = viewport_duration
    data.state.sequence_timecode_start_frame = 0
    data.state.is_playing = false
    data.state.sequence_frame_rate = { fps_numerator = 25, fps_denominator = 1 }
end

local function vp_start()
    return data.state.viewport_start_time
end

print("=== viewport_state.surface_range ===")

-- -----------------------------------------------------------------------
-- 1. Range + playhead both already visible → no scroll.
-- Viewport [0, 1000], range [200, 400], playhead at 500 — all in view.
-- -----------------------------------------------------------------------
do
    reset(0, 1000, 500, 10000)
    viewport_state.surface_range(200, 400)
    assert(vp_start() == 0, string.format("already-visible range must not scroll (got %d)", vp_start()))
    print("  1. range + playhead visible → no scroll ✓")
end

-- -----------------------------------------------------------------------
-- 2. Range fits and playhead fits, union fits too → center on union.
-- Viewport duration 1000; range [5000, 5400] (width 400); playhead 5200.
-- Union [5000, 5400] width 400 << 1000 → fits. Midpoint = 5200.
-- Centered → viewport_start = 5200 - 500 = 4700.
-- -----------------------------------------------------------------------
do
    reset(0, 1000, 5200, 10000)
    viewport_state.surface_range(5000, 5400)
    assert(vp_start() == 4700,
        string.format("center-on-union midpoint: expected 4700, got %d", vp_start()))
    print("  2. range + playhead both fit → centered on union ✓")
end

-- -----------------------------------------------------------------------
-- 3. Range fits but playhead far away → upstream-edge-left with padding.
-- Viewport duration 1000; range [5000, 5400]; playhead 200 (far left).
-- Union [200, 5400] width 5200 >> 1000 → doesn't fit. Region wins:
-- range.start=5000 at viewport.start + padding. Padding = 5% of 1000 = 50.
-- viewport_start = 5000 - 50 = 4950.
-- -----------------------------------------------------------------------
do
    reset(0, 1000, 200, 10000)
    viewport_state.surface_range(5000, 5400)
    assert(vp_start() == 4950,
        string.format("upstream-edge-left + 5%% padding: expected 4950, got %d", vp_start()))
    print("  3. range fits, playhead far → upstream edge at viewport.start + padding ✓")
end

-- -----------------------------------------------------------------------
-- 4. Range wider than viewport → upstream-edge-left with padding.
-- Viewport duration 500; range [2000, 5000] width 3000 > 500. Upstream
-- edge at viewport.start + padding (5% of 500 = 25).
-- viewport_start = 2000 - 25 = 1975.
-- -----------------------------------------------------------------------
do
    reset(0, 500, 100, 10000)
    viewport_state.surface_range(2000, 5000)
    assert(vp_start() == 1975,
        string.format("range wider than viewport: expected 1975, got %d", vp_start()))
    print("  4. range wider than viewport → upstream edge + padding ✓")
end

-- -----------------------------------------------------------------------
-- 5. Upstream-edge-left clamped to content floor (sequence_timecode_start).
-- Viewport duration 1000; range [0, 200]; playhead 8000 (far).
-- Would want viewport_start = -50 (0 - 50 padding), clamped to 0.
-- -----------------------------------------------------------------------
do
    reset(5000, 1000, 8000, 10000)
    viewport_state.surface_range(0, 200)
    assert(vp_start() == 0,
        string.format("upstream-edge-left clamped to floor: expected 0, got %d", vp_start()))
    print("  5. upstream-edge clamped to content floor ✓")
end

print("\n✅ test_viewport_policy_surface_range.lua passed")
