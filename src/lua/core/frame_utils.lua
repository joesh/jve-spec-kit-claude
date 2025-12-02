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
function M.time_to_frame(time_obj, frame_rate)
    local rate = M.normalize_rate(frame_rate)
    local r = Rational.hydrate(time_obj, rate.fps_numerator, rate.fps_denominator)
    
    if not r then return 0, false end
    
    -- Rescale if necessary
    if r.fps_numerator ~= rate.fps_numerator or r.fps_denominator ~= rate.fps_denominator then
        local rescaled = r:rescale(rate.fps_numerator, rate.fps_denominator)
        return rescaled.frames, true
    end
    return r.frames, true
end

-- Convert frame number to Rational time
function M.frame_to_time(frame_number, frame_rate)
    local rate = M.normalize_rate(frame_rate)
    return Rational.new(frame_number, rate.fps_numerator, rate.fps_denominator)
end

-- Snap time to nearest frame boundary
function M.snap_to_frame(time_obj, frame_rate)
    local rate = M.normalize_rate(frame_rate)
    local r = Rational.hydrate(time_obj, rate.fps_numerator, rate.fps_denominator)
    
    if not r then
        return Rational.new(0, rate.fps_numerator, rate.fps_denominator)
    end
    
    return r:rescale(rate.fps_numerator, rate.fps_denominator)
end

-- Snap a delta (relative change) to frame boundaries
-- Returns Rational
function M.snap_delta_to_frame(delta, frame_rate)
    return M.snap_to_frame(delta, frame_rate)
end

-- Format time as timecode string (HH:MM:SS:FF)
function M.format_timecode(time_obj, frame_rate, opts)
    local rate = M.normalize_rate(frame_rate)
    local r = Rational.hydrate(time_obj, rate.fps_numerator, rate.fps_denominator)
    
    -- Get total frames
    local total_frames
    local sign = ""
    
    if r then
        local rescaled = r:rescale(rate.fps_numerator, rate.fps_denominator)
        total_frames = rescaled.frames
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

-- Parse a timecode string into a Rational time using the provided frame rate.
function M.parse_timecode(timecode, frame_rate)
    local rate = M.normalize_rate(frame_rate)
    if not timecode or timecode == "" then
        return nil
    end

    local trimmed = timecode:match("^%s*(.-)%s*$")
    if not trimmed or trimmed == "" then
        return nil
    end

    local sign = 1
    if trimmed:sub(1, 1) == "-" then
        sign = -1
        trimmed = trimmed:sub(2)
    elseif trimmed:sub(1, 1) == "+" then
        trimmed = trimmed:sub(2)
    end

    local parts = {}
    for token in trimmed:gmatch("[%d]+") do
        table.insert(parts, tonumber(token))
    end
    if #parts < 4 then
        return nil
    end

    local hh, mm, ss, ff = parts[1], parts[2], parts[3], parts[4]
    local fps = math.floor((rate.fps_numerator / rate.fps_denominator) + 0.5)
    if fps <= 0 then fps = 1 end

    local total_frames = ff + (ss * fps) + (mm * 60 * fps) + (hh * 3600 * fps)
    if sign < 0 then total_frames = -total_frames end

    return Rational.new(total_frames, rate.fps_numerator, rate.fps_denominator)
end

-- Calculate a "nice" ruler interval (prefers 1/2/5 * 10^k frame buckets)
-- Returns: interval_ms, format_hint, interval_value (in hint units)
function M.get_ruler_interval(viewport_duration_ms, frame_rate, target_pixels, pixels_per_ms)
    local target_ms = target_pixels / (pixels_per_ms > 0 and pixels_per_ms or 1)
    local rate = M.normalize_rate(frame_rate)
    local fps = rate.fps_numerator / rate.fps_denominator
    if fps <= 0 then
        fps = 24
    end
    local frame_ms = 1000.0 / fps

    local seen = {}
    local candidates = {}

    local function add_interval_from_seconds(seconds)
        local frames = seconds * fps
        if frames < 1 then
            frames = 1
        end
        local rounded_frames = math.max(1, math.floor(frames + 0.5))
        local interval_ms = rounded_frames * frame_ms
        local key = math.floor(interval_ms * 1000 + 0.5)
        if seen[key] then
            return
        end
        seen[key] = true

        local hint
        local value
        if rounded_frames < fps then
            hint = "frames"
            value = rounded_frames
        elseif rounded_frames < fps * 60 then
            hint = "seconds"
            value = rounded_frames / fps
        else
            hint = "minutes"
            value = rounded_frames / (fps * 60)
        end

        table.insert(candidates, {
            ms = interval_ms,
            hint = hint,
            value = value,
            frames = rounded_frames,
        })
    end

    local multipliers = {1, 2, 5}
    -- Generate 1/2/5 * 10^k second buckets (covers sub-second through minutes)
    for k = -3, 4 do
        local scale = 10 ^ k
        for _, m in ipairs(multipliers) do
            add_interval_from_seconds(m * scale)
        end
    end

    -- Ensure single-frame and a couple of tiny multiples are always considered
    add_interval_from_seconds(1 / fps)
    add_interval_from_seconds(2 / fps)

    -- For mid/large viewports prefer time-based buckets over fine frame buckets
    if viewport_duration_ms and viewport_duration_ms >= 2500 then
        local filtered = {}
        for _, cand in ipairs(candidates) do
            if not (cand.hint == "frames" and cand.frames < fps) then
                table.insert(filtered, cand)
            end
        end
        if #filtered > 0 then
            candidates = filtered
        end
    end

    table.sort(candidates, function(a, b)
        return a.ms < b.ms
    end)

    local desired_spacing_px = target_pixels
    local min_spacing_px = desired_spacing_px * 0.7

    local best = nil
    local best_spacing = nil

    -- Prefer the smallest interval that keeps spacing reasonably close to target
    for _, cand in ipairs(candidates) do
        local spacing = cand.ms * pixels_per_ms
        if spacing >= min_spacing_px then
            if not best or spacing < best_spacing or (spacing == best_spacing and cand.ms < best.ms) then
                best = cand
                best_spacing = spacing
            end
        end
    end

    -- Fallback: pick the largest interval if everything was too small
    if not best then
        for _, cand in ipairs(candidates) do
            local spacing = cand.ms * pixels_per_ms
            if not best or spacing > best_spacing or (spacing == best_spacing and cand.ms < best.ms) then
                best = cand
                best_spacing = spacing
            end
        end
    end

    -- If we landed on a mid-frame bucket (e.g., 12 frames at 24fps) while viewing several seconds,
    -- prefer to round up to the next whole-second bucket for cleaner labels.
    if best and best.hint == "frames" and best.frames >= (fps / 2) and viewport_duration_ms >= 2000 then
        local one_second_ms = frame_ms * fps
        for _, cand in ipairs(candidates) do
            if cand.ms >= one_second_ms then
                best = cand
                break
            end
        end
    end

    return best.ms, best.hint, best.value
end

return M
