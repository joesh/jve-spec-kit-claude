--- Domain rule: when a multi-clip selection is dragged to a different track,
-- every selected clip moves to the target track. The operation preserves
-- each clip's duration and its timeline position (delta_frames = 0 when
-- the drag doesn't shift horizontally, delta_frames = N when it does).
--
-- Replaces: tests/synthetic/lua/test_drag_multi_clip_cross_track_integration.lua
-- (that test built the DB by hand, faked view.get_track_id_at_y, and called
-- handle_release directly — this version drives the real gesture pipeline).

local env = require("synthetic.integration.timeline_render.render_env")

print("=== test_drag_multi_clip_cross_track ===")

env.boot()
local state = env.context().state
local widget = env.video_widget()

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

-- ── Scenario A: two V1 clips dragged to V2, same horizontal position ─────────
-- V1: clip_a [0,100) + clip_b [200,80).
-- V2: anchor clip [450,50) so we can find V2's band y-coordinate.
-- Drag: grab clip_a's centre (frame 50) and release at the same x on V2's band.
-- delta_frames = 0 → clips move track only; positions unchanged.
print("  A: two clips cross-track drag (delta=0); both land on V2 at original positions")
do
    local seq = env.fresh_sequence("CrossTrack A")
    local tracks = env.tracks()
    assert(tracks.V1 and tracks.V2, "need V1 and V2")

    env.place_clips(seq, {
        { track_id = tracks.V1.id, position = 0,   duration = 100 },
        { track_id = tracks.V1.id, position = 200, duration = 80  },
        { track_id = tracks.V2.id, position = 450, duration = 50  }, -- band anchor
    })
    env.view_frames(600, 0)

    local tab = state.get_tab_strip()
    local v1_clips = tab:track_clip_index(tracks.V1.id)
    local clip_a, clip_b = nil, nil
    for _, c in ipairs(v1_clips) do
        if not c.is_gap then
            if c.sequence_start == 0   then clip_a = c end
            if c.sequence_start == 200 then clip_b = c end
        end
    end
    assert(clip_a, "A: clip_a not found at frame 0")
    assert(clip_b, "A: clip_b not found at frame 200")

    local v1_band = find_band(0, 100)
    local v2_band = find_band(450, 500)
    local v1_mid_y = v1_band.y + v1_band.height / 2
    local v2_mid_y = v2_band.y + v2_band.height / 2

    local h = env.mouse_handler(widget)
    local cx_a = env.x_of(50)   -- centre of clip_a
    local cx_b = env.x_of(240)  -- centre of clip_b

    -- Click clip_a to select; shift-click clip_b to extend selection.
    h({ type = "press",   x = cx_a, y = v1_mid_y, button = 1,
        shift = false, alt = false, ctrl = false, command = false })
    h({ type = "release", x = cx_a, y = v1_mid_y, button = 1,
        shift = false, alt = false, ctrl = false, command = false })
    env.pump(50)
    h({ type = "press",   x = cx_b, y = v1_mid_y, button = 1,
        shift = true, alt = false, ctrl = false, command = false })
    h({ type = "release", x = cx_b, y = v1_mid_y, button = 1,
        shift = true, alt = false, ctrl = false, command = false })
    env.pump(50)

    -- Confirm both real clips are selected (ignore any gap selection).
    local sel = state.get_selected_clips()
    local sel_a, sel_b = false, false
    for _, c in ipairs(sel) do
        if c.id == clip_a.id then sel_a = true end
        if c.id == clip_b.id then sel_b = true end
    end
    assert(sel_a, "A: clip_a not selected")
    assert(sel_b, "A: clip_b not selected after shift-click")

    -- Drag: press on clip_a's centre on V1, cross the threshold, release on V2
    -- at the same horizontal x (delta_frames = 0 — only track changes).
    h({ type = "press", x = cx_a, y = v1_mid_y, button = 1,
        shift = false, alt = false, ctrl = false, command = false })
    h({ type = "move",  x = cx_a + 6, y = v1_mid_y, button = 1,
        shift = false, alt = false, ctrl = false, command = false })
    h({ type = "move",  x = cx_a, y = v2_mid_y, button = 1,
        shift = false, alt = false, ctrl = false, command = false })
    env.pump(120)
    h({ type = "release", x = cx_a, y = v2_mid_y, button = 1,
        shift = false, alt = false, ctrl = false, command = false })
    env.pump(250)

    -- V1 must be empty of clip_a and clip_b.
    local tab2 = state.get_tab_strip()
    local v1_after = tab2:track_clip_index(tracks.V1.id)
    local v2_after = tab2:track_clip_index(tracks.V2.id)

    local found_a_on_v1, found_b_on_v1 = false, false
    for _, c in ipairs(v1_after) do
        if not c.is_gap then
            if c.id == clip_a.id then found_a_on_v1 = true end
            if c.id == clip_b.id then found_b_on_v1 = true end
        end
    end
    assert(not found_a_on_v1, "A: clip_a must leave V1 after cross-track drag")
    assert(not found_b_on_v1, "A: clip_b must leave V1 after cross-track drag")

    -- V2 must contain both clips at their original positions (delta=0).
    local clip_a_on_v2, clip_b_on_v2 = nil, nil
    for _, c in ipairs(v2_after) do
        if not c.is_gap then
            if c.id == clip_a.id then clip_a_on_v2 = c end
            if c.id == clip_b.id then clip_b_on_v2 = c end
        end
    end
    assert(clip_a_on_v2, "A: clip_a must be on V2 after cross-track drag")
    assert(clip_b_on_v2, "A: clip_b must be on V2 after cross-track drag")

    -- Positions unchanged (delta_frames=0 → same sequence_start).
    assert(clip_a_on_v2.sequence_start == 0, string.format(
        "A: clip_a must stay at frame 0 (no horizontal delta); got %d",
        clip_a_on_v2.sequence_start))
    assert(clip_b_on_v2.sequence_start == 200, string.format(
        "A: clip_b must stay at frame 200 (no horizontal delta); got %d",
        clip_b_on_v2.sequence_start))

    -- Durations unchanged.
    assert(clip_a_on_v2.duration == 100, string.format(
        "A: clip_a duration must be unchanged (100); got %d", clip_a_on_v2.duration))
    assert(clip_b_on_v2.duration == 80, string.format(
        "A: clip_b duration must be unchanged (80); got %d", clip_b_on_v2.duration))

    print("    OK")
