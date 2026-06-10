--- Starting a drag-selection must not move or resize the timeline panes.
--
-- Bug (Joe, 2026-06-09): dragging to select made everything inside the
-- timeline jump up by roughly a scrollbar's height. The selection
-- rubber band was parented to the video/audio QSplitter, and QSplitter
-- adopts any child widget as a pane — hidden panes are collapsed, so
-- the moment the band became visible the splitter granted it a slice
-- and shrank/shifted the real panes.
--
-- Domain assertion: the panes' on-screen geometry is identical before,
-- during, and after a drag-selection gesture.
--
-- Run: ./build/bin/jve --test tests/synthetic/integration/test_drag_select_no_layout_jump.lua

local ui = require("synthetic.integration.ui_test_env")

print("=== test_drag_select_no_layout_jump ===")

local _, info = ui.launch({
    project_name = "DragSelect Layout Test",
})
local db_path = info.db_path

local panel = require("ui.timeline.timeline_panel")

ui.pump(300)

local video_widget = panel.video_widget
local audio_widget = panel.audio_widget
assert(video_widget and audio_widget, "no timeline view widgets")

local function geom(w)
    local gx, gy = qt_constants.WIDGET.MAP_TO_GLOBAL(w, 0, 0)
    local ww, hh = qt_constants.PROPERTIES.GET_SIZE(w)
    return { gx = gx, gy = gy, w = ww, h = hh }
end

local function assert_same(label, a, b)
    assert(a.gx == b.gx and a.gy == b.gy and a.w == b.w and a.h == b.h,
        string.format(
            "%s: pane moved/resized during drag-select — "
            .. "pos (%d,%d)->(%d,%d) size %dx%d->%dx%d",
            label, a.gx, a.gy, b.gx, b.gy, a.w, a.h, b.w, b.h))
end

local before_v = geom(video_widget)
local before_a = geom(audio_widget)

-- Drive the video view's real registered mouse handler: press in empty
-- timeline space, then drag — the path that shows the rubber band.
local hname = "tl_mouse_" .. tostring(video_widget):gsub("[^%w]", "_")
local handler = _G[hname]
assert(type(handler) == "function", "no mouse handler global " .. hname)

handler({ type = "press", x = 50, y = 40, button = 1 })
handler({ type = "move", x = 130, y = 85, button = 1 })
ui.pump(100)

assert_same("video pane (during drag)", before_v, geom(video_widget))
assert_same("audio pane (during drag)", before_a, geom(audio_widget))
print("  panes stable while the rubber band is visible")

handler({ type = "release", x = 130, y = 85, button = 1 })
ui.pump(100)

assert_same("video pane (after drag)", before_v, geom(video_widget))
assert_same("audio pane (after drag)", before_a, geom(audio_widget))
print("  panes stable after release")

require("synthetic.helpers.blank_project").cleanup(db_path)
ui.cleanup()
print("✅ test_drag_select_no_layout_jump.lua passed")
