--- During a ripple drag, tracks that shift as a CONSEQUENCE of the drag
-- (no edge of theirs selected) render implied edge handles in a dimmed
-- available color ON THEIR OWN BAND — the editor's cue for "this track
-- moves too". The handle must sit at that track's shifting boundary,
-- not on the dragged track.
--
-- Layout: V1 clip [0,1000) — gap — clip [2000,3000); V2 clip [2000,3000).
-- Dragging V1's gap in-edge left by 200 frames ripples V2's clip.
-- Expect: implied (dimmed) handle rects inside V2's band.
--
-- Converted from test_timeline_implied_edge_preview.lua, which mocked
-- command_manager.get_executor to FABRICATE the whole preview payload —
-- it never exercised the real preview computation. This version drives
-- the real drag pipeline end to end and is the regression test for the
-- cross-track bug where non-lead preview edges resolved to the lead
-- track's clip and rendered on the wrong band.
--
-- Run: ./build/bin/jve.app/Contents/MacOS/jve --test tests/synthetic/integration/batch_timeline_render.lua

local env = require("synthetic.integration.timeline_render.render_env")
local color_utils = require("ui.color_utils")

print("=== test_implied_edge_preview ===")

env.boot()

print("  A: ripple-shifted track renders implied handle at its boundary")
local seq = env.fresh_sequence("Implied Edge Preview")
local tracks = env.tracks()
assert(tracks.V1 and tracks.V2, "need V1 and V2 tracks")

env.place_clips(seq, {
    { track_id = tracks.V1.id, position = 0,    duration = 700 },
    { track_id = tracks.V1.id, position = 2000, duration = 700 },
    { track_id = tracks.V2.id, position = 2000, duration = 700 },
})
env.view_frames(3500, 0)

local widget = env.video_widget()

