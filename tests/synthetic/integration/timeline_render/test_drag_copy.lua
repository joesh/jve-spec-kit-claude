--- Domain rule: Alt/Option-drag duplicates the dragged clip(s) rather than
-- moving them. The original clip stays at its source position on its source
-- track; a new clip with identical media appears at the drop position on the
-- drop track.
--
-- Replaces: tests/synthetic/lua/test_timeline_drag_copy.lua
-- (that test built the DB by hand and called the drag handler directly with a
-- fabricated drag_state including alt_copy=true; this version drives the real
-- gesture pipeline end to end).

local env = require("synthetic.integration.timeline_render.render_env")

print("=== test_drag_copy ===")

env.boot()
local state = env.context().state
local widget = env.video_widget()

-- Locate a track band from a clip's known pixel span.
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

-- ── Scenario: alt-drag V1 clip to V2 band creates copy, original stays ─────
print("  A: alt-drag to a different track duplicates rather than moves")
do
    local seq = env.fresh_sequence("DragCopy A")
    local tracks = env.tracks()
    assert(tracks.V1 and tracks.V2, "need V1 and V2 tracks")

    -- Place the target clip on V1 at a non-trivial offset. Also place a short
    -- anchor clip on V2 so we can locate V2's band via find_band.
    env.place_clips(seq, {
        { track_id = tracks.V1.id, position = 47,  duration = 153 },
        { track_id = tracks.V2.id, position = 400, duration = 80  },
    })
    env.view_frames(600, 0)

    -- Find band y coords.
    local v1_band = find_band(47, 200)   -- clip [47, 200)
    local v2_band = find_band(400, 480)  -- anchor clip [400, 480) on V2

    local v1_mid_y = v1_band.y + v1_band.height / 2
    local v2_mid_y = v2_band.y + v2_band.height / 2

    -- Identify the V1 clip by position.
    local tab = state.get_tab_strip()
    local v1_clips = tab:track_clip_index(tracks.V1.id)
    local v1_clip = nil
    for _, c in ipairs(v1_clips) do
        if not c.is_gap and c.sequence_start == 47 then
            v1_clip = c; break
        end
    end
    assert(v1_clip, "A: V1 clip at frame 47 not found")

    -- Select V1 clip first via plain click.
    local h = env.mouse_handler(widget)
    local clip_cx = env.x_of(47 + 76)  -- centre of clip
    h({ type = "press",   x = clip_cx, y = v1_mid_y, button = 1,
        shift = false, alt = false, ctrl = false, command = false })
    h({ type = "release", x = clip_cx, y = v1_mid_y, button = 1,
        shift = false, alt = false, ctrl = false, command = false })
    env.pump(80)

    -- Confirm clip is selected.
    local sel = state.get_selected_clips()
    local is_sel = false
    for _, c in ipairs(sel) do if c.id == v1_clip.id then is_sel = true; break end end
    assert(is_sel, "A: plain click did not select V1 clip")

    -- Alt-drag: press on clip with alt=true, threshold move, then drag to
    -- V2's y at frame 250 (well clear of the V2 anchor clip at 400).
    local drag_target_x = env.x_of(250)
    h({ type = "press", x = clip_cx, y = v1_mid_y, button = 1,
        shift = false, alt = true, ctrl = false, command = false })
    -- Threshold move (same track, just to arm the drag).
    h({ type = "move",  x = clip_cx + 6, y = v1_mid_y, button = 1,
        shift = false, alt = true, ctrl = false, command = false })
    -- Main move: to V2's band at the target x.
    h({ type = "move",  x = drag_target_x, y = v2_mid_y, button = 1,
        shift = false, alt = true, ctrl = false, command = false })
    env.pump(100)
    -- Release to commit the duplicate.
    h({ type = "release", x = drag_target_x, y = v2_mid_y, button = 1,
        shift = false, alt = true, ctrl = false, command = false })
    env.pump(200)

    -- Verify original clip still at V1 / frame 47.
    local tab2 = state.get_tab_strip()
    local v1_after = tab2:track_clip_index(tracks.V1.id)
    local original_still_there = false
    for _, c in ipairs(v1_after) do
        if not c.is_gap
            and c.sequence_start == 47
            and c.id == v1_clip.id then
            original_still_there = true; break
        end
    end
    assert(original_still_there,
        "A: original clip was moved/removed from V1 frame 47 — alt-drag must duplicate, not move")

    -- Verify the copy on V2. A drag preserves the grab point within the
    -- clip: the press was at the clip's centre (frame 123 = 47 + 76) and the
    -- release at frame 250, so the whole clip moves by that mouse delta —
    -- the copy starts at 47 + (250 - 123) = 174. ±2 frames for px rounding.
    local expected_start = 47 + (250 - (47 + 76))
    local v2_after = tab2:track_clip_index(tracks.V2.id)
    local copy = nil
    local copy_parts = {}
    for _, c in ipairs(v2_after) do
        if not c.is_gap and c.id ~= v1_clip.id and c.sequence_start ~= 400 then
            copy_parts[#copy_parts+1] = string.format("id=%s start=%d dur=%d",
                tostring(c.id):sub(1,8), c.sequence_start, c.duration)
            copy = c
        end
    end
    assert(copy, "A: no copy clip found on V2 after alt-drag (only the anchor)")
    assert(#copy_parts == 1, string.format(
        "A: expected exactly 1 copy on V2; got: %s",
        table.concat(copy_parts, ", ")))
    assert(math.abs(copy.sequence_start - expected_start) <= 2, string.format(
        "A: copy must land where the grab offset puts it (start ~%d); got %d",
        expected_start, copy.sequence_start))
    assert(copy.duration == 153, string.format(
        "A: copy must keep the original's 153-frame duration; got %d",
        copy.duration))

    print("    OK")
end

print("✅ test_drag_copy.lua passed")
