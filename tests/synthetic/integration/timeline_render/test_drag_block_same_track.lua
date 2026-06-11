--- Domain rule: dragging a block of selected clips on the same track
-- by N frames moves every clip in the selection forward by exactly N frames
-- (grab offset preserved). Unselected clips on the same track are NOT
-- displaced — unless the dragged clip lands on one, in which case the
-- overlapped portion is OVERWRITTEN (track-based NLE convention, decided
-- by Joe 2026-06-11): the stationary clip is head-trimmed to start where
-- the dropped clip ends, its trimmed content discarded (source_in advances
-- by the trimmed amount).
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

-- ── Scenario C: drop onto an unselected clip overwrites the overlap ──────────
-- V1: clip_e [0,100) + clip_f [200,300). Drag clip_e right by 150 so it lands
-- [150,250), overlapping clip_f's head by 50 frames. Track-based NLE
-- convention (Joe, 2026-06-11): the drop wins — clip_f is head-trimmed to
-- start where clip_e ends. The trimmed 50 frames of clip_f's content are
-- discarded, so clip_f's source_in advances by the same amount (the frame
-- visible at its new in-edge is the content that was always at that
-- timeline position).
print("  C: drop onto unselected clip overwrites the overlapped portion")
do
    local seq = env.fresh_sequence("DragBlock C")
    local tracks = env.tracks()
    assert(tracks.V1, "need V1")

    env.place_clips(seq, {
        { track_id = tracks.V1.id, position = 0,   duration = 100 },
        { track_id = tracks.V1.id, position = 200, duration = 100 },
    })
    env.view_frames(500, 0)

    local tab = state.get_tab_strip()
    local v1_clips = tab:track_clip_index(tracks.V1.id)
    local clip_e, clip_f = nil, nil
    for _, c in ipairs(v1_clips) do
        if not c.is_gap then
            if c.sequence_start == 0   then clip_e = c end
            if c.sequence_start == 200 then clip_f = c end
        end
    end
    assert(clip_e, "C: clip_e not found at frame 0")
    assert(clip_f, "C: clip_f not found at frame 200")
    local f_source_in_before = clip_f.source_in

    local band_e = find_band(0, 100)
    local mid_y = band_e.y + band_e.height / 2
    local h = env.mouse_handler(widget)

    -- Select clip_e, then drag its centre from frame 50 to frame 200
    -- (delta +150 → clip_e lands [150,250), overlapping clip_f by 50).
    local cx_e = env.x_of(50)
    h({ type = "press",   x = cx_e, y = mid_y, button = 1,
        shift = false, alt = false, ctrl = false, command = false })
    h({ type = "release", x = cx_e, y = mid_y, button = 1,
        shift = false, alt = false, ctrl = false, command = false })
    env.pump(80)

    local target_x = env.x_of(200)
    h({ type = "press", x = cx_e, y = mid_y, button = 1,
        shift = false, alt = false, ctrl = false, command = false })
    h({ type = "move",  x = cx_e + 6, y = mid_y, button = 1,
        shift = false, alt = false, ctrl = false, command = false })
    h({ type = "move",  x = target_x, y = mid_y, button = 1,
        shift = false, alt = false, ctrl = false, command = false })
    env.pump(120)
    h({ type = "release", x = target_x, y = mid_y, button = 1,
        shift = false, alt = false, ctrl = false, command = false })
    env.pump(200)

    local tab2 = state.get_tab_strip()
    local v1_after = tab2:track_clip_index(tracks.V1.id)
    local e_after, f_after = nil, nil
    for _, c in ipairs(v1_after) do
        if not c.is_gap then
            if c.id == clip_e.id then e_after = c end
            if c.id == clip_f.id then f_after = c end
        end
    end
    assert(e_after, "C: dragged clip_e disappeared")
    assert(f_after, "C: clip_f fully deleted — only the overlapped 50 frames "
        .. "should be overwritten, not the whole clip")

    -- clip_e lands intact at ~150 (±2 px rounding), duration unchanged.
    assert(math.abs(e_after.sequence_start - 150) <= 2, string.format(
        "C: clip_e must land at ~150; got %d", e_after.sequence_start))
    assert(e_after.duration == 100, string.format(
        "C: dropped clip keeps its full duration (100); got %d", e_after.duration))

    -- clip_f is head-trimmed exactly to clip_e's actual out edge (derive
    -- from e_after so pixel rounding of the drop can't skew the trim math).
    local e_end = e_after.sequence_start + e_after.duration
    local trimmed = e_end - 200   -- frames of clip_f's head that were covered
    assert(f_after.sequence_start == e_end, string.format(
        "C: clip_f must start where clip_e ends (%d); got %d",
        e_end, f_after.sequence_start))
    assert(f_after.duration == 100 - trimmed, string.format(
        "C: clip_f duration must lose exactly the overlap (%d → %d); got %d",
        100, 100 - trimmed, f_after.duration))
    -- source_in is in MEDIA frames: the fixture media is 25fps in a 24fps
    -- sequence, so the trimmed timeline duration converts at 25/24
    -- (timecode math: trimmed/24 seconds × 25 media fps).
    local expected_src_advance = math.floor(trimmed * 25 / 24 + 0.5)
    assert(f_after.source_in == f_source_in_before + expected_src_advance, string.format(
        "C: clip_f source_in must advance by the trimmed duration converted "
        .. "to media rate (%d seq frames @24fps = %d media frames @25fps): "
        .. "expected %d, got %d",
        trimmed, expected_src_advance,
        f_source_in_before + expected_src_advance, f_after.source_in))

    -- Undo restores BOTH clips: the move and the overwrite trim are one
    -- user gesture, so one undo brings back clip_e at 0 and clip_f's full
    -- untrimmed content at 200.
    local command_manager = require("core.command_manager")
    assert(command_manager.undo(), "C: undo of the overwrite drag must succeed")
    env.pump(150)

    local tab3 = state.get_tab_strip()
    local v1_undo = tab3:track_clip_index(tracks.V1.id)
    local e_undo, f_undo = nil, nil
    for _, c in ipairs(v1_undo) do
        if not c.is_gap then
            if c.id == clip_e.id then e_undo = c end
            if c.id == clip_f.id then f_undo = c end
        end
    end
    assert(e_undo and e_undo.sequence_start == 0 and e_undo.duration == 100,
        string.format("C: undo must restore clip_e to [0,100); got start=%s dur=%s",
            tostring(e_undo and e_undo.sequence_start), tostring(e_undo and e_undo.duration)))
    assert(f_undo and f_undo.sequence_start == 200 and f_undo.duration == 100
        and f_undo.source_in == f_source_in_before,
        string.format("C: undo must restore clip_f to [200,300) src_in=%d; "
            .. "got start=%s dur=%s src_in=%s", f_source_in_before,
            tostring(f_undo and f_undo.sequence_start),
            tostring(f_undo and f_undo.duration),
            tostring(f_undo and f_undo.source_in)))

    print("    OK")
end

print("✅ test_drag_block_same_track.lua passed")
