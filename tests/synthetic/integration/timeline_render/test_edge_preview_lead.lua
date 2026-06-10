--- Domain rule: when multiple edges are dragged together the renderer
-- must forward the designated "lead edge" (the one the user physically
-- grabbed) to the BatchRippleEdit dry-run.  The lead_edge determines
-- which side drives the delta sign and which constraint wins when edges
-- on opposite brackets are co-selected (e.g. an in+out roll pair or a
-- two-track sync drag).
--
-- Scenario: clip [0,600) on V1; clip [400,600) on V2.
-- Press near V2 clip's in-edge → the input handler picks that edge as the
-- lead and sets view.drag_state.lead_edge accordingly.  After drag + pump,
-- state.get_active_edge_drag_state().lead_edge must match the V2 in-edge.
--
-- Converted from test_timeline_edge_preview_lead.lua (which monkey-patched
-- command_manager.get_executor to intercept the BatchRippleEdit call and
-- capture the lead_edge parameter).  This version reads the real drag state
-- written by the real input handler.
--
-- Run via: ./build/bin/jve.app/Contents/MacOS/jve --test
--   tests/synthetic/integration/batch_timeline_render.lua

local env = require("synthetic.integration.timeline_render.render_env")

print("=== test_edge_preview_lead ===")

env.boot()
local state_module = env.context().state

local seq = env.fresh_sequence("EdgePreviewLead")
local tracks = env.tracks()
assert(tracks.V1 and tracks.V2, "need V1 and V2 tracks")

-- V1: clip [0, 600).  V2: clip [400, 600) — in-edge at frame 400.
env.place_clips(seq, {
    { track_id = tracks.V1.id, position = 0,   duration = 600 },
})
env.place_clips(seq, {
    { track_id = tracks.V2.id, position = 400, duration = 600 },
})
env.view_frames(1400, 0)

local widget = env.video_widget()

-- Find V2 clip's band.  V2 clip spans [x_of(400), x_of(1000)).
local function find_v2_band()
    local lx = env.x_of(400)
    local rx = env.x_of(1000)
    for _, r in ipairs(env.rects(widget)) do
        if math.abs(r.x - lx) < 10 and math.abs((r.x + r.width) - rx) < 10
            and r.height > 10 then
            return r
        end
    end
    error(string.format(
        "V2 clip band [400,1000) not found (lx=%.1f rx=%.1f) in %d cmds",
        lx, rx, #env.draw_commands(widget)))
end

local v2_band = find_v2_band()
local v2_mid_y = v2_band.y + v2_band.height / 2

-- Press 3px to the right of V2 clip's in-edge (frame 400) — inside the clip
-- body, within the 7px edge zone, so the in-edge is picked as the lead.
local in_edge_frame = 400
local press_x  = env.x_of(in_edge_frame) + 3
-- Drag left by 240 frames (shrink from the in side)
local delta_px = -(env.x_of(in_edge_frame + 240) - env.x_of(in_edge_frame))

local h = env.mouse_handler(widget)
h({ type = "press",   x = press_x, y = v2_mid_y, button = 1,
    shift = false, alt = false, ctrl = false, command = false })
h({ type = "move",    x = press_x + 6, y = v2_mid_y, button = 1,
    shift = false, alt = false, ctrl = false, command = false })
h({ type = "move",    x = press_x + delta_px, y = v2_mid_y, button = 1,
    shift = false, alt = false, ctrl = false, command = false })
env.pump(150)

-- The active drag state must record the V2 in-edge as the lead.
local ds = state_module.get_active_edge_drag_state()
assert(ds, "no active edge drag state after gesture")
assert(ds.lead_edge, "drag state has no lead_edge")

-- Find the V2 clip ID so we can assert clip_id match.
local tab = state_module.get_tab_strip()
local v2_clips = tab:track_clip_index(tracks.V2.id)
assert(v2_clips and #v2_clips > 0, "V2 has no clips after placement")
local v2_clip = nil
for _, c in ipairs(v2_clips) do
    if not c.is_gap then v2_clip = c; break end
end
assert(v2_clip, "no real clip on V2")

assert(ds.lead_edge.clip_id == v2_clip.id, string.format(
    "lead_edge.clip_id should be V2 clip (%s); got %s",
    tostring(v2_clip.id):sub(1, 12),
    tostring(ds.lead_edge.clip_id):sub(1, 12)))
assert(ds.lead_edge.edge_type == "in", string.format(
    "lead_edge.edge_type should be 'in'; got %q",
    tostring(ds.lead_edge.edge_type)))

-- The dry-run must have executed (preview_data present).
assert(ds.preview_data ~= nil,
    "preview_data not set — dry-run did not run; lead_edge was not forwarded")

-- Clean up
h({ type = "release", x = press_x + delta_px, y = v2_mid_y, button = 1,
    shift = false, alt = false, ctrl = false, command = false })
env.pump(80)

print("✅ test_edge_preview_lead.lua passed")
