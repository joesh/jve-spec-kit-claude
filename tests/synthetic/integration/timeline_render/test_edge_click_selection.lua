--- Domain rules for edge click selection, verified end-to-end against the
-- real app:
--
--   A. Shift-clicking an unselected edge ADDS it to the current selection
--      (toggle-in semantics — the original selected edge stays).
--
--   B. Click-without-drag on a single-edge (ripple) grab narrows a two-edge
--      selection on release: pressing at the edit point in roll mode arms both
--      edges; releasing with no drag and then clicking one side in ripple mode
--      reduces the selection to just that side's edge.
--
--   C. Click-without-drag in the roll zone (boundary ±3 px) does NOT narrow
--      the selection — both edges of the edit point stay selected.
--
-- Replaces: tests/synthetic/lua/test_timeline_edge_clicks.lua
-- (that test stubbed edge_picker.pick_edges and timeline_state directly;
--  this version drives the real gesture pipeline).

local env = require("synthetic.integration.timeline_render.render_env")

print("=== test_edge_click_selection ===")

env.boot()
local state = env.context().state
local widget = env.video_widget()

-- Locate the first non-gap clip's band rect from rendered rects.
local function find_band(left_frame, right_frame)
    local lx = env.x_of(left_frame)
    local rx = env.x_of(right_frame)
    for _, r in ipairs(env.rects(widget)) do
        if r.height > 10
            and math.abs(r.x - lx) < 10
            and math.abs((r.x + r.width) - rx) < 10 then
            return r
        end
    end
    error(string.format(
        "band rect not found for [%d,%d] (lx=%.1f rx=%.1f) in %d cmds",
        left_frame, right_frame, lx, rx, #env.draw_commands(widget)))
end

-- ── Scenario A: Shift-click adds an edge to the selection ─────────────────
-- Setup: two clips with a gap between them. Click the right clip's in-edge
-- (ripple grab, 5px right of boundary) to select 1 edge. Then shift-click
-- the left clip's out-edge → selection grows to 2 edges.
print("  A: shift-click adds edge to selection (does not replace)")
do
    local seq = env.fresh_sequence("EdgeClick A")
    local tracks = env.tracks()
    assert(tracks.V1, "need V1")

    -- Non-trivial layout: clips at [0,300) and [500,800) with a 200-frame gap.
    env.place_clips(seq, {
        { track_id = tracks.V1.id, position = 0,   duration = 300 },
        { track_id = tracks.V1.id, position = 500, duration = 300 },
    })
    env.view_frames(1000, 0)

    local tab = state.get_tab_strip()
    local v1_clips = tab:track_clip_index(tracks.V1.id)
    local clip_left, clip_right = nil, nil
    for _, c in ipairs(v1_clips) do
        if not c.is_gap then
            if c.sequence_start == 0   then clip_left  = c end
            if c.sequence_start == 500 then clip_right = c end
        end
    end
    assert(clip_left,  "A: no clip at frame 0")
    assert(clip_right, "A: no clip at frame 500")

    local h = env.mouse_handler(widget)

    -- Find V1 band mid_y from the left clip.
    local band = find_band(0, 300)
    local mid_y = band.y + band.height / 2

    -- Step 1: ripple-grab the left clip's out-edge (frame 300, press 5px to the left).
    local bx_left_out = env.x_of(300)
    local px1 = bx_left_out - 5
    h({ type = "press",   x = px1, y = mid_y, button = 1,
        shift = false, alt = false, ctrl = false, command = false })
    h({ type = "release", x = px1, y = mid_y, button = 1,
        shift = false, alt = false, ctrl = false, command = false })
    env.pump(80)

    local edges_after_first_click = state.get_selected_edges() or {}
    -- A ripple grab targets exactly one edge (the out-edge of the left clip).
    assert(#edges_after_first_click == 1, string.format(
        "A: ripple click must select exactly 1 edge; got %d",
        #edges_after_first_click))

    -- Step 2: shift-click the right clip's in-edge (frame 500, 5px right).
    local bx_right_in = env.x_of(500)
    local px2 = bx_right_in + 5
    h({ type = "press",   x = px2, y = mid_y, button = 1,
        shift = true, alt = false, ctrl = false, command = false })
    h({ type = "release", x = px2, y = mid_y, button = 1,
        shift = true, alt = false, ctrl = false, command = false })
    env.pump(80)

    local edges_after_shift = state.get_selected_edges() or {}
    assert(#edges_after_shift == 2, string.format(
        "A: shift-click must ADD the second edge (1 → 2 selected); got %d",
        #edges_after_shift))
    print("    OK")
end

-- ── Scenario B: Click-without-drag narrows a two-edge selection on release ─
-- Setup: two adjacent clips sharing an edit point at frame 350.
-- Step 1: roll-grab (press at boundary, ±1px) → two edges selected.
-- Step 2: click 5px to the right (ripple grab of right clip's in-edge), no drag.
-- Expected: release narrows selection to 1 edge.
print("  B: click-without-drag on ripple grab narrows two-edge selection")
do
    local seq = env.fresh_sequence("EdgeClick B")
    local tracks = env.tracks()
    assert(tracks.V1, "need V1")

    -- Adjacent clips at [0,350) and [350,700) — edit point at frame 350.
    env.place_clips(seq, {
        { track_id = tracks.V1.id, position = 0,   duration = 350 },
        { track_id = tracks.V1.id, position = 350, duration = 350 },
    })
    env.view_frames(900, 0)

    local tab = state.get_tab_strip()
    local v1_clips = tab:track_clip_index(tracks.V1.id)
    local clip_a, clip_b = nil, nil
    for _, c in ipairs(v1_clips) do
        if not c.is_gap then
            if c.sequence_start == 0   then clip_a = c end
            if c.sequence_start == 350 then clip_b = c end
        end
    end
    assert(clip_a, "B: no clip at frame 0")
    assert(clip_b, "B: no clip at frame 350")

    local h = env.mouse_handler(widget)
    local band = find_band(0, 350)
    local mid_y = band.y + band.height / 2

    local edit_x = env.x_of(350)

    -- Step 1: roll-grab at ±1px of edit point → picker returns both edges.
    h({ type = "press",   x = edit_x + 1, y = mid_y, button = 1,
        shift = false, alt = false, ctrl = false, command = false })
    h({ type = "release", x = edit_x + 1, y = mid_y, button = 1,
        shift = false, alt = false, ctrl = false, command = false })
    env.pump(80)

    local edges_roll = state.get_selected_edges() or {}
    -- A roll click at the edit point of two adjacent clips selects BOTH
    -- edges (left.out + right.in) — the narrowing precondition.
    assert(#edges_roll == 2, string.format(
        "B: roll click at the edit point must select both edges; got %d",
        #edges_roll))

    -- Step 2: ripple-grab 5px right of edit point (B's in-edge), no drag.
    -- Press (arms potential_drag with picker_target_edges = {B.in}), then
    -- release without any move event → narrowing fires.
    h({ type = "press",   x = edit_x + 5, y = mid_y, button = 1,
        shift = false, alt = false, ctrl = false, command = false })
    h({ type = "release", x = edit_x + 5, y = mid_y, button = 1,
        shift = false, alt = false, ctrl = false, command = false })
    env.pump(80)

    local edges_after_ripple_click = state.get_selected_edges() or {}
    assert(#edges_after_ripple_click == 1, string.format(
        "B: ripple click-without-drag must narrow the 2-edge selection to "
        .. "exactly the clicked side; got %d edge(s)",
        #edges_after_ripple_click))
    assert(edges_after_ripple_click[1].clip_id == clip_b.id, string.format(
        "B: narrowed edge should belong to clip_b (frame 350); got clip_id=%s",
        tostring(edges_after_ripple_click[1].clip_id)))
    print("    OK")
end

-- ── Scenario C: Roll-zone click does NOT narrow selection on release ────────
-- Setup: same two adjacent clips. Roll-grab the edit point → 2 edges selected.
-- Click exactly at the edit point (roll zone, 0..1px offset) and release.
-- Expected: selection count unchanged (picker returned both; #target == #current).
print("  C: roll-zone click preserves both edges on release")
do
    local seq = env.fresh_sequence("EdgeClick C")
    local tracks = env.tracks()
    assert(tracks.V1, "need V1")

    env.place_clips(seq, {
        { track_id = tracks.V1.id, position = 0,   duration = 420 },
        { track_id = tracks.V1.id, position = 420, duration = 380 },
    })
    env.view_frames(1000, 0)

    local h = env.mouse_handler(widget)
    local band = find_band(0, 420)
    local mid_y = band.y + band.height / 2
    local edit_x = env.x_of(420)

    -- First click: establish a two-edge roll selection at the edit point.
    h({ type = "press",   x = edit_x, y = mid_y, button = 1,
        shift = false, alt = false, ctrl = false, command = false })
    h({ type = "release", x = edit_x, y = mid_y, button = 1,
        shift = false, alt = false, ctrl = false, command = false })
    env.pump(80)

    local edges_first = state.get_selected_edges() or {}
    assert(#edges_first == 2, string.format(
        "C: click at the edit point must select both edges (roll); got %d",
        #edges_first))
    local count_first = #edges_first

    -- Second click at same exact position (roll zone).
    h({ type = "press",   x = edit_x, y = mid_y, button = 1,
        shift = false, alt = false, ctrl = false, command = false })
    h({ type = "release", x = edit_x, y = mid_y, button = 1,
        shift = false, alt = false, ctrl = false, command = false })
    env.pump(80)

    local edges_second = state.get_selected_edges() or {}
    -- Roll-zone click: picker returns both edges (same as current selection).
    -- Narrowing condition: #target < #current → false, so selection unchanged.
    assert(#edges_second == count_first, string.format(
        "C: roll-zone click-without-drag changed selection count from %d to %d "
        .. "(narrowing must not fire when picker returns full selection)",
        count_first, #edges_second))
    print("    OK")
end

print("✅ test_edge_click_selection.lua passed")
