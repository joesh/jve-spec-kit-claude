--- Domain rule: double-clicking a timeline clip loads it into the source
-- viewer in live-bound mode (spec 019 FR-026). Two reject paths produce
-- no-ops: empty timeline space (FR-027) and gap-as-clip rows (FR-027).
--
-- Observable: source_viewer.get_live_clip_id() returns the clicked clip's
-- id after a successful double-click; it is unchanged after a reject-path
-- double-click.
--
-- Replaces: tests/synthetic/lua/test_timeline_double_click_dispatches_open_clip.lua
-- (that test stubbed command_manager.execute_interactive and view.hit_test_clip;
-- this version fires a real double_click event through the registered mouse
-- handler and reads the real source_viewer state).

local env = require("synthetic.integration.timeline_render.render_env")

print("=== test_double_click_opens_clip ===")

env.boot()
local state   = env.context().state
local widget  = env.video_widget()
local sv      = require("ui.source_viewer")

local function find_band(left_frame, right_frame)
    local lx = env.x_of(left_frame)
    local rx = env.x_of(right_frame)
    for _, r in ipairs(env.rects(widget)) do
        if r.height > 10
            and math.abs(r.x - lx) < 10
            and math.abs((r.x + r.width) - rx) < 10 then
            return r
        end
    end
    error(string.format(
        "band rect not found for frames [%d,%d] (lx=%.1f rx=%.1f) in %d cmds",
        left_frame, right_frame, lx, rx, #env.draw_commands(widget)))
end

-- ── Scenario A: double-click on a real clip → source viewer loads it ─────────
print("  A: double-click on timeline clip → source_viewer enters live_bound_clip mode")
do
    -- Reset source_viewer to a clean state so the pre-condition is clear.
    sv._reset_for_tests()
    assert(sv.get_live_clip_id() == nil,
        "A: source_viewer must be unloaded before test")

    local seq = env.fresh_sequence("DblClick A")
    local tracks = env.tracks()
    assert(tracks.V1, "need V1")

    -- Place clip at [73,273) — non-trivial offset, centre at frame 173.
    env.place_clips(seq, {
        { track_id = tracks.V1.id, position = 73, duration = 200 },
    })
    env.view_frames(500, 0)

    local tab = state.get_tab_strip()
    local v1_clips = tab:track_clip_index(tracks.V1.id)
    local clip = nil
    for _, c in ipairs(v1_clips) do
        if not c.is_gap and c.sequence_start == 73 then clip = c; break end
    end
    assert(clip, "A: clip not found at frame 73")

    -- Locate the clip body band in the draw-command queue.
    local band = find_band(73, 273)
    local mid_y  = band.y + band.height / 2
    local center_x = env.x_of(173)  -- centre of clip in pixel space

    -- Fire double_click through the real registered mouse-handler global.
    local h = env.mouse_handler(widget)
    h({ type = "double_click", x = center_x, y = mid_y, button = 1,
        shift = false, alt = false, ctrl = false, command = false })
    env.pump(200)

    -- Observable: source viewer is now in live-bound mode with this clip.
    assert(sv.get_mode() == "live_bound_clip", string.format(
        "A: source_viewer must be in live_bound_clip mode after double-click; got %q",
        tostring(sv.get_mode())))
    assert(sv.get_live_clip_id() == clip.id, string.format(
        "A: source_viewer must hold the double-clicked clip id (%s); got %s",
        tostring(clip.id):sub(1, 8), tostring(sv.get_live_clip_id()):sub(1, 8)))

    print("    OK")
end

-- ── Scenario B: double-click on empty timeline space → no-op ─────────────────
-- Fresh sequence. Double-click well before the only clip — empty timeline
-- space. source_viewer must stay in neutral/unchanged mode.
--
-- Note: each double-click on a real clip auto-switches the timeline's
-- displayed tab to the SOURCE tab (the master sequence). Scenario B uses a
-- fresh sequence opened after scenario A so the record tab is displayed
-- again, ensuring env.x_of() maps against the right viewport.
print("  B: double-click on empty space → source_viewer mode unchanged")
do
    -- Open a new record sequence so the displayed tab is the record tab
    -- (not the source tab left from scenario A).
    local seq_b = env.fresh_sequence("DblClick B")
    local tracks_b = env.tracks()
    assert(tracks_b.V1, "need V1")

    -- Single clip at [200,300) — frame 50 is empty space to the left.
    env.place_clips(seq_b, {
        { track_id = tracks_b.V1.id, position = 200, duration = 100 },
    })
    env.view_frames(500, 0)

    -- Capture current mode BEFORE the empty-space double-click.
    local mode_before = sv.get_mode()
    local clip_id_before = sv.get_live_clip_id()

    -- Locate the clip band to get a valid mid_y (same track row as the empty space).
    local band_b = find_band(200, 300)
    local mid_y_b = band_b.y + band_b.height / 2

    -- Double-click at frame 50 — before the clip in-edge at 200 → empty space.
    local h = env.mouse_handler(widget)
    h({ type = "double_click", x = env.x_of(50), y = mid_y_b, button = 1,
        shift = false, alt = false, ctrl = false, command = false })
    env.pump(150)

    -- source_viewer must not have changed: mode and live_clip_id unchanged.
    assert(sv.get_mode() == mode_before, string.format(
        "B: double-click on empty space must not change source_viewer mode; "
        .. "before=%q after=%q", tostring(mode_before), tostring(sv.get_mode())))
    assert(sv.get_live_clip_id() == clip_id_before, string.format(
        "B: double-click on empty space must not change live_clip_id; "
        .. "before=%s after=%s",
        tostring(clip_id_before), tostring(sv.get_live_clip_id())))

    print("    OK")
end

-- ── Scenario C: second double-click on a different clip replaces the load ─────
-- Two clips on V1. Double-click the first → source_viewer loads it. Then
-- double-click the second → source_viewer replaces with the second clip.
--
-- Important: after the first double-click the timeline switches its displayed
-- tab to the source tab (master sequence). To double-click the second clip,
-- we must deliver the event to the same physical widget at the pre-computed
-- pixel coordinates — captured BEFORE any double-click fires.
print("  C: double-click on a second clip replaces the source_viewer contents")
do
    sv._reset_for_tests()

    local seq_c = env.fresh_sequence("DblClick C")
    local tracks_c = env.tracks()
    assert(tracks_c.V1, "need V1")

    -- Two clips: clip_x at [0,120), clip_y at [200,100).
    env.place_clips(seq_c, {
        { track_id = tracks_c.V1.id, position = 0,   duration = 120 },
        { track_id = tracks_c.V1.id, position = 200, duration = 100 },
    })
    env.view_frames(500, 0)

    local tab_c = state.get_tab_strip()
    local v1_c = tab_c:track_clip_index(tracks_c.V1.id)
    local clip_x, clip_y = nil, nil
    for _, c in ipairs(v1_c) do
        if not c.is_gap then
            if c.sequence_start == 0   then clip_x = c end
            if c.sequence_start == 200 then clip_y = c end
        end
    end
    assert(clip_x, "C: clip_x not found at frame 0")
    assert(clip_y, "C: clip_y not found at frame 200")

    -- Pre-compute clip_x click coords before any double-click fires.
    -- clip_y coords are re-acquired after the first double-click switches
    -- the displayed tab to the source tab and we switch back.
    local band_x = find_band(0, 120)
    local mid_y_c = band_x.y + band_x.height / 2
    local cx_x = env.x_of(60)   -- centre of clip_x (frame 60)
    local cy_x = mid_y_c

    local h = env.mouse_handler(widget)

    -- Double-click clip_x.
    h({ type = "double_click", x = cx_x, y = cy_x, button = 1,
        shift = false, alt = false, ctrl = false, command = false })
    env.pump(200)
    assert(sv.get_live_clip_id() == clip_x.id, string.format(
        "C: first double-click must load clip_x (%s); got %s",
        tostring(clip_x.id):sub(1,8), tostring(sv.get_live_clip_id()):sub(1,8)))

    -- The first double-click switched the displayed tab to the source tab.
    -- Switch back to the record tab so the second double-click hit-tests
    -- against the record sequence layout (where clip_y lives at frame 200).
    state.switch_to_record_tab(seq_c)
    env.view_frames(500, 0)  -- restore the record viewport
    env.pump(100)

    -- Now re-locate clip_y's band (display is back on the record sequence).
    local band_y_after = find_band(200, 300)
    local cx_y_after = env.x_of(250)
    local cy_y_after = band_y_after.y + band_y_after.height / 2

    -- Double-click clip_y — must replace clip_x in the source viewer.
    h({ type = "double_click", x = cx_y_after, y = cy_y_after, button = 1,
        shift = false, alt = false, ctrl = false, command = false })
    env.pump(200)
    assert(sv.get_live_clip_id() == clip_y.id, string.format(
        "C: second double-click must replace source_viewer with clip_y (%s); got %s",
        tostring(clip_y.id):sub(1,8), tostring(sv.get_live_clip_id()):sub(1,8)))

    print("    OK")
end

print("✅ test_double_click_opens_clip.lua passed")
