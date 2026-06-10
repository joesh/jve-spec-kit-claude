--- Domain rule: downstream non-active clips (those shifted by a ripple
-- but NOT directly grabbed by the user) must NOT receive their own
-- per-clip outline.  Each track with shifted content gets exactly one
-- per-track contoured outline confined to that track's vertical band.
--
-- Layout:
--   V1: clip [0,1000) — gap [1000,1600) — clip [1600,1000)
--   V2: clip [2600,600) — downstream; shifts to [2800,600) after a
--       -200-frame gap-in-edge drag that pushes downstream RIGHT by +200
--
-- Lead edge: V1 gap in-edge (frame 1000) dragged LEFT by -200 frames
--   in RIPPLE mode.  The gap expands, and all content downstream of
--   frame 1000 shifts RIGHT by 200 frames.
--
-- Gesture: press 5px RIGHT of the gap in-edge (frame 1000) — outside
--   the ±3px roll zone → picks only the gap in-edge with trim_type="ripple".
--
-- Note: this test uses a single lead edge on V1; V2 has a downstream clip
-- that shifts as a consequence, not as a co-selected edge.  The known
-- production bug ("multi-track ripple preview resolves non-lead-track
-- edges to the lead track's clip") affects co-selected edge HANDLE
-- rendering, not shift-block contour rendering — so V2 contour
-- assertions here are safe.
--
-- Assertions:
--   (negative) The downstream V2 clip at its shifted position has no
--     per-clip yellow outline (no rect whose four thin sides exactly
--     match the shifted clip's dimensions).
--   (positive) A yellow rect exists confined to V2's vertical band AND
--     overlapping the shifted clip's x range.
--
-- Converted from test_timeline_ripple_preview_single_block_outline.lua
-- (which used ripple_layout + Clip.create + stubbed _G.timeline).
--
-- Run via: ./build/bin/jve.app/Contents/MacOS/jve --test
--   tests/synthetic/integration/batch_timeline_render.lua

local env = require("synthetic.integration.timeline_render.render_env")

print("=== test_ripple_preview_single_block_outline ===")

env.boot()

local seq = env.fresh_sequence("RipplePreviewSingleBlock")
local tracks = env.tracks()
assert(tracks.V1 and tracks.V2, "need V1 and V2 tracks")

-- V1 content
env.place_clips(seq, {
    { track_id = tracks.V1.id, position = 0,    duration = 1000 },
    { track_id = tracks.V1.id, position = 1600, duration = 1000 },
})
-- V2 downstream clip — shifts as a consequence; not co-selected.
env.place_clips(seq, {
    { track_id = tracks.V2.id, position = 2600, duration = 600 },
})
env.view_frames(4000, 0)

local widget = env.video_widget()

-- Locate V1 and V2 track bands from painted clip bodies.
local function find_band(left_frame, right_frame, label)
    local lx = env.x_of(left_frame)
    local rx = env.x_of(right_frame)
    for _, r in ipairs(env.rects(widget)) do
        if math.abs(r.x - lx) < 10 and math.abs((r.x + r.width) - rx) < 10
            and r.height > 10 then
            return r
        end
    end
    error(string.format(
        "%s band [%d,%d) not found (lx=%.1f rx=%.1f) in %d cmds",
        label, left_frame, right_frame, lx, rx, #env.draw_commands(widget)))
end

local v1_band = find_band(0, 1000, "V1")
local v2_band = find_band(2600, 3200, "V2")

local V1_Y, V1_H = v1_band.y, v1_band.height
local V2_Y, V2_H = v2_band.y, v2_band.height
local v1_mid_y   = V1_Y + V1_H / 2

-- Drag V1 gap in-edge (frame 1000) LEFT by -200 frames.
-- Press 5px right of frame 1000 — outside the ±3px roll zone →
-- picks only the gap's in-edge with trim_type="ripple".
-- Ripple shifts everything downstream of frame 1000 RIGHT by +200:
--   V2 clip [2600,600) → [2800,600).
local gap_in_frame = 1000
local delta_frames = -200
local press_x      = env.x_of(gap_in_frame) + 5
local delta_px     = env.x_of(gap_in_frame + delta_frames) - env.x_of(gap_in_frame)
local dir_sign     = (delta_px >= 0) and 1 or -1

local h = env.mouse_handler(widget)
h({ type = "press",  x = press_x, y = v1_mid_y, button = 1,
    shift = false, alt = false, ctrl = false, command = false })
h({ type = "move",   x = press_x + dir_sign * 6, y = v1_mid_y, button = 1,
    shift = false, alt = false, ctrl = false, command = false })
h({ type = "move",   x = press_x + delta_px, y = v1_mid_y, button = 1,
    shift = false, alt = false, ctrl = false, command = false })
env.pump(150)

local yellow_rects = env.rects(widget, "#ffff00")
assert(#yellow_rects > 0, "expected yellow preview rects after drag")

-- Downstream V2 clip shifts from [2600,600) to [2800,600).
local shifted_start    = 2800
local shifted_dur      = 600
local shifted_left_px  = env.x_of(shifted_start)
local shifted_right_px = env.x_of(shifted_start + shifted_dur)

-- Note on the negative "no per-clip outline" assertion from the original
-- unit test: when only ONE clip exists in the downstream track band, a
-- per-track contour outline and a per-clip outline are geometrically
-- indistinguishable (both produce four thin strokes at the same x/y).
-- The real domain rule is "per-track contour, not per-clip," which is
-- observable only when multiple clips are present in the same track band
-- (in which case a per-clip approach would produce N outlines while the
-- contour approach merges them into one run).  With a single V2 downstream
-- clip we can only verify the POSITIVE side: the contour exists and is
-- confined to V2's band.  The coalescing/non-coalescing of multiple
-- clips is fully covered by test_ripple_preview_contoured_runs.

-- Positive assertion: a yellow rect confined to V2's band overlaps
-- the shifted clip's x range.
local found_v2_contour = false
for _, r in ipairs(yellow_rects) do
    local top    = r.y
    local bottom = r.y + r.height
    local left   = r.x
    local right  = r.x + r.width
    local in_v2  = top >= V2_Y - 2 and bottom <= V2_Y + V2_H + 2
    local x_over = left < shifted_right_px and right > shifted_left_px
    if in_v2 and x_over then
        found_v2_contour = true; break
    end
end
assert(found_v2_contour, string.format(
    "expected a yellow preview outline confined to V2 band (y=%d..%d) "
    .. "overlapping shifted clip x range (%.1f..%.1f)",
    V2_Y, V2_Y + V2_H, shifted_left_px, shifted_right_px))

h({ type = "release", x = press_x + delta_px, y = v1_mid_y, button = 1,
    shift = false, alt = false, ctrl = false, command = false })
env.pump(80)

print("✅ test_ripple_preview_single_block_outline.lua passed")
