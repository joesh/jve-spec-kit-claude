--- Binding contract: timeline.get_commands reads back the REAL pending
-- draw-command queue of a TimelineRenderer widget.
--
-- This is the witness that lets renderer tests run against the real
-- widget instead of stubbing the `timeline` global (Joe, 2026-06-09:
-- "get rid of stubs and mocks and use the real jve wherever possible").
-- Tests assert on what will actually be painted — the queue the C++
-- painter consumes — produced through the real bindings.
--
-- Run: ./build/bin/jve.app/Contents/MacOS/jve --test tests/synthetic/binding/test_timeline_get_commands.lua

print("=== test_timeline_get_commands ===")

assert(type(qt_constants) == "table", "must run via jve --test")

local widget = qt_constants.WIDGET.CREATE_TIMELINE()
assert(widget, "CREATE_TIMELINE returned nothing")

-- Queue one command of each shape with non-trivial float coordinates.
timeline.clear_commands(widget)
timeline.add_rect(widget, 10.5, 20, 30.25, 40, "#4a90e2")
timeline.add_line(widget, 1.5, 2, 3, 4.75, "#ff0000", 2)
timeline.add_text(widget, 5, 6, "label text", "#ffffff")
timeline.add_triangle(widget, 0, 0, 10, 0, 5, 8, "#00ff00")

local cmds = timeline.get_commands(widget)
assert(type(cmds) == "table", "get_commands must return a table")
assert(#cmds == 4, "queued 4 commands, got " .. tostring(#cmds))

-- Order is paint order.
local r, l, t, tri = cmds[1], cmds[2], cmds[3], cmds[4]

assert(r.type == "rect", "cmd1 type: " .. tostring(r.type))
assert(r.x == 10.5 and r.y == 20 and r.width == 30.25 and r.height == 40,
    string.format("rect coords round-trip: x=%s y=%s w=%s h=%s",
        tostring(r.x), tostring(r.y), tostring(r.width), tostring(r.height)))
assert(r.color == "#4a90e2", "rect color: " .. tostring(r.color))

assert(l.type == "line", "cmd2 type: " .. tostring(l.type))
assert(l.x == 1.5 and l.y == 2 and l.x2 == 3 and l.y2 == 4.75,
    "line coords round-trip")
assert(l.color == "#ff0000", "line color: " .. tostring(l.color))
assert(l.line_width == 2, "line width: " .. tostring(l.line_width))

assert(t.type == "text", "cmd3 type: " .. tostring(t.type))
assert(t.text == "label text", "text content: " .. tostring(t.text))
assert(t.x == 5 and t.y == 6, "text coords round-trip")

assert(tri.type == "triangle", "cmd4 type: " .. tostring(tri.type))
assert(tri.x3 == 5 and tri.y3 == 8, "triangle third point round-trip")

-- clear empties the queue.
timeline.clear_commands(widget)
local after = timeline.get_commands(widget)
assert(type(after) == "table" and #after == 0,
    "queue must be empty after clear_commands, got " .. tostring(#after))

print("✅ test_timeline_get_commands.lua passed")
