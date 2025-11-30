-- Timecode utilities for frame-accurate editing
-- Refactored to use Rational Time objects

local Rational = require("core.rational")
local frame_utils = require("core.frame_utils")

local M = {}

-- Convert Rational/MS to Frames (Integer)
function M.to_frames(time_obj, frame_rate)
    local frames, _ = frame_utils.time_to_frame(time_obj, frame_rate)
    return frames
end

-- Convert Frames to Rational
function M.to_time(frames, frame_rate)
    return frame_utils.frame_to_time(frames, frame_rate)
end

-- Format time object to timecode string
function M.to_string(time_obj, frame_rate, drop_frame)
    return frame_utils.format_timecode(time_obj, frame_rate, {drop_frame=drop_frame})
end

-- Parse timecode string to Rational
function M.parse_timecode(timecode, frame_rate)
    local rate = frame_utils.normalize_rate(frame_rate)
    
    if not timecode then return nil end
    local trimmed = timecode:match("^%s*(.-)%s*$")
    if not trimmed or trimmed == "" then return nil end

    local sign = 1
    if trimmed:sub(1, 1) == "-" then
        sign = -1
        trimmed = trimmed:sub(2)
    elseif trimmed:sub(1, 1) == "+" then
        trimmed = trimmed:sub(2)
    end

    -- Split by separators
    local parts = {}
    for token in trimmed:gmatch("[%d]+") do
        table.insert(parts, tonumber(token))
    end

    -- Pad or validation could go here
    -- Assuming HH:MM:SS:FF
    if #parts < 4 then return nil end
    
    local hh = parts[1]
    local mm = parts[2]
    local ss = parts[3]
    local ff = parts[4]

    local fps = math.floor((rate.fps_numerator / rate.fps_denominator) + 0.5)
    
    local total_frames = ff + (ss * fps) + (mm * 60 * fps) + (hh * 3600 * fps)
    if sign < 0 then total_frames = -total_frames end
    
    return Rational.new(total_frames, rate.fps_numerator, rate.fps_denominator)
end

-- Calculate appropriate ruler interval
-- Returns: interval_ms, format_hint, interval_value (in hint units)
function M.get_ruler_interval(viewport_duration_ms, frame_rate, target_pixels, pixels_per_ms)
    local target_ms = target_pixels / pixels_per_ms
    local rate = frame_utils.normalize_rate(frame_rate)
    local fps = rate.fps_numerator / rate.fps_denominator
    local frame_ms = 1000.0 / fps

    -- Define tiers
    -- 1. Frame level
    if target_ms < frame_ms * 5 then
        return frame_ms, "frames", 1
    elseif target_ms < frame_ms * 10 then
        return frame_ms * 5, "frames", 5
    elseif target_ms < 1000 then
        -- Sub-second (frames)
        local frames = math.ceil(target_ms / frame_ms)
        return frames * frame_ms, "frames", frames
    elseif target_ms < 5000 then
        return 1000, "seconds", 1
    elseif target_ms < 10000 then
        return 5000, "seconds", 5
    elseif target_ms < 30000 then
        return 10000, "seconds", 10
    elseif target_ms < 60000 then
        return 30000, "seconds", 30
    else
        return 60000, "minutes", 1
    end
end

-- Format ruler label
function M.format_ruler_label(time_ms, frame_rate, hint)
    if hint == "frames" or not hint then
        -- Full Timecode
        local r = Rational.from_seconds(time_ms / 1000.0) -- Approx
        -- Better: use frame_utils
        return frame_utils.format_timecode(time_ms, frame_rate)
    elseif hint == "seconds" then
        -- MM:SS
        local seconds = math.floor(time_ms / 1000.0)
        local minutes = math.floor(seconds / 60)
        local secs = seconds % 60
        return string.format("%02d:%02d", minutes, secs)
    elseif hint == "minutes" then
        -- HH:MM
        local minutes = math.floor(time_ms / 60000.0)
        local hours = math.floor(minutes / 60)
        local mins = minutes % 60
        return string.format("%02d:%02d", hours, mins)
    end
    return ""
end

return M