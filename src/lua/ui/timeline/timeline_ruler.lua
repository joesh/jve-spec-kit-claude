-- Timeline Ruler Module
-- Displays time markers and playhead position in HH:MM:SS:FF timecode format
-- Listens to timeline state for viewport changes
-- Dynamically scales tick marks and labels based on zoom level

local M = {}
local timecode = require("core.timecode")
local frame_utils = require("core.frame_utils")
local profile_scope = require("core.profile_scope")

M.RULER_HEIGHT = 32
local MIN_LABEL_SPACING = 20
local AVERAGE_CHAR_WIDTH = 7.0

local BACKGROUND_COLOR = "#1e1e1e"
local BASELINE_COLOR = "#3b3b3b"
local MAJOR_TICK_COLOR = "#585858"
local MEDIUM_TICK_COLOR = "#585858"
local MINOR_TICK_COLOR = "#585858"
local LABEL_COLOR = "#b2b2b2"

local BASELINE_HEIGHT = 1
local MAJOR_TICK_HEIGHT = 10
local MEDIUM_TICK_HEIGHT = 5
local MINOR_TICK_HEIGHT = 3
local LABEL_Y = 18

local function estimate_label_width(label)
    if not label or label == "" then
        return 0
    end
    return #label * AVERAGE_CHAR_WIDTH
end

