--- Monitor Mark Bar Module
--
-- Responsibilities:
-- - Renders a thin horizontal bar showing mark in/out range + playhead
-- - Listens to a state_provider for redraws
-- - Handles mouse input: click to set playhead, drag marks
--
-- Uses ScriptableTimeline widget as a drawing canvas (no tracks/clips).
-- Visual language matches timeline ruler: cyan mark range, red handles/playhead.
--
-- Config table:
--   state_provider  table with:
--     .total_frames  number (read)
--     .playhead      number (read)
--   has_clip()      → boolean
--   get_mark_in()   → number|nil
--   get_mark_out()  → number|nil
--   on_seek(frame)  function called on click/drag
--   on_listener(fn) function to register render callback
--
-- @file monitor_mark_bar.lua

local M = {}

M.BAR_HEIGHT = 20

-- Colors (matching timeline ruler mark rendering)
local BACKGROUND_COLOR = "#1e1e1e"
local MARK_RANGE_FILL = "#19dfeeff"   -- translucent cyan overlay
local MARK_EDGE_COLOR = "#ff6b6b"     -- red handle
local PLAYHEAD_COLOR = "#ff6b6b"      -- red playhead
local DURATION_BAR_COLOR = "#2a2a2a"  -- dark strip for clip extent

local HANDLE_WIDTH = 2
local PLAYHEAD_LINE_WIDTH = 2

--- Create a mark bar attached to a ScriptableTimeline widget.
-- @param widget: ScriptableTimeline widget (created via CREATE_TIMELINE)
-- @param config: { state_provider, has_clip, get_mark_in, get_mark_out, on_seek, on_listener }
-- @return table with {widget, render, on_mouse_event}
function M.create(widget, config)
    assert(widget, "monitor_mark_bar.create: widget is nil")
    assert(type(config) == "table",
        "monitor_mark_bar.create: config table required")
    assert(config.state_provider,
        "monitor_mark_bar.create: config.state_provider required")
    assert(type(config.on_seek) == "function",
        "monitor_mark_bar.create: config.on_seek function required")
    assert(type(config.has_clip) == "function",
        "monitor_mark_bar.create: config.has_clip function required")
    assert(type(config.get_mark_in) == "function",
        "monitor_mark_bar.create: config.get_mark_in function required")
    assert(type(config.get_mark_out) == "function",
        "monitor_mark_bar.create: config.get_mark_out function required")
    assert(type(config.on_listener) == "function",
        "monitor_mark_bar.create: config.on_listener function required")

    local state = config.state_provider
    local on_seek = config.on_seek
    local has_clip = config.has_clip
    local get_mark_in = config.get_mark_in
    local get_mark_out = config.get_mark_out

    local bar = {
        widget = widget,
    }

    -- Convert frame index to pixel x-coordinate
    local function frame_to_x(frame, width)
        local total = state.total_frames
        if total <= 0 then return 0 end
        return math.floor((frame / total) * width + 0.5)
    end

    -- Convert pixel x-coordinate to frame index
    local function x_to_frame(x, width)
        local total = state.total_frames
        if total <= 0 or width <= 0 then return 0 end
        local frame = math.floor((x / width) * total + 0.5)
        return math.max(0, math.min(frame, total - 1))
    end

    local function render()
        if not bar.widget then return end

        local width = select(1, timeline.get_dimensions(bar.widget))
        if not width or width <= 0 then return end

        timeline.clear_commands(bar.widget)

        -- Background
        timeline.add_rect(bar.widget, 0, 0, width, M.BAR_HEIGHT, BACKGROUND_COLOR)

        if not has_clip() then
            timeline.update(bar.widget)
            return
        end

        -- Clip duration strip
        timeline.add_rect(bar.widget, 0, 0, width, M.BAR_HEIGHT, DURATION_BAR_COLOR)

        local mark_in = get_mark_in()
        local mark_out = get_mark_out()

        -- Mark range fill
        if mark_in and mark_out and mark_out > mark_in then
            local start_x = frame_to_x(mark_in, width)
            local end_x = frame_to_x(mark_out, width)
            if end_x <= start_x then end_x = start_x + 1 end
            local region_width = math.max(1, end_x - start_x)
            timeline.add_rect(bar.widget, start_x, 0, region_width, M.BAR_HEIGHT, MARK_RANGE_FILL)
        end

        -- Mark edge handles
        if mark_in then
            local x = frame_to_x(mark_in, width)
            local handle_x = math.max(0, x - math.floor(HANDLE_WIDTH / 2))
            timeline.add_rect(bar.widget, handle_x, 0, math.max(HANDLE_WIDTH, 2), M.BAR_HEIGHT, MARK_EDGE_COLOR)
        end
        if mark_out then
            local x = frame_to_x(mark_out, width)
            local handle_x = math.max(0, x - math.floor(HANDLE_WIDTH / 2))
            timeline.add_rect(bar.widget, handle_x, 0, math.max(HANDLE_WIDTH, 2), M.BAR_HEIGHT, MARK_EDGE_COLOR)
        end

        -- Playhead
        local playhead = state.playhead
        local playhead_x = frame_to_x(playhead, width)

        -- Playhead triangle caret (top)
        local caret_w = 10
        local caret_h = 5
        timeline.add_triangle(bar.widget,
            playhead_x - caret_w / 2, 0,
            playhead_x + caret_w / 2, 0,
            playhead_x, caret_h,
            PLAYHEAD_COLOR)

        -- Playhead vertical line
        timeline.add_line(bar.widget, playhead_x, caret_h, playhead_x, M.BAR_HEIGHT,
            PLAYHEAD_COLOR, PLAYHEAD_LINE_WIDTH)

        timeline.update(bar.widget)
    end

    -- Mouse interaction
    local dragging = false

    local function on_mouse_event(event_type, x, y, button, modifiers)
        if not has_clip() then return end
        local width = select(1, timeline.get_dimensions(bar.widget))
        if not width or width <= 0 then return end

        if event_type == "press" then
            dragging = true
            local frame = x_to_frame(x, width)
            on_seek(frame)

        elseif event_type == "move" then
            if dragging then
                local frame = x_to_frame(x, width)
                on_seek(frame)
            end

        elseif event_type == "release" then
            dragging = false
        end

        render()
    end

    -- Wire up Lua state and mouse handler
    timeline.set_lua_state(widget)

    local handler_name = "monitor_mark_bar_mouse_handler_" .. tostring(widget)
    _G[handler_name] = function(event)
        if event.type ~= "wheel" then
            on_mouse_event(event.type, event.x, event.y, event.button, event)
        end
    end
    timeline.set_mouse_event_handler(widget, handler_name)

    -- Resize handler: re-render when layout changes widget dimensions
    local resize_name = "monitor_mark_bar_resize_handler_" .. tostring(widget)
    _G[resize_name] = function() render() end
    timeline.set_resize_event_handler(widget, resize_name)

    -- Listen to state changes for redraws
    config.on_listener(render)

    -- Initial render
    render()

    return {
        widget = widget,
        render = render,
        on_mouse_event = on_mouse_event,
    }
end

return M
