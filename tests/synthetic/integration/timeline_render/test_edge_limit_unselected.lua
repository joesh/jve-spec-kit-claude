--- Domain rule: when an unselected edge blocks a drag (implied limiter),
-- the renderer must paint it in a DIMMED limit color so the editor can
-- see which clip is blocking the move — even though that clip was never
-- directly picked.
--
-- Mechanism: when a ripple drag would propagate a leftward downstream
-- shift to a track, and the tightest gap on that track is smaller than
-- the propagation amount, BatchRippleEdit records the unselected clip
-- whose out-edge is the blocker as a forced_clamped_edge. The renderer
-- then emits that edge with is_limiter=true, is_implied=true, and the
-- edge_drag_renderer draws it in the dimmed limit color.
--
-- Scenario:
--   V1: clip_A [0, 800)  — gap [800, 200) — clip_B [1000, 400)
--   V2: clip_V2 [200, 600)   out-edge at frame 800
--
-- Drag V2's OUT-edge LEFT by -400 (shrink the clip from its right side).
-- No gap is adjacent to V2's out-edge on the V2 track, so only the
-- out-edge is selected. Applied_delta = -400. Cross-track propagation
-- to V1 is also -400 (leftward). V1's gap [800,1000) is only 200 frames
-- wide, so clip_B cannot shift left 400 without colliding with clip_A.
-- Pipeline clamps propagation to -200 and marks clip_A:out as the blocker.
--
-- Expected: renderer draws at least one dimmed-limit-color rect in V1's
-- track band (where clip_A lives).
--
-- Run via: ./build/bin/jve.app/Contents/MacOS/jve --test
--   tests/synthetic/integration/batch_timeline_render.lua

local env          = require("synthetic.integration.timeline_render.render_env")
local color_utils  = require("ui.color_utils")

print("=== test_edge_limit_unselected ===")

env.boot()
local state_module = env.context().state

local seq = env.fresh_sequence("EdgeLimitUnselected")
local tracks = env.tracks()
assert(tracks.V1 and tracks.V2, "need V1 and V2 tracks")

-- V1: clip_A [0,800)  gap [800..1000)  clip_B [1000,400)
-- V2: clip_V2 [200,600)   out-edge at frame 800
-- No gap immediately to the left of V2 out-edge — pressing inside V2 body
-- near the right edge picks V2's out-edge only.
env.place_clips(seq, {
    { track_id = tracks.V1.id, position = 0,    duration = 800  },
    { track_id = tracks.V1.id, position = 1000, duration = 400  },
})
env.place_clips(seq, {
    { track_id = tracks.V2.id, position = 200, duration = 600 },
})
env.view_frames(1800, 0)

local widget = env.video_widget()

-- Locate a clip band by its pixel span.
local function find_band(left_frame, right_frame)
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

local v1_band  = find_band(0, 800)
local v2_band  = find_band(200, 800)
local v2_mid_y = v2_band.y + v2_band.height / 2

-- Press 3px LEFT of V2 clip's out-edge (frame 800) — inside the clip body.
-- Drag LEFT by -400 frames to shrink V2 from the right.
local out_edge_frame = 800
local press_x  = env.x_of(out_edge_frame) - 3
local delta_px = env.x_of(out_edge_frame - 400) - env.x_of(out_edge_frame)

local h = env.mouse_handler(widget)
h({ type = "press",   x = press_x, y = v2_mid_y, button = 1,
    shift = false, alt = false, ctrl = false, command = false })
h({ type = "move",    x = press_x - 6, y = v2_mid_y, button = 1,
    shift = false, alt = false, ctrl = false, command = false })
h({ type = "move",    x = press_x + delta_px, y = v2_mid_y, button = 1,
    shift = false, alt = false, ctrl = false, command = false })
env.pump(150)

-- The dry-run must have executed.
local ds = state_module.get_active_edge_drag_state()
assert(ds, "no active edge drag state after gesture")
assert(ds.preview_clamped_delta_frames ~= nil,
    "preview_clamped_delta_frames not set — dry-run did not run")

-- The downstream propagation (-400) is blocked by V1's 200-frame gap,
-- so the pipeline clamps to -200. The applied delta should also be
-- clamped in magnitude.
assert(math.abs(ds.preview_clamped_delta_frames) <= 400, string.format(
    "expected clamped delta magnitude ≤ 400 (sanity check); got %s",
    tostring(ds.preview_clamped_delta_frames)))

-- The implied-limiter dim factor matches edge_drag_renderer.lua's constant.
local IMPLIED_EDGE_DIM_FACTOR = 0.55
local colors = env.colors()
local limit_color = assert(colors.edge_selected_limit,
    "timeline_state.colors.edge_selected_limit missing")
local dimmed_limit_color = color_utils.dim_hex(limit_color, IMPLIED_EDGE_DIM_FACTOR)

-- Count dimmed-limit-color rects within V1's track band (where clip_A lives).
local function count_dimmed_in_band(band)
    local n = 0
    for _, r in ipairs(env.rects(widget, dimmed_limit_color)) do
        if r.y >= band.y and r.y <= band.y + band.height then
            n = n + 1
        end
    end
    return n
end

local v1_dimmed = count_dimmed_in_band(v1_band)
assert(v1_dimmed > 0, string.format(
    "expected at least one dimmed-limit-color rect (%s) on V1 band "
    .. "(clip_A:out is the unselected blocker); found 0 in %d draw commands",
    dimmed_limit_color, #env.draw_commands(widget)))

-- Clean up
h({ type = "release", x = press_x + delta_px, y = v2_mid_y, button = 1,
    shift = false, alt = false, ctrl = false, command = false })
env.pump(80)

print("✅ test_edge_limit_unselected.lua passed")
