--- Domain rule: dragging a gap clip's edge via a ripple edit shifts all
-- downstream content; the renderer must paint at least one preview-color
-- rect that intersects each downstream clip's shifted position.
--
-- Three sub-scenarios:
--
--   A. Gap out-edge ripple rightward — V1 has a real gap between two
--      clips; ripple-dragging the gap's out-edge rightward (+200 frames)
--      grows the gap and shifts the downstream clip; a preview-color rect
--      must intersect the downstream clip's shifted region on V1.
--
--   B. Gap-only leading track — a clip on V1 is deleted after placement,
--      leaving only a gap before the surviving downstream clip.  Dragging
--      the gap's out-edge left by -200 frames must mark the downstream
--      clip's shifted position with a preview-color rect.
--
--   C. Multi-track propagation — same drag as A with a clip on V2 sharing
--      the downstream position; V2's clip shifts too and must get its own
--      preview-color rect ON V2'S BAND (the original
--      test_timeline_gap_downstream_preview scenario).
--
-- Converted from test_timeline_gap_downstream_preview.lua and
--   test_timeline_gap_only_preview.lua (both stubbed _G.timeline and
--   injected drag_state; this version drives the real app).
--
-- Run via: ./build/bin/jve.app/Contents/MacOS/jve --test
--   tests/synthetic/integration/batch_timeline_render.lua

local env             = require("synthetic.integration.timeline_render.render_env")
local command_manager = require("core.command_manager")  -- used by sub-test B (DeleteClip, SelectClips)

print("=== test_gap_ripple_preview ===")

env.boot()
local state_module = env.context().state

local PREVIEW_COLOR = "#ffff00"   -- hardcoded in timeline_view_renderer.lua

