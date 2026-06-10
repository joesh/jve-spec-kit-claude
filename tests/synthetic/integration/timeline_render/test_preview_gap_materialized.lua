--- Domain rule: when a gap clip's edge is dragged in ripple mode, the
-- gap body itself must NOT receive a yellow preview rectangle.  Only
-- the downstream real clips that shift as a result get yellow outlines;
-- the gap is empty space and must not be highlighted as a moved clip.
--
-- Layout (V1): clip [0,1000) — gap [1000,1600) — clip [1600,800).
-- Lead edge: V1 gap's in-edge (at frame 1000) dragged LEFT by -200
--   frames in RIPPLE mode.  This expands the gap leftward, causing the
--   left clip to shrink and all downstream content to shift RIGHT by 200.
--   The downstream clip [1600,800) shifts to [1800,800).
--
-- To get ripple mode the press must be >3px from the edge boundary
-- (the roll zone is ±3px centered; pressing ≥5px inside the gap body
-- is safely outside the roll zone and picks the gap's in-edge alone
-- with trim_type="ripple").
--
-- Assertions:
--   (positive) At least one yellow rect exists (shift_block contour for
--     the downstream clip's shifted position [1800,2600)).
--   (negative) No yellow rect's span matches the gap body dimensions
--     (neither the pre-drag gap [1000,1600) nor the post-drag [800,1600)).
--
-- Converted from test_timeline_preview_gap_materialized.lua (which
-- stubbed _G.timeline and injected drag_state directly).
--
-- Run via: ./build/bin/jve.app/Contents/MacOS/jve --test
--   tests/synthetic/integration/batch_timeline_render.lua

local env = require("synthetic.integration.timeline_render.render_env")

print("=== test_preview_gap_materialized ===")

env.boot()

local seq = env.fresh_sequence("PreviewGapMaterialized")
local tracks = env.tracks()
assert(tracks.V1, "need V1 track")

-- V1: clip [0,1000) — gap [1000,1600) — clip [1600,800)
env.place_clips(seq, {
    { track_id = tracks.V1.id, position = 0,    duration = 1000 },
    { track_id = tracks.V1.id, position = 1600, duration = 800  },
})
env.view_frames(2800, 0)

local widget = env.video_widget()

-- Find V1 band from the first clip [0,1000).
local function find_v1_band()
    local lx = env.x_of(0)
    local rx = env.x_of(1000)
    for _, r in ipairs(env.rects(widget)) do
        if math.abs(r.x - lx) < 10 and math.abs((r.x + r.width) - rx) < 10
            and r.height > 10 then
            return r
        end
    end
    error(string.format(
        "V1 band [0,1000) not found (lx=%.1f rx=%.1f) in %d cmds",
        lx, rx, #env.draw_commands(widget)))
end

local v1_band  = find_v1_band()
local v1_mid_y = v1_band.y + v1_band.height / 2

-- The gap spans [1000, 1600); its pixel coordinates.
local gap_orig_start_px = env.x_of(1000)
local gap_orig_end_px   = env.x_of(1600)
local gap_post_start_px = env.x_of(800)   -- post-drag: gap starts at 800

-- Press 5px right of gap in-edge (frame 1000) — inside the gap body,
-- outside the ±3px roll zone → picks the gap's in-edge alone with
-- trim_type="ripple".
-- Drag left by -200 frames: gap in-edge moves 1000→800, gap grows,
-- downstream content shifts RIGHT by +200 frames.
local gap_in_frame = 1000
local delta_frames = -200
local delta_px     = env.x_of(gap_in_frame + delta_frames) - env.x_of(gap_in_frame)
local dir_sign     = (delta_px >= 0) and 1 or -1

local h = env.mouse_handler(widget)
h({ type = "press",  x = env.x_of(gap_in_frame) + 5, y = v1_mid_y, button = 1,
    shift = false, alt = false, ctrl = false, command = false })
h({ type = "move",   x = env.x_of(gap_in_frame) + 5 + dir_sign * 6, y = v1_mid_y, button = 1,
    shift = false, alt = false, ctrl = false, command = false })
h({ type = "move",   x = env.x_of(gap_in_frame) + 5 + delta_px, y = v1_mid_y, button = 1,
    shift = false, alt = false, ctrl = false, command = false })
env.pump(150)

local yellow_rects = env.rects(widget, "#ffff00")
assert(#yellow_rects > 0,
    "expected yellow preview rects after ripple gap in-edge drag")

-- Gap in-edge drag -200 → downstream shifts RIGHT by +200.
-- Downstream clip [1600,800) shifts to [1800,800).
local shifted_left  = env.x_of(1800)
local shifted_right = env.x_of(2600)

-- Assert (negative): no yellow rect spans the original or post-drag gap body.
-- A "gap body" yellow rect would have x near the gap start AND
-- x+width near the gap end — check both the original [1000,1600) extent
-- and the post-drag [800,1600) extent.
for _, r in ipairs(yellow_rects) do
    local spans_orig_gap = math.abs(r.x - gap_orig_start_px) <= 3
                        and math.abs((r.x + r.width) - gap_orig_end_px) <= 3
    assert(not spans_orig_gap, string.format(
        "gap body must not receive a yellow rect spanning [1000,1600) "
        .. "(rect x=%.1f w=%.1f)",
        r.x, r.width))

    local spans_post_gap = math.abs(r.x - gap_post_start_px) <= 3
                        and math.abs((r.x + r.width) - gap_orig_end_px) <= 3
    assert(not spans_post_gap, string.format(
        "gap body must not receive a yellow rect spanning post-drag [800,1600) "
        .. "(rect x=%.1f w=%.1f)",
        r.x, r.width))
end

-- Assert (positive): at least one yellow rect overlaps the downstream
-- clip's shifted region [1800, 2600).
local found_downstream = false
for _, r in ipairs(yellow_rects) do
    local rx_left  = r.x
    local rx_right = r.x + r.width
    if rx_left < shifted_right and rx_right > shifted_left then
        found_downstream = true; break
    end
end
assert(found_downstream, string.format(
    "no yellow rect overlaps the downstream clip's shifted region "
    .. "[%.1f, %.1f) in %d yellow rects",
    shifted_left, shifted_right, #yellow_rects))

h({ type = "release", x = env.x_of(gap_in_frame) + 5 + delta_px, y = v1_mid_y, button = 1,
    shift = false, alt = false, ctrl = false, command = false })
env.pump(80)

print("✅ test_preview_gap_materialized.lua passed")
