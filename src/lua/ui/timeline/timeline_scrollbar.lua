-- Timeline Horizontal Scrollbar Module
-- Custom scrollbar where:
-- - Thumb position represents viewport_start_value
-- - Thumb size represents viewport_duration (zoom level)
-- - Dragging thumb = scroll
-- - Stretching thumb edges = zoom

local profile_scope = require("core.profile_scope")

local M = {}

M.SCROLLBAR_HEIGHT = 20

-- Create a new timeline scrollbar widget
-- Parameters:
--   widget: ScriptableTimeline Qt widget (used for rendering the scrollbar)
--   state_module: Reference to timeline_state module
function M.create(widget, state_module)
    local scrollbar = {
        widget = widget,
        state = state_module,
        dragging_thumb = false,
        dragging_left_edge = false,
        dragging_right_edge = false,
        drag_start_x = 0,
        drag_start_viewport_start = 0,
        drag_start_viewport_duration = 0,
    }

    -- Calculate total timeline duration (based on content)
    local function get_total_duration()
        local max_time = 60000  -- Minimum 60 seconds

        for _, clip in ipairs(state_module.get_clips()) do
            local clip_end = clip.start_value + clip.duration
            if clip_end > max_time then
                max_time = clip_end
            end
        end

        -- Add 10 seconds padding
        return max_time + 10000
    end

    -- Render the scrollbar
    local function render()
        if not scrollbar.widget then
            return
        end

        -- Get widget dimensions
        local width, height = timeline.get_dimensions(scrollbar.widget)

        -- Clear previous drawing commands
        timeline.clear_commands(scrollbar.widget)

        -- Background
        timeline.add_rect(scrollbar.widget, 0, 0, width, M.SCROLLBAR_HEIGHT, "#1a1a1a")

        -- Get viewport and total duration
        local viewport_start = state_module.get_viewport_start_value()
        local viewport_duration = state_module.get_viewport_duration()
        local total_duration = get_total_duration()

        -- Calculate thumb position and size
        local thumb_x = math.floor((viewport_start / total_duration) * width)
        local thumb_width = math.floor((viewport_duration / total_duration) * width)

        -- Ensure thumb is at least 20 pixels wide
        thumb_width = math.max(20, thumb_width)

        -- Thumb
        timeline.add_rect(scrollbar.widget, thumb_x, 2, thumb_width, M.SCROLLBAR_HEIGHT - 4, "#4a4a4a")

        -- Thumb edges (for resize handles)
        timeline.add_line(scrollbar.widget, thumb_x, 2, thumb_x, M.SCROLLBAR_HEIGHT - 2, "#666666", 2)
        timeline.add_line(scrollbar.widget, thumb_x + thumb_width, 2, thumb_x + thumb_width, M.SCROLLBAR_HEIGHT - 2, "#666666", 2)

        -- Trigger Qt repaint
        timeline.update(scrollbar.widget)
    end

    -- Mouse event handler
    local function on_mouse_event(event_type, x, y, button, modifiers)
        local width, height = timeline.get_dimensions(scrollbar.widget)
        local total_duration = get_total_duration()

        local viewport_start = state_module.get_viewport_start_value()
        local viewport_duration = state_module.get_viewport_duration()

        local thumb_x = math.floor((viewport_start / total_duration) * width)
        local thumb_width = math.floor((viewport_duration / total_duration) * width)
        thumb_width = math.max(20, thumb_width)

        if event_type == "press" then
            -- Check if clicking on left edge (resize)
            if math.abs(x - thumb_x) < 5 then
                scrollbar.dragging_left_edge = true
                scrollbar.drag_start_x = x
                scrollbar.drag_start_viewport_start = viewport_start
                scrollbar.drag_start_viewport_duration = viewport_duration

            -- Check if clicking on right edge (resize)
            elseif math.abs(x - (thumb_x + thumb_width)) < 5 then
                scrollbar.dragging_right_edge = true
                scrollbar.drag_start_x = x
                scrollbar.drag_start_viewport_start = viewport_start
                scrollbar.drag_start_viewport_duration = viewport_duration

            -- Check if clicking on thumb (scroll)
            elseif x >= thumb_x and x <= thumb_x + thumb_width then
                scrollbar.dragging_thumb = true
                scrollbar.drag_start_x = x
                scrollbar.drag_start_viewport_start = viewport_start

            -- Click outside thumb - jump to that position
            else
                local new_start = math.floor((x / width) * total_duration)
                -- Center viewport on click position
                new_start = new_start - (viewport_duration / 2)
                new_start = math.max(0, math.min(total_duration - viewport_duration, new_start))
                state_module.set_viewport_start_value(new_start)
            end

        elseif event_type == "move" then
            if scrollbar.dragging_thumb then
                -- Dragging thumb = scroll
                local delta_x = x - scrollbar.drag_start_x
                local delta_time = math.floor((delta_x / width) * total_duration)
                local new_start = scrollbar.drag_start_viewport_start + delta_time

                -- Clamp to valid range
                new_start = math.max(0, math.min(total_duration - viewport_duration, new_start))
                state_module.set_viewport_start_value(new_start)

            elseif scrollbar.dragging_left_edge then
                -- Dragging left edge = zoom + scroll
                local delta_x = x - scrollbar.drag_start_x
                local delta_time = math.floor((delta_x / width) * total_duration)

                local new_start = scrollbar.drag_start_viewport_start + delta_time
                local new_duration = scrollbar.drag_start_viewport_duration - delta_time

                -- Ensure minimum duration of 1 second
                if new_duration >= 1000 then
                    new_start = math.max(0, new_start)
                    state_module.set_viewport_start_value(new_start)
                    state_module.set_viewport_duration(new_duration)
                end

            elseif scrollbar.dragging_right_edge then
                -- Dragging right edge = zoom
                local delta_x = x - scrollbar.drag_start_x
                local delta_time = math.floor((delta_x / width) * total_duration)

                local new_duration = scrollbar.drag_start_viewport_duration + delta_time

                -- Ensure minimum duration of 1 second
                if new_duration >= 1000 then
                    state_module.set_viewport_duration(new_duration)
                end
            end

        elseif event_type == "release" then
            scrollbar.dragging_thumb = false
            scrollbar.dragging_left_edge = false
            scrollbar.dragging_right_edge = false
        end

        render()
    end

    -- Initialize
    timeline.set_lua_state(widget)

    -- Wire up mouse event handler
    -- Create a global function that the C++ can call
    local handler_name = "timeline_scrollbar_mouse_handler_" .. tostring(widget)
    _G[handler_name] = function(event)
        on_mouse_event(event.type, event.x, event.y, event.button, event)
    end
    timeline.set_mouse_event_handler(widget, handler_name)

    -- Listen to state changes
    state_module.add_listener(profile_scope.wrap("timeline_scrollbar.render", render))

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
