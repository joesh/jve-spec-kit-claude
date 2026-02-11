--- Playback Helpers: shared utilities for source and timeline playback
--
-- Responsibilities:
-- - Audio control functions (start, stop, sync)
-- - Time/frame conversion utilities
-- - Rational time helpers
--
-- Non-goals:
-- - Does not own playback state (owned by playback_controller)
-- - Does not decide source vs timeline mode
--
-- @file playback_helpers.lua

local M = {}

--------------------------------------------------------------------------------
-- Frame/Time Conversion
--------------------------------------------------------------------------------

--- Calculate frame index from media time (microseconds)
-- @param t_us Media time in microseconds
-- @param fps_num FPS numerator
-- @param fps_den FPS denominator
-- @return Frame index (integer)
function M.calc_frame_from_time_us(t_us, fps_num, fps_den)
    assert(type(t_us) == "number", "playback_helpers.calc_frame_from_time_us: t_us must be number")
    assert(fps_num and fps_den, "playback_helpers.calc_frame_from_time_us: fps not set")
    -- frame = t_us * fps_num / (1000000 * fps_den)
    return math.floor(t_us * fps_num / (1000000 * fps_den))
end

--- Calculate media time (microseconds) from frame index
-- @param frame Frame index
-- @param fps_num FPS numerator
-- @param fps_den FPS denominator
-- @return Media time in microseconds
function M.calc_time_us_from_frame(frame, fps_num, fps_den)
    assert(fps_num and fps_den, "playback_helpers.calc_time_us_from_frame: fps not set")
    -- t_us = frame * 1000000 * fps_den / fps_num
    return math.floor(frame * 1000000 * fps_den / fps_num)
end

--------------------------------------------------------------------------------
-- Audio Control (transport event helpers)
--------------------------------------------------------------------------------

--- Sync audio state with video speed (ONLY call on transport events)
-- @param audio_playback audio_playback module reference
-- @param direction -1=reverse, 0=stopped, 1=forward
-- @param speed magnitude: 0.5, 1, 2, 4, 8
function M.sync_audio(audio_playback, direction, speed)
    if not audio_playback then return end
    if not audio_playback.is_ready() then return end

    -- Speed convention invariants
    assert(speed >= 0, "playback_helpers.sync_audio: speed must be non-negative (magnitude)")
    assert(direction == 1 or direction == -1 or direction == 0,
        "playback_helpers.sync_audio: direction must be -1, 0, or 1")

    -- Calculate signed speed (direction * magnitude)
    local signed_speed = direction * speed
    audio_playback.set_speed(signed_speed)
end

--- Start audio playback (transport event)
-- @param audio_playback audio_playback module reference
-- @param frame Current frame position
-- @param fps_num FPS numerator
-- @param fps_den FPS denominator
-- @param direction -1=reverse, 0=stopped, 1=forward
-- @param speed magnitude: 0.5, 1, 2, 4, 8
function M.start_audio(audio_playback, frame, fps_num, fps_den, direction, speed)
    if not audio_playback then return end
    if not audio_playback.is_ready() then return end

    -- Sync speed first (transport event)
    M.sync_audio(audio_playback, direction, speed)

    -- Sync position from current frame
    local media_time_us = M.calc_time_us_from_frame(frame, fps_num, fps_den)
    audio_playback.seek(media_time_us)

    audio_playback.start()
end

--- Stop audio playback
-- @param audio_playback audio_playback module reference
function M.stop_audio(audio_playback)
    if not audio_playback then return end
    if not audio_playback.is_ready() then return end

    audio_playback.stop()
end

--------------------------------------------------------------------------------
-- Seek Helpers
--------------------------------------------------------------------------------

--- Seek to a Rational time position
-- @param time_rat Rational: Timeline position to seek to
-- @param fps_num FPS numerator

--- Clamp frame index to valid range
-- @param frame Frame index (integer)
-- @param total_frames Total frames in source
-- @return frame_idx Clamped frame index
function M.frame_clamped(frame, total_frames)
    assert(type(frame) == "number", "playback_helpers.frame_clamped: frame must be integer")
    return math.max(0, math.min(frame, total_frames - 1))
end

return M
