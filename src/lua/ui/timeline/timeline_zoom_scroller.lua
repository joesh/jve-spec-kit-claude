--- Timeline Zoom Scroller
-- Premiere-style horizontal scroller below the track lanes. The thumb
-- mirrors the visible time window within the scrollable extent: its
-- position is the window's left edge, its width the window's duration.
-- Dragging the thumb pans; dragging either END of the thumb stretches
-- or shrinks it — i.e. zooms — with the opposite window edge anchored.
-- Clicking the track outside the thumb pages the window toward the
-- click.
--
-- Custom-painted (same machinery as timeline_ruler): the horizontal
-- axis is virtual time, so no Qt scrollbar fits — QScrollBar has no
-- thumb-end grab zones and its range is a pixel range owned by layout.
--
-- All gestures dispatch through command_manager (ScrollTimelineViewport
-- for pans/pages, ZoomTimelineViewport for thumb-end drags) — the same
-- rebindable paths the wheel uses. The widget is a pure projection of
-- viewport state, re-rendered from the state listener; it never holds
-- scroll/zoom state of its own beyond the in-flight drag capture.
local M = {}
local command_manager = require("core.command_manager")
local profile_scope = require("core.profile_scope")

M.SCROLLER_HEIGHT = 14

local TRACK_COLOR  = "#282828"
local BORDER_COLOR = "#404040"
local THUMB_COLOR  = "#555555"
local HANDLE_COLOR = "#7a7a7a"

local HANDLE_W = 8     -- grab zone at each thumb end (px)
local MIN_THUMB_W = 24 -- visual floor so the thumb stays grabbable
local THUMB_PAD_Y = 2  -- breathing room above/below the thumb