-- Create a new timeline ruler widget
-- Parameters:
--   widget: ScriptableTimeline Qt widget (used just for rendering the ruler)
--   state_module: Reference to timeline_state module
function M.create(widget, state_module)
    local ruler = {
        widget = widget,
        state = state_module,
    }

    local function get_frame_rate()
        if state_module and state_module.get_sequence_frame_rate then
            local rate = state_module.get_sequence_frame_rate()
            if type(rate) == "table" and rate.fps_numerator then
                return rate
            elseif type(rate) == "number" and rate > 0 then
                return rate
            end
        end
        return frame_utils.default_frame_rate
    end

    local function to_ms(val)
        if type(val) == "table" and val.to_seconds then
            return val:to_seconds() * 1000.0
        elseif type(val) == "number" then
            return val
        end
        return 0
    end

    -- Render the ruler
    local function render()
        if not ruler.widget then
            return
        end

        -- Get widget dimensions
        local width, height = timeline.get_dimensions(ruler.widget)

        -- Clear previous drawing commands
        timeline.clear_commands(ruler.widget)

        -- Get viewport state (Convert to MS for rendering logic)
        local viewport_start = to_ms(state_module.get_viewport_start_time())
        local viewport_duration = to_ms(state_module.get_viewport_duration())
        local viewport_end = viewport_start + viewport_duration
        local playhead_value = to_ms(state_module.get_playhead_position())

        -- Ruler background
        timeline.add_rect(ruler.widget, 0, 0, width, M.RULER_HEIGHT, BACKGROUND_COLOR)
        timeline.add_rect(ruler.widget, 0, M.RULER_HEIGHT - BASELINE_HEIGHT, width, BASELINE_HEIGHT, BASELINE_COLOR)

        local mark_in = to_ms(state_module.get_mark_in and state_module.get_mark_in())
        local mark_out = to_ms(state_module.get_mark_out and state_module.get_mark_out())
        local explicit_mark_in = state_module.has_explicit_mark_in and state_module.has_explicit_mark_in()
        local explicit_mark_out = state_module.has_explicit_mark_out and state_module.has_explicit_mark_out()

        local function draw_mark_region()
            if (not mark_in) and (not mark_out) then
                return
            end

            local colors = state_module.colors or {}
            local fill_color = colors.mark_range_fill
            if not fill_color then
                error("timeline_state.colors.mark_range_fill is nil; expected translucent color for mark range overlay")
            end
            local edge_color = colors.mark_range_edge or colors.playhead or "#ff6b6b"
            local handle_width = 2

            if mark_in and mark_out and mark_out > mark_in then
                local visible_start = math.max(mark_in, viewport_start)
                local visible_end = math.min(mark_out, viewport_end)
                if visible_end > visible_start then
                    local start_x = state_module.time_to_pixel(visible_start, width)
                    local end_x = state_module.time_to_pixel(visible_end, width)
                    if end_x <= start_x then
                        end_x = start_x + 1
                    end
                    local region_width = end_x - start_x
                    if region_width <= 0 then
                        region_width = 1
                    end
                    timeline.add_rect(ruler.widget, start_x, 0, region_width, M.RULER_HEIGHT, fill_color)
                end
            end

            local function draw_handle(time_ms)
                if not time_ms then
                    return
                end
                if time_ms < viewport_start or time_ms > viewport_end then
                    return
                end
                local x = state_module.time_to_pixel(time_ms, width)
                local handle_x = x - math.floor(handle_width / 2)
                if handle_x < 0 then
                    handle_x = 0
                end
                timeline.add_rect(ruler.widget, handle_x, 0, math.max(handle_width, 2), M.RULER_HEIGHT, edge_color)
            end

            if explicit_mark_in then
                draw_handle(mark_in)
            end
            if explicit_mark_out then
                draw_handle(mark_out)
            end
        end

        draw_mark_region()

        -- Get sequence frame rate
        local frame_rate = get_frame_rate()

        -- Calculate appropriate frame-based interval
        local pixels_per_ms = width / viewport_duration
        local interval_ms, format_hint, interval_value = timecode.get_ruler_interval(
            viewport_duration,
            frame_rate,
            100,  -- target pixel spacing
            pixels_per_ms
        )

        local subdivisions = 0
        if format_hint == "frames" then
            if interval_value and interval_value > 1 then
                subdivisions = math.min(4, interval_value - 1)
            end
        elseif format_hint == "seconds" then
            subdivisions = 4
        elseif format_hint == "minutes" then
            subdivisions = 5
        end

        local minor_interval = subdivisions > 0 and (interval_ms / (subdivisions + 1)) or nil

        -- Draw time markers at frame-accurate positions
        local start_marker = math.floor(viewport_start / interval_ms) * interval_ms
        local last_label_end = -math.huge

        local function to_pixel(time_ms)
            if time_ms < viewport_start or time_ms > viewport_end then
                return nil
            end
            local x = state_module.time_to_pixel(time_ms, width)
            if x < 0 or x > width then
                return nil
            end
            return x
        end

        local function draw_tick_at(x, height, color)
            local baseline = M.RULER_HEIGHT - BASELINE_HEIGHT
            timeline.add_line(ruler.widget, x, baseline - height, x, baseline, color, 1)
        end

        local time_ms = start_marker
        while time_ms <= viewport_end do
            local x = to_pixel(time_ms)
            if x then
                -- Timecode label with appropriate precision
                local label = timecode.format_ruler_label(time_ms, frame_rate, format_hint)
                local label_width = estimate_label_width(label)
                local label_start = x - (label_width / 2)
                if label_start < 0 then
                    label_start = 0
                elseif label_start + label_width > width then
                    label_start = width - label_width
                end

                local show_label = (label_start - last_label_end) >= MIN_LABEL_SPACING
                if show_label then
                    draw_tick_at(x, MAJOR_TICK_HEIGHT, MAJOR_TICK_COLOR)
                    timeline.add_text(ruler.widget, label_start, LABEL_Y, label, LABEL_COLOR)
                    last_label_end = label_start + label_width
                else
                    draw_tick_at(x, MEDIUM_TICK_HEIGHT, MEDIUM_TICK_COLOR)
                end

                if minor_interval then
                    for sub = 1, subdivisions do
                        local minor_time = time_ms + (minor_interval * sub)
                        if minor_time >= viewport_start and minor_time <= viewport_end then
                            local minor_x = to_pixel(minor_time)
                            if minor_x then
                                if subdivisions >= 4 and sub % 2 == 0 then
                                    draw_tick_at(minor_x, MEDIUM_TICK_HEIGHT, MEDIUM_TICK_COLOR)
                                else
                                    draw_tick_at(minor_x, MINOR_TICK_HEIGHT, MINOR_TICK_COLOR)
                                end
                            end
                        end
                    end
                end
            end
            time_ms = time_ms + interval_ms
        end

        -- Draw playhead marker if in visible range
        if playhead_value >= viewport_start and playhead_value <= viewport_end then
            local playhead_x = state_module.time_to_pixel(playhead_value, width)

            -- Small triangle at playhead position
            local handle_size = 8
            local handle_y = 0
            local tip_y = handle_y + handle_size

            timeline.add_line(ruler.widget, playhead_x - handle_size/2, handle_y, playhead_x, tip_y, "#ff6b6b", 2)
            timeline.add_line(ruler.widget, playhead_x, tip_y, playhead_x + handle_size/2, handle_y, "#ff6b6b", 2)
            timeline.add_line(ruler.widget, playhead_x - handle_size/2, handle_y, playhead_x + handle_size/2, handle_y, "#ff6b6b", 2)
        end

        -- Trigger Qt repaint
        timeline.update(ruler.widget)
    end

    -- Mouse event handler for playhead dragging
    local function on_mouse_event(event_type, x, y, button, modifiers)
        local width, height = timeline.get_dimensions(ruler.widget)
        local frame_rate = get_frame_rate()

        if event_type == "press" then
            -- Check if clicking on playhead
            local playhead_rat = state_module.get_playhead_position()
            local playhead_ms = to_ms(playhead_rat)
            local playhead_x = state_module.time_to_pixel(playhead_ms, width)

            if math.abs(x - playhead_x) < 10 then
                state_module.set_dragging_playhead(true)
            else
                -- Click anywhere on ruler to set playhead (snap to frame)
                local time_rat = state_module.pixel_to_time(x, width)
                local snapped_rat = frame_utils.snap_to_frame(time_rat, frame_rate)
                state_module.set_playhead_value(snapped_rat)
                state_module.set_dragging_playhead(true)
            end

        elseif event_type == "move" then
            if state_module.is_dragging_playhead() then
                local time_rat = state_module.pixel_to_time(x, width)
                local snapped_rat = frame_utils.snap_to_frame(time_rat, frame_rate)
                state_module.set_playhead_value(snapped_rat)
            end

        elseif event_type == "release" then
            state_module.set_dragging_playhead(false)
        end

        render()
    end

    local function on_wheel_event(delta_x, delta_y, modifiers)
        local horizontal = delta_x or 0
        if math.abs(horizontal) < 0.0001 and modifiers and modifiers.shift then
            horizontal = delta_y or 0
        end

        if horizontal and math.abs(horizontal) > 0.0001 then
            local width = timeline.get_dimensions(widget)
            if width and width > 0 then
                local viewport_duration = state_module.get_viewport_duration()
                local delta_time = (-horizontal / width) * viewport_duration
                local new_start = state_module.get_viewport_start_time() + delta_time
                state_module.set_viewport_start_time(new_start)
                render()
            end
        end
    end

    -- Initialize
    timeline.set_lua_state(widget)

    -- Wire up mouse event handler
    local handler_name = "timeline_ruler_mouse_handler_" .. tostring(widget)
    _G[handler_name] = function(event)
        if event.type == "wheel" then
            on_wheel_event(event.delta_x, event.delta_y, event)
        else
            on_mouse_event(event.type, event.x, event.y, event.button, event)
        end
    end
    timeline.set_mouse_event_handler(widget, handler_name)

    -- Listen to state changes
    state_module.add_listener(profile_scope.wrap("timeline_ruler.render", render))

    -- Initial render
    render()

    -- Public interface
    return {
        widget = widget,
        render = render,
        on_mouse_event = on_mouse_event,
        on_wheel_event = on_wheel_event,
    }
end

return M
