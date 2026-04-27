--- Timecode utilities for frame-accurate editing
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
function M.to_string(time_obj, frame_rate, drop_frame, tc_start)
    return frame_utils.format_timecode(time_obj, frame_rate, {drop_frame=drop_frame, tc_start=tc_start})
end

-- Parse timecode string to Rational (delegates to frame_utils)
function M.parse_timecode(timecode, frame_rate)
    return frame_utils.parse_timecode(timecode, frame_rate)
end

-- Calculate appropriate ruler interval in frames
-- Returns: interval_frames, format_hint, interval_value (in hint units)
function M.get_ruler_interval(viewport_duration_frames, frame_rate, target_pixels, pixels_per_frame)
    return frame_utils.get_ruler_interval(viewport_duration_frames, frame_rate, target_pixels, pixels_per_frame)
end

-- Format ruler label
function M.format_ruler_label(time_obj, frame_rate, tc_start)
    -- Accept Rational or frame count; convert to Rational time.
    local rate = frame_utils.normalize_rate(frame_rate)
    local tc_obj
    if getmetatable(time_obj) == Rational.metatable then
        tc_obj = time_obj
    elseif type(time_obj) == "number" then
        tc_obj = Rational.new(time_obj, rate.fps_numerator, rate.fps_denominator)
    else
        error("timecode.format_ruler_label: unsupported time_obj type: " .. type(time_obj))
    end

    -- Always emit full timecode (HH:MM:SS:FF) for ruler labels to avoid ambiguous MM:SS displays.
    local opts = tc_start and tc_start ~= 0 and { tc_start = tc_start } or nil
    return frame_utils.format_timecode(tc_obj, frame_rate, opts)
end

return M
