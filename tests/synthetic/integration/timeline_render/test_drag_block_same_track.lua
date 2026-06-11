--- Domain rule: dragging a block of selected clips on the same track
-- by N frames moves every clip in the selection forward by exactly N frames
-- (grab offset preserved). Unselected clips on the same track are NOT
-- displaced. Scenarios keep the drop zone clear of other clips — what
-- SHOULD happen when a dragged clip lands on an existing one (overwrite
-- vs coexist) is an open policy question for Joe; this test deliberately
-- does not pin either answer.
--
-- Replaces: tests/synthetic/lua/test_drag_block_right_overlap_integration.lua
-- (that test built the DB by hand, called handle_release directly with a
-- fabricated drag_state, and asserted overlap/occlusion resolution — a
-- behavior the production code no longer has. This version drives a real
-- gesture end-to-end and pins only the uncontested move semantics.)

local env = require("synthetic.integration.timeline_render.render_env")

print("=== test_drag_block_same_track ===")

env.boot()
local state = env.context().state
local widget = env.video_widget()

-- Helper: locate a clip band by its [left_frame, right_frame) pixel span.
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

-- ── Scenario A: single selected clip nudged right by a whole-frame delta ────
-- V1: clip_a [47,197) — gap — clip_b [450,550) (unselected, well clear of
-- the drop zone). Drag clip_a right so its centre moves from frame 122 to
-- frame 250. The drag delta is 250 - 122 = 128 frames (grab offset
-- preserved). After commit: clip_a is [175,325), clip_b untouched at 450.
print("  A: single clip same-track drag moves by exact delta; unselected clip untouched")
do
    local seq = env.fresh_sequence("DragBlock A")
    local tracks = env.tracks()
    assert(tracks.V1, "need V1")

    env.place_clips(seq, {
        { track_id = tracks.V1.id, position = 47,  duration = 150 },
        { track_id = tracks.V1.id, position = 450, duration = 100 },
    })
    env.view_frames(600, 0)

    local tab = state.get_tab_strip()
    local v1_clips = tab:track_clip_index(tracks.V1.id)
    local clip_a, clip_b = nil, nil
    for _, c in ipairs(v1_clips) do
        if not c.is_gap then
            if c.sequence_start == 47  then clip_a = c end
            if c.sequence_start == 450 then clip_b = c end
        end
    end
    assert(clip_a, "A: clip_a not found at frame 47")
    assert(clip_b, "A: clip_b not found at frame 450")

    local band_a = find_band(47, 197)
    local mid_y = band_a.y + band_a.height / 2
    local h = env.mouse_handler(widget)

    -- Select clip_a with a plain click on its centre.
    local center_x = env.x_of(47 + 75)  -- centre at frame 122
    h({ type = "press",   x = center_x, y = mid_y, button = 1,
        shift = false, alt = false, ctrl = false, command = false })
    h({ type = "release", x = center_x, y = mid_y, button = 1,
        shift = false, alt = false, ctrl = false, command = false })
    env.pump(80)
    local sel = state.get_selected_clips()
    local is_sel = false
    for _, c in ipairs(sel) do if c.id == clip_a.id then is_sel = true; break end end
    assert(is_sel, "A: click did not select clip_a")

    -- Drag: press on centre (frame 122), threshold move, then move to frame 250.
    -- The grab offset is 75 frames from the clip's in-edge (frame 47).
    -- Release x corresponds to frame 250 → the clip in-edge lands at 250 - 75 = 175.
    -- Domain: Nudge amount = release_frame - press_frame = 250 - 122 = 128 frames.
    local target_x = env.x_of(250)
    h({ type = "press", x = center_x, y = mid_y, button = 1,
        shift = false, alt = false, ctrl = false, command = false })
    h({ type = "move",  x = center_x + 6, y = mid_y, button = 1,
        shift = false, alt = false, ctrl = false, command = false })
    h({ type = "move",  x = target_x, y = mid_y, button = 1,
        shift = false, alt = false, ctrl = false, command = false })
    env.pump(120)
    h({ type = "release", x = target_x, y = mid_y, button = 1,
        shift = false, alt = false, ctrl = false, command = false })
    env.pump(200)

    local expected_delta = 250 - (47 + 75)   -- 128 frames
    local expected_start = 47 + expected_delta -- 175 frames

    local tab2 = state.get_tab_strip()
    local v1_after = tab2:track_clip_index(tracks.V1.id)
    local clip_a_after, clip_b_after = nil, nil
    for _, c in ipairs(v1_after) do
        if not c.is_gap then
            if c.id == clip_a.id then clip_a_after = c end
            if c.id == clip_b.id then clip_b_after = c end
        end
    end
    assert(clip_a_after, "A: clip_a disappeared after drag")
    assert(clip_b_after, "A: clip_b disappeared after drag (must be untouched)")

    -- clip_a lands where the grab offset puts it (±2 frames for px rounding).
    assert(math.abs(clip_a_after.sequence_start - expected_start) <= 2, string.format(
        "A: clip_a must land at frame ~%d (original %d + delta %d); got %d",
        expected_start, 47, expected_delta, clip_a_after.sequence_start))
    assert(clip_a_after.duration == 150, string.format(
        "A: clip_a duration must be unchanged (150); got %d", clip_a_after.duration))

    -- clip_b is completely unaffected.
    assert(clip_b_after.sequence_start == 450, string.format(
        "A: clip_b must remain at frame 450 (unselected, unaffected); got %d",
        clip_b_after.sequence_start))
    assert(clip_b_after.duration == 100, string.format(
        "A: clip_b duration must be unchanged (100); got %d", clip_b_after.duration))

    print("    OK")
