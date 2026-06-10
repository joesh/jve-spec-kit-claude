--- Domain rule: when a ripple edit is constrained by a gap, the yellow
-- preview rectangles for affected clips must not extend left of the
-- clamped position.  No yellow rect should appear to the left of the
-- timeline origin (or whatever the gap clamp resolves to).
--
-- Layout (V1): clip [0,500) — gap [500,1000) — clip [1000,600).
-- Lead edge: V1 gap's in-edge dragged left by -2000 frames (far past
-- the 500-frame gap width and the timeline start).  After clamp the
-- downstream clip [1000,600) can shift AT MOST 500 frames leftward
-- (gap width); its preview rect must start at x ≥ x_of(0).
--
-- Converted from test_timeline_preview_gap_clamp.lua (which stubbed
-- _G.timeline and injected drag_state with a hardcoded width).
--
-- Run via: ./build/bin/jve.app/Contents/MacOS/jve --test
--   tests/synthetic/integration/batch_timeline_render.lua

local env = require("synthetic.integration.timeline_render.render_env")

print("=== test_preview_gap_clamp ===")

env.boot()

local seq = env.fresh_sequence("PreviewGapClamp")
local tracks = env.tracks()
assert(tracks.V1, "need V1 track")

-- V1: clip [0,500) — gap [500,1000) — clip [1000,600)
env.place_clips(seq, {
    { track_id = tracks.V1.id, position = 0,    duration = 500 },
    { track_id = tracks.V1.id, position = 1000, duration = 600 },
})
env.view_frames(2000, 0)

local widget = env.video_widget()

-- Find V1 clip body band from the first clip [0,500).
local function find_v1_band()
    local lx = env.x_of(0)
    local rx = env.x_of(500)
    for _, r in ipairs(env.rects(widget)) do
        if math.abs(r.x - lx) < 10 and math.abs((r.x + r.width) - rx) < 10
            and r.height > 10 then
            return r
        end
    end
    error(string.format(
        "V1 band [0,500) not found (lx=%.1f rx=%.1f) in %d cmds",
        lx, rx, #env.draw_commands(widget)))
end

local v1_band  = find_v1_band()
local v1_mid_y = v1_band.y + v1_band.height / 2

-- Press 3px right of gap in-edge (frame 500) — inside the gap body.
-- Drag left by -2000 frames (far past gap width of 500 frames and
-- the timeline origin).
local gap_in_frame = 500
local delta_frames = -2000
local delta_px     = env.x_of(gap_in_frame + delta_frames) - env.x_of(gap_in_frame)
-- delta_px will be negative (leftward) and likely clip to x=0 in pixel coords.
local dir_sign = (delta_px >= 0) and 1 or -1

local h = env.mouse_handler(widget)
h({ type = "press",  x = env.x_of(gap_in_frame) + 3, y = v1_mid_y, button = 1,
    shift = false, alt = false, ctrl = false, command = false })
h({ type = "move",   x = env.x_of(gap_in_frame) + 3 + dir_sign * 6, y = v1_mid_y, button = 1,
    shift = false, alt = false, ctrl = false, command = false })
h({ type = "move",   x = env.x_of(gap_in_frame) + 3 + delta_px, y = v1_mid_y, button = 1,
    shift = false, alt = false, ctrl = false, command = false })
env.pump(150)

-- Clamp boundary: downstream clip can shift at most 500 frames left
-- (gap width), placing it at frame 500.  In pixels, x_of(0) is the
-- leftmost the preview can appear.
local clamp_x = env.x_of(0)

local yellow_rects = env.rects(widget, "#ffff00")
assert(#yellow_rects > 0, "expected yellow preview rects for the dragged downstream clip")

for _, r in ipairs(yellow_rects) do
    assert(r.x >= clamp_x - 1, string.format(
        "preview rect extends left of clamp: rect.x=%.1f clamp_x=%.1f",
        r.x, clamp_x))
end

h({ type = "release", x = env.x_of(gap_in_frame) + 3 + delta_px, y = v1_mid_y, button = 1,
    shift = false, alt = false, ctrl = false, command = false })
env.pump(80)

print("✅ test_preview_gap_clamp.lua passed")
