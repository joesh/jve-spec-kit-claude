-- Frame Utilities: Frame-accurate timing calculations for NLE operations
-- Refactored to use Rational Time objects

local Rational = require("core.rational")

local M = {}

-- Default frame rate: 30/1 (integer tuple)
M.default_frame_rate = { fps_numerator = 30, fps_denominator = 1 }

-- Helper: Normalize rate input to table
function M.normalize_rate(rate)
    if not rate then
        return M.default_frame_rate
    end
    if type(rate) == "table" and rate.fps_numerator then
        return rate
    end
    if type(rate) == "number" then
        return { fps_numerator = math.floor(rate + 0.5), fps_denominator = 1 }
    end
    return M.default_frame_rate
end

-- Calculate frame duration (Rational object)
function M.frame_duration(frame_rate)
    local rate = M.normalize_rate(frame_rate)
    -- 1 frame duration = 1 / (num/den) = den/num seconds?
    -- No, 1 frame IS 1 unit in the timebase.
    -- Rational(1, rate.num, rate.den) represents 1 frame's duration in time.
    return Rational.new(1, rate.fps_numerator, rate.fps_denominator)
end

-- Legacy helper: frame duration in ms (float)
function M.frame_duration_ms(frame_rate)
    local rate = M.normalize_rate(frame_rate)
    return (rate.fps_denominator / rate.fps_numerator) * 1000.0
end

-- Convert Rational time to frame number (integer)
-- This assumes the time object is already in the correct timebase.
-- If not, it rescales it.
function M.time_to_frame(time_obj, frame_rate)
    local rate = M.normalize_rate(frame_rate)
    
    if type(time_obj) == "number" then
        -- Legacy: treat as milliseconds
        local seconds = time_obj / 1000.0
        local r = Rational.from_seconds(seconds, rate.fps_numerator, rate.fps_denominator)
        return r.frames, true
    end
    
    if type(time_obj) == "table" and time_obj.frames then
        -- Rescale if necessary
        if time_obj.fps_numerator ~= rate.fps_numerator or time_obj.fps_denominator ~= rate.fps_denominator then
            local rescaled = time_obj:rescale(rate.fps_numerator, rate.fps_denominator)
            return rescaled.frames, true
        end
        return time_obj.frames, true
    end
    
    return 0, false
end

-- Convert frame number to Rational time
function M.frame_to_time(frame_number, frame_rate)
    local rate = M.normalize_rate(frame_rate)
    return Rational.new(frame_number, rate.fps_numerator, rate.fps_denominator)
end

-- Snap time to nearest frame boundary
-- For Rational time in the correct base, this is a no-op (it's always integer frames).
-- If converting from seconds/ms or different rate, it rescales.
function M.snap_to_frame(time_obj, frame_rate)
    local rate = M.normalize_rate(frame_rate)
    if type(time_obj) == "number" then
        -- Legacy MS
        local seconds = time_obj / 1000.0
        return Rational.from_seconds(seconds, rate.fps_numerator, rate.fps_denominator)
    end
    if type(time_obj) == "table" and time_obj.frames then
        return time_obj:rescale(rate.fps_numerator, rate.fps_denominator)
    end
    return Rational.new(0, rate.fps_numerator, rate.fps_denominator)
end

-- Snap a delta (relative change) to frame boundaries
-- Returns Rational
function M.snap_delta_to_frame(delta, frame_rate)
    return M.snap_to_frame(delta, frame_rate)
end

-- Format time as timecode string (HH:MM:SS:FF)
function M.format_timecode(time_obj, frame_rate, opts)
    local rate = M.normalize_rate(frame_rate)
    
    -- Get total frames
    local total_frames
    local sign = ""
    
    if type(time_obj) == "number" then
        if time_obj < 0 then sign = "-" end
        local abs_ms = math.abs(time_obj)
        local seconds = abs_ms / 1000.0
        local r = Rational.from_seconds(seconds, rate.fps_numerator, rate.fps_denominator)
        total_frames = r.frames
    elseif type(time_obj) == "table" and time_obj.frames then
        local r = time_obj:rescale(rate.fps_numerator, rate.fps_denominator)
        total_frames = r.frames
        if total_frames < 0 then
            sign = "-"
            total_frames = -total_frames
        end
    else
        total_frames = 0
    end

    local drop_frame = false
    local separator = ":"
    if type(opts) == "table" then
        drop_frame = opts.drop_frame or false
        separator = opts.separator or separator
    end

    -- Standard NLE Timecode math (Non-Drop for now)
    -- Rate calculation:
    -- 24/1 -> 24
    -- 30000/1001 -> 29.97 -> 30 (NDF)
    local fps = math.floor((rate.fps_numerator / rate.fps_denominator) + 0.5)
    if fps == 0 then fps = 1 end

    local frames_per_minute = fps * 60
    local frames_per_hour = frames_per_minute * 60

    local hours = math.floor(total_frames / frames_per_hour)
    local remaining = total_frames % frames_per_hour

    local minutes = math.floor(remaining / frames_per_minute)
    remaining = remaining % frames_per_minute

    local seconds = math.floor(remaining / fps)
    local frames = remaining % fps

    local sep = drop_frame and ";" or separator
    return string.format("%s%02d%s%02d%s%02d%s%02d", sign, hours, sep, minutes, sep, seconds, sep, frames)
end

return M