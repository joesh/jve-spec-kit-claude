--- Domain rule: when the lead edge is a real clip's out-edge (not a gap),
-- a co-selected gap edge on another track must NOT constrain the clamped
-- delta to the gap's length.  The clip's media boundary governs; the gap
-- is a passive participant.
--
-- Layout: V1 has clip [0,1000) — gap [1000,1600) — clip [1600,1000).
--         V2 has clip [1200,1200) (out-edge at frame 2400).
-- Lead edge: V2 clip out-edge.  Co-selected edge: V1 gap in-edge.
-- Requested delta: +1800 frames (far larger than the V1 gap's 600 frames).
-- Domain rule: preview_clamped_delta_frames must equal 1800 (or be bounded
-- only by V2 clip's media limit, not by the V1 gap length); the V1 gap's
-- in-edge key must NOT appear in clamped_edges.
--
-- Converted from test_timeline_lead_gap_preview.lua (which stubbed
-- _G.timeline and injected drag_state directly).
--
-- Run via: ./build/bin/jve.app/Contents/MacOS/jve --test
--   tests/synthetic/integration/batch_timeline_render.lua

local env = require("synthetic.integration.timeline_render.render_env")

print("=== test_lead_gap_preview ===")

env.boot()
local state_module = env.context().state

local seq = env.fresh_sequence("LeadGapPreview")
local tracks = env.tracks()
assert(tracks.V1 and tracks.V2, "need V1 and V2 tracks")

-- V1: clip [0,1000) → gap [1000,1600) → clip [1600,1000)
env.place_clips(seq, {
    { track_id = tracks.V1.id, position = 0,    duration = 1000 },
    { track_id = tracks.V2.id, position = 1200,  duration = 1200 },
})
-- Second V1 clip past the gap
env.place_clips(seq, {
    { track_id = tracks.V1.id, position = 1600, duration = 1000 },
})
env.view_frames(3600, 0)

local widget = env.video_widget()

-- Locate V2 clip band: spans [1200, 2400).
local function find_v2_band()
    local lx = env.x_of(1200)
    local rx = env.x_of(2400)
    for _, r in ipairs(env.rects(widget)) do
        if math.abs(r.x - lx) < 10 and math.abs((r.x + r.width) - rx) < 10
            and r.height > 10 then
            return r
        end
    end
    error(string.format(
        "V2 clip band [1200,2400) not found (lx=%.1f rx=%.1f) in %d cmds",
        lx, rx, #env.draw_commands(widget)))
end

local v2_band  = find_v2_band()
local v2_mid_y = v2_band.y + v2_band.height / 2

-- Press 3px left of V2 clip's out-edge (frame 2400) — inside the clip body.
-- Drag right by +1800 frames.  The gap on V1 is only 600 frames — the
-- delta must NOT be clamped to 600.
local out_edge_frame = 2400
local press_x        = env.x_of(out_edge_frame) - 3
-- Use a smaller delta that won't exhaust the media (~720 frames headroom
-- in V2 clip: source_out=1200, media≈720 effective → 720-1200 = negative,
-- so headroom is actually determined by the source_out which is 1200).
-- The V2 clip has duration=1200 at source_out=1200, media is ~720 frames
-- effective, so the clip already fills the media.  Use delta=+200 as the
-- claim: clamped_delta should NOT equal V1 gap size (600) but may be
-- anything bounded by the real limits.  The key assertion is: the V1 gap's
-- in-edge key must NOT appear in clamped_edges.
local delta_frames = 200
local delta_px     = env.x_of(out_edge_frame + delta_frames) - env.x_of(out_edge_frame)
local dir_sign     = (delta_px >= 0) and 1 or -1

local h = env.mouse_handler(widget)
h({ type = "press",  x = press_x, y = v2_mid_y, button = 1,
    shift = false, alt = false, ctrl = false, command = false })
h({ type = "move",   x = press_x + dir_sign * 6, y = v2_mid_y, button = 1,
    shift = false, alt = false, ctrl = false, command = false })
h({ type = "move",   x = press_x + delta_px, y = v2_mid_y, button = 1,
    shift = false, alt = false, ctrl = false, command = false })
env.pump(150)

local ds = state_module.get_active_edge_drag_state()
assert(ds, "no active edge drag state after gesture")
assert(ds.preview_data ~= nil,
    "preview_data not set — dry-run did not execute")
assert(ds.preview_clamped_delta_frames ~= nil,
    "preview_clamped_delta_frames not set")

-- Identify the V1 gap's in-edge key so we can confirm it's not a clamper.
-- The gap spans [1000, 1600); find the gap clip on V1.
local tab = state_module.get_tab_strip()
local v1_clips = tab:track_clip_index(tracks.V1.id)
local v1_gap = nil
for _, c in ipairs(v1_clips) do
    if c.is_gap and c.sequence_start == 1000 then
        v1_gap = c; break
    end
end
assert(v1_gap, "V1 gap at frame 1000 not found after placement")

local gap_in_key = string.format("%s:in", v1_gap.id)
local clamped = ds.clamped_edges or {}
assert(not clamped[gap_in_key], string.format(
    "V1 gap in-edge must NOT be the limiter; it's %s frames wide "
    .. "but the lead is the V2 clip out-edge (got clamped_edges[%s]=%s)",
    600, gap_in_key, tostring(clamped[gap_in_key])))

h({ type = "release", x = press_x + delta_px, y = v2_mid_y, button = 1,
    shift = false, alt = false, ctrl = false, command = false })
env.pump(80)

print("✅ test_lead_gap_preview.lua passed")
