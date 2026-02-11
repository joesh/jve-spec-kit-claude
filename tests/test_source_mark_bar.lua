require('test_env')

-- Test source_mark_bar mouse interaction and rendering
-- Verifies: click-to-seek, drag, resize re-render, frame conversion

print("=== Test Source Mark Bar ===")

-- Mock global timeline drawing API
local draw_log = {}
local mock_widget_width = 400
_G.timeline = {
    get_dimensions = function() return mock_widget_width, 20 end,
    clear_commands = function() table.insert(draw_log, "clear") end,
    add_rect = function(_, x, y, w, h, color)
        table.insert(draw_log, {type="rect", x=x, y=y, w=w, h=h, color=color})
    end,
    add_line = function(_, x1, y1, x2, y2, color, lw)
        table.insert(draw_log, {type="line", x1=x1, y1=y1, x2=x2, y2=y2, color=color})
    end,
    add_triangle = function(_, x1, y1, x2, y2, x3, y3, color)
        table.insert(draw_log, {type="triangle", x1=x1, y1=y1, x3=x3, y3=y3, color=color})
    end,
    add_text = function() end,
    update = function() table.insert(draw_log, "update") end,
    set_lua_state = function() end,
    set_mouse_event_handler = function() end,
    set_resize_event_handler = function() end,
}

-- Mock logger
package.loaded["core.logger"] = {
    info = function() end,
    debug = function() end,
    warn = function() end,
    error = function() end,
}

-- Mock database (no DB in this test)
package.loaded["core.database"] = {
    has_connection = function() return false end,
    load_clip_marks = function() return nil end,
    save_clip_marks = function() end,
}

-- Track viewer_panel.show_frame calls (direct video seek)
local show_frame_calls = {}
package.loaded["ui.viewer_panel"] = {
    show_frame = function(frame_idx)
        table.insert(show_frame_calls, frame_idx)
    end,
    has_media = function() return true end,
}

-- Track playback_controller calls
local pc_calls = {}
local mock_pc = {
    timeline_mode = false,
    is_playing = function() return false end,
    stop = function() table.insert(pc_calls, "stop") end,
    set_position = function(frame)
        table.insert(pc_calls, {type="set_position", frame=frame})
    end,
}
package.loaded["core.playback.playback_controller"] = mock_pc

-- Load modules fresh
package.loaded["ui.source_viewer_state"] = nil
local source_viewer_state = require("ui.source_viewer_state")

package.loaded["ui.source_mark_bar"] = nil
local source_mark_bar = require("ui.source_mark_bar")

print("\n--- Section 1: Create & Resize Rendering ---")

print("\nTest 1.1: Create mark bar")
local mock_widget = {}
local bar = source_mark_bar.create(mock_widget)
assert(bar, "create should return bar table")
assert(bar.widget == mock_widget, "bar.widget should be the passed widget")
assert(type(bar.render) == "function", "bar should have render function")
assert(type(bar.on_mouse_event) == "function", "bar should have on_mouse_event function")
print("  ✓ mark bar created")