end

-- ── Scenario B: cross-track drag with horizontal delta ───────────────────────
-- V1: clip_c [0,100). Drag to V2 while also shifting right 150 frames.
-- Grab at centre (frame 50), release at frame 200 on V2.
-- clip_c lands on V2 at position 0 + (200 - 50) = 150.
print("  B: cross-track drag with horizontal delta shifts position AND changes track")
do
    local seq = env.fresh_sequence("CrossTrack B")
    local tracks = env.tracks()
    assert(tracks.V1 and tracks.V2, "need V1 and V2")

    -- Need V2 anchor to find its band.
    env.place_clips(seq, {
        { track_id = tracks.V1.id, position = 0,   duration = 100 },
        { track_id = tracks.V2.id, position = 400, duration = 50  },
    })
    env.view_frames(600, 0)

    local tab = state.get_tab_strip()
    local v1_clips = tab:track_clip_index(tracks.V1.id)
    local clip_c = nil
    for _, c in ipairs(v1_clips) do
        if not c.is_gap and c.sequence_start == 0 then clip_c = c; break end
    end
    assert(clip_c, "B: clip_c not found at frame 0")

    local v1_band = find_band(0, 100)
    local v2_band = find_band(400, 450)
    local v1_mid_y = v1_band.y + v1_band.height / 2
    local v2_mid_y = v2_band.y + v2_band.height / 2

    local h = env.mouse_handler(widget)
    local press_x  = env.x_of(50)   -- centre of clip_c (grab offset = 50 frames from in-edge)
    local target_x = env.x_of(200)  -- release at frame 200

    -- Click to select.
    h({ type = "press",   x = press_x, y = v1_mid_y, button = 1,
        shift = false, alt = false, ctrl = false, command = false })
    h({ type = "release", x = press_x, y = v1_mid_y, button = 1,
        shift = false, alt = false, ctrl = false, command = false })
    env.pump(50)

    -- Drag to V2 band at target_x.
    h({ type = "press", x = press_x, y = v1_mid_y, button = 1,
        shift = false, alt = false, ctrl = false, command = false })
    h({ type = "move",  x = press_x + 6, y = v1_mid_y, button = 1,
        shift = false, alt = false, ctrl = false, command = false })
    h({ type = "move",  x = target_x, y = v2_mid_y, button = 1,
        shift = false, alt = false, ctrl = false, command = false })
    env.pump(120)
    h({ type = "release", x = target_x, y = v2_mid_y, button = 1,
        shift = false, alt = false, ctrl = false, command = false })
    env.pump(250)

    -- Domain: delta = 200 - 50 = 150 frames; clip_c in-edge = 0 + 150 = 150.
    local expected_delta = 200 - 50   -- 150
    local expected_start = 0 + expected_delta  -- 150

    local tab2 = state.get_tab_strip()
    local v2_after = tab2:track_clip_index(tracks.V2.id)
    local clip_c_on_v2 = nil
    for _, c in ipairs(v2_after) do
        if not c.is_gap and c.id == clip_c.id then clip_c_on_v2 = c; break end
    end
    assert(clip_c_on_v2, "B: clip_c not found on V2 after cross-track+horizontal drag")

    assert(math.abs(clip_c_on_v2.sequence_start - expected_start) <= 2, string.format(
        "B: clip_c must land at frame ~%d (original 0 + delta %d); got %d",
        expected_start, expected_delta, clip_c_on_v2.sequence_start))
    assert(clip_c_on_v2.duration == 100, string.format(
        "B: clip_c duration must be unchanged (100); got %d", clip_c_on_v2.duration))

    -- Must be gone from V1.
    local v1_after = tab2:track_clip_index(tracks.V1.id)
    local still_on_v1 = false
    for _, c in ipairs(v1_after) do
        if not c.is_gap and c.id == clip_c.id then still_on_v1 = true; break end
    end
    assert(not still_on_v1, "B: clip_c must leave V1 after cross-track drag")

    print("    OK")
end

print("✅ test_drag_multi_clip_cross_track.lua passed")
