--- Domain rule: when a single gap edge is dragged by a delta that would
-- push the downstream clip before the timeline origin (frame 0), the
-- preview must clamp at frame 0 — the shifted_clips entry must report
-- new_start_value == 0, not a negative frame.
--
-- Layout (V2 only): gap [0,2000) — clip [2000,500).
-- Lead edge: V2 gap's out-edge (frame 2000) dragged LEFT by -3000 frames
--   in RIPPLE mode (far past the 2000-frame gap width and the timeline
--   start).  After clamp the downstream clip can shift at most 2000
--   frames leftward, landing at frame 0.
--
-- Gesture: press 5px LEFT of the gap out-edge (frame 2000) — outside
--   the ±3px roll zone → picks only the gap's out-edge alone with
--   trim_type="ripple" (not a roll pair).
--
-- Domain rule: preview_data.shifted_clips must contain the V2 clip
--   with new_start_value == 0 (clamped at timeline start).
--
-- Converted from test_timeline_single_gap_preview_clamp.lua (which
-- used ripple_layout, stubbed _G.timeline, and read preview_data
-- directly from view.drag_state).
--
-- Run via: ./build/bin/jve.app/Contents/MacOS/jve --test
--   tests/synthetic/integration/batch_timeline_render.lua

local env = require("synthetic.integration.timeline_render.render_env")

print("=== test_single_gap_preview_clamp ===")

env.boot()
local state_module = env.context().state

local seq = env.fresh_sequence("SingleGapPreviewClamp")
local tracks = env.tracks()
assert(tracks.V2, "need V2 track")

-- V2: clip at [2000, 500) — the leading gap [0,2000) is implicit.
env.place_clips(seq, {
    { track_id = tracks.V2.id, position = 2000, duration = 500 },
})
env.view_frames(3200, 0)

local widget = env.video_widget()

-- Find V2 clip band from [2000, 2500).
local function find_v2_band()
    local lx = env.x_of(2000)
    local rx = env.x_of(2500)
    for _, r in ipairs(env.rects(widget)) do
        if math.abs(r.x - lx) < 10 and math.abs((r.x + r.width) - rx) < 10
            and r.height > 10 then
            return r
        end
    end
    error(string.format(
        "V2 band [2000,2500) not found (lx=%.1f rx=%.1f) in %d cmds",
        lx, rx, #env.draw_commands(widget)))
end

local v2_band  = find_v2_band()
local v2_mid_y = v2_band.y + v2_band.height / 2

-- The leading gap's out-edge is at frame 2000.  Press 5px LEFT of it
-- (inside the gap body) — outside the ±3px roll zone → picks only the
-- gap's out-edge with trim_type="ripple".
-- Drag left by -3000 frames (far past the 2000-frame gap and origin).
local gap_out_frame = 2000
local delta_frames  = -3000
local press_x       = env.x_of(gap_out_frame) - 5
-- Pixel target: clamp to x=0 since the delta extends far off-screen left.
local raw_target    = press_x + (env.x_of(gap_out_frame + delta_frames) - env.x_of(gap_out_frame))
local target_x      = math.max(raw_target, 0)
local dir_sign      = -1

local h = env.mouse_handler(widget)
h({ type = "press",  x = press_x, y = v2_mid_y, button = 1,
    shift = false, alt = false, ctrl = false, command = false })
h({ type = "move",   x = press_x + dir_sign * 6, y = v2_mid_y, button = 1,
    shift = false, alt = false, ctrl = false, command = false })
h({ type = "move",   x = target_x, y = v2_mid_y, button = 1,
    shift = false, alt = false, ctrl = false, command = false })
env.pump(150)

local ds = state_module.get_active_edge_drag_state()
assert(ds, "no active edge drag state after gesture")
assert(ds.preview_data ~= nil,
    "preview_data not set — dry-run did not execute")

-- Identify the V2 clip so we can assert on its shifted entry.
local tab    = state_module.get_tab_strip()
local v2_clips = tab:track_clip_index(tracks.V2.id)
local v2_clip = nil
for _, c in ipairs(v2_clips) do
    if not c.is_gap then v2_clip = c; break end
end
assert(v2_clip, "no real clip on V2 after placement")

-- Find the shifted_clips entry for the V2 clip.
local shifted_lookup = {}
for _, entry in ipairs(ds.preview_data.shifted_clips or {}) do
    shifted_lookup[entry.clip_id] = entry
end

local clip_shift = shifted_lookup[v2_clip.id]
assert(clip_shift, string.format(
    "preview_data.shifted_clips must contain an entry for V2 clip %s; "
    .. "got %d shifted entries",
    tostring(v2_clip.id):sub(1, 12), #(ds.preview_data.shifted_clips or {})))

assert(clip_shift.new_start_value == 0, string.format(
    "clamped preview must stop at timeline start (frame 0); "
    .. "got new_start_value=%s",
    tostring(clip_shift.new_start_value)))

h({ type = "release", x = target_x, y = v2_mid_y, button = 1,
    shift = false, alt = false, ctrl = false, command = false })
env.pump(80)

print("✅ test_single_gap_preview_clamp.lua passed")
