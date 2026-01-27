--- JKL Shuttle Playback Controller
--
-- Responsibilities:
-- - Manages playback state (playing/stopped, direction, speed)
-- - Implements JKL shuttle behavior with speed ramping
-- - Schedules frame display via timer
--
-- **VIDEO FOLLOWS AUDIO.** During playback, video queries audio_playback.get_media_time_us()
-- to determine which frame to display. Video NEVER pushes time into audio.
-- sync_audio() is called ONLY on transport events (start, shuttle, slow_play, seek).
--
-- Non-goals:
-- - Does not own video decoding (delegates to viewer_panel)
-- - Does not handle keyboard input (delegated to keyboard_shortcuts)
--
-- @file playback_controller.lua

local logger = require("core.logger")
local media_cache = require("ui.media_cache")

local M = {
    state = "stopped",  -- "stopped" | "playing"
    direction = 0,      -- -1=reverse, 0=stopped, 1=forward
    speed = 1,          -- magnitude: 0.5, 1, 2, 4, 8
    frame = 0,          -- current fractional frame position
    total_frames = 0,

    -- Rational FPS (no float-only storage)
    fps_num = nil,
    fps_den = nil,
    fps = nil,  -- fps_num/fps_den for display/interval only

    -- Frame-derived max media time (for audio clamp)
    max_media_time_us = 0,

    -- Transport mode: how we're playing (chooses boundary behavior)
    -- "none"    = stopped
    -- "shuttle" = JKL shuttle (latches at boundaries)
    -- "play"    = spacebar play (stops at boundaries)
    transport_mode = "none",

    -- Boundary latch state
    latched = false,
    latched_boundary = nil,  -- "start" | "end" | nil
}

-- Viewer panel reference (set via init)
local viewer_panel = nil

-- Audio playback module (optional, set via init_audio)
local audio_playback = nil

-- Initialize with viewer panel reference
function M.init(vp)
    assert(vp, "playback_controller.init: viewer_panel is nil")
    viewer_panel = vp
end

-- Initialize audio playback (optional)
-- @param ap audio_playback module reference
function M.init_audio(ap)
    audio_playback = ap
    logger.debug("playback_controller", "Audio playback initialized")
end

--------------------------------------------------------------------------------
-- Frame/Time Conversion (rational arithmetic)
--------------------------------------------------------------------------------

--- Calculate frame index from media time (microseconds)
-- Uses rational fps for precision (localized for future int64 swap).
-- @param t_us Media time in microseconds
-- @return Frame index (integer)
function M.calc_frame_from_time_us(t_us)
    assert(type(t_us) == "number", "playback_controller.calc_frame_from_time_us: t_us must be number")
    assert(M.fps_num and M.fps_den, "playback_controller.calc_frame_from_time_us: fps not set")
    -- frame = t_us * fps_num / (1000000 * fps_den)
    return math.floor(t_us * M.fps_num / (1000000 * M.fps_den))
end

--- Calculate media time (microseconds) from frame index
-- @param frame Frame index
-- @return Media time in microseconds
local function calc_time_us_from_frame(frame)
    assert(M.fps_num and M.fps_den, "playback_controller.calc_time_us_from_frame: fps not set")
    -- t_us = frame * 1000000 * fps_den / fps_num
    return math.floor(frame * 1000000 * M.fps_den / M.fps_num)
end

--------------------------------------------------------------------------------
-- Audio Sync (ONLY on transport events)
--------------------------------------------------------------------------------

--- Sync audio state with video (ONLY call on transport events, NOT from _tick)
-- Transport events: start, shuttle, slow_play, seek
local function sync_audio()
    if not audio_playback then return end
    if not audio_playback.initialized then return end

    -- Speed convention invariants
    assert(M.speed >= 0, "playback_controller: speed must be non-negative (magnitude)")
    assert(M.direction == 1 or M.direction == -1 or M.direction == 0,
        "playback_controller: direction must be -1, 0, or 1")

    -- Calculate signed speed (direction * magnitude)
    local signed_speed = M.direction * M.speed
    audio_playback.set_speed(signed_speed)
