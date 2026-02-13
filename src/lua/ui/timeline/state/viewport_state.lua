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
-- Size: ~172 LOC
-- Volatility: unknown
--
-- @file viewport_state.lua
-- Original intent (unreviewed):
-- Timeline Viewport State
-- Manages viewport position, zoom, playhead, and pixel conversions
local M = {}
local data = require("ui.timeline.state.timeline_state_data")

local viewport_guard_count = 0

-- Helper: Compute content length based on clips in state (integer frames)
local function compute_sequence_content_length()
    local state = data.state
    local max_end = 0
    for _, clip in ipairs(state.clips) do
        if type(clip.timeline_start) == "number" and type(clip.duration) == "number" then
            local clip_end = clip.timeline_start + clip.duration
            if clip_end > max_end then
                max_end = clip_end
            end
        end
    end
    return max_end
end

-- Helper: Calculate timeline extent (content + playhead + buffer) in frames
local function calculate_timeline_extent()
    local state = data.state
    local max_end = compute_sequence_content_length()

    local seq_fps = state.sequence_frame_rate
    assert(seq_fps and seq_fps.fps_numerator and seq_fps.fps_denominator,
        "viewport_state: missing sequence_frame_rate")

    if state.playhead_position > max_end then
        max_end = state.playhead_position
    end

    if state.viewport_start_time and state.viewport_duration then
        local viewport_end = state.viewport_start_time + state.viewport_duration
        if viewport_end > max_end then
            max_end = viewport_end
        end
    end

    -- Buffer and minimum extent in frames (derived from seconds)
    local fps = seq_fps.fps_numerator / seq_fps.fps_denominator
    local buffer_frames = math.floor(10 * fps)  -- 10 seconds
    local min_extent_frames = math.floor(60 * fps)  -- 60 seconds

    return math.max(min_extent_frames, max_end + buffer_frames)
end

-- Helper: Clamp viewport start (all integer frames)
local function clamp_viewport_start(desired_start, duration)
    assert(type(desired_start) == "number" and desired_start == math.floor(desired_start),
        "viewport_state: desired_start must be integer, got " .. tostring(desired_start))
    assert(type(duration) == "number" and duration == math.floor(duration),
        "viewport_state: duration must be integer, got " .. tostring(duration))

    local total_extent = calculate_timeline_extent()
    local max_start = math.max(0, total_extent - duration)

    if desired_start < 0 then return 0 end
    if desired_start > max_start then return max_start end
    return desired_start
end

local function ensure_playhead_visible()
    if viewport_guard_count > 0 then return false end
    local state = data.state

    local duration = state.viewport_duration
    if type(duration) ~= "number" or duration <= 0 then return false end

    local start = state.viewport_start_time
    local end_time = start + duration
    local playhead = state.playhead_position

    if playhead < start or playhead > end_time then
        local desired_start = playhead - math.floor(duration / 2)
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
    assert(type(time_obj) == "number" and time_obj == math.floor(time_obj),
        "viewport_state.set_viewport_start_time: time must be integer, got " .. tostring(time_obj))
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
    assert(type(duration_obj) == "number" and duration_obj == math.floor(duration_obj),
        "viewport_state.set_viewport_duration: duration must be integer, got " .. tostring(duration_obj))

    if state.viewport_duration ~= duration_obj then
        local playhead = state.playhead_position
        local half = math.floor(duration_obj / 2)
        local desired_start = playhead - half
        local clamped_start = clamp_viewport_start(desired_start, duration_obj)

        state.viewport_duration = duration_obj
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
    assert(type(time_obj) == "number" and time_obj == math.floor(time_obj),
        "viewport_state.set_playhead_position: time must be integer frame, got " .. tostring(time_obj))

    local changed = state.playhead_position ~= time_obj
    state.playhead_position = time_obj

    local viewport_adjusted = ensure_playhead_visible()

    if changed or viewport_adjusted then
        data.notify_listeners()
        if persist_callback then persist_callback() end
        if changed and selection_callback then selection_callback() end
    end
end

-- Convert time (integer frame) to pixel position
function M.time_to_pixel(time_obj, viewport_width)
    local state = data.state
    assert(type(time_obj) == "number" and math.floor(time_obj) == time_obj,
        "viewport_state.time_to_pixel: time must be integer frame")

    local start_frames = state.viewport_start_time
    local duration_frames = state.viewport_duration

    if type(start_frames) ~= "number" or type(duration_frames) ~= "number" then
        return 0
    end
    if duration_frames <= 0 then return 0 end

    local delta_frames = time_obj - start_frames
    local pixels_per_frame = viewport_width / duration_frames
    return math.floor(delta_frames * pixels_per_frame)
end

-- Convert pixel position to time (returns integer frame)
function M.pixel_to_time(pixel, viewport_width)
    local state = data.state
    local start_frames = state.viewport_start_time
    local duration_frames = state.viewport_duration

    if type(start_frames) ~= "number" or type(duration_frames) ~= "number" then
        return 0
    end
    if duration_frames <= 0 then
        return start_frames
    end

    local pixels_per_frame = viewport_width / duration_frames
    local delta_frames = pixel / pixels_per_frame
    return math.floor(start_frames + delta_frames + 0.5)
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