-- Create a zoom scroller on a ScriptableTimeline widget.
-- Parameters:
--   widget: ScriptableTimeline Qt widget (rendering + mouse surface)
--   state_module: reference to timeline_state
function M.create(widget, state_module)
    --- Thumb geometry from viewport state. Returns nil on a blank
    -- panel (no displayed tab) or an unrealized widget (width 0) —
    -- both legitimate "nothing to show" states, not errors.
    -- scale is px per frame against the scrollable extent; the thumb
    -- rect is clamped to MIN_THUMB_W for grabbability (drag math uses
    -- scale, never the clamped rect, so the mapping stays honest).
    local function geometry()
        local width = select(1, timeline.get_dimensions(widget))
        if not width or width <= 0 then return nil end
        local start = state_module.get_viewport_start_time()
        local duration = state_module.get_viewport_duration()
        if not start or not duration then return nil end
        local floor_frame = state_module.get_start_timecode_frame()
        assert(type(floor_frame) == "number",
            "timeline_zoom_scroller: displayed tab has a viewport but no "
            .. "sequence_timecode_start_frame (sequence load did not run)")
        local extent = state_module.get_timeline_extent()
        local total = extent - floor_frame
        assert(total > 0, string.format(
            "timeline_zoom_scroller: non-positive scrollable extent "
            .. "(extent=%d floor=%d)", extent, floor_frame))
        local scale = width / total
        local thumb_w = math.max(MIN_THUMB_W, duration * scale)
        local thumb_x = (start - floor_frame) * scale
        thumb_x = math.max(0, math.min(width - thumb_w, thumb_x))
        return {
            width = width, scale = scale, floor = floor_frame,
            start = start, duration = duration,
            thumb_x = thumb_x, thumb_w = thumb_w,
        }
    end

    local function render()
        if not widget then return end
        timeline.clear_commands(widget)
        local width = select(1, timeline.get_dimensions(widget))
        if not width or width <= 0 then
            timeline.update(widget)
            return
        end
        timeline.add_rect(widget, 0, 0, width, M.SCROLLER_HEIGHT, TRACK_COLOR)
        timeline.add_rect(widget, 0, 0, width, 1, BORDER_COLOR)
        local g = geometry()
        if g then
            local y = THUMB_PAD_Y
            local h = M.SCROLLER_HEIGHT - 2 * THUMB_PAD_Y
            timeline.add_rect(widget, g.thumb_x, y, g.thumb_w, h, THUMB_COLOR)
            timeline.add_rect(widget, g.thumb_x, y, HANDLE_W, h, HANDLE_COLOR)
            timeline.add_rect(widget, g.thumb_x + g.thumb_w - HANDLE_W, y,
                HANDLE_W, h, HANDLE_COLOR)
        end
        timeline.update(widget)
    end

    --- Classify an x position against the thumb. The end zones are
    -- HANDLE_W wide; a thumb too narrow to hold two full handles plus
    -- a pan zone splits into thirds so every gesture stays reachable.
    local function hit_test(x, g)
        if x < g.thumb_x or x >= g.thumb_x + g.thumb_w then
            return "track"
        end
        local zone_w = math.min(HANDLE_W, g.thumb_w / 3)
        if x < g.thumb_x + zone_w then
            return "resize_left"
        end
        if x >= g.thumb_x + g.thumb_w - zone_w then
            return "resize_right"
        end
        return "pan"
    end

    -- In-flight drag capture. Frame targets derive from the
    -- PRESS-time scale and viewport — not the live ones — so the
    -- gesture stays monotonic while the extent shifts under it
    -- (zooming out grows the extent, which would re-scale a live
    -- mapping mid-drag).
    local drag = nil
    local hover_cursor = nil

    local function set_cursor(name)
        if hover_cursor == name then return end
        hover_cursor = name
        -- luacheck: globals qt_set_widget_cursor
        qt_set_widget_cursor(widget, name)
    end

    local function dispatch_pan_to(target_start)
        local current = state_module.get_viewport_start_time()
        if not current then return end
        local delta = target_start - current
        if delta == 0 then return end
        command_manager.execute("ScrollTimelineViewport", {
            delta_frames = delta,
        })
    end

    local function dispatch_zoom(new_duration, anchor_frame)
        if new_duration == state_module.get_viewport_duration() then return end
        command_manager.execute("ZoomTimelineViewport", {
            duration_frames = new_duration,
            anchor_frame = anchor_frame,
        })
    end

    local function on_press(x)
        local g = geometry()
        if not g then return end  -- blank panel: scroller is inert
        local zone = hit_test(x, g)
        if zone == "track" then
            -- Page jump: one window's worth toward the click, standard
            -- scrollbar semantics.
            local direction = (x < g.thumb_x) and -1 or 1
            command_manager.execute("ScrollTimelineViewport", {
                delta_frames = direction * g.duration,
            })
            return
        end
        drag = {
            mode = zone,
            press_x = x,
            start = g.start,
            duration = g.duration,
            scale = g.scale,
        }
    end

    local function on_drag_move(x)
        local dframes = math.floor((x - drag.press_x) / drag.scale + 0.5)
        if drag.mode == "pan" then
            dispatch_pan_to(drag.start + dframes)
        elseif drag.mode == "resize_right" then
            -- Left window edge anchored; right edge follows the handle.
            -- The command clamps the duration floor.
            dispatch_zoom(drag.duration + dframes, drag.start)
        elseif drag.mode == "resize_left" then
            -- Right window edge anchored; left edge follows the handle.
            dispatch_zoom(drag.duration - dframes,
                drag.start + drag.duration)
        end
    end

    local function on_hover_move(x)
        local g = geometry()
        if not g then
            set_cursor("arrow")
            return
        end
        local zone = hit_test(x, g)
        if zone == "resize_left" or zone == "resize_right" then
            set_cursor("size_horz")
        else
            set_cursor("arrow")
        end
    end

    local function on_mouse_event(event_type, x, _y, _button, _modifiers)
        if event_type == "press" then
            on_press(x)
        elseif event_type == "move" then
            if drag then
                on_drag_move(x)
            else
                on_hover_move(x)
            end
        elseif event_type == "release" then
            drag = nil
        end
        state_module.flush_pending_notify()
    end

    -- Horizontal wheel over the scroller pans, same as over the ruler.
    local function on_wheel_event(delta_x, delta_y, modifiers)
        local horizontal = delta_x or 0
        if math.abs(horizontal) < 0.0001 and modifiers and modifiers.shift then
            horizontal = delta_y or 0
        end
        if math.abs(horizontal) <= 0.0001 then return end
        local g = geometry()
        if not g then return end
        -- Over the scroller, wheel pixels map at the SCROLLER's scale
        -- (whole-extent-across-the-track), not the lanes' viewport
        -- scale — the surface under the pointer defines the mapping.
        local delta_frames = math.floor((-horizontal) / g.scale)
        if delta_frames == 0 then return end
        command_manager.execute("ScrollTimelineViewport", {
            delta_frames = delta_frames,
        })
        state_module.flush_pending_notify()
    end

    timeline.set_lua_state(widget)

    local handler_name = "timeline_zoom_scroller_mouse_" .. tostring(widget)
    _G[handler_name] = function(event)
        if event.type == "wheel" then
            on_wheel_event(event.delta_x, event.delta_y, event)
            return true
        end
        on_mouse_event(event.type, event.x, event.y, event.button, event)
    end
    timeline.set_mouse_event_handler(widget, handler_name)

    local resize_name = "zoom_scroller_resize_" .. tostring(widget):gsub("[^%w]", "_")
    _G[resize_name] = function() render() end
    timeline.set_resize_event_handler(widget, resize_name)

    state_module.add_listener(
        profile_scope.wrap("timeline_zoom_scroller.render", render))

    render()

    return {
        widget = widget,
        render = render,
        geometry = geometry,
        on_mouse_event = on_mouse_event,
        on_wheel_event = on_wheel_event,
    }
end

return M