end

--- Start audio playback (transport event)
local function start_audio()
    if not audio_playback then return end
    if not audio_playback.initialized then return end

    -- Sync speed first (transport event)
    sync_audio()

    -- Sync position from current frame
    local media_time_us = calc_time_us_from_frame(M.frame)
    audio_playback.seek(media_time_us)

    audio_playback.start()
end

--- Stop audio playback
local function stop_audio()
    if not audio_playback then return end
    if not audio_playback.initialized then return end

    audio_playback.stop()
end

--------------------------------------------------------------------------------
-- Source Configuration
--------------------------------------------------------------------------------

--- Set source media parameters (call when loading new media)
-- @param total_frames Total frame count (required, >= 1)
-- @param fps_num FPS numerator (required, > 0)
-- @param fps_den FPS denominator (required, > 0)
function M.set_source(total_frames, fps_num, fps_den)
    assert(total_frames and total_frames >= 1,
        "playback_controller.set_source: total_frames must be >= 1")
    assert(fps_num and fps_num > 0,
        "playback_controller.set_source: fps_num must be > 0")
    assert(fps_den and fps_den > 0,
        "playback_controller.set_source: fps_den must be > 0")

    M.total_frames = total_frames
    M.fps_num = fps_num
    M.fps_den = fps_den
    M.fps = fps_num / fps_den  -- for display/interval only
    M.frame = 0

    -- Compute max media time for audio clamp (frame-derived, not container metadata)
    -- Last valid frame is total_frames - 1
    M.max_media_time_us = calc_time_us_from_frame(total_frames - 1)

    -- Inform audio of max time (required before start)
    if audio_playback and audio_playback.initialized then
        audio_playback.set_max_media_time(M.max_media_time_us)
    end

    M.stop()
    logger.debug("playback_controller", string.format(
        "Source set: %d frames @ %d/%d fps (max_time=%.3fs)",
        total_frames, fps_num, fps_den, M.max_media_time_us / 1000000
    ))
end

--------------------------------------------------------------------------------
-- Transport Control
--------------------------------------------------------------------------------

--- Shuttle in given direction (1=forward, -1=reverse)
-- Implements unwinding: opposite direction slows before reversing
function M.shuttle(dir)
    assert(dir == 1 or dir == -1, "playback_controller.shuttle: dir must be 1 or -1")

    -- Handle unlatch: opposite direction while latched resumes playback
    if M.latched then
        -- Check if direction change is away from boundary
        local at_start = (M.latched_boundary == "start")
        local at_end = (M.latched_boundary == "end")
        local moving_away = (at_start and dir == 1) or (at_end and dir == -1)

        if moving_away then
            -- Unlatch and start in new direction
            M.direction = dir
            M.speed = 1
            M._unlatch_resume()
            M._schedule_tick()
            return
        else
            -- Same direction as boundary, stay latched (no-op)
            return
        end
    end

    local was_stopped = (M.state == "stopped")

    if M.state == "stopped" then
        -- Start at 1x in requested direction
        M.direction = dir
        M.speed = 1
        M.state = "playing"
        M.transport_mode = "shuttle"
        logger.debug("playback_controller", string.format("Started shuttle %s at 1x", dir == 1 and "forward" or "reverse"))
    elseif M.direction == dir then
        -- Same direction: speed up (max 8x)
        if M.speed < 8 then
            M.speed = M.speed * 2
            logger.debug("playback_controller", string.format("Speed up to %dx", M.speed))
        end
    else
        -- Opposite direction: slow down first (unwind)
        if M.speed > 1 then
            M.speed = M.speed / 2
            logger.debug("playback_controller", string.format("Slowing to %dx", M.speed))
        elseif M.speed == 1 then
            -- At 1x, stop (next press will start opposite direction)
            M.stop()
            logger.debug("playback_controller", "Stopped (unwound to 0)")
            return
        elseif M.speed == 0.5 then
            -- At 0.5x, stop
            M.stop()
            return
        end
    end

    -- Set transport mode (shuttle latches at boundaries)
    M.transport_mode = "shuttle"

    -- Notify media_cache of playhead change (triggers prefetch)
    media_cache.set_playhead(math.floor(M.frame), M.direction, M.speed)

    -- Sync audio (transport event)
    if was_stopped then
        start_audio()
    else
        sync_audio()  -- Speed change = transport event
    end

    M._schedule_tick()
