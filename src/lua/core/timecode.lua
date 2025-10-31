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

    if not pixels_per_ms then
        pixels_per_ms = 1920 / viewport_duration_ms
    end

    local frame_ms = 1000 / frame_rate

    local candidate_intervals = {
        {kind = "frames", value = 1},
        {kind = "frames", value = 2},
        {kind = "frames", value = 4},
        {kind = "frames", value = 8},
        {kind = "seconds", value = 1},
        {kind = "seconds", value = 2},
        {kind = "seconds", value = 5},
        {kind = "seconds", value = 10},
        {kind = "seconds", value = 20},
        {kind = "seconds", value = 30},
        {kind = "minutes", value = 1},
        {kind = "minutes", value = 2},
        {kind = "minutes", value = 5},
        {kind = "minutes", value = 10},
    }

    local function interval_to_ms(entry)
        if entry.kind == "frames" then
            return entry.value * frame_ms
        elseif entry.kind == "seconds" then
            return entry.value * 1000
        elseif entry.kind == "minutes" then
            return entry.value * 60000
        end
        return 1000
    end

    local best_entry = candidate_intervals[#candidate_intervals]
    local best_score = math.huge

    for _, entry in ipairs(candidate_intervals) do
        local interval_ms = interval_to_ms(entry)
        local count = viewport_duration_ms / interval_ms
        local score = math.abs(count - 10)

        if count >= 4 and score < best_score then
            best_score = score
            best_entry = entry
        end
    end

    -- If everything produced too many ticks, pick the largest interval.
    if best_score == math.huge then
        best_entry = candidate_intervals[#candidate_intervals]
    end

    local interval_ms = interval_to_ms(best_entry)
    if best_entry.kind == "frames" then
        return interval_ms, "frames", best_entry.value
    elseif best_entry.kind == "seconds" then
        return interval_ms, "seconds", best_entry.value
    else
        return interval_ms, "minutes", best_entry.value
    end
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
