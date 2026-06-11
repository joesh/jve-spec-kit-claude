--- Domain rule: Opt/Alt-pressing on an ALREADY-SELECTED clip must not change
-- the selection. The press should arm a duplicate-drag against the existing
-- selection, not re-run SelectClips (which would expand to the whole link
-- group and clobber a deliberate partial selection).
-- Corollary: Opt-pressing on an UNSELECTED clip DOES change the selection
-- (normal SelectClips dispatch with alt-expansion).
--
-- Replaces: tests/synthetic/lua/test_opt_drag_preserves_selection.lua
-- (that test stubbed command_manager and package.loaded["ui.focus_manager"];
--  this version drives the real app).

local env = require("synthetic.integration.timeline_render.render_env")

print("=== test_opt_drag_preserves_selection ===")

env.boot()
local state = env.context().state
local widget = env.video_widget()

-- ── Scenario A: Opt-press on an ALREADY-SELECTED clip ─────────────────────
-- Domain: selection is preserved; no link-group expansion.
print("  A: opt-press on already-selected clip preserves selection")
do
    local seq = env.fresh_sequence("OptDrag A")
    local tracks = env.tracks()
    assert(tracks.V1, "need V1")

    -- Place one clip at frame 100, duration 200 (non-trivial offsets).
    env.place_clips(seq, {
        { track_id = tracks.V1.id, position = 100, duration = 200 },
    })
    env.view_frames(600, 0)

    local h = env.mouse_handler(widget)

    -- Normal left-click (no modifiers) to select the clip.
    local clip_cx = env.x_of(100 + 100)  -- centre of the clip
    local tab = state.get_tab_strip()
    local v1_clips = tab:track_clip_index(tracks.V1.id)
    local placed = nil
    for _, c in ipairs(v1_clips) do
        if not c.is_gap then placed = c; break end
    end
    assert(placed, "A: no real clip on V1 after placement")

    -- Find band y for click.
    local band_lx = env.x_of(placed.sequence_start)
    local band_rx = env.x_of(placed.sequence_start + placed.duration)
    local band = nil
    for _, r in ipairs(env.rects(widget)) do
        if r.height > 10
            and math.abs(r.x - band_lx) < 10
            and math.abs((r.x + r.width) - band_rx) < 10 then
            band = r; break
        end
    end
    assert(band, "A: clip band rect not found in draw commands")
    local mid_y = band.y + band.height / 2

    -- Plain click to select.
    h({ type = "press",   x = clip_cx, y = mid_y, button = 1,
        shift = false, alt = false, ctrl = false, command = false })
    h({ type = "release", x = clip_cx, y = mid_y, button = 1,
        shift = false, alt = false, ctrl = false, command = false })
    env.pump(80)

    local selected_before = state.get_selected_clips()
    local is_selected = false
    for _, c in ipairs(selected_before) do
        if c.id == placed.id then is_selected = true; break end
    end
    assert(is_selected, "A: clip was not selected by plain click")
    local count_before = #selected_before

    -- Now alt-press on the SAME already-selected clip.
    h({ type = "press", x = clip_cx, y = mid_y, button = 1,
        shift = false, alt = true, ctrl = false, command = false })
    env.pump(50)

    -- Selection must be unchanged.
    local selected_after = state.get_selected_clips()
    assert(#selected_after == count_before, string.format(
        "A: selection count changed from %d to %d after alt-press on selected clip "
        .. "(link-group expansion must not fire)",
        count_before, #selected_after))

    local still_there = false
    for _, c in ipairs(selected_after) do
        if c.id == placed.id then still_there = true; break end
    end
    assert(still_there, "A: original clip was deselected by alt-press")

    -- Release to end.
    h({ type = "release", x = clip_cx, y = mid_y, button = 1,
        shift = false, alt = true, ctrl = false, command = false })
    env.pump(50)
    print("    OK")
end

-- ── Scenario B: Opt-press on an UNSELECTED clip changes selection ──────────
-- Domain: alt-expansion fires on a new click; selection changes to the clip
-- (and potentially its link group, which is empty in this synthetic fixture).
print("  B: opt-press on unselected clip changes selection")
do
    local seq = env.fresh_sequence("OptDrag B")
    local tracks = env.tracks()
    assert(tracks.V1, "need V1")

    env.place_clips(seq, {
        { track_id = tracks.V1.id, position = 73, duration = 137 },
    })
    env.view_frames(500, 0)

    local h = env.mouse_handler(widget)
    local tab = state.get_tab_strip()
    local v1_clips = tab:track_clip_index(tracks.V1.id)
    local placed = nil
    for _, c in ipairs(v1_clips) do
        if not c.is_gap then placed = c; break end
    end
    assert(placed, "B: no real clip on V1")

    -- Confirm nothing is selected to start.
    -- (fresh_sequence clears the timeline; a new sequence starts with empty selection)
    -- There may be residual selection from scenario A on a different seq; clear with
    -- a click on empty space to the right of any clip, then check.
    local empty_x = env.x_of(400)
    local band_lx = env.x_of(placed.sequence_start)
    local band_rx = env.x_of(placed.sequence_start + placed.duration)
    local band = nil
    for _, r in ipairs(env.rects(widget)) do
        if r.height > 10
            and math.abs(r.x - band_lx) < 10
            and math.abs((r.x + r.width) - band_rx) < 10 then
            band = r; break
        end
    end
    assert(band, "B: clip band rect not found")
    local mid_y = band.y + band.height / 2

    -- Click empty space to clear selection.
    h({ type = "press",   x = empty_x, y = mid_y, button = 1,
        shift = false, alt = false, ctrl = false, command = false })
    h({ type = "release", x = empty_x, y = mid_y, button = 1,
        shift = false, alt = false, ctrl = false, command = false })
    env.pump(80)

    -- Now alt-press on the unselected clip.
    local clip_cx = env.x_of(placed.sequence_start + math.floor(placed.duration / 2))
    h({ type = "press", x = clip_cx, y = mid_y, button = 1,
        shift = false, alt = true, ctrl = false, command = false })
    env.pump(50)

    local selected = state.get_selected_clips()
    local clip_now_selected = false
    for _, c in ipairs(selected) do
        if c.id == placed.id then clip_now_selected = true; break end
    end
    assert(clip_now_selected, string.format(
        "B: opt-press on unselected clip did not select it "
        .. "(got %d selected clips)", #selected))

    h({ type = "release", x = clip_cx, y = mid_y, button = 1,
        shift = false, alt = true, ctrl = false, command = false })
    env.pump(50)
    print("    OK")
end

print("✅ test_opt_drag_preserves_selection.lua passed")
