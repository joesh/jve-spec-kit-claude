--- TODO: one-line summary (human review required)
--
-- Responsibilities:
-- - TODO
--
-- Non-goals:
-- - TODO
--
-- Invariants:
-- - TODO
--
-- Size: ~284 LOC
-- Volatility: unknown
--
-- @file timeline_ruler.lua
-- Original intent (unreviewed):
-- Timeline Ruler Module
-- Displays time markers and playhead position in HH:MM:SS:FF timecode format
-- Listens to timeline state for viewport changes
-- Dynamically scales tick marks and labels based on zoom level
local M = {}
local timecode = require("core.timecode")
local Rational = require("core.rational")
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

    -- Render the ruler
    local function render()
        if not ruler.widget then
            return
        end

        -- Get widget dimensions
        local width = select(1, timeline.get_dimensions(ruler.widget))

        -- Clear previous drawing commands
        timeline.clear_commands(ruler.widget)

        -- Get viewport state (Rational)
        local viewport_start_rt = state_module.get_viewport_start_time()
        local viewport_duration_rt = state_module.get_viewport_duration()
        local viewport_end_rt = viewport_start_rt + viewport_duration_rt
        local playhead_rt = state_module.get_playhead_position()

        -- Ruler background
        timeline.add_rect(ruler.widget, 0, 0, width, M.RULER_HEIGHT, BACKGROUND_COLOR)
        timeline.add_rect(ruler.widget, 0, M.RULER_HEIGHT - BASELINE_HEIGHT, width, BASELINE_HEIGHT, BASELINE_COLOR)

        local mark_in_rt = state_module.get_mark_in and state_module.get_mark_in()
        local mark_out_rt = state_module.get_mark_out and state_module.get_mark_out()
        local explicit_mark_in = state_module.has_explicit_mark_in and state_module.has_explicit_mark_in()
        local explicit_mark_out = state_module.has_explicit_mark_out and state_module.has_explicit_mark_out()

        local function draw_mark_region()
            if (not mark_in_rt) and (not mark_out_rt) then
                return
            end

            local colors = state_module.colors or {}
            local fill_color = colors.mark_range_fill
            if not fill_color then
                error("timeline_state.colors.mark_range_fill is nil; expected translucent color for mark range overlay")
            end
            local edge_color = colors.mark_range_edge or colors.playhead or "#ff6b6b"
            local handle_width = 2

            if mark_in_rt and mark_out_rt and mark_out_rt > mark_in_rt then
                local visible_start = mark_in_rt
                if visible_start < viewport_start_rt then visible_start = viewport_start_rt end
                local visible_end = mark_out_rt
                if visible_end > viewport_end_rt then visible_end = viewport_end_rt end
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

            local function draw_handle(time_rt)
                if not time_rt then
                    return
                end
                if time_rt < viewport_start_rt or time_rt > viewport_end_rt then
                    return
                end
                local x = state_module.time_to_pixel(time_rt, width)
                local handle_x = x - math.floor(handle_width / 2)
                if handle_x < 0 then
                    handle_x = 0
                end
                timeline.add_rect(ruler.widget, handle_x, 0, math.max(handle_width, 2), M.RULER_HEIGHT, edge_color)
            end

            if explicit_mark_in then
                draw_handle(mark_in_rt)
            end
            if explicit_mark_out then
                draw_handle(mark_out_rt)
            end
        end

        draw_mark_region()

        -- Get sequence frame rate
        local frame_rate = get_frame_rate()
        if (frame_rate.fps_numerator / frame_rate.fps_denominator) <= 0 then
            frame_rate = frame_utils.default_frame_rate
        end

        -- Calculate appropriate frame-based interval
        local viewport_start_frames = viewport_start_rt:rescale(frame_rate.fps_numerator, frame_rate.fps_denominator).frames
        local viewport_end_frames = viewport_end_rt:rescale(frame_rate.fps_numerator, frame_rate.fps_denominator).frames
        local viewport_duration_frames = viewport_duration_rt:rescale(frame_rate.fps_numerator, frame_rate.fps_denominator).frames
        if viewport_duration_frames <= 0 then
            return
        end

        local pixels_per_frame = width / viewport_duration_frames
        local interval_frames, format_hint, interval_value = timecode.get_ruler_interval(
            viewport_duration_frames,
            frame_rate,
            100,  -- target pixel spacing
            pixels_per_frame
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

        local minor_interval = nil
        if subdivisions > 0 then
            minor_interval = interval_frames / (subdivisions + 1)
        end

        -- Draw time markers at frame-accurate positions
        local function align_start()
            if format_hint == "seconds" then
                local unit_frames = interval_frames
                return math.floor((viewport_start_frames / unit_frames) + 1e-6) * unit_frames
            elseif format_hint == "minutes" then
                local unit_frames = interval_frames
                return math.floor((viewport_start_frames / unit_frames) + 1e-6) * unit_frames
            else
                -- frames or sub-second
                local unit_frames = interval_frames
                return math.floor((viewport_start_frames / unit_frames) + 1e-6) * unit_frames
            end
        end

        local start_marker = align_start()
        local last_label_end = -math.huge

        local function to_pixel(frame_pos)
            if frame_pos < viewport_start_frames or frame_pos > viewport_end_frames then
                return nil
            end
            local tick_rt = Rational.new(frame_pos, frame_rate.fps_numerator, frame_rate.fps_denominator)
            local x = state_module.time_to_pixel(tick_rt, width)
            if x < 0 or x > width then
                return nil
            end
            return x
        end

        local function draw_tick_at(x, tick_height, color)
            local baseline = M.RULER_HEIGHT - BASELINE_HEIGHT
            timeline.add_line(ruler.widget, x, baseline - tick_height, x, baseline, color, 1)
        end

        local idx = 0
        while true do
            local frame_pos = start_marker + (interval_frames * idx)
            if frame_pos > viewport_end_frames + 0.5 then
                break
            end
            -- snap to nearest frame (already frame-based)
            local snapped_frames = math.floor(frame_pos + 0.5)
            local x = to_pixel(snapped_frames)
            if x then
                -- Timecode label with appropriate precision
                local label = timecode.format_ruler_label(snapped_frames, frame_rate)
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
                        local minor_frame = snapped_frames + (minor_interval * sub)
                        local minor_int = math.floor(minor_frame + 0.5)
                        if minor_int >= viewport_start_frames and minor_int <= viewport_end_frames then
                            local minor_x = to_pixel(minor_int)
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
            idx = idx + 1
        end

        -- Draw playhead marker if in visible range
        if playhead_rt >= viewport_start_rt and playhead_rt <= viewport_end_rt then
            local playhead_x = state_module.time_to_pixel(playhead_rt, width)

            -- DEBUG: Log ruler width and playhead position
            if os.getenv("JVE_DEBUG_PLAYHEAD") == "1" then
                local logger = require("core.logger")
                logger.debug("playhead_debug", string.format(
                    "RULER: width=%d playhead_x=%d playhead_frames=%d",
                    width, playhead_x, playhead_rt.frames or -1
                ))
            end

            -- Filled triangle caret at playhead position
            local handle_width = 14   -- width of triangle base
            local handle_height = 8   -- height from top to tip
            local handle_y = 0
            local tip_y = handle_y + handle_height
            local playhead_color = "#ff6b6b"

            -- Draw filled triangle (points: top-left, top-right, bottom-tip)
            timeline.add_triangle(ruler.widget,
                playhead_x - handle_width/2, handle_y,   -- top-left
                playhead_x + handle_width/2, handle_y,   -- top-right
                playhead_x, tip_y,                        -- bottom tip
                playhead_color)

            -- Vertical line from caret tip to bottom of ruler (connects to timeline playhead line)
            timeline.add_line(ruler.widget, playhead_x, tip_y, playhead_x, M.RULER_HEIGHT, playhead_color, 2)
        end

        -- Trigger Qt repaint
        timeline.update(ruler.widget)
    end

    -- Track whether we've entered scrub mode during this drag
    local scrub_mode_active = false

    -- Mouse event handler for playhead dragging
    local function on_mouse_event(event_type, x, y, button, modifiers)
        local width = select(1, timeline.get_dimensions(ruler.widget))
        local frame_rate = get_frame_rate()

        if event_type == "press" then
            -- Don't set scrub mode yet — a click (press+release) should use
            -- Play mode so the cache populates with nearby frames.
            -- Scrub mode activates on first drag move.
            scrub_mode_active = false

            -- Check if clicking on playhead
            local playhead_rat = state_module.get_playhead_position()
            local playhead_x = state_module.time_to_pixel(playhead_rat, width)

            if math.abs(x - playhead_x) < 10 then
                state_module.set_dragging_playhead(true)
            else
                -- Click anywhere on ruler to set playhead (snap to frame)
                local time_rat = state_module.pixel_to_time(x, width)
                local snapped_rat = frame_utils.snap_to_frame(time_rat, frame_rate)
                state_module.set_playhead_position(snapped_rat)
                state_module.set_dragging_playhead(true)
            end

        elseif event_type == "move" then
            if state_module.is_dragging_playhead() then
                -- Activate scrub mode on first drag move (not click)
                if not scrub_mode_active then
                    local qt_c = require("core.qt_constants")
                    if qt_c.EMP and qt_c.EMP.SET_DECODE_MODE then
                        qt_c.EMP.SET_DECODE_MODE("scrub")
                    end
                    scrub_mode_active = true
                end

                local time_rat = state_module.pixel_to_time(x, width)
                local snapped_rat = frame_utils.snap_to_frame(time_rat, frame_rate)
                state_module.set_playhead_position(snapped_rat)
            end

        elseif event_type == "release" then
            state_module.set_dragging_playhead(false)

            -- Restore decode mode after drag: Play if playback is active,
            -- Park otherwise. Previously always set Park, which left the
            -- decoder in single-frame mode during active playback.
            if scrub_mode_active then
                local qt_c = require("core.qt_constants")
                if qt_c.EMP and qt_c.EMP.SET_DECODE_MODE then
                    local pc = require("core.playback.playback_controller")
                    if pc.is_playing() then
                        qt_c.EMP.SET_DECODE_MODE("play")
                    else
                        qt_c.EMP.SET_DECODE_MODE("park")
                    end
                end
                scrub_mode_active = false
            end
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