end

--- K+J or K+L: slow playback at 0.5x
function M.slow_play(dir)
    assert(dir == 1 or dir == -1, "playback_controller.slow_play: dir must be 1 or -1")
    local was_stopped = (M.state == "stopped")
    M.direction = dir
    M.speed = 0.5
    M.state = "playing"
    M.transport_mode = "shuttle"  -- slow_play latches at boundaries like shuttle
    logger.debug("playback_controller", string.format("Slow play %s at 0.5x", dir == 1 and "forward" or "reverse"))

    -- Notify media_cache of playhead change (triggers prefetch)
    media_cache.set_playhead(math.floor(M.frame), M.direction, M.speed)

    -- Sync audio (transport event)
    if was_stopped then
        start_audio()
    else
        sync_audio()  -- Speed change = transport event
    end

    M._schedule_tick()
end

--- Stop playback
function M.stop()
    M.state = "stopped"
    M.direction = 0
    M.speed = 1
    M.transport_mode = "none"
    M._clear_latch()

    -- Stop audio
    stop_audio()

    logger.debug("playback_controller", "Stopped")
end

--------------------------------------------------------------------------------
-- Boundary Latch (shuttle mode only)
--------------------------------------------------------------------------------

--- Clear latch state without side effects
function M._clear_latch()
    M.latched = false
    M.latched_boundary = nil
end

--- Latch at boundary (transport event)
-- PIN: One-shot, side-effect controlled, computes boundary time from frame.
-- PIN: Latch time is frame-derived, NOT sampled from AOP.
function M._latch(boundary_frame)
    if M.latched then return end

    assert(M.fps_num > 0 and M.fps_den > 0,
        "playback_controller._latch: fps must be set")

    M.latched = true
    M.latched_boundary = (boundary_frame == 0) and "start" or "end"
    M.frame = boundary_frame

    -- Deterministic time for boundary frame (rational math)
    local t_us = math.floor(boundary_frame * 1000000 * M.fps_den / M.fps_num)

    -- Clamp to valid media range
    if audio_playback and audio_playback.max_media_time_us then
        t_us = math.max(0, math.min(t_us, audio_playback.max_media_time_us))
    else
        t_us = math.max(0, t_us)
    end

    -- Transport event: freeze audio at boundary time
    if audio_playback and audio_playback.initialized and audio_playback.latch then
        audio_playback.latch(t_us)
    end

    if viewer_panel then
        viewer_panel.show_frame(M.frame)
    end

    logger.debug("playback_controller", string.format(
        "Latched at %s boundary (frame %d, t=%.3fs)",
        M.latched_boundary, boundary_frame, t_us / 1000000))
end

--- Unlatch and resume playback (transport event)
-- Called when user changes direction while latched.
function M._unlatch_resume()
    if not M.latched then return end

    -- Get current media time (while not playing, this is M.media_time_us)
    local t_us = 0
    if audio_playback and audio_playback.initialized then
        t_us = audio_playback.get_media_time_us()
    end

    M._clear_latch()

    -- Transport event sequence: seek, sync speed, start
    if audio_playback and audio_playback.initialized then
        audio_playback.seek(t_us)
        local signed_speed = M.direction * M.speed
        audio_playback.set_speed(signed_speed)
        audio_playback.start()
    end

    logger.debug("playback_controller", "Unlatched and resumed")
end

--- Check if currently playing
function M.is_playing()
    return M.state == "playing"
end

