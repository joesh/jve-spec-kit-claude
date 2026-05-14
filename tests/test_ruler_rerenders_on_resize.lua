#!/usr/bin/env luajit

-- Regression: dragging the headers-column width changes the ruler widget's
-- width via Qt's layout, but the ruler renders on Lua state-change listeners
-- only — it had no resize hook. So `time_to_pixel(playhead, width)` kept
-- using the previous frame's `width`, leaving the playhead glyph at its old
-- pixel x while the timeline view (which DOES re-render on resize) drew the
-- new x. Visible as two red playhead lines (Joe 2026-05-14).
--
-- Black-box: stub the C++ timeline surface, instantiate the ruler, capture
-- the global handler name registered via timeline.set_resize_event_handler,
-- invoke it, and assert that the ruler re-drew its commands using the
-- current widget width.

require("test_env")

print("=== test_ruler_rerenders_on_resize.lua ===")

local widget_width = 400
local registered_resize_handler = nil
local registered_mouse_handler = nil
local clear_calls = 0
local last_lines_at_width = {}   -- width -> count of add_line() calls in that render

_G.timeline = {
    get_dimensions = function() return widget_width, 32 end,
    clear_commands = function()
        clear_calls = clear_calls + 1
        last_lines_at_width[widget_width] = 0
    end,
    add_rect      = function() end,
    add_line      = function()
        last_lines_at_width[widget_width] = (last_lines_at_width[widget_width] or 0) + 1
    end,
    add_triangle  = function() end,
    add_text      = function() end,
    update        = function() end,
    set_lua_state = function() end,
    set_mouse_event_handler  = function(_w, name) registered_mouse_handler = name end,
    set_resize_event_handler = function(_w, name) registered_resize_handler = name end,
    set_desired_height = function() end,
}

package.loaded["core.logger"] = {
    for_area = function() return {
        event = function() end, detail = function() end,
        warn = function() end, error = function() end,
    } end,
}

-- Minimal state_module surface required by timeline_ruler.render()
local frame_utils = require("core.frame_utils")
local state_module = {
    colors = { playhead = "#ff6b6b", mark_range_edge = "#ff0000" },
    get_viewport_start_time = function() return 0 end,
    get_viewport_duration   = function() return 240 end,
    get_playhead_position   = function() return 120 end,  -- center of viewport
    get_sequence_frame_rate = function() return frame_utils.default_frame_rate end,
    get_display_mark_in     = function() return nil end,
    get_display_mark_out    = function() return nil end,
    get_mark_in             = function() return nil end,
    get_mark_out            = function() return nil end,
    time_to_pixel = function(t, w)
        local dur = 240
        return math.floor(t * w / dur)
    end,
    pixel_to_time = function(px, w) return math.floor(px * 240 / w) end,
    add_listener = function() end,
    is_dragging_playhead = function() return false end,
    set_dragging_playhead = function() end,
    set_playhead_position = function() end,
    snap_frame = function(_, f) return f end,
    get_ghost_mark = function() return nil end,
}

local timeline_ruler = require("ui.timeline.timeline_ruler")
local ruler = timeline_ruler.create({ _type = "ruler_widget" }, state_module)
assert(ruler, "ruler.create returned nil")

assert(registered_resize_handler ~= nil,
    "FAIL: ruler must register a resize handler with timeline.set_resize_event_handler "
    .. "so it re-renders when its widget is resized by the headers-column width drag")
assert(type(_G[registered_resize_handler]) == "function",
    "FAIL: registered resize handler '" .. tostring(registered_resize_handler)
    .. "' is not a callable global")

-- Sanity: initial render drew at width 400 with at least one line (playhead).
assert((last_lines_at_width[400] or 0) >= 1,
    "test setup: expected initial render at width 400 to draw at least one line")

-- Simulate the Qt resize: widget gets wider because the headers column shrank.
widget_width = 700
local clears_before = clear_calls
_G[registered_resize_handler]({ width = widget_width, height = 32 })
assert(clear_calls > clears_before, string.format(
    "FAIL: resize handler must trigger a re-render (clear_commands call). "
    .. "clears before=%d after=%d", clears_before, clear_calls))
assert((last_lines_at_width[700] or 0) >= 1,
    "FAIL: ruler must redraw using NEW widget width 700 after resize; "
    .. "no draw commands recorded at that width. The playhead-x calc reads "
    .. "the live widget width, so a missing re-render leaves the old glyph in place.")

print("  ruler registered resize handler — OK")
print("  resize triggered re-render at new width — OK")
print("\n✅ test_ruler_rerenders_on_resize.lua passed")
