--- Domain rule: downstream preview outlines are CONTOURED — they follow
-- actual per-track clip positions, NOT a single bbox spanning the full
-- shift extent.  Clips whose pixel gap is smaller than 1/20 of the
-- viewport width COALESCE into one outline run (visual smoothing).
-- Runs entirely outside the visible viewport are CULLED.
--
-- Three properties pinned:
--   A. Large gap between two clips → two separate outlines (not bridged).
--   B. Small gap between two clips → one merged outline.
--   C. Off-screen content → not outlined at all.
--
-- Layout (V1, viewport 0..6000 frames at real widget width W px;
-- coalesce threshold = W/20 px):
--   user_clip  [100, 300)   — user drags out-edge left by -100 frames
--   close_a    [1000, 1100) — downstream; shifts to [900, 1000)
--   close_b    [1300, 1400) — downstream; shifts to [1200, 1300)
--     gap between shifted close_a end (1000) and shifted close_b start (1200)
--     = 200 frames → must be below threshold → MERGED into one run
--   far        [3000, 3100) — downstream; shifts to [2900, 3000)
--     gap from shifted close_b end (1300) to shifted far start (2900)
--     = 1600 frames → must be above threshold → SEPARATE outline
--
-- Gesture: press 5px LEFT of the out-edge (frame 300) to stay outside
-- the ±3px roll zone and pick the out-edge alone with trim_type="ripple".
--
-- Converted from test_timeline_ripple_preview_contoured_runs.lua (which
-- used ripple_layout, Clip.create, and a stubbed _G.timeline).
--
-- Run via: ./build/bin/jve.app/Contents/MacOS/jve --test
--   tests/synthetic/integration/batch_timeline_render.lua

local env = require("synthetic.integration.timeline_render.render_env")

print("=== test_ripple_preview_contoured_runs ===")

env.boot()

local seq = env.fresh_sequence("RipplePreviewContoured")
local tracks = env.tracks()
assert(tracks.V1, "need V1 track")

-- Place user_clip and downstream clips.  All durations are well within
-- the ≈720-frame media limit at 24 fps.
env.place_clips(seq, {
    { track_id = tracks.V1.id, position = 100,  duration = 200  }, -- user_clip
    { track_id = tracks.V1.id, position = 1000, duration = 100  }, -- close_a
    { track_id = tracks.V1.id, position = 1300, duration = 100  }, -- close_b
    { track_id = tracks.V1.id, position = 3000, duration = 100  }, -- far
})

-- Viewport: 6000 frames, real widget width.
env.view_frames(6000, 0)

local widget = env.video_widget()
local W      = env.widget_width(widget)

-- Verify coalesce relationships hold at the real widget width.
local px_per_frame         = W / 6000
local coalesce_threshold   = W / 20
local gap_close_px         = 200 * px_per_frame   -- close_a end (1000) → close_b start (1200) after shift
local gap_far_px           = 1600 * px_per_frame  -- close_b end (1300) → far start (2900) after shift

assert(gap_close_px < coalesce_threshold, string.format(
    "close gap (%.1f px) must be below coalesce threshold (%.1f px); "
    .. "adjust viewport if widget is very narrow",
    gap_close_px, coalesce_threshold))
assert(gap_far_px > coalesce_threshold, string.format(
    "far gap (%.1f px) must exceed coalesce threshold (%.1f px)",
    gap_far_px, coalesce_threshold))