-- Locate a track-band rect by its clip's known pixel span.
local function find_band(widget, left_frame, right_frame)
    local lx = env.x_of(left_frame)
    local rx = env.x_of(right_frame)
    for _, r in ipairs(env.rects(widget)) do
        if math.abs(r.x - lx) < 10 and math.abs((r.x + r.width) - rx) < 10
            and r.height > 10 then
            return r
        end
    end
    error(string.format(
        "band rect not found for frames [%d,%d] (lx=%.1f rx=%.1f) in %d cmds",
        left_frame, right_frame, lx, rx, #env.draw_commands(widget)))
end

-- Return true when any preview-color rect overlaps the given pixel region.
local function preview_rect_in_region(widget, px_left, px_right, band)
    for _, r in ipairs(env.rects(widget, PREVIEW_COLOR)) do
        local rx_left  = r.x
        local rx_right = r.x + r.width
        local ry_top   = r.y
        local ry_bot   = r.y + r.height
        local x_overlap = rx_left < px_right and rx_right > px_left
        local y_overlap = ry_top  < band.y + band.height and ry_bot > band.y
        if x_overlap and y_overlap then return true end
    end
    return false
end

-- Assert the preview outline's right boundary lands at the shifted clip's
-- END.  This is what distinguishes a ripple (whole clip shifts; outline
-- ends at start+duration+delta) from a roll (clip end fixed; outline ends
-- at the original end).  Checks the rightmost preview-color rect edge on
-- the band against `expected_right_px` within tolerance.
local function assert_preview_right_edge(widget, expected_right_px, band, label)
    local max_right = nil
    for _, r in ipairs(env.rects(widget, PREVIEW_COLOR)) do
        local y_overlap = r.y < band.y + band.height and (r.y + r.height) > band.y
        if y_overlap then
            local right = r.x + r.width
            if not max_right or right > max_right then max_right = right end
        end
    end
    assert(max_right, label .. ": no preview-color rect on the band at all")
    assert(math.abs(max_right - expected_right_px) <= 12, string.format(
        "%s: preview outline's right boundary is at x=%.1f, expected ~%.1f "
        .. "(shifted clip end). A roll-style outline (clip end fixed) would "
        .. "land elsewhere — the gesture must ripple-shift the whole clip.",
        label, max_right, expected_right_px))
end

-- Initiate an edge drag without releasing.  Press 5px inside the clip/gap
-- body near `edge_frame`, move past threshold, then move to `delta_px`.
-- 5px selects a single-edge RIPPLE grab: ROLL_ZONE_PX=7 makes ±3px of the
-- boundary a roll grab (both edges, no ripple); EDGE_ZONE_PX=7 caps the
-- grab range, so 4..7px on one side is the ripple band.
-- `inside_dir`: "right" → press is 5px to the right of edge_frame
--               (grabs the right-hand element's in-edge);
--               "left"  → press is 5px to the left
--               (grabs the left-hand element's out-edge).
local function begin_drag(h, edge_frame, mid_y, delta_px, inside_dir)
    inside_dir = inside_dir or "right"
    local ex      = env.x_of(edge_frame)
    local press_x = (inside_dir == "right") and (ex + 5) or (ex - 5)
    h({ type = "press", x = press_x, y = mid_y, button = 1,
        shift = false, alt = false, ctrl = false, command = false })
    local dir_sign = (delta_px >= 0) and 1 or -1
    h({ type = "move",  x = press_x + dir_sign * 6, y = mid_y, button = 1,
        shift = false, alt = false, ctrl = false, command = false })
    h({ type = "move",  x = press_x + delta_px, y = mid_y, button = 1,
        shift = false, alt = false, ctrl = false, command = false })
    env.pump(150)
    return press_x
end

------------------------------------------------------------------------
-- Sub-test A: single-track gap out-edge ripple shifts downstream content
--
-- V1:  clip [0,1000) — gap [1000,1600) — clip [1600,2600)
--
-- Ripple-drag the gap's out-edge rightward by +200 frames (grows the
-- gap).  Downstream V1 clip at [1600,2600) shifts to [1800,2800).
-- A preview-color rect must intersect that shifted region on V1's band.
------------------------------------------------------------------------
print("  A: gap out-edge ripple marks downstream clip in preview color")
do
    local seq = env.fresh_sequence("GapRipplePreview A")
    local tracks = env.tracks()
    assert(tracks.V1, "need V1 track")

    env.place_clips(seq, {
        { track_id = tracks.V1.id, position = 0,    duration = 1000 },
        { track_id = tracks.V1.id, position = 1600, duration = 1000 },
    })
    env.view_frames(3200, 0)

    local widget = env.video_widget()

    -- V1 band for the first clip (used to locate mid_y for the gesture).
    local v1_first_band = find_band(widget, 0, 1000)
    local v1_mid_y      = v1_first_band.y + v1_first_band.height / 2

    -- Band for the downstream clip [1600,2600) — where the preview must land.
    local v1_right_band = find_band(widget, 1600, 2600)

    -- Ripple-grab the gap's out-edge (boundary at frame 1600, press on
    -- the gap side) and drag rightward +200. The gap grows; the
    -- downstream clip shifts right: 1600 → 1800.
    local delta_frames = 200
    local delta_px     = env.x_of(1600 + delta_frames) - env.x_of(1600)

    local h = env.mouse_handler(widget)
    local press_x = begin_drag(h, 1600, v1_mid_y, delta_px, "left")

    local shifted_start = 1600 + delta_frames   -- 1800
    local shifted_dur   = 1000
    local sl = env.x_of(shifted_start)
    local sr = env.x_of(shifted_start + shifted_dur)
    assert(preview_rect_in_region(widget, sl, sr, v1_right_band),
        string.format(
            "A: no preview-color rect intersects downstream clip's shifted region "
            .. "(x=%.0f..%.0f, y=%d..%d) in %d draw cmds",
            sl, sr,
            v1_right_band.y, v1_right_band.y + v1_right_band.height,
            #env.draw_commands(widget)))
    assert_preview_right_edge(widget, sr, v1_right_band, "A")

    h({ type = "release", x = press_x + delta_px, y = v1_mid_y, button = 1,
        shift = false, alt = false, ctrl = false, command = false })
    env.pump(80)
    print("    OK")
end

------------------------------------------------------------------------
-- Sub-test B: gap-only leading track — downstream clip shifts into preview
--
-- Place clip [0,500) then delete it via RippleDeleteSelection, leaving a
-- gap [0,500) before clip [500,700).  Drag the gap's out-edge left by
-- -200 frames.  The downstream clip shifts from 500→300.  A preview-color
-- rect must intersect its shifted position.
------------------------------------------------------------------------
print("  B: gap-only track — out-edge drag marks downstream clip in preview color")
do
    local seq = env.fresh_sequence("GapRipplePreview B")
    local tracks = env.tracks()
    assert(tracks.V1, "need V1 track")

    -- Place two clips; then delete the first one to create a leading gap.
    env.place_clips(seq, {
        { track_id = tracks.V1.id, position = 0,   duration = 500 },
        { track_id = tracks.V1.id, position = 500,  duration = 700 },
    })

    -- Select and ripple-delete the first clip to create the gap.
    local tab = state_module.get_tab_strip()
    local v1_clips = tab:track_clip_index(tracks.V1.id)
    local first_clip = nil
    for _, c in ipairs(v1_clips) do
        if not c.is_gap and c.sequence_start == 0 then
            first_clip = c; break
        end
    end
    assert(first_clip, "B: no clip at frame 0 on V1 after placement")

    local del_r = command_manager.execute("DeleteClip", {
        project_id  = env.context().project_id,
        sequence_id = seq,
        clip_id     = first_clip.id,
    })
    assert(del_r and del_r.success,
        "B: DeleteClip failed: " .. tostring(del_r and del_r.error_message))
    env.pump(100)

    env.view_frames(1400, 0)

    local widget = env.video_widget()

    -- After deletion the gap [0,500) should be present; downstream clip at 500.
    local tab2 = state_module.get_tab_strip()
    local v1c2 = tab2:track_clip_index(tracks.V1.id)
    local gap_clip = nil
    local downstream_clip = nil
    for _, c in ipairs(v1c2) do
        if c.is_gap and c.sequence_start == 0 then
            gap_clip = c
        elseif not c.is_gap and c.sequence_start == 500 then
            downstream_clip = c
        end
    end
    assert(gap_clip, "B: no gap at frame 0 after clip deletion")
    assert(downstream_clip, "B: no downstream clip at frame 500 after deletion")

    -- Locate V1 band from the downstream clip's body.
    local v1_band  = find_band(widget, 500, 1200)
    local v1_mid_y = v1_band.y + v1_band.height / 2

    -- Ripple-grab the gap's out-edge (boundary at frame 500, press on the
    -- gap side) and drag leftward -200 frames. The gap shrinks; the
    -- downstream clip shifts left: 500 → 300.
    local delta_frames  = -200
    local delta_px      = env.x_of(500 + delta_frames) - env.x_of(500)

    local h = env.mouse_handler(widget)
    local press_x = begin_drag(h, 500, v1_mid_y, delta_px, "left")

    -- Downstream clip shifts from 500 to 300.
    local shifted_start = 500 + delta_frames   -- 300
    local shifted_dur   = downstream_clip.duration

    local sl = env.x_of(shifted_start)
    local sr = env.x_of(shifted_start + shifted_dur)
    assert(preview_rect_in_region(widget, sl, sr, v1_band),
        string.format(
            "B: no preview-color rect intersecting downstream clip's shifted region "
            .. "(x=%.0f..%.0f, y=%d..%d) in %d draw cmds",
            sl, sr,
            v1_band.y, v1_band.y + v1_band.height,
            #env.draw_commands(widget)))
    assert_preview_right_edge(widget, sr, v1_band, "B")

    h({ type = "release", x = press_x + delta_px, y = v1_mid_y, button = 1,
        shift = false, alt = false, ctrl = false, command = false })
    env.pump(80)
    print("    OK")
end

------------------------------------------------------------------------
-- Sub-test C: multi-track propagation — V2's downstream clip gets its
-- own preview-color rect on V2's band
--
-- V1:  clip [0,1000) — gap — clip [1600,2600)
-- V2:  clip [1600,2600)
--
-- Same drag as A (gap out-edge ripple +200).  The ripple propagates to
-- V2, whose clip shifts 1600 → 1800; a preview-color rect must intersect
-- that shifted region on V2's band, not just on V1's.
------------------------------------------------------------------------
print("  C: multi-track — propagated track's clip marked on its own band")
do
    local seq = env.fresh_sequence("GapRipplePreview C")
    local tracks = env.tracks()
    assert(tracks.V1 and tracks.V2, "need V1 and V2 tracks")

    env.place_clips(seq, {
        { track_id = tracks.V1.id, position = 0,    duration = 1000 },
        { track_id = tracks.V1.id, position = 1600, duration = 1000 },
        { track_id = tracks.V2.id, position = 1600, duration = 1000 },
    })
    env.view_frames(3200, 0)

    local widget = env.video_widget()

    local v1_first_band = find_band(widget, 0, 1000)
    local v1_mid_y      = v1_first_band.y + v1_first_band.height / 2

    -- Two bands share the [1600,2600) span; the one on a different row
    -- than V1's first clip is V2's.
    local v2_band = nil
    local c2_l, c2_r = env.x_of(1600), env.x_of(2600)
    for _, r in ipairs(env.rects(widget)) do
        if r.height > 10
            and math.abs(r.x - c2_l) < 10 and math.abs((r.x + r.width) - c2_r) < 10
            and math.abs(r.y - v1_first_band.y) > 4 then
            v2_band = r
        end
    end
    assert(v2_band, "C: V2 clip rect not found on a distinct band")

    local delta_frames = 200
    local delta_px     = env.x_of(1600 + delta_frames) - env.x_of(1600)

    local h = env.mouse_handler(widget)
    local press_x = begin_drag(h, 1600, v1_mid_y, delta_px, "left")

    local sl = env.x_of(1600 + delta_frames)
    local sr = env.x_of(1600 + delta_frames + 1000)
    assert(preview_rect_in_region(widget, sl, sr, v2_band),
        string.format(
            "C: no preview-color rect intersects V2's shifted clip region "
            .. "(x=%.0f..%.0f, y=%d..%d) in %d draw cmds — propagated-track "
            .. "preview missing or on the wrong band",
            sl, sr, v2_band.y, v2_band.y + v2_band.height,
            #env.draw_commands(widget)))
    assert_preview_right_edge(widget, sr, v2_band, "C")

    h({ type = "release", x = press_x + delta_px, y = v1_mid_y, button = 1,
        shift = false, alt = false, ctrl = false, command = false })
    env.pump(80)
    print("    OK")
end

print("✅ test_gap_ripple_preview.lua passed")
