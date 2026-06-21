-- Unit: FR-001 through-edit chevron rendering (spec 025).
--
-- DOMAIN RULE: at every cut where two adjacent same-track clips form a
-- through-edit, the renderer draws TWO inward-pointing red triangles whose
-- tips meet on the cut line — and ONLY on the Record tab (the Source tab
-- shows a raw master, never a through-edit). Non-through-edit cuts and cuts
-- scrolled out of the viewport draw nothing.
--
-- Black-box at the render-phase boundary: we feed clips + a tab kind and
-- assert the emitted triangle primitives, without standing up Qt.

require("test_env")

local renderer = require("ui.timeline.view.timeline_view_renderer")

print("=== test_through_edit_chevrons.lua ===")

local MARKER = "#ff6b6b"

-- Capture every timeline.add_triangle into a list the test can inspect.
local function install_capture()
    local calls = {}
    _G.timeline = {
        add_triangle = function(_w, x1, y1, x2, y2, x3, y3, color)
            calls[#calls + 1] = { x1 = x1, y1 = y1, x2 = x2, y2 = y2, x3 = x3, y3 = y3, color = color }
        end,
    }
    return calls
end

-- A predicate-shaped clip on a video track.
local function vclip(start, dur, src_in, src_out, master)
    return {
        sequence_start = start, duration = dur,
        source_in = src_in, source_out = src_out,
        master_layer_track_id = master, master_audio_track_id = nil,
    }
end

-- Build a ctx + stub state_module for the chevron phase. `clips` is the
-- single track's clip list; `kind` the displayed tab kind.
local function make_ctx(clips, tab_kind, viewport_start, viewport_end)
    local state_module = {
        colors = { through_edit_marker = MARKER },
        time_to_pixel = function(frame, _w) return frame end,  -- identity px==frame
        get_tab_strip = function()
            return {
                get_displayed     = function() return { kind = tab_kind } end,
                track_clip_index  = function(_id) return clips end,
            }
        end,
    }
    return {
        view = { filtered_tracks = { { id = "t1" } }, widget = "W" },
        state_module = state_module,
        layout_by_id = { t1 = { y = 0, height = 50, track_type = "VIDEO" } },
        height = 100,
        viewport_start = viewport_start or 0,
        viewport_end = viewport_end or 100000,
    }
end

-- (A) Record tab, three contiguous same-source clips → 2 cuts → 4 triangles.
do
    local clips = {
        vclip(0,   100, 0,   100, "m"),
        vclip(100, 100, 100, 200, "m"),
        vclip(200, 100, 200, 300, "m"),
    }
    local calls = install_capture()
    renderer._render_through_edit_markers(make_ctx(clips, "record"))
    assert(#calls == 4, string.format(
        "two through-edit cuts must draw 4 triangles (2 each); got %d", #calls))
    local tips = {}
    for _, c in ipairs(calls) do
        assert(c.color == MARKER, "chevrons must use the through-edit marker color")
        tips[c.x1] = (tips[c.x1] or 0) + 1   -- x1 is the tip (on the cut line)
    end
    assert(tips[100] == 2 and tips[200] == 2,
        "each cut (frame 100 and 200) must get exactly two tips on the cut line")
    print("  PASS: 3-clip chain → 4 chevrons, tips on the two cut lines")
end

-- (B) Source tab → no chevrons (through-edits never show on a raw master).
do
    local clips = {
        vclip(0,   100, 0,   100, "m"),
        vclip(100, 100, 100, 200, "m"),
    }
    local calls = install_capture()
    renderer._render_through_edit_markers(make_ctx(clips, "source"))
    assert(#calls == 0, "Source tab must draw no through-edit chevrons")
    print("  PASS: Source tab draws nothing")
end

-- (C) Adjacent but different source → not a through-edit → no chevrons.
do
    local clips = {
        vclip(0,   100, 0,   100, "m1"),
        vclip(100, 100, 100, 200, "m2"),   -- different master track
    }
    local calls = install_capture()
    renderer._render_through_edit_markers(make_ctx(clips, "record"))
    assert(#calls == 0, "different-source adjacent clips are not a through-edit → no chevrons")
    print("  PASS: different-source cut draws nothing")
end

-- (D) A through-edit cut scrolled out of the viewport draws nothing.
do
    local clips = {
        vclip(0,   100, 0,   100, "m"),
        vclip(100, 100, 100, 200, "m"),
    }
    local calls = install_capture()
    -- viewport [300, 400] excludes the cut at frame 100.
    renderer._render_through_edit_markers(make_ctx(clips, "record", 300, 400))
    assert(#calls == 0, "a cut outside the viewport must not draw chevrons")
    print("  PASS: off-viewport cut culled")
end

_G.timeline = nil
print("✅ test_through_edit_chevrons.lua passed")
