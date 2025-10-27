-- Timeline Ruler Module
-- Displays time markers and playhead position in HH:MM:SS:FF timecode format
-- Listens to timeline state for viewport changes
-- Dynamically scales tick marks and labels based on zoom level

local M = {}
local timecode = require("core.timecode")
local db = require("core.database")

M.RULER_HEIGHT = 32

-- Cache sequence frame rate
local cached_frame_rate = nil

-- Get frame rate from sequence (cached)
local function get_frame_rate()
    if cached_frame_rate then
        return cached_frame_rate
    end

    local db_conn = db.get_connection()
    if db_conn then
        local query = db_conn:prepare("SELECT frame_rate FROM sequences WHERE id = 'default_sequence'")
        if query and query:exec() and query:next() then
            cached_frame_rate = query:value(0) or 30.0
        end
    end

    cached_frame_rate = cached_frame_rate or 30.0
    return cached_frame_rate
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

        -- Draw time markers at frame-accurate positions
        local start_marker = math.floor(viewport_start / interval_ms) * interval_ms

        for time_ms = start_marker, viewport_end, interval_ms do
            if time_ms >= viewport_start then
                local x = state_module.time_to_pixel(time_ms, width)

                if x >= 0 and x <= width then
                    -- Tick mark
                    timeline.add_line(ruler.widget, x, M.RULER_HEIGHT - 10, x, M.RULER_HEIGHT, "#555555", 1)

                    -- Timecode label with appropriate precision
                    local label = timecode.format_ruler_label(time_ms, frame_rate, format_hint)
                    timeline.add_text(ruler.widget, x + 3, 18, label, "#cccccc")
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
        local frame_rate = get_frame_rate()

        -- Helper to snap time to nearest frame boundary
        local function snap_to_frame(time_ms)
            local frames = timecode.ms_to_frames(time_ms, frame_rate)
            return timecode.frames_to_ms(frames, frame_rate)
        end

        if event_type == "press" then
            -- Check if clicking on playhead
            local playhead_time = state_module.get_playhead_time()
            local playhead_x = state_module.time_to_pixel(playhead_time, width)

            if math.abs(x - playhead_x) < 10 then
                state_module.set_dragging_playhead(true)
            else
                -- Click anywhere on ruler to set playhead (snap to frame)
                local time = state_module.pixel_to_time(x, width)
                local snapped_time = snap_to_frame(time)
                state_module.set_playhead_time(snapped_time)
            end

        elseif event_type == "move" then
            if state_module.is_dragging_playhead() then
                local time = state_module.pixel_to_time(x, width)
                local snapped_time = snap_to_frame(time)
                state_module.set_playhead_time(snapped_time)
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
    state_module.add_listener(render)

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
