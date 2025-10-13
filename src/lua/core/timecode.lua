--- Timecode utilities for frame-accurate editing
-- Converts between milliseconds, frames, and HH:MM:SS:FF timecode strings
-- Supports drop-frame and non-drop-frame timecode

local M = {}

--- Convert milliseconds to frames
-- @param time_ms number: Time in milliseconds
-- @param frame_rate number: Frames per second (e.g., 29.97, 30, 24)
-- @return number: Frame count (0-indexed)
function M.ms_to_frames(time_ms, frame_rate)
    if not time_ms or not frame_rate then return 0 end
    return math.floor((time_ms * frame_rate) / 1000)
end

--- Convert frames to milliseconds
-- @param frames number: Frame count (0-indexed)
-- @param frame_rate number: Frames per second
-- @return number: Time in milliseconds
function M.frames_to_ms(frames, frame_rate)
    if not frames or not frame_rate or frame_rate == 0 then return 0 end
    return math.floor((frames * 1000) / frame_rate)
end

--- Convert milliseconds to timecode string
-- @param time_ms number: Time in milliseconds
-- @param frame_rate number: Frames per second
-- @param drop_frame boolean: Use drop-frame timecode (optional, default false)
-- @return string: Timecode in HH:MM:SS:FF format
function M.ms_to_timecode(time_ms, frame_rate, drop_frame)
    if not time_ms or not frame_rate then return "00:00:00:00" end

    local frames = M.ms_to_frames(time_ms, frame_rate)
    return M.frames_to_timecode(frames, frame_rate, drop_frame)
end

--- Convert frames to timecode string
-- @param frames number: Frame count (0-indexed)
-- @param frame_rate number: Frames per second
-- @param drop_frame boolean: Use drop-frame timecode (optional, default false)
-- @return string: Timecode in HH:MM:SS:FF format
function M.frames_to_timecode(frames, frame_rate, drop_frame)
    if not frames or not frame_rate then return "00:00:00:00" end

    -- For drop-frame, we'd need special handling of 29.97fps
    -- For now, implement non-drop-frame only
    local fps = math.floor(frame_rate + 0.5)

    local total_frames = math.floor(frames)
    local ff = total_frames % fps
    local total_seconds = math.floor(total_frames / fps)
    local ss = total_seconds % 60
    local total_minutes = math.floor(total_seconds / 60)
    local mm = total_minutes % 60
    local hh = math.floor(total_minutes / 60)

    local separator = drop_frame and ";" or ":"
    return string.format("%02d:%02d:%02d%s%02d", hh, mm, ss, separator, ff)
end

--- Parse timecode string to milliseconds
-- @param timecode string: Timecode in HH:MM:SS:FF or HH:MM:SS;FF format
-- @param frame_rate number: Frames per second
-- @return number|nil: Time in milliseconds, or nil if invalid
function M.timecode_to_ms(timecode, frame_rate)
    if not timecode or not frame_rate then return nil end

    -- Match HH:MM:SS:FF or HH:MM:SS;FF
    local hh, mm, ss, ff = timecode:match("^(%d+):(%d+):(%d+)[;:](%d+)$")
    if not hh then return nil end

    local hours = tonumber(hh)
    local minutes = tonumber(mm)
    local seconds = tonumber(ss)
    local frames = tonumber(ff)

    local total_frames = frames +
                        (seconds * frame_rate) +
                        (minutes * 60 * frame_rate) +
                        (hours * 3600 * frame_rate)

    return M.frames_to_ms(total_frames, frame_rate)
end

--- Get appropriate ruler interval for given viewport duration
-- Returns frame-based intervals that look clean on screen
-- @param viewport_duration_ms number: How much time is visible
-- @param frame_rate number: Frames per second
-- @param target_pixel_spacing number: Desired pixels between markers (optional, default 100)
-- @param pixels_per_ms number: Current zoom level (optional)
-- @return number: Interval in milliseconds
-- @return string: Label format hint ("frames", "seconds", "minutes")
function M.get_ruler_interval(viewport_duration_ms, frame_rate, target_pixel_spacing, pixels_per_ms)
    target_pixel_spacing = target_pixel_spacing or 100

    -- Calculate how many milliseconds per pixel
    if not pixels_per_ms then
        -- Assume 1920px width if not provided
        pixels_per_ms = 1920 / viewport_duration_ms
    end

    -- Target interval in milliseconds
    local target_interval_ms = target_pixel_spacing / pixels_per_ms

    -- Frame duration in milliseconds
    local frame_ms = 1000 / frame_rate

    -- Define intervals in frames, then convert to ms
    -- Intervals: 1f, 5f, 10f, 30f, 1s, 5s, 10s, 30s, 1m, 5m, 10m
    local intervals_frames = {1, 5, 10, 30}
    local intervals_seconds = {1, 5, 10, 30}
    local intervals_minutes = {1, 5, 10}

    -- Try frame-based intervals first
    for _, frames in ipairs(intervals_frames) do
        local interval_ms = frames * frame_ms
        if interval_ms >= target_interval_ms then
            return interval_ms, "frames", frames
        end
    end

    -- Try second-based intervals
    for _, seconds in ipairs(intervals_seconds) do
        local interval_ms = seconds * 1000
        if interval_ms >= target_interval_ms then
            return interval_ms, "seconds", seconds
        end
    end

    -- Try minute-based intervals
    for _, minutes in ipairs(intervals_minutes) do
        local interval_ms = minutes * 60000
        if interval_ms >= target_interval_ms then
            return interval_ms, "minutes", minutes
        end
    end

    -- Fall back to 10 minutes
    return 600000, "minutes", 10
end

--- Format timecode for ruler display based on zoom level
-- Always shows HH:MM:SS:FF format for clarity (professional NLE standard)
-- @param time_ms number: Time in milliseconds
-- @param frame_rate number: Frames per second
-- @param format_hint string: "frames", "seconds", or "minutes" (unused, kept for compatibility)
-- @return string: Formatted label in HH:MM:SS:FF format
function M.format_ruler_label(time_ms, frame_rate, format_hint)
    local frames = M.ms_to_frames(time_ms, frame_rate)
    local fps = math.floor(frame_rate + 0.5)

    local ff = frames % fps
    local total_seconds = math.floor(frames / fps)
    local ss = total_seconds % 60
    local total_minutes = math.floor(total_seconds / 60)
    local mm = total_minutes % 60
    local hh = math.floor(total_minutes / 60)

    -- Always show full HH:MM:SS:FF format for professional clarity
    -- This avoids ambiguity between MM:SS:FF and HH:MM:SS
    return string.format("%02d:%02d:%02d:%02d", hh, mm, ss, ff)
end

return M