print("\nTest 1.2: Render without clip shows background only")
draw_log = {}
bar.render()
assert(draw_log[1] == "clear", "Should clear commands first")
assert(draw_log[#draw_log] == "update", "Should call update last")
local rect_count = 0
for _, cmd in ipairs(draw_log) do
    if type(cmd) == "table" and cmd.type == "rect" then rect_count = rect_count + 1 end
end
assert(rect_count == 1, "Should draw only background rect without clip, got " .. rect_count)
print("  ✓ no-clip render is background only")

print("\nTest 1.3: Render with clip shows playhead")
-- IS-a refactor: has_clip() checks current_sequence_id, not current_clip_id
source_viewer_state.current_sequence_id = "test_masterclip_1"
source_viewer_state.total_frames = 100
source_viewer_state.fps_num = 30
source_viewer_state.fps_den = 1
source_viewer_state.playhead = 50
source_viewer_state.mark_in = nil
source_viewer_state.mark_out = nil

draw_log = {}
bar.render()

local has_triangle = false
local has_line = false
for _, cmd in ipairs(draw_log) do
    if type(cmd) == "table" then
        if cmd.type == "triangle" then has_triangle = true end
        if cmd.type == "line" then has_line = true end
    end
end
assert(has_triangle, "Should draw playhead triangle")
assert(has_line, "Should draw playhead line")
print("  ✓ clip render shows playhead")

print("\nTest 1.4: Playhead at frame 50 of 100 renders at midpoint")
local triangle_cmd = nil
for _, cmd in ipairs(draw_log) do
    if type(cmd) == "table" and cmd.type == "triangle" then
        triangle_cmd = cmd
        break
    end
end
assert(triangle_cmd, "Should have triangle command")
assert(triangle_cmd.x3 == 200,
    string.format("Playhead triangle should be at x=200, got x=%d", triangle_cmd.x3))
print("  ✓ playhead at correct pixel position")

print("\nTest 1.5: Render with marks shows mark handles + range fill")
source_viewer_state.mark_in = 20
source_viewer_state.mark_out = 80

draw_log = {}
bar.render()

rect_count = 0
for _, cmd in ipairs(draw_log) do
    if type(cmd) == "table" and cmd.type == "rect" then rect_count = rect_count + 1 end
end
assert(rect_count == 5,
    string.format("Should draw 5 rects (bg+strip+range+2 handles), got %d", rect_count))
print("  ✓ marks render correctly")

print("\nTest 1.6: Render with zero-width widget is no-op")
local saved_width = mock_widget_width
mock_widget_width = 0
draw_log = {}
bar.render()
assert(#draw_log == 0, "Should not draw anything with zero width")
mock_widget_width = saved_width
print("  ✓ zero-width render is safe no-op")

print("\n--- Section 2: Click → Show Frame ---")

print("\nTest 2.1: Click at midpoint calls viewer_panel.show_frame(50)")
source_viewer_state.playhead = 0
show_frame_calls = {}

bar.on_mouse_event("press", 200, 10, 1, {})

assert(source_viewer_state.playhead == 50,
    string.format("Playhead should be 50, got %d", source_viewer_state.playhead))
assert(#show_frame_calls >= 1,
    "Should call viewer_panel.show_frame at least once")
assert(show_frame_calls[1] == 50,
    string.format("show_frame should be called with 50, got %s", tostring(show_frame_calls[1])))
print("  ✓ click calls show_frame(50)")

print("\nTest 2.2: Click at x=0 shows frame 0")
show_frame_calls = {}
bar.on_mouse_event("press", 0, 10, 1, {})
assert(#show_frame_calls >= 1, "Should call show_frame")
assert(show_frame_calls[1] == 0,
    string.format("show_frame should be called with 0, got %s", tostring(show_frame_calls[1])))
print("  ✓ click at x=0 → show_frame(0)")

print("\nTest 2.3: Click at x=399 shows frame near end")
show_frame_calls = {}
bar.on_mouse_event("press", 399, 10, 1, {})
assert(#show_frame_calls >= 1, "Should call show_frame")
assert(show_frame_calls[1] >= 98,
    string.format("show_frame should be >= 98, got %s", tostring(show_frame_calls[1])))
print("  ✓ click at end → near last frame")

print("\nTest 2.4: Click stops playback if playing")
mock_pc.is_playing = function() return true end
pc_calls = {}
bar.on_mouse_event("press", 200, 10, 1, {})
local found_stop = false
for _, call in ipairs(pc_calls) do
    if call == "stop" then found_stop = true end
end
assert(found_stop, "Should stop playback on click")
mock_pc.is_playing = function() return false end
print("  ✓ click stops playback")

print("\nTest 2.5: Click in timeline_mode STILL shows frame (mark bar is source-only)")
mock_pc.timeline_mode = true
show_frame_calls = {}
source_viewer_state.playhead = 0

bar.on_mouse_event("press", 200, 10, 1, {})

assert(#show_frame_calls >= 1,
    "show_frame MUST be called even in timeline_mode (mark bar is source viewer)")
assert(show_frame_calls[1] == 50,
    string.format("show_frame should be 50 in timeline_mode, got %s",
        tostring(show_frame_calls[1])))
mock_pc.timeline_mode = false
print("  ✓ timeline_mode does NOT block show_frame")

print("\n--- Section 3: Drag ---")

print("\nTest 3.1: Drag updates playhead and shows frame continuously")
source_viewer_state.playhead = 0
show_frame_calls = {}

bar.on_mouse_event("press", 100, 10, 1, {})   -- frame 25
assert(source_viewer_state.playhead == 25,
    string.format("After press at 100: expected 25, got %d", source_viewer_state.playhead))

bar.on_mouse_event("move", 200, 10, 1, {})    -- frame 50
assert(source_viewer_state.playhead == 50,
    string.format("After drag to 200: expected 50, got %d", source_viewer_state.playhead))

bar.on_mouse_event("move", 300, 10, 1, {})    -- frame 75
assert(source_viewer_state.playhead == 75,
    string.format("After drag to 300: expected 75, got %d", source_viewer_state.playhead))

bar.on_mouse_event("release", 300, 10, 1, {})

-- Move after release should NOT update
show_frame_calls = {}
bar.on_mouse_event("move", 100, 10, 1, {})
assert(source_viewer_state.playhead == 75,
    "Move after release should not update playhead")
assert(#show_frame_calls == 0,
    "Move after release should not call show_frame")
print("  ✓ drag updates continuously, release stops")

print("\nTest 3.2: Each drag move calls show_frame")
show_frame_calls = {}
bar.on_mouse_event("press", 100, 10, 1, {})
bar.on_mouse_event("move", 200, 10, 1, {})
bar.on_mouse_event("move", 300, 10, 1, {})
bar.on_mouse_event("release", 300, 10, 1, {})
-- press(25) + move(50) + move(75) = 3 show_frame calls
assert(#show_frame_calls == 3,
    string.format("Should have 3 show_frame calls during drag, got %d", #show_frame_calls))
print("  ✓ drag seeks on every move")

print("\n--- Section 4: Edge Cases ---")

print("\nTest 4.1: Click without clip loaded is no-op")
-- IS-a refactor: has_clip() checks current_sequence_id
source_viewer_state.current_sequence_id = nil
source_viewer_state.total_frames = 0
show_frame_calls = {}
pc_calls = {}
bar.on_mouse_event("press", 200, 10, 1, {})
assert(#show_frame_calls == 0, "Should not call show_frame without clip")
assert(#pc_calls == 0, "Should not call playback_controller without clip")
print("  ✓ no-clip click is safe no-op")

print("\n✅ test_source_mark_bar.lua passed")