-- Find V1 band from user_clip [100,300).
local function find_v1_band()
    local lx = env.x_of(100)
    local rx = env.x_of(300)
    for _, r in ipairs(env.rects(widget)) do
        if math.abs(r.x - lx) < 10 and math.abs((r.x + r.width) - rx) < 10
            and r.height > 10 then
            return r
        end
    end
    error(string.format(
        "V1 user_clip band [100,300) not found (lx=%.1f rx=%.1f) in %d cmds",
        lx, rx, #env.draw_commands(widget)))
end

local v1_band  = find_v1_band()
local v1_mid_y = v1_band.y + v1_band.height / 2
local V1_Y     = v1_band.y
local V1_H     = v1_band.height

-- Drag user_clip's out-edge (frame 300) left by -100 frames.
-- Press 5px LEFT of the out-edge — outside the ±3px roll zone →
-- picks only the out-edge with trim_type="ripple".
-- Downstream clips shift LEFT by -100:
--   close_a: [1000,1100) → [900,1000)
--   close_b: [1300,1400) → [1200,1300)
--   far:     [3000,3100) → [2900,3000)
local out_edge_frame = 300
local delta_frames   = -100
local press_x        = env.x_of(out_edge_frame) - 5
local delta_px       = env.x_of(out_edge_frame + delta_frames) - env.x_of(out_edge_frame)
local dir_sign       = (delta_px >= 0) and 1 or -1

local h = env.mouse_handler(widget)
h({ type = "press",  x = press_x, y = v1_mid_y, button = 1,
    shift = false, alt = false, ctrl = false, command = false })
h({ type = "move",   x = press_x + dir_sign * 6, y = v1_mid_y, button = 1,
    shift = false, alt = false, ctrl = false, command = false })
h({ type = "move",   x = press_x + delta_px, y = v1_mid_y, button = 1,
    shift = false, alt = false, ctrl = false, command = false })
env.pump(150)

-- Collect yellow rects confined to V1's band.
local function in_v1_band(r)
    return r.y >= V1_Y and r.y < V1_Y + V1_H
end
local v1_yellow = {}
for _, r in ipairs(env.rects(widget, "#ffff00")) do
    if in_v1_band(r) then v1_yellow[#v1_yellow + 1] = r end
end
assert(#v1_yellow > 0, "expected yellow preview rects in V1 band after drag")

-- Pixel boundaries for the two expected outline groups (shifted positions).
local group1_left  = env.x_of(900)    -- close_a shifted start
local group1_right = env.x_of(1300)   -- close_b shifted end
local group2_left  = env.x_of(2900)   -- far shifted start
local group2_right = env.x_of(3000)   -- far shifted end

local function approx(a, b, tol) return math.abs(a - b) <= (tol or 2) end

-- Property A+B: a single merged top or bottom stroke spanning
-- group1_left..group1_right (height ≤ 4 = outline thickness × 2).
local found_group1 = false
for _, r in ipairs(v1_yellow) do
    if approx(r.x, group1_left) and approx(r.x + r.width, group1_right)
       and r.height <= 4 then
        found_group1 = true; break
    end
end
assert(found_group1, string.format(
    "expected ONE merged outline stroke spanning close_a+close_b "
    .. "(x=%.1f..%.1f, height<=4); 200-frame gap (%.1f px) is below "
    .. "coalesce threshold (%.1f px)",
    group1_left, group1_right, gap_close_px, coalesce_threshold))

-- Property B (separate): a distinct top or bottom stroke for the far clip.
local found_group2 = false
for _, r in ipairs(v1_yellow) do
    if approx(r.x, group2_left) and approx(r.x + r.width, group2_right)
       and r.height <= 4 then
        found_group2 = true; break
    end
end
assert(found_group2, string.format(
    "expected a SEPARATE outline for far clip (x=%.1f..%.1f, height<=4); "
    .. "1600-frame gap (%.1f px) exceeds coalesce threshold (%.1f px)",
    group2_left, group2_right, gap_far_px, coalesce_threshold))

-- Property A (no bridge): no thin horizontal rect spans continuously
-- from group1_left all the way to group2_left or beyond.
for _, r in ipairs(v1_yellow) do
    if r.x <= group1_left + 2 and (r.x + r.width) >= group2_left - 2
       and r.height <= 4 then
        error(string.format(
            "found bridging outline (x=%.1f w=%.1f) across the %.1f-px gap "
            .. "— above-threshold gaps must split into separate runs",
            r.x, r.width, gap_far_px))
    end
end

-- Property C (culling): no outline extends past the visible viewport.
local viewport_right_px = env.x_of(6000)
for _, r in ipairs(v1_yellow) do
    assert(r.x + r.width <= viewport_right_px + 4, string.format(
        "yellow rect (x=%.1f w=%.1f) extends past viewport right (%.1f) "
        .. "— off-screen runs must be culled",
        r.x, r.width, viewport_right_px))
end

h({ type = "release", x = press_x + delta_px, y = v1_mid_y, button = 1,
    shift = false, alt = false, ctrl = false, command = false })
env.pump(80)

print("✅ test_ripple_preview_contoured_runs.lua passed")
