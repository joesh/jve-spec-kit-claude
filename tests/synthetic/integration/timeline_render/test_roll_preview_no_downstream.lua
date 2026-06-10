--- Domain rule: a roll edit trims one clip's out-edge and the adjacent
-- clip's in-edge symmetrically — it does NOT shift any downstream content.
-- Therefore the renderer must NOT paint yellow preview rectangles at
-- downstream clip positions during a roll drag.  The participating
-- clip edges (those being rolled) DO get yellow outlines.
--
-- Layout (V1): clip [0,1000) — gap [1000,2000) — clip [2000,1000)
--              — downstream clip [3600,800) (not a roll participant)
-- Lead edge: roll trim on gap in-edge (frame 1000) + clip in-edge
--   (frame 2000) together, delta -200 frames.
-- Domain rule: yellow rect near frame 3600 (downstream) must NOT appear.
--   Yellow rects near the roll zone (frames 1000..2000) MUST appear.
--
-- Converted from test_timeline_roll_preview_no_downstream.lua (which
-- used ripple_layout and stubbed _G.timeline).
--
-- Run via: ./build/bin/jve.app/Contents/MacOS/jve --test
--   tests/synthetic/integration/batch_timeline_render.lua

local env = require("synthetic.integration.timeline_render.render_env")

print("=== test_roll_preview_no_downstream ===")

env.boot()

local seq = env.fresh_sequence("RollPreviewNoDownstream")
local tracks = env.tracks()
assert(tracks.V1, "need V1 track")

-- V1: clip [0,1000) — gap [1000,2000) — clip [2000,1000) — clip [3600,800)
env.place_clips(seq, {
    { track_id = tracks.V1.id, position = 0,    duration = 1000 },
    { track_id = tracks.V1.id, position = 2000, duration = 1000 },
    { track_id = tracks.V1.id, position = 3600, duration = 400  },
})
env.view_frames(4800, 0)

local widget  = env.video_widget()

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

-- The gap spans [1000,2000); its in-edge is at frame 1000.
-- The clip [2000,1000) has its in-edge at frame 2000.
-- A roll drag picks BOTH edges when pressing in the roll zone between
-- frame 1000 and frame 2000 near the boundary.  Press 3px right of
-- frame 1000 (inside the gap) — the edge picker should pick the gap's
-- in-edge in roll mode; the adjacent clip's in-edge is co-selected.
local roll_frame = 1000
local delta_frames = -200
local press_x   = env.x_of(roll_frame) + 3
local delta_px  = env.x_of(roll_frame + delta_frames) - env.x_of(roll_frame)
local dir_sign  = (delta_px >= 0) and 1 or -1

local h = env.mouse_handler(widget)
h({ type = "press",  x = press_x, y = v1_mid_y, button = 1,
    shift = false, alt = false, ctrl = false, command = false })
h({ type = "move",   x = press_x + dir_sign * 6, y = v1_mid_y, button = 1,
    shift = false, alt = false, ctrl = false, command = false })
h({ type = "move",   x = press_x + delta_px, y = v1_mid_y, button = 1,
    shift = false, alt = false, ctrl = false, command = false })
env.pump(150)

-- The drag must have engaged (active edge drag state present).
local ds = env.context().state.get_active_edge_drag_state()
assert(ds, "no active edge drag state after roll gesture")
assert(ds.preview_data ~= nil or ds.preview_clamped_delta_frames ~= nil,
    "roll drag must produce preview data")

local yellow_rects = env.rects(widget, "#ffff00")
assert(#yellow_rects > 0,
    "roll drag must produce at least one yellow rect for the participating edges")

-- Domain rule: no yellow rect near the downstream clip's position (3600).
local downstream_px = env.x_of(3600)
for _, r in ipairs(yellow_rects) do
    local near_downstream = math.abs(r.x - downstream_px) < 5
                         or math.abs((r.x + r.width) - downstream_px) < 5
    assert(not near_downstream, string.format(
        "roll preview must not highlight downstream clip; "
        .. "found yellow rect at x=%.1f near downstream_px=%.1f",
        r.x, downstream_px))
end

h({ type = "release", x = press_x + delta_px, y = v1_mid_y, button = 1,
    shift = false, alt = false, ctrl = false, command = false })
env.pump(80)

print("✅ test_roll_preview_no_downstream.lua passed")