--- Seek to specific frame
function M.seek(frame_idx)
    assert(frame_idx, "playback_controller.seek: frame_idx is nil")
    assert(frame_idx >= 0, "playback_controller.seek: frame_idx must be >= 0")

    -- Clear latch on seek (seek takes over)
    M._clear_latch()

    M.frame = math.min(frame_idx, M.total_frames - 1)

    -- Sync audio position (transport event)
    if audio_playback and audio_playback.initialized then
        local media_time_us = calc_time_us_from_frame(M.frame)
        audio_playback.seek(media_time_us)
    end

    -- Display frame if we have viewer
    if viewer_panel then
        viewer_panel.show_frame(math.floor(M.frame))
    end

    logger.debug("playback_controller", string.format("Seek to frame %d", math.floor(M.frame)))
end

--- Get current playback info for display
function M.get_status()
    if M.state == "stopped" then
        return "stopped"
    end
    local dir_str = M.direction == 1 and ">" or "<"
    return string.format("%s %.1fx", dir_str, M.speed)
end

--------------------------------------------------------------------------------
-- Video Tick (follows audio)
--------------------------------------------------------------------------------

--- Internal: tick function called by timer
-- VIDEO FOLLOWS AUDIO: queries audio_playback.get_media_time_us() for current time.
-- Never pushes time into audio.
function M._tick()
    if M.state ~= "playing" then return end
    assert(viewer_panel, "playback_controller._tick: viewer_panel not set")
    assert(M.fps_num and M.fps_num > 0 and M.fps_den and M.fps_den > 0,
        "playback_controller._tick: fps must be set and positive")

    -- Early return while latched (no advancement, just keep ticking)
    if M.latched then
        viewer_panel.show_frame(M.frame)
        M._schedule_tick()
        return
    end

    -- Frame advancement: video ALWAYS follows audio when audio is active (Rule V1)
    -- Transport mode only affects boundary behavior, not time source.
    if audio_playback and audio_playback.initialized and audio_playback.playing then
        -- AUDIO ACTIVE: Video follows audio time (spec Rule V1)
        local t_vid_us = audio_playback.get_media_time_us()
        M.frame = M.calc_frame_from_time_us(t_vid_us)
    else
        -- NO AUDIO: Advance frame independently (fallback only)
        M.frame = M.frame + (M.direction * M.speed)
    end

    -- Clamp to valid range
    M.frame = math.max(0, math.min(M.frame, M.total_frames - 1))

    -- Boundary detection
    local hit_start = (M.direction < 0 and M.frame <= 0)
    local hit_end = (M.direction > 0 and M.frame >= M.total_frames - 1)

    if hit_start or hit_end then
        local boundary_frame = hit_start and 0 or (M.total_frames - 1)
        M.frame = boundary_frame

        if M.transport_mode == "shuttle" then
            -- Shuttle mode: latch at boundary, continue ticking
            M._latch(boundary_frame)
            M._schedule_tick()
            return
        else
            -- Normal play mode: stop at boundary
            M.stop()
            logger.debug("playback_controller", hit_start and "Hit start boundary" or "Hit end boundary")
            return
        end
    end

    -- Display frame
    local frame_idx = math.floor(M.frame)
    viewer_panel.show_frame(frame_idx)

    -- Notify media_cache of playhead change (triggers prefetch in travel direction)
    media_cache.set_playhead(frame_idx, M.direction, M.speed)

    -- DO NOT call audio_playback.set_media_time() - video follows audio, not vice versa

    -- Schedule next tick
    M._schedule_tick()
end

--- Internal: schedule next timer tick
function M._schedule_tick()
    if M.state ~= "playing" then return end
    assert(M.fps and M.fps > 0, "playback_controller._schedule_tick: fps not set")

    -- Base interval is 1 frame duration
    local base_interval = math.floor(1000 / M.fps)
    local interval

    if M.speed < 1 then
        -- Slower than 1x: show each frame for longer
        -- At 0.5x, show each frame for 2x the normal duration
        interval = math.floor(base_interval / M.speed)
    else
        -- 1x or faster: use base interval
        -- At 2x we skip frames, not shorten interval
        interval = base_interval
    end

    -- Minimum interval to avoid runaway
    interval = math.max(interval, 16)  -- ~60fps max

    qt_create_single_shot_timer(interval, function()
        M._tick()
    end)
end

return M
