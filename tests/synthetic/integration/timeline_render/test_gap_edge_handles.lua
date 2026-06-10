--- Selecting a gap clip's edge renders trim handles at the gap boundary.
--
-- Layout (real commands): clip [0,1000) — gap [1000,2000) — clip [2000,3000)
-- on V1. Clicking just inside the gap near a boundary selects that
-- boundary's edges (real input path); the renderer must draw at least
-- one handle rect in the edge-selected color near the boundary's pixel
-- position, for both the gap's in edge and its out edge.
--
-- Converted from tests/synthetic/lua/test_timeline_view_gap_edge_render.lua
-- (which stubbed the timeline global, the state module, and the view) —
-- this version drives the real app and reads the real draw-command queue.
--
-- Run: ./build/bin/jve.app/Contents/MacOS/jve --test tests/synthetic/integration/batch_timeline_render.lua

local env = require("synthetic.integration.timeline_render.render_env")

print("=== test_gap_edge_handles ===")

env.boot()
local seq = env.fresh_sequence("Gap Edge Handles")
local tracks = env.tracks()
assert(tracks.V1, "no V1 track in fresh sequence")

env.place_clips(seq, {
    { track_id = tracks.V1.id, position = 0,    duration = 1000 },
    { track_id = tracks.V1.id, position = 2000, duration = 1000 },
})
env.view_frames(3500, 0)

local state = env.context().state
local widget = env.video_widget()

-- Locate the V1 track band from the REAL painted geometry: the first
-- clip's body rect spans x_of(0)..x_of(1000); its y/height is the band.
local function find_clip_band()
    local left, right = env.x_of(0), env.x_of(1000)
    for _, r in ipairs(env.rects(widget)) do
        if math.abs(r.x - left) < 8 and math.abs((r.x + r.width) - right) < 8
            and r.height > 10 then
            return r
        end
    end
    error(string.format(
        "clip body rect not found between x=%.1f and x=%.1f in %d draw commands",
        left, right, #env.draw_commands(widget)))
end
local band = find_clip_band()
local mid_y = band.y + band.height / 2

local edge_color = assert(env.colors().edge_selected_available,
    "timeline_state.colors.edge_selected_available missing")

-- Click just inside the gap near a boundary; assert a handle rect in the
-- edge-selected color renders near that boundary's pixel position.
local function assert_handles_near(click_x, boundary_frame, label)
    env.click(widget, click_x, mid_y)
    local edges = state.get_selected_edges()
    assert(#edges > 0, label .. ": click selected no edges "
        .. string.format("(x=%.1f y=%.1f)", click_x, mid_y))

    local boundary_x = env.x_of(boundary_frame)
    local handles = {}
    for _, r in ipairs(env.rects(widget, edge_color)) do
        if r.width >= 2 then handles[#handles + 1] = r end
    end
    assert(#handles > 0, label .. ": no handle rects in the edge-selected color")

    local nearest = math.huge
    for _, r in ipairs(handles) do
        nearest = math.min(nearest,
            math.min(math.abs(r.x - boundary_x),
                     math.abs((r.x + r.width) - boundary_x)))
    end
    assert(nearest < 20, string.format(
        "%s: nearest handle edge is %.1fpx from the boundary at x=%.1f",
        label, nearest, boundary_x))
end

-- Gap in edge: boundary at frame 1000, click 3px inside the gap.
assert_handles_near(env.x_of(1000) + 3, 1000, "gap in-edge")

-- Gap out edge: boundary at frame 2000, click 3px inside the gap.
assert_handles_near(env.x_of(2000) - 3, 2000, "gap out-edge")

print("✅ test_gap_edge_handles.lua passed")