end

-- ── Scenario B: two clips selected, dragged together as a block ──────────────
-- V1: clip_c [0,100) + clip_d [200,80). Select both, drag right 70 frames.
-- Expected: clip_c at 0+70=70, clip_d at 200+70=270; relative spacing preserved.
print("  B: two-clip block drag shifts both by same delta, preserves relative spacing")
do
    local seq = env.fresh_sequence("DragBlock B")
    local tracks = env.tracks()
    assert(tracks.V1, "need V1")

    env.place_clips(seq, {
        { track_id = tracks.V1.id, position = 0,   duration = 100 },
        { track_id = tracks.V1.id, position = 200, duration = 80  },
    })
    env.view_frames(500, 0)

    local tab = state.get_tab_strip()
    local v1_clips = tab:track_clip_index(tracks.V1.id)
    local clip_c, clip_d = nil, nil
    for _, c in ipairs(v1_clips) do
        if not c.is_gap then
            if c.sequence_start == 0   then clip_c = c end
            if c.sequence_start == 200 then clip_d = c end
        end
    end
    assert(clip_c, "B: clip_c not found at frame 0")
    assert(clip_d, "B: clip_d not found at frame 200")

    local band_c = find_band(0, 100)
    local mid_y = band_c.y + band_c.height / 2
    local h = env.mouse_handler(widget)

    -- Click clip_c to select, shift-click clip_d to add to selection.
    local cx_c = env.x_of(50)   -- centre of clip_c (frame 50)
    local cx_d = env.x_of(240)  -- centre of clip_d (frame 240)
    h({ type = "press",   x = cx_c, y = mid_y, button = 1,
        shift = false, alt = false, ctrl = false, command = false })
    h({ type = "release", x = cx_c, y = mid_y, button = 1,
        shift = false, alt = false, ctrl = false, command = false })
    env.pump(50)
    h({ type = "press",   x = cx_d, y = mid_y, button = 1,
        shift = true, alt = false, ctrl = false, command = false })
    h({ type = "release", x = cx_d, y = mid_y, button = 1,
        shift = true, alt = false, ctrl = false, command = false })
    env.pump(50)

    -- Verify both real clips are selected (gap in same region may also be
    -- selected; that is expected and harmless — the drag handler skips gaps).
    local sel = state.get_selected_clips()
    local sel_c, sel_d = false, false
    for _, c in ipairs(sel) do
        if c.id == clip_c.id then sel_c = true end
        if c.id == clip_d.id then sel_d = true end
    end
    assert(sel_c, "B: clip_c not selected after click")
    assert(sel_d, "B: clip_d not selected after shift-click")

    -- Drag: grab clip_c's centre (frame 50), release at frame 120 → delta = 70.
    local press_x  = env.x_of(50)
    local target_x = env.x_of(120)
    h({ type = "press", x = press_x, y = mid_y, button = 1,
        shift = false, alt = false, ctrl = false, command = false })
    h({ type = "move",  x = press_x + 6, y = mid_y, button = 1,
        shift = false, alt = false, ctrl = false, command = false })
    h({ type = "move",  x = target_x, y = mid_y, button = 1,
        shift = false, alt = false, ctrl = false, command = false })
    env.pump(120)
    h({ type = "release", x = target_x, y = mid_y, button = 1,
        shift = false, alt = false, ctrl = false, command = false })
    env.pump(200)

    local expected_delta = 120 - 50  -- 70 frames

    local tab2 = state.get_tab_strip()
    local v1_after = tab2:track_clip_index(tracks.V1.id)
    local clip_c_after, clip_d_after = nil, nil
    for _, c in ipairs(v1_after) do
        if not c.is_gap then
            if c.id == clip_c.id then clip_c_after = c end
            if c.id == clip_d.id then clip_d_after = c end
        end
    end
    assert(clip_c_after, "B: clip_c disappeared after drag")
    assert(clip_d_after, "B: clip_d disappeared after drag")

    assert(math.abs(clip_c_after.sequence_start - (0 + expected_delta)) <= 2, string.format(
        "B: clip_c must shift by delta %d: expected ~%d, got %d",
        expected_delta, 0 + expected_delta, clip_c_after.sequence_start))
    assert(clip_c_after.duration == 100, string.format(
        "B: clip_c duration unchanged (100); got %d", clip_c_after.duration))

    assert(math.abs(clip_d_after.sequence_start - (200 + expected_delta)) <= 2, string.format(
        "B: clip_d must shift by same delta %d: expected ~%d, got %d",
        expected_delta, 200 + expected_delta, clip_d_after.sequence_start))
    assert(clip_d_after.duration == 80, string.format(
        "B: clip_d duration unchanged (80); got %d", clip_d_after.duration))

    -- Relative spacing preserved: gap between clips stays at 200-100=100 frames.
    local spacing_after = clip_d_after.sequence_start - (clip_c_after.sequence_start + clip_c_after.duration)
    assert(spacing_after == 100, string.format(
        "B: relative spacing between clips must be preserved (100 frames); got %d",
        spacing_after))

    print("    OK")
end

print("✅ test_drag_block_same_track.lua passed")
