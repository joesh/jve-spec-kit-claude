-- Time Utilities: Rational time for frame-locked video and sample-accurate audio.
-- Represents time as (value, rate). Video uses frames at timeline fps; audio uses samples at audio sample rate.

local Rational = require("core.rational")

local M = {}

-- Defaults
M.default_audio_rate = 48000

-- Create a Rational object.
function M.rational(value, fps_numerator, fps_denominator)
    -- If value is already a Rational object, return it.
    if getmetatable(value) == Rational.metatable then
        return value
    end
    -- If fps_numerator is missing but it's a number, assume it's frame count for default fps.
    if type(fps_numerator) == "number" and not fps_denominator then
        return Rational.new(value, fps_numerator)
    end
    return Rational.new(value, fps_numerator, fps_denominator)
end

-- Convert a Rational object to a target rate, applying rounding mode.
function M.convert(rt, target_fps_numerator, target_fps_denominator)
    if getmetatable(rt) ~= Rational.metatable then
        error("M.convert: rt must be a Rational object", 2)
    end
    return rt:rescale(target_fps_numerator, target_fps_denominator)
end

-- Add two Rational objects.
function M.add(lhs, rhs)
    if getmetatable(lhs) ~= Rational.metatable then
        error("M.add: lhs must be a Rational object", 2)
    end
    if getmetatable(rhs) ~= Rational.metatable then
        error("M.add: rhs must be a Rational object", 2)
    end
    return lhs + rhs
end

-- Subtract two Rational objects.
function M.sub(lhs, rhs)
    if getmetatable(lhs) ~= Rational.metatable then
        error("M.sub: lhs must be a Rational object", 2)
    end
    if getmetatable(rhs) ~= Rational.metatable then
        error("M.sub: rhs must be a Rational object", 2)
    end
    return lhs - rhs
end

-- Compare two Rational objects (returns -1, 0, 1).
function M.compare(lhs, rhs)
    if getmetatable(lhs) ~= Rational.metatable then
        error("M.compare: lhs must be a Rational object", 2)
    end
    if getmetatable(rhs) ~= Rational.metatable then
        error("M.compare: rhs must be a Rational object", 2)
    end
    if lhs < rhs then return -1 end
    if lhs == rhs then return 0 end
    return 1
end

-- Quantize a Rational object to integer frames at given fps.
function M.to_frames(rt, fps_numerator, fps_denominator)
    if getmetatable(rt) ~= Rational.metatable then
        error("M.to_frames: rt must be a Rational object", 2)
    end
    local rescaled_rt = rt:rescale(fps_numerator, fps_denominator)
    return rescaled_rt.frames
end

-- Quantize a Rational object to integer samples at given sample rate.
function M.to_samples(rt, sample_rate)
    if getmetatable(rt) ~= Rational.metatable then
        error("M.to_samples: rt must be a Rational object", 2)
    end
    -- Sample rate is equivalent to fps_numerator, with denominator 1
    local rescaled_rt = rt:rescale(sample_rate, 1)
    return rescaled_rt.frames
end

-- Create Rational object from frames at fps.
function M.from_frames(frames, fps_numerator, fps_denominator)
    return Rational.new(frames, fps_numerator, fps_denominator)
end

-- Create Rational object from samples at sample rate.
function M.from_samples(samples, sample_rate)
    return Rational.new(samples, sample_rate, 1)
end

-- Convert milliseconds to Rational at a target rate.
function M.from_milliseconds(ms, fps_numerator, fps_denominator)
    if type(ms) ~= "number" then
        error("M.from_milliseconds: ms must be a number", 2)
    end
    local seconds = ms / 1000.0
    return Rational.from_seconds(seconds, fps_numerator, fps_denominator)
end

-- Convert a Rational object to milliseconds (double precision).
function M.to_milliseconds(rt)
    if type(rt) == "number" then
        -- Treat bare numbers as milliseconds
        return rt
    end
    if rt and type(rt) == "table" then
        -- Try common Rational shape or method
        if getmetatable(rt) == Rational.metatable or rt.to_seconds then
            local ok, seconds = pcall(function() return rt:to_seconds() end)
            if ok then
                return seconds * 1000.0
            end
        end
        -- As a fallback, try hydrating
        local hydrated = Rational.hydrate and Rational.hydrate(rt)
        if hydrated then
            return hydrated:to_seconds() * 1000.0
        end
    end
    error("M.to_milliseconds: rt must be a Rational object or millisecond number", 2)
end

return M
