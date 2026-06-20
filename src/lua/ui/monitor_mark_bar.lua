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

local ui_constants = require("core.ui_constants")

local M = {}

M.BAR_HEIGHT = 20

--- Translate a horizontal wheel/trackpad pixel delta into a frame delta
--- using the bar's pixel/frame scale (viewport_duration frames over
--- width pixels). Pure conversion — clamping is the consuming command's
--- job, not this helper's. Kept as a module-level function so the
--- dispatch math is testable without a Qt harness.
function M.compute_wheel_frame_delta(delta_x, width, viewport_duration)
    assert(type(delta_x) == "number",
        "monitor_mark_bar.compute_wheel_frame_delta: delta_x must be number, got "
        .. type(delta_x))
    assert(type(width) == "number" and width > 0, string.format(
        "monitor_mark_bar.compute_wheel_frame_delta: width must be a positive "
        .. "number, got %s", tostring(width)))
    assert(type(viewport_duration) == "number" and viewport_duration > 0, string.format(
        "monitor_mark_bar.compute_wheel_frame_delta: viewport_duration must be "
        .. "a positive number, got %s", tostring(viewport_duration)))
    return math.floor((delta_x / width) * viewport_duration + 0.5)
end

-- Colors (matching timeline ruler mark rendering)
local BACKGROUND_COLOR = ui_constants.COLORS.SURFACE_CANVAS
local MARK_RANGE_FILL = ui_constants.COLORS.MARK_RANGE_FILL   -- translucent cyan overlay
local MARK_EDGE_COLOR = ui_constants.COLORS.ACCENT_PLAYHEAD     -- red handle
local PLAYHEAD_COLOR = ui_constants.COLORS.ACCENT_PLAYHEAD      -- red playhead
local DURATION_BAR_COLOR = ui_constants.COLORS.CONTROL_INACTIVE_BG  -- dark strip for clip extent

local HANDLE_WIDTH = 2
local PLAYHEAD_LINE_WIDTH = 2

--- Create a mark bar attached to a ScriptableTimeline widget.
-- @param widget: ScriptableTimeline widget (created via CREATE_TIMELINE)
-- @param config: { state_provider, has_clip, get_mark_in, get_mark_out,
--                  on_seek, on_listener, monitor_view_id }
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
    assert(type(config.monitor_view_id) == "string" and config.monitor_view_id ~= "",
        "monitor_mark_bar.create: config.monitor_view_id required (used to "
        .. "route wheel/trackpad gestures to the right SequenceMonitor via "
        .. "command_manager dispatch)")

    local state = config.state_provider
    local on_seek = config.on_seek
    local has_clip = config.has_clip
    local get_mark_in = config.get_mark_in
    local get_mark_out = config.get_mark_out
    local monitor_view_id = config.monitor_view_id

    local bar = {
        widget = widget,
    }

    -- Convert frame index to pixel x-coordinate (viewport-aware)
    local function frame_to_x(frame, width)
        local vp_dur = state.viewport_duration
        if vp_dur <= 0 then return 0 end
        return math.floor(((frame - state.viewport_start) / vp_dur) * width + 0.5)
    end

    -- Convert pixel x-coordinate to frame index (viewport-aware)
    local function x_to_frame(x, width)
        local vp_dur = state.viewport_duration
        local sf = state.start_frame or 0
        if vp_dur <= 0 or width <= 0 then return sf end
        local frame = math.floor(state.viewport_start + (x / width) * vp_dur + 0.5)
        return math.max(sf, math.min(frame, state.total_frames - 1))
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

        -- Mark range fill. Open-ended mark range domain rule (see
        -- timeline_view_renderer.render_mark_overlay for the full
        -- exposition; both surfaces use the same rule):
        --   mark_in present, mark_out nil  → [mark_in, total_frames)
        --   mark_in nil, mark_out present  → [start_frame, mark_out)
        --   both present                   → [mark_in, mark_out)
        -- The `or` fallbacks below are this surface's start/end-of-
        -- domain floor/ceiling, NOT silent defaults per rule 2.13.
        if mark_in or mark_out then
            local eff_in = mark_in or (state.start_frame or 0)
            local eff_out = mark_out or state.total_frames
            if eff_out > eff_in then
                local start_x = frame_to_x(eff_in, width)
                local end_x = frame_to_x(eff_out, width)
                if end_x <= start_x then end_x = start_x + 1 end
                local region_width = math.max(1, end_x - start_x)
                timeline.add_rect(bar.widget, start_x, 0, region_width, M.BAR_HEIGHT, MARK_RANGE_FILL)
            end
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
        if event.type == "wheel" then
            -- TimelineRenderer.wheelEvent asserts the Lua handler returns
            -- an explicit boolean. Every branch must return true/false.
            if not has_clip() then return true end
            local width = select(1, timeline.get_dimensions(widget))
            if not width or width <= 0 then return true end
            -- Horizontal trackpad scroll. Shift+wheel (or single-axis
            -- wheel mice) substitutes delta_y for delta_x, mirroring
            -- the timeline ruler's wheel mapping.
            local delta_x = event.delta_x or 0
            local modifiers = event.modifiers or {}
            if math.abs(delta_x) < 0.0001 and modifiers.shift then
                delta_x = event.delta_y or 0
            end
            if math.abs(delta_x) < 0.0001 then return true end
            local delta_frames = M.compute_wheel_frame_delta(
                delta_x, width, state.viewport_duration)
            if delta_frames == 0 then return true end
            -- Gesture → command mapping. Hardcoded; will move to a
            -- config table when the trackpad/mouse editor lands (analog
            -- of the keyboard editor — see memory todo_gesture_command_editor).
            -- Opt = pan the displayed viewport
            -- range; everything else = scrub the playhead. Both go
            -- through command_manager so the future editor can rebind
            -- the gesture to any other command.
            local command_name = modifiers.alt and "PanMonitorMarkBar"
                                                or "ScrubMonitorPlayhead"
            require("core.command_manager").execute(command_name, {
                monitor_view_id = monitor_view_id,
                delta_frames    = delta_frames,
            })
            return true
        else
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
