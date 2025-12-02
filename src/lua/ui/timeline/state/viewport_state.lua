-- Timeline Viewport State
-- Manages viewport position, zoom, playhead, and pixel conversions

local M = {}
local Rational = require("core.rational")
local data = require("ui.timeline.state.timeline_state_data")

local viewport_guard_count = 0

-- Helper: Compute content length based on clips in state
local function compute_sequence_content_length()
    local state = data.state
    local max_end = Rational.new(0, state.sequence_frame_rate.fps_numerator, state.sequence_frame_rate.fps_denominator)
    for _, clip in ipairs(state.clips) do
        if getmetatable(clip.timeline_start) == Rational.metatable and getmetatable(clip.duration) == Rational.metatable then
            local clip_end = clip.timeline_start + clip.duration
            if clip_end > max_end then
                max_end = clip_end
            end
        end
    end
    return max_end
end

-- Helper: Calculate timeline extent (content + playhead + buffer)
local function calculate_timeline_extent()
    local state = data.state
    local max_end = compute_sequence_content_length()
    
    local seq_fps = state.sequence_frame_rate
    
    if state.playhead_position > max_end then
        max_end = state.playhead_position
    end

    if state.viewport_start_time and state.viewport_duration then
        local viewport_end = state.viewport_start_time + state.viewport_duration
        if viewport_end > max_end then
            max_end = viewport_end
        end
    end

    -- Use seconds (not raw frames) for buffer and minimum extent to avoid multi-hour baselines
    local buffer = Rational.from_seconds(10, seq_fps.fps_numerator, seq_fps.fps_denominator)
    local min_extent = Rational.from_seconds(60, seq_fps.fps_numerator, seq_fps.fps_denominator)

    return Rational.max(min_extent, max_end + buffer)
end

-- Helper: Clamp viewport start
local function clamp_viewport_start(desired_start, duration)
    local total_extent = calculate_timeline_extent()
    local zero = Rational.new(0, desired_start.fps_numerator, desired_start.fps_denominator)
    local max_start = Rational.max(zero, total_extent - duration)

    if desired_start < zero then return zero end
    if desired_start > max_start then return max_start end
    return desired_start
end

local function ensure_playhead_visible()
    if viewport_guard_count > 0 then return false end
    local state = data.state
    
    local duration = state.viewport_duration
    if not duration or duration.frames <= 0 then return false end

    local start = state.viewport_start_time
    local end_time = start + duration
    local playhead = state.playhead_position

    if playhead < start or playhead > end_time then
        local desired_start = playhead - (duration / 2)
        local clamped = clamp_viewport_start(desired_start, duration)
        if state.viewport_start_time ~= clamped then
            state.viewport_start_time = clamped
            return true
        end
    end
    return false
end

function M.get_viewport_start_time()
    return data.state.viewport_start_time
end

function M.get_viewport_duration()
    return data.state.viewport_duration
end

function M.set_viewport_start_time(time_obj, persist_callback)
    local state = data.state
    local clamped = clamp_viewport_start(time_obj, state.viewport_duration)
    if state.viewport_start_time ~= clamped then
        state.viewport_start_time = clamped
        data.notify_listeners()
        if persist_callback then persist_callback() end
    end
end

function M.set_viewport_duration(duration_obj, persist_callback)
    local state = data.state
    local new_duration = duration_obj
    if type(new_duration) == "number" then
        local fps = state.sequence_frame_rate
        new_duration = Rational.new(new_duration, fps.fps_numerator, fps.fps_denominator)
    end

    if state.viewport_duration ~= new_duration then
        local playhead = state.playhead_position
        local half = new_duration / 2
        local desired_start = playhead - half
        local clamped_start = clamp_viewport_start(desired_start, new_duration)

        state.viewport_duration = new_duration
        state.viewport_start_time = clamped_start
        data.notify_listeners()
        if persist_callback then persist_callback() end
    end
end

function M.get_playhead_position()
    return data.state.playhead_position
end

function M.set_playhead_position(time_obj, persist_callback, selection_callback)
    local state = data.state
    local normalized = time_obj
    if type(normalized) == "number" then
        local fps = state.sequence_frame_rate
        normalized = Rational.new(normalized, fps.fps_numerator, fps.fps_denominator)
    end

    local changed = state.playhead_position ~= normalized
    state.playhead_position = normalized

    local viewport_adjusted = ensure_playhead_visible()

    if changed or viewport_adjusted then
        data.notify_listeners()
        if persist_callback then persist_callback() end
        if changed and selection_callback then selection_callback() end
    end
end

function M.time_to_pixel(time_obj, viewport_width)
    local state = data.state
    local time_ms
    if type(time_obj) == "table" and time_obj.to_seconds then
        time_ms = time_obj:to_seconds() * 1000.0
    else
        time_ms = tonumber(time_obj) or 0
    end

    local start_ms = state.viewport_start_time:to_seconds() * 1000.0
    local duration_ms = state.viewport_duration:to_seconds() * 1000.0
    
    if duration_ms <= 0 then return 0 end
    
    local pixels_per_ms = viewport_width / duration_ms
    return math.floor((time_ms - start_ms) * pixels_per_ms)
end

function M.pixel_to_time(pixel, viewport_width)
    local state = data.state
    local start_ms = state.viewport_start_time:to_seconds() * 1000.0
    local duration_ms = state.viewport_duration:to_seconds() * 1000.0
    
    local pixels_per_ms = viewport_width / duration_ms
    local time_ms = start_ms + (pixel / pixels_per_ms)
    
    local rate = state.sequence_frame_rate
    return Rational.from_seconds(time_ms / 1000.0, rate.fps_numerator, rate.fps_denominator)
end

function M.push_viewport_guard()
    viewport_guard_count = viewport_guard_count + 1
    return viewport_guard_count
end

function M.pop_viewport_guard()
    if viewport_guard_count > 0 then
        viewport_guard_count = viewport_guard_count - 1
    end
    return viewport_guard_count
end

return M