-- Locate both tracks' bands from real painted clip rects (V1's first
-- clip spans x_of(0)..x_of(700); V2's clip shares V1's second clip's x
-- span but sits in a different band).
local function find_bands()
    local v1_l, v1_r = env.x_of(0), env.x_of(700)
    local c2_l, c2_r = env.x_of(2000), env.x_of(2700)
    local v1_band, bands_at_c2 = nil, {}
    for _, r in ipairs(env.rects(widget)) do
        if r.height > 10 then
            if math.abs(r.x - v1_l) < 8 and math.abs((r.x + r.width) - v1_r) < 8 then
                v1_band = r
            elseif math.abs(r.x - c2_l) < 8 and math.abs((r.x + r.width) - c2_r) < 8 then
                bands_at_c2[#bands_at_c2 + 1] = r
            end
        end
    end
    assert(v1_band, "V1 first clip rect not found")
    local v2_band = nil
    for _, r in ipairs(bands_at_c2) do
        if math.abs(r.y - v1_band.y) > 4 then v2_band = r end
    end
    assert(v2_band, "V2 clip rect not found in a different band than V1")
    return v1_band, v2_band
end
local v1_band, v2_band = find_bands()

-- Real ripple drag: press 5px inside V1's first clip near its out-edge
-- (±3px of the boundary is the ROLL zone — roll doesn't ripple; ≥5px
-- picks the single edge in ripple mode), threshold move, then drag
-- left 200 frames. Rippling the out-edge leftward shifts all
-- downstream content left, including V2's clip — the implied-edge case.
local h = env.mouse_handler(widget)
local boundary_x = env.x_of(700)
local press_x = boundary_x - 5
local v1_mid = v1_band.y + v1_band.height / 2
local delta_px = env.x_of(700 - 200) - boundary_x

h({ type = "press", x = press_x, y = v1_mid, button = 1,
    shift = false, alt = false, ctrl = false, command = false })
h({ type = "move",  x = press_x - 6, y = v1_mid, button = 1,
    shift = false, alt = false, ctrl = false, command = false })
h({ type = "move",  x = press_x + delta_px, y = v1_mid, button = 1,
    shift = false, alt = false, ctrl = false, command = false })
env.pump(150)

-- While the drag is live: V2's band must contain implied handle rects
-- in the dimmed available color AT THE SHIFTING BOUNDARY — V2's content
-- boundary at frame 2000, drawn at its dragged position (2000 - 200).
-- A handle elsewhere on the band (e.g. at x=0, the leading gap's
-- in-edge) means the implied edge was anchored to the wrong clip/edge.
local available = assert(env.colors().edge_selected_available,
    "colors.edge_selected_available missing")
local implied_color = color_utils.dim_hex(available, 0.55)
local boundary_px = env.x_of(2000 - 200)

local at_boundary, elsewhere = 0, {}
for _, r in ipairs(env.rects(widget, implied_color)) do
    local cy = r.y + r.height / 2
    if cy >= v2_band.y and cy <= v2_band.y + v2_band.height then
        local near = math.min(math.abs(r.x - boundary_px),
                              math.abs((r.x + r.width) - boundary_px))
        if near < 12 then
            at_boundary = at_boundary + 1
        else
            elsewhere[#elsewhere + 1] = string.format("x=%.0f", r.x)
        end
    end
end

h({ type = "release", x = press_x + delta_px, y = v1_mid, button = 1,
    shift = false, alt = false, ctrl = false, command = false })
env.pump(50)

assert(at_boundary > 0, string.format(
    "ripple-shifted V2 must render implied (dimmed) edge handles at its "
    .. "shifting boundary (x≈%.0f) — found none there; stray implied rects "
    .. "on V2 band at [%s]",
    boundary_px, table.concat(elsewhere, " ")))
print("    OK")

------------------------------------------------------------------------
-- Scenario B: implied edge that LIMITS the drag renders in the dimmed
-- LIMIT color at the clamped position.
--
-- Layout: V1 clip [0,1700) — gap — clip [4500,5200)  (2800 slack)
--         V2 clip [0,1400) — gap — clip [2000,2700)  ( 600 slack)
--
-- Dragging V1's out-edge (frame 1700) left 1000 frames must clamp at
-- -600: V2's downstream clip collides with V2's upstream clip at 1400.
-- V2 is the binding limiter, so its implied handle renders in the
-- dimmed LIMIT color at x_of(2000 - 600) = x_of(1400).
--
-- Converted from test_timeline_implied_gap_clamp_color.lua, which
-- fabricated the BatchRippleEdit payload (clamp map included) via a
-- mocked executor; this drives the real clamp computation.
------------------------------------------------------------------------
print("  B: limiting implied edge renders in dimmed limit color at clamp")
do
    local seq_b = env.fresh_sequence("Implied Edge Limit Color")
    local tr = env.tracks()
    assert(tr.V1 and tr.V2, "need V1 and V2 tracks")

    env.place_clips(seq_b, {
        { track_id = tr.V1.id, position = 0,    duration = 1700 },
        { track_id = tr.V1.id, position = 4500, duration = 700 },
        { track_id = tr.V2.id, position = 0,    duration = 1400 },
        { track_id = tr.V2.id, position = 2000, duration = 700 },
    })
    env.view_frames(5500, 0)

    local wb = env.video_widget()

    -- Locate V2's downstream clip band [2000,2700) on a different band
    -- than V1's first clip [0,1700).
    local v1_l, v1_r = env.x_of(0), env.x_of(1700)
    local c2_l, c2_r = env.x_of(2000), env.x_of(2700)
    local v1b, v2b = nil, nil
    for _, r in ipairs(env.rects(wb)) do
        if r.height > 10 then
            if math.abs(r.x - v1_l) < 8 and math.abs((r.x + r.width) - v1_r) < 8 then
                v1b = r
            elseif math.abs(r.x - c2_l) < 8 and math.abs((r.x + r.width) - c2_r) < 8 then
                v2b = r
            end
        end
    end
    assert(v1b, "B: V1 first clip rect not found")
    assert(v2b, "B: V2 downstream clip rect not found")
    assert(math.abs(v2b.y - v1b.y) > 4, "B: V2 rect not on a distinct band")

    local hb = env.mouse_handler(wb)
    local bx = env.x_of(1700)
    local px = bx - 5
    local my = v1b.y + v1b.height / 2
    local dpx = env.x_of(1700 - 1000) - bx

    hb({ type = "press", x = px, y = my, button = 1,
         shift = false, alt = false, ctrl = false, command = false })
    hb({ type = "move",  x = px - 6, y = my, button = 1,
         shift = false, alt = false, ctrl = false, command = false })
    hb({ type = "move",  x = px + dpx, y = my, button = 1,
         shift = false, alt = false, ctrl = false, command = false })
    env.pump(150)

    -- The drag must clamp at -600 (V2 collision), not the requested -1000.
    local st = env.context().state
    local ds = st.get_active_edge_drag_state()
    assert(ds, "B: no active edge drag state after gesture")
    assert(ds.preview_clamped_delta_frames == -600, string.format(
        "B: ripple must clamp where V2's clips collide (600 frames of gap); "
        .. "expected clamped delta -600, got %s",
        tostring(ds.preview_clamped_delta_frames)))

    -- V2's implied handle is the limiter: dimmed LIMIT color at the
    -- clamped boundary x_of(2000 - 600).
    local limit = assert(env.colors().edge_selected_limit,
        "colors.edge_selected_limit missing")
    local implied_limit_color = color_utils.dim_hex(limit, 0.55)
    local clamp_px = env.x_of(2000 - 600)

    local hit, strays = 0, {}
    for _, r in ipairs(env.rects(wb, implied_limit_color)) do
        local cy = r.y + r.height / 2
        if cy >= v2b.y and cy <= v2b.y + v2b.height then
            local near = math.min(math.abs(r.x - clamp_px),
                                  math.abs((r.x + r.width) - clamp_px))
            if near < 12 then hit = hit + 1
            else strays[#strays + 1] = string.format("x=%.0f", r.x) end
        end
    end

    hb({ type = "release", x = px + dpx, y = my, button = 1,
         shift = false, alt = false, ctrl = false, command = false })
    env.pump(50)

    assert(hit > 0, string.format(
        "B: limiting track must render implied handles in dimmed LIMIT "
        .. "color at the clamped boundary (x≈%.0f) — found none; "
        .. "limit-colored rects elsewhere on V2 band: [%s]",
        clamp_px, table.concat(strays, " ")))
    print("    OK")
end

print("✅ test_implied_edge_preview.lua passed")
