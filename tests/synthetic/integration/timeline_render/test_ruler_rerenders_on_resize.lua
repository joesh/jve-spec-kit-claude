--- When the ruler widget is resized (e.g. the headers column is dragged),
-- the ruler must re-render so that time-position indicators (playhead
-- triangle, tick labels) are placed at pixel positions computed from the NEW
-- width.  Without a resize hook, the ruler retains stale commands at the old
-- width, resulting in two visible playhead glyphs: one from the timeline view
-- (which already listens for resize) and one stale one from the ruler.
--
-- Domain rule: after any resize the ruler's draw-command queue must contain
-- at least one command that references the new width (i.e. the queue was
-- cleared and rebuilt at the new size, not left over from the old render).
-- We verify this by:
--   1. reading the ruler widget width before resize
--   2. resizing the ruler widget to a different width
--   3. confirming the draw-command count is non-zero (ruler re-rendered)
--   4. confirming that at least one rect spans up to (or near) the new width,
--      which is only possible if `timeline.get_dimensions` returned the new
--      width to the render function
--
-- Converted from tests/synthetic/lua/test_ruler_rerenders_on_resize.lua
-- (which stubbed _G.timeline and timeline_ruler directly) — this version
-- uses the real ruler widget exposed as timeline_panel.ruler_widget.
--
-- Run: ./build/bin/jve.app/Contents/MacOS/jve --test tests/synthetic/integration/batch_timeline_render.lua

local env = require("synthetic.integration.timeline_render.render_env")

print("=== test_ruler_rerenders_on_resize ===")

env.boot()
-- Use a fresh sequence so timeline state is clean.
env.fresh_sequence("Ruler Resize Test")
env.pump(100)

local panel       = env.context().panel
local ruler_widget = assert(panel.ruler_widget,
    "timeline_panel.ruler_widget is nil — panel must expose its ruler widget")

-- Current width before resize.
local w0 = select(1, qt_constants.PROPERTIES.GET_SIZE(ruler_widget))
assert(type(w0) == "number" and w0 > 0,
    "ruler_widget: GET_SIZE returned no valid width before resize")

-- Choose a new width that is meaningfully different from the current one.
-- We shrink by 200 px; the ruler is inside an Expanding layout so it must
-- accept explicit sizes via SET_SIZE (same as layout.lua at startup).
local w1 = w0 - 200
assert(w1 >= 80, string.format(
    "ruler widget starting width (%d) is too narrow to shrink by 200 px "
    .. "— adjust test constants", w0))

-- Resize the widget.  Qt's resizeEvent fires synchronously on SET_SIZE;
-- the ruler's registered resize handler calls render() which calls
-- timeline.clear_commands + rebuild.
qt_constants.PROPERTIES.SET_SIZE(ruler_widget, w1, 32)
env.pump(100)

-- Ruler must have re-rendered: command count must be non-zero.
local cmds_after = env.draw_commands(ruler_widget)
assert(#cmds_after > 0, string.format(
    "ruler_widget: no draw commands after resize from %d→%d px — "
    .. "ruler did not re-render; the resize handler is not wired",
    w0, w1))

-- At least one rect must reach near the new width (within 2 px).
-- The ruler draws a full-width background rect as its first command;
-- that rect's width must equal w1 if the render used the new size.
local found_full_width = false
for _, cmd in ipairs(cmds_after) do
    if cmd.type == "rect" and math.abs((cmd.x + cmd.width) - w1) <= 2 then
        found_full_width = true
        break
    end
end
assert(found_full_width, string.format(
    "ruler_widget: no rect reaches the new width (%d px) after resize — "
    .. "render may have used the OLD width (%d px) from a stale capture. "
    .. "Playhead and tick positions would be wrong.\n"
    .. "Commands drawn: %d",
    w1, w0, #cmds_after))

print(string.format(
    "  ruler re-rendered after resize (%d→%d px): %d draw commands, "
    .. "full-width rect confirmed",
    w0, w1, #cmds_after))
print("✅ test_ruler_rerenders_on_resize.lua passed")
