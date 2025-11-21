-- Frame Utilities: Frame-accurate timing calculations for NLE operations
-- All video editing operations must align to frame boundaries for proper playback

local M = {}

-- Default frame rate (can be overridden per-sequence)
M.default_frame_rate = 30.0

-- Calculate frame duration in milliseconds
function M.frame_duration_ms(frame_rate)
    frame_rate = frame_rate or M.default_frame_rate
    return 1000.0 / frame_rate
end

-- Calculate frame number at given time
-- Returns: frame_number (0-based), exact_match (boolean)
function M.time_to_frame(time_ms, frame_rate)
    frame_rate = frame_rate or M.default_frame_rate
    local frame_duration = M.frame_duration_ms(frame_rate)
    local frame_number = time_ms / frame_duration
    local rounded = math.floor(frame_number + 0.5)
    local exact = math.abs(frame_number - rounded) < 0.001
    return rounded, exact
end

-- Convert frame number to time in milliseconds
function M.frame_to_time(frame_number, frame_rate)
    frame_rate = frame_rate or M.default_frame_rate
    local frame_duration = M.frame_duration_ms(frame_rate)
    return math.floor(frame_number * frame_duration + 0.5)
end

-- Snap time to nearest frame boundary
-- mode: "round" (default), "floor", "ceil"
function M.snap_to_frame(time_ms, frame_rate, mode)
    frame_rate = frame_rate or M.default_frame_rate
    mode = mode or "round"

    local frame_duration = M.frame_duration_ms(frame_rate)
    local frame_number = time_ms / frame_duration

    if mode == "floor" then
        frame_number = math.floor(frame_number)
    elseif mode == "ceil" then
        frame_number = math.ceil(frame_number)
    else  -- "round"
        frame_number = math.floor(frame_number + 0.5)
    end

    return M.frame_to_time(frame_number, frame_rate)
end

-- Check if time is on a frame boundary
function M.is_frame_aligned(time_ms, frame_rate, tolerance_ms)
    frame_rate = frame_rate or M.default_frame_rate
    tolerance_ms = tolerance_ms or 0.5

    local snapped = M.snap_to_frame(time_ms, frame_rate)
    return math.abs(time_ms - snapped) < tolerance_ms
end

-- Snap a delta (relative change) to frame boundaries
-- This is different from snapping absolute time - we want the delta itself to be frame-multiple
function M.snap_delta_to_frame(delta_ms, frame_rate)
    frame_rate = frame_rate or M.default_frame_rate
    local frame_duration = M.frame_duration_ms(frame_rate)

    -- Round to nearest multiple of frame duration
    local frame_count = math.floor(delta_ms / frame_duration + 0.5)
    return math.floor(frame_count * frame_duration + 0.5)
end

-- Format time as timecode string (HH:MM:SS:FF)
function M.format_timecode(time_ms, frame_rate, opts)
    frame_rate = frame_rate or M.default_frame_rate

    local drop_frame = false
    local separator = ":"

    if type(opts) == "boolean" then
        drop_frame = opts
    elseif type(opts) == "table" then
        drop_frame = opts.drop_frame or false
        separator = opts.separator or separator
    end

    local frame_duration = M.frame_duration_ms(frame_rate)
    local abs_ms = math.abs(time_ms or 0)
    local sign = ""
    if time_ms and time_ms < 0 then
        sign = "-"
    end

    local total_frames = math.floor(abs_ms / frame_duration + 0.5)

    -- Drop-frame handling would adjust total_frames here. For now we just flag separator.
    local frames_per_second = math.max(1, math.floor(frame_rate + 0.5))
    local frames_per_minute = frames_per_second * 60
    local frames_per_hour = frames_per_minute * 60

    local hours = math.floor(total_frames / frames_per_hour)
    local remaining = total_frames % frames_per_hour

    local minutes = math.floor(remaining / frames_per_minute)
    remaining = remaining % frames_per_minute

    local seconds = math.floor(remaining / frames_per_second)
    local frames = remaining % frames_per_second

    local sep = drop_frame and ";" or separator
    return string.format("%s%02d%s%02d%s%02d%s%02d", sign, hours, sep, minutes, sep, seconds, sep, frames)
end

-- Parse timecode string to milliseconds
function M.parse_timecode(timecode_str, frame_rate, opts)
    frame_rate = frame_rate or M.default_frame_rate

    if not timecode_str then
        return nil, "Invalid timecode format"
    end

    local trimmed = timecode_str:match("^%s*(.-)%s*$")
    if trimmed == "" then
        return nil, "Invalid timecode format"
    end

    local sign = 1
    if trimmed:sub(1, 1) == "-" then
        sign = -1
        trimmed = trimmed:sub(2)
    elseif trimmed:sub(1, 1) == "+" then
        trimmed = trimmed:sub(2)
    end

    local normalized = trimmed:gsub("[,%;%.]", ":")
    normalized = normalized:gsub("%s+", ":")

    local parts = {}
    for token in normalized:gmatch("[^:]+") do
        table.insert(parts, token)
    end

    if #parts == 0 or #parts > 4 then
        return nil, "Invalid timecode format"
    end

    while #parts < 4 do
        table.insert(parts, 1, "0")
    end

    local hours = tonumber(parts[1])
    local minutes = tonumber(parts[2])
    local seconds = tonumber(parts[3])
    local frames = tonumber(parts[4])

    if not (hours and minutes and seconds and frames) then
        return nil, "Invalid timecode components"
    end

    if minutes < 0 or minutes >= 60 or seconds < 0 or seconds >= 60 or frames < 0 then
        return nil, "Invalid timecode components"
    end

    local frames_per_second = math.max(1, math.floor(frame_rate + 0.5))
    if frames >= frames_per_second then
        seconds = seconds + math.floor(frames / frames_per_second)
        frames = frames % frames_per_second
    end

    if seconds >= 60 then
        minutes = minutes + math.floor(seconds / 60)
        seconds = seconds % 60
    end

    if minutes >= 60 then
        hours = hours + math.floor(minutes / 60)
        minutes = minutes % 60
    end

    local frame_duration = M.frame_duration_ms(frame_rate)
    local total_frames = (hours * 3600 * frame_rate) +
                         (minutes * 60 * frame_rate) +
                         (seconds * frame_rate) +
                         frames

    local time_ms = total_frames * frame_duration
    return sign * math.floor(time_ms + 0.5)
end

-- Validate that clip boundaries are frame-aligned
function M.validate_clip_alignment(clip, frame_rate)
    frame_rate = frame_rate or M.default_frame_rate

    local errors = {}

    if not M.is_frame_aligned(clip.start_value, frame_rate) then
        table.insert(errors, string.format("start_value %dms not frame-aligned", clip.start_value))
    end

    if not M.is_frame_aligned(clip.duration, frame_rate) then
        table.insert(errors, string.format("duration %dms not frame-aligned", clip.duration))
    end

    if clip.source_in and not M.is_frame_aligned(clip.source_in, frame_rate) then
        table.insert(errors, string.format("source_in %dms not frame-aligned", clip.source_in))
    end

    if clip.source_out and not M.is_frame_aligned(clip.source_out, frame_rate) then
        table.insert(errors, string.format("source_out %dms not frame-aligned", clip.source_out))
    end

    return #errors == 0, errors
end

return M
