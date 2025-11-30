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

return M