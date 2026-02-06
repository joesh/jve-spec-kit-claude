--- Source Mark Bar Module
--
-- Responsibilities:
-- - Renders a thin horizontal bar showing mark in/out range + playhead
--   for the currently loaded source clip
-- - Listens to source_viewer_state for redraws
-- - Handles mouse input: click to set playhead, drag marks
--
-- Uses ScriptableTimeline widget as a drawing canvas (no tracks/clips).
-- Visual language matches timeline ruler: cyan mark range, red handles/playhead.
--
-- @file source_mark_bar.lua

local source_viewer_state = require("ui.source_viewer_state")

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

--- Create a source mark bar attached to a ScriptableTimeline widget.
-- @param widget: ScriptableTimeline widget (created via CREATE_TIMELINE)
-- @return table with {widget, render}
function M.create(widget)
    assert(widget, "source_mark_bar.create: widget is nil")

    local bar = {
        widget = widget,
    }

    -- Convert frame index to pixel x-coordinate
    local function frame_to_x(frame, width)
        local total = source_viewer_state.total_frames
        if total <= 0 then return 0 end
        return math.floor((frame / total) * width + 0.5)
    end

    -- Convert pixel x-coordinate to frame index
    local function x_to_frame(x, width)
        local total = source_viewer_state.total_frames
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

        if not source_viewer_state.has_clip() then
            timeline.update(bar.widget)
            return
        end

        -- Clip duration strip
        timeline.add_rect(bar.widget, 0, 0, width, M.BAR_HEIGHT, DURATION_BAR_COLOR)

        local mark_in = source_viewer_state.mark_in
        local mark_out = source_viewer_state.mark_out

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
        local playhead = source_viewer_state.playhead
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

    -- Seek video to a source frame and sync playback_controller position.
    local function seek_to_frame(frame)
        local playback_controller = require("core.playback.playback_controller")
        if playback_controller.is_playing() then
            playback_controller.stop()
        end
        local viewer_panel = require("ui.viewer_panel")
        assert(viewer_panel.has_media(),
            "source_mark_bar.seek_to_frame: no media loaded in viewer_panel")
        viewer_panel.show_frame(frame)
        playback_controller.set_position(frame)
    end

    -- Mouse interaction
    local dragging = false

    local function on_mouse_event(event_type, x, y, button, modifiers)
        if not source_viewer_state.has_clip() then return end
        local width = select(1, timeline.get_dimensions(bar.widget))
        if not width or width <= 0 then return end

        if event_type == "press" then
            dragging = true
            local frame = x_to_frame(x, width)
            source_viewer_state.set_playhead(frame)
            seek_to_frame(frame)

        elseif event_type == "move" then
            if dragging then
                local frame = x_to_frame(x, width)
                source_viewer_state.set_playhead(frame)
                seek_to_frame(frame)
            end

        elseif event_type == "release" then
            dragging = false
        end

        render()
    end

    -- Wire up Lua state and mouse handler
    timeline.set_lua_state(widget)

    local handler_name = "source_mark_bar_mouse_handler_" .. tostring(widget)
    _G[handler_name] = function(event)
        if event.type ~= "wheel" then
            on_mouse_event(event.type, event.x, event.y, event.button, event)
        end
    end
    timeline.set_mouse_event_handler(widget, handler_name)

    -- Resize handler: re-render when layout changes widget dimensions
    local resize_name = "source_mark_bar_resize_handler_" .. tostring(widget)
    _G[resize_name] = function() render() end
    timeline.set_resize_event_handler(widget, resize_name)

    -- Listen to source_viewer_state changes
    source_viewer_state.add_listener(render)

    -- Initial render
    render()

    return {
        widget = widget,
        render = render,
        on_mouse_event = on_mouse_event,
    }
end

return M
