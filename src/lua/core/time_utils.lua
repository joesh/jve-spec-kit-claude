-- Time Utilities: Rational time for frame-locked video and sample-accurate audio.
-- Represents time as (value, rate). Video uses frames at timeline fps; audio uses samples at audio sample rate.

local frame_utils = require("core.frame_utils")

local M = {}

-- Defaults
M.default_frame_rate = frame_utils.default_frame_rate
M.default_audio_rate = 48000

local function normalize_rate(rate, fallback)
    if type(rate) == "number" and rate > 0 then
        return rate
    end
    return fallback
end

local function round_mode(value, mode)
    if mode == "floor" then
        return math.floor(value)
    elseif mode == "ceil" then
        return math.ceil(value)
    end
    -- default: round half up
    return math.floor(value + 0.5)
end

-- Create a RationalTime table.
function M.rational(value, rate)
    return { value = value or 0, rate = normalize_rate(rate, M.default_frame_rate) }
end

-- Convert to a target rate, applying rounding mode ("round" | "floor" | "ceil").
function M.convert(rt, target_rate, mode)
    if not rt then
        return nil, "nil time"
    end
    local rate = normalize_rate(target_rate, rt.rate or M.default_frame_rate)
    if not rate or rate <= 0 then
        return nil, "invalid target rate"
    end
    if rt.rate == rate then
        return { value = rt.value, rate = rate }
    end
    local scaled = (rt.value or 0) * rate / (rt.rate or M.default_frame_rate)
    return { value = round_mode(scaled, mode), rate = rate }
end

-- Add two RationalTime values; result uses rate of lhs unless override provided.
function M.add(lhs, rhs, opts)
    if not lhs or not rhs then
        return nil, "nil operand"
    end
    local target_rate = normalize_rate(opts and opts.rate, lhs.rate or M.default_frame_rate)
    local rhs_conv = M.convert(rhs, target_rate, opts and opts.mode or "round")
    return { value = (lhs.value or 0) + (rhs_conv.value or 0), rate = target_rate }
end

-- Subtract rhs from lhs.
function M.sub(lhs, rhs, opts)
    if not lhs or not rhs then
        return nil, "nil operand"
    end
    local target_rate = normalize_rate(opts and opts.rate, lhs.rate or M.default_frame_rate)
    local rhs_conv = M.convert(rhs, target_rate, opts and opts.mode or "round")
    return { value = (lhs.value or 0) - (rhs_conv.value or 0), rate = target_rate }
end

-- Compare two RationalTimes (returns -1, 0, 1).
function M.compare(lhs, rhs, mode)
    if not lhs or not rhs then
        return nil, "nil operand"
    end
    local rhs_conv = M.convert(rhs, lhs.rate or M.default_frame_rate, mode or "round")
    local a = lhs.value or 0
    local b = rhs_conv.value or 0
    if a < b then return -1 end
    if a > b then return 1 end
    return 0
end

-- Quantize a RationalTime to integer frames at given fps.
function M.to_frames(rt, fps, mode)
    local target_rate = normalize_rate(fps, M.default_frame_rate)
    local conv = M.convert(rt, target_rate, mode or "round")
    return conv and conv.value or nil
end

-- Quantize a RationalTime to integer samples at given sample rate.
function M.to_samples(rt, sample_rate, mode)
    local target_rate = normalize_rate(sample_rate, M.default_audio_rate)
    local conv = M.convert(rt, target_rate, mode or "round")
    return conv and conv.value or nil
end

-- Create RationalTime from frames at fps.
function M.from_frames(frames, fps)
    return { value = frames or 0, rate = normalize_rate(fps, M.default_frame_rate) }
end

-- Create RationalTime from samples at sample rate.
function M.from_samples(samples, sample_rate)
    return { value = samples or 0, rate = normalize_rate(sample_rate, M.default_audio_rate) }
end

-- Convenience: convert milliseconds to RationalTime at a target rate.
function M.from_milliseconds(ms, rate)
    local target_rate = normalize_rate(rate, M.default_frame_rate)
    local seconds = (ms or 0) / 1000.0
    local value = seconds * target_rate
    return { value = round_mode(value, "round"), rate = target_rate }
end

-- Convert a RationalTime to milliseconds (double precision).
function M.to_milliseconds(rt)
    if not rt or not rt.rate or rt.rate <= 0 then
        return nil
    end
    return (rt.value or 0) * 1000.0 / rt.rate
end

return M
