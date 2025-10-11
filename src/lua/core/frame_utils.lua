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
function M.format_timecode(time_ms, frame_rate, drop_frame)
    frame_rate = frame_rate or M.default_frame_rate
    drop_frame = drop_frame or false

    local total_frames = math.floor(time_ms / M.frame_duration_ms(frame_rate))

    -- Drop-frame timecode is complex - for now just do non-drop
    local frames_per_second = math.floor(frame_rate)
    local frames_per_minute = frames_per_second * 60
    local frames_per_hour = frames_per_minute * 60

    local hours = math.floor(total_frames / frames_per_hour)
    local remaining = total_frames % frames_per_hour

    local minutes = math.floor(remaining / frames_per_minute)
    remaining = remaining % frames_per_minute

    local seconds = math.floor(remaining / frames_per_second)
    local frames = remaining % frames_per_second

    local separator = drop_frame and ";" or ":"
    return string.format("%02d:%02d:%02d%s%02d", hours, minutes, seconds, separator, frames)
end

-- Parse timecode string to milliseconds
function M.parse_timecode(timecode_str, frame_rate)
    frame_rate = frame_rate or M.default_frame_rate

    -- Match HH:MM:SS:FF or HH:MM:SS;FF (drop frame)
    local hours, minutes, seconds, frames = timecode_str:match("(%d+):(%d+):(%d+)[:;](%d+)")

    if not hours then
        return nil, "Invalid timecode format"
    end

    hours = tonumber(hours)
    minutes = tonumber(minutes)
    seconds = tonumber(seconds)
    frames = tonumber(frames)

    local total_frames = frames +
                        (seconds * frame_rate) +
                        (minutes * 60 * frame_rate) +
                        (hours * 60 * 60 * frame_rate)

    return M.frame_to_time(total_frames, frame_rate)
end

-- Validate that clip boundaries are frame-aligned
function M.validate_clip_alignment(clip, frame_rate)
    frame_rate = frame_rate or M.default_frame_rate

    local errors = {}

    if not M.is_frame_aligned(clip.start_time, frame_rate) then
        table.insert(errors, string.format("start_time %dms not frame-aligned", clip.start_time))
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
