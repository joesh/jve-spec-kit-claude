--- Domain rule: dragging a clip's in-edge rightward past the clip's own
-- out-edge is forbidden; the preview must clamp at the minimum clip
-- duration (1 frame / full-duration delete-equivalent) rather than
-- allowing the clip to shrink to zero or negative length.
--
-- Scenario: a 5-frame clip at [0,5) on V1.  Dragging its in-edge +1000
-- frames (far past the out-edge at frame 5) must produce a clamped delta
-- equal to the clip's duration (5 frames) — the maximum rightward motion
-- before the clip is annihilated.
--
-- Converted from test_timeline_edge_min_duration_clamp.lua (which set up
-- a 5-frame ripple_layout clip and called renderer.render(view) directly
-- with a fake view and stubbed _G.timeline).  This version drives the
-- real app through the mouse handler.
--
-- Run via: ./build/bin/jve.app/Contents/MacOS/jve --test
--   tests/synthetic/integration/batch_timeline_render.lua

local env = require("synthetic.integration.timeline_render.render_env")

print("=== test_edge_min_duration_clamp ===")

env.boot()
local state_module = env.context().state

-- Place a very short clip (5 frames) and zoom so it occupies visible pixels.
-- view_frames(60, 0) at widget ~1600px → 5-frame clip ≈ 133px wide.
local seq = env.fresh_sequence("MinDurationClamp")
local tracks = env.tracks()
assert(tracks.V1, "no V1 track")

env.place_clips(seq, {
    { track_id = tracks.V1.id, position = 0, duration = 5 },
})
env.view_frames(60, 0)

local widget = env.video_widget()

-- Locate the 5-frame clip's band by its pixel span [x_of(0), x_of(5)).
local function find_band()
    local lx = env.x_of(0)
    local rx = env.x_of(5)
    for _, r in ipairs(env.rects(widget)) do
        if math.abs(r.x - lx) < 10 and math.abs((r.x + r.width) - rx) < 10
            and r.height > 10 then
            return r
        end
    end
    error(string.format(
        "5-frame clip band not found (lx=%.1f rx=%.1f) in %d draw commands",
        lx, rx, #env.draw_commands(widget)))
end

local band   = find_band()
local mid_y  = band.y + band.height / 2

-- Press near the in-edge (frame 0), 3px inside the clip (right of in-edge).
-- Drag +1000 frames worth of pixels rightward.
local in_edge_frame = 0
local press_x  = env.x_of(in_edge_frame) + 3
local delta_px = env.x_of(in_edge_frame + 1000) - env.x_of(in_edge_frame)

local h = env.mouse_handler(widget)
h({ type = "press",   x = press_x, y = mid_y, button = 1,
    shift = false, alt = false, ctrl = false, command = false })
-- Move past 5-px drag threshold
h({ type = "move",    x = press_x + 6, y = mid_y, button = 1,
    shift = false, alt = false, ctrl = false, command = false })
-- Move to extreme rightward position
h({ type = "move",    x = press_x + delta_px, y = mid_y, button = 1,
    shift = false, alt = false, ctrl = false, command = false })
env.pump(150)

-- After the dry-run, preview_clamped_delta_frames must equal the clip's
-- duration (5 frames): the furthest the in-edge can move right before the
-- clip is fully consumed.
local ds = state_module.get_active_edge_drag_state()
assert(ds, "no active edge drag state after gesture")
assert(ds.preview_clamped_delta_frames ~= nil,
    "preview_clamped_delta_frames not set — dry-run did not run")
assert(ds.preview_clamped_delta_frames == 5, string.format(
    "expected in-edge clamp at clip duration (5 frames); got %s",
    tostring(ds.preview_clamped_delta_frames)))

-- The preview data itself must exist (dry-run returned a payload)
assert(ds.preview_data ~= nil,
    "preview_data not populated — dry-run failed to return payload")

-- Clean up
h({ type = "release", x = press_x + delta_px, y = mid_y, button = 1,
    shift = false, alt = false, ctrl = false, command = false })
env.pump(80)

print("✅ test_edge_min_duration_clamp.lua passed")
