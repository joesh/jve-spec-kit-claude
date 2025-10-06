-- Timeline Ruler Module
-- Displays time markers and playhead position
-- Listens to timeline state for viewport changes

local M = {}

M.RULER_HEIGHT = 32

-- Create a new timeline ruler widget
-- Parameters:
--   widget: ScriptableTimeline Qt widget (used just for rendering the ruler)
--   state_module: Reference to timeline_state module
function M.create(widget, state_module)
    local ruler = {
        widget = widget,
        state = state_module,
    }

    -- Render the ruler
    local function render()
        if not ruler.widget then
            return
        end

        -- Get widget dimensions
        local width, height = timeline.get_dimensions(ruler.widget)

        -- Clear previous drawing commands
        timeline.clear_commands(ruler.widget)

        -- Get viewport state
        local viewport_start = state_module.get_viewport_start_time()
        local viewport_duration = state_module.get_viewport_duration()
        local viewport_end = viewport_start + viewport_duration
        local playhead_time = state_module.get_playhead_time()

        -- Ruler background
        timeline.add_rect(ruler.widget, 0, 0, width, M.RULER_HEIGHT, "#2a2a2a")

        -- Calculate appropriate interval based on viewport duration
        -- We want markers roughly 80-120 pixels apart
        local target_pixel_spacing = 100
        local pixels_per_ms = width / viewport_duration
        local interval_ms = math.floor(target_pixel_spacing / pixels_per_ms)

        -- Round to nice intervals: 100ms, 200ms, 500ms, 1s, 2s, 5s, 10s, 30s, 60s
        local nice_intervals = {100, 200, 500, 1000, 2000, 5000, 10000, 30000, 60000}
        for _, nice in ipairs(nice_intervals) do
            if interval_ms <= nice then
                interval_ms = nice
                break
            end
        end
        -- If still too large, use 60s
        if interval_ms > 60000 then
            interval_ms = 60000
        end

        -- Draw time markers
        local start_marker = math.floor(viewport_start / interval_ms) * interval_ms

        for time_ms = start_marker, viewport_end, interval_ms do
            if time_ms >= viewport_start then
                local x = state_module.time_to_pixel(time_ms, width)

                if x >= 0 and x <= width then
                    -- Tick mark
                    timeline.add_line(ruler.widget, x, M.RULER_HEIGHT - 10, x, M.RULER_HEIGHT, "#3a3a3a", 1)

                    -- Time label (convert to seconds)
                    local seconds = time_ms / 1000
                    local label = string.format("%.1fs", seconds)
                    timeline.add_text(ruler.widget, x + 2, 18, label, "#cccccc")
                end
            end
        end

        -- Draw playhead marker if in visible range
        if playhead_time >= viewport_start and playhead_time <= viewport_end then
            local playhead_x = state_module.time_to_pixel(playhead_time, width)

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

        if event_type == "press" then
            -- Check if clicking on playhead
            local playhead_time = state_module.get_playhead_time()
            local playhead_x = state_module.time_to_pixel(playhead_time, width)

            if math.abs(x - playhead_x) < 10 then
                state_module.set_dragging_playhead(true)
            else
                -- Click anywhere on ruler to set playhead
                local time = state_module.pixel_to_time(x, width)
                state_module.set_playhead_time(time)
            end

        elseif event_type == "move" then
            if state_module.is_dragging_playhead() then
                local time = state_module.pixel_to_time(x, width)
                state_module.set_playhead_time(time)
            end

        elseif event_type == "release" then
            state_module.set_dragging_playhead(false)
        end

        render()
    end

    -- Initialize
    timeline.set_lua_state(widget)

    -- Wire up mouse event handler
    local handler_name = "timeline_ruler_mouse_handler_" .. tostring(widget)
    _G[handler_name] = function(event)
        on_mouse_event(event.type, event.x, event.y, event.button, event)
    end
    timeline.set_mouse_event_handler(widget, handler_name)

    -- Listen to state changes
    state_module.add_listener(render)

    -- Initial render
    render()

    -- Public interface
    return {
        widget = widget,
        render = render,
        on_mouse_event = on_mouse_event,
    }
end

return M
