-- time_utils.lua
-- Time conversions for Rational (frames @ rate), plus a small set of filename-safe date helpers.

local Rational = require("core.rational")

local M = {}

M.default_audio_rate = 48000

local function require_number(value, name)
    if value == nil then
        error("FATAL: time_utils: missing " .. tostring(name), 3)
    end
    if type(value) ~= "number" then
        error("FATAL: time_utils: " .. tostring(name) .. " must be a number", 3)
    end
end

local function normalize_rate(fps_numerator, fps_denominator)
    require_number(fps_numerator, "fps_numerator")
    if fps_denominator == nil then
        fps_denominator = 1
    end
    require_number(fps_denominator, "fps_denominator")
    return fps_numerator, fps_denominator
end

function M.rational(frames, fps_numerator, fps_denominator)
    local num, den = normalize_rate(fps_numerator, fps_denominator)
    require_number(frames, "frames")
    return Rational.new(frames, num, den)
end

function M.from_frames(frames, fps_numerator, fps_denominator)
    return M.rational(frames, fps_numerator, fps_denominator)
end

function M.to_frames(time_obj, fps_numerator, fps_denominator)
    local num, den = normalize_rate(fps_numerator, fps_denominator)
    if getmetatable(time_obj) ~= Rational.metatable then
        error("FATAL: time_utils.to_frames requires a Rational time_obj", 2)
    end
    return time_obj:rescale(num, den).frames
end

function M.add(lhs, rhs)
    if getmetatable(lhs) ~= Rational.metatable then
        error("FATAL: time_utils.add requires Rational lhs", 2)
    end
    if getmetatable(rhs) ~= Rational.metatable then
        error("FATAL: time_utils.add requires Rational rhs", 2)
    end
    return lhs + rhs
end

function M.compare(a, b)
    if getmetatable(a) ~= Rational.metatable then
        error("FATAL: time_utils.compare requires Rational a", 2)
    end
    if getmetatable(b) ~= Rational.metatable then
        error("FATAL: time_utils.compare requires Rational b", 2)
    end

    local left = a.frames * a.fps_denominator * b.fps_numerator
    local right = b.frames * b.fps_denominator * a.fps_numerator
    if left == right then
        return 0
    end
    return left < right and -1 or 1
end

function M.to_milliseconds(time_obj)
    if getmetatable(time_obj) ~= Rational.metatable then
        error("FATAL: time_utils.to_milliseconds requires a Rational time_obj", 2)
    end
    return (time_obj.frames * time_obj.fps_denominator * 1000.0) / time_obj.fps_numerator
end

function M.from_milliseconds(milliseconds, fps_numerator, fps_denominator)
    local num, den = normalize_rate(fps_numerator, fps_denominator)
    require_number(milliseconds, "milliseconds")
    local numerator = milliseconds * num
    local divisor = 1000 * den
    local frames = math.floor((numerator + (divisor / 2)) / divisor)
    return Rational.new(frames, num, den)
end

function M.from_samples(samples, sample_rate)
    require_number(samples, "samples")
    require_number(sample_rate, "sample_rate")
    return Rational.new(samples, sample_rate, 1)
end

function M.to_samples(time_obj, sample_rate)
    if getmetatable(time_obj) ~= Rational.metatable then
        error("FATAL: time_utils.to_samples requires a Rational time_obj", 2)
    end
    require_number(sample_rate, "sample_rate")
    return time_obj:rescale(sample_rate, 1).frames
end

-- Human-readable datestamp suitable for filenames.
-- Example: 2025-12-15_14-03-27
function M.human_datestamp_for_filename(timestamp_seconds)
    require_number(timestamp_seconds, "timestamp_seconds")
    return os.date("%Y-%m-%d_%H-%M-%S", timestamp_seconds)
end

return M
