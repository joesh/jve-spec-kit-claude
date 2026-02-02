--- JKL Shuttle Playback Controller (Coordinator)
--
-- Responsibilities:
-- - Manages playback state (playing/stopped, direction, speed)
-- - Implements JKL shuttle behavior with speed ramping
-- - Schedules frame display via timer
-- - Coordinates source_playback and timeline_playback sub-modules
-- - Resolves audio independently from video (supports J/L cuts, multi-track)
--
-- **VIDEO FOLLOWS AUDIO.** During playback, video queries audio_playback.get_time_us()
-- to determine which frame to display. Video NEVER pushes time into audio.
-- sync_audio() is called ONLY on transport events (start, shuttle, slow_play, seek).
--
-- Architecture:
-- - playback_controller (this file): coordinator, owns state, routes to sub-modules
-- - source_playback: source-mode tick logic, latch/unlatch, media_cache prefetch
-- - timeline_playback: timeline-mode tick logic, clip resolution, source switching
-- - playback_helpers: shared utilities (time conversion, audio control)
-- - timeline_resolver: resolves video AND audio clips at playhead time
--
-- Non-goals:
-- - Does not own video decoding (delegates to viewer_panel)
-- - Does not handle keyboard input (delegated to keyboard_shortcuts)
--
-- @file playback_controller.lua

local logger = require("core.logger")
local qt_constants = require("core.qt_constants")
local media_cache = require("core.media.media_cache")
local source_playback = require("core.playback.source_playback")
local timeline_playback = require("core.playback.timeline_playback")
local timeline_resolver = require("core.playback.timeline_resolver")
local helpers = require("core.playback.playback_helpers")

local M = {
    state = "stopped",  -- "stopped" | "playing"
    direction = 0,      -- -1=reverse, 0=stopped, 1=forward
    speed = 1,          -- magnitude: 0.5, 1, 2, 4, 8
    _position = 0,      -- current fractional frame position (source mode only;
                        -- in timeline mode, get_position() reads timeline_state)
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

    -- Boundary latch state (source mode only)
    latched = false,
    latched_boundary = nil,  -- "start" | "end" | nil

    -- Timeline playback mode state
    timeline_mode = false,      -- true = playing timeline, false = playing source
    sequence_id = nil,          -- active sequence when in timeline mode
    current_clip_id = nil,      -- track which VIDEO clip is currently playing
    current_audio_clip_ids = {}, -- set of active audio clip IDs (for change detection)
    timeline_sync_callback = nil, -- callback(frame_idx) called during _tick for playhead sync

    -- External move detection: last frame committed by _tick().
    -- If get_position() differs from this, an external caller moved the playhead
    -- (frame-forward, go-to-edit, ruler click, undo) and we must re-anchor audio.
    -- nil when stopped (detection inactive).
    _last_committed_frame = nil,

    -- Frame decimation: tick generation counter.
    -- Incremented on stop(). Timer callbacks capture generation at schedule time;
    -- stale callbacks (generation mismatch) are discarded without executing.
    _tick_generation = 0,

    -- Frame decimation: last frame displayed by _tick().
    -- If audio hasn't advanced past this frame, the tick is skipped (no redundant decode).
    -- nil when stopped, set on play/shuttle/slow_play/seek.
    _last_tick_frame = nil,
}

-- Viewer panel reference (set via init)
local viewer_panel = nil

-- Audio playback module (optional, set via init_audio)
local audio_playback = nil

-- Timeline state reference (set when entering timeline mode)
local timeline_state_ref = nil

--------------------------------------------------------------------------------
-- Position Accessors (single source of truth)
--------------------------------------------------------------------------------

--- Get current frame position.
-- In timeline mode, reads from timeline_state (Rational→int).
-- In source mode, returns local _position.
function M.get_position()
    if M.timeline_mode and timeline_state_ref then
        local rat = timeline_state_ref.get_playhead_position()
        return helpers.rational_to_frame_clamped(rat, M.fps_num, M.fps_den, M.total_frames)
    end
    return M._position
end

--- Set current frame position (fires timeline_state listeners in timeline mode).
-- In timeline mode, writes through to timeline_state (int→Rational).
-- Always updates local _position.
function M.set_position(v)
    if M.timeline_mode and timeline_state_ref then
        local rat = helpers.frame_to_rational(math.floor(v), M.fps_num, M.fps_den)
        timeline_state_ref.set_playhead_position(rat)
    end
    M._position = v
end

--- Set position without firing timeline_state listeners.
-- Use when the caller has already updated timeline_state (e.g. seek from
-- timeline panel click) and re-firing would cause re-entrant listener loops.
function M.set_position_silent(v)
    M._position = v
end

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

--- Initialize (or re-initialize) audio for the currently active media_cache source.
-- Shared path for source-mode clip load. Uses set_audio_sources.
function M.init_audio_for_active_media()
    local audio_pb = require("core.media.audio_playback")

    local info = media_cache.get_asset_info()
    assert(info, "playback_controller.init_audio_for_active_media: no active media")

    if not (qt_constants.SSE and qt_constants.AOP) then return end

    -- Lazy session init on first audio source
    if not audio_pb.session_initialized then
        if not info.has_audio then return end
        audio_pb.init_session(info.audio_sample_rate, 2)
    end

    if not info.has_audio then
        audio_pb.set_audio_sources({}, media_cache)
        audio_playback = audio_pb
        return
    end

    local file_path = media_cache.get_file_path()
    assert(file_path, "playback_controller.init_audio_for_active_media: no active file_path")
    media_cache.ensure_audio_pooled(file_path)

    audio_pb.set_audio_sources({{
        path = file_path,
        source_offset_us = 0,
        volume = 1.0,
        duration_us = info.duration_us,
    }}, media_cache)
    audio_pb.set_max_time(M.max_media_time_us)
    audio_playback = audio_pb
end

--- Shutdown audio session. Called on app exit or project switch.
function M.shutdown_audio_session()
    if audio_playback and audio_playback.session_initialized then
        audio_playback.shutdown_session()
        audio_playback = nil
    end
end

--------------------------------------------------------------------------------
-- Frame/Time Conversion (delegates to helpers, but exposed for backward compat)
--------------------------------------------------------------------------------

--- Calculate frame index from media time (microseconds)
-- @param t_us Media time in microseconds
-- @return Frame index (integer)
function M.calc_frame_from_time_us(t_us)
    assert(M.fps_num and M.fps_den, "playback_controller.calc_frame_from_time_us: fps not set")
    return helpers.calc_frame_from_time_us(t_us, M.fps_num, M.fps_den)
end

--- Calculate media time (microseconds) from frame index (internal use)
local function calc_time_us_from_frame(frame)
    assert(M.fps_num and M.fps_den, "playback_controller.calc_time_us_from_frame: fps not set")
    return helpers.calc_time_us_from_frame(frame, M.fps_num, M.fps_den)
end

--------------------------------------------------------------------------------
-- Audio Sync (delegates to helpers)
--------------------------------------------------------------------------------

local function sync_audio()
    helpers.sync_audio(audio_playback, M.direction, M.speed)
end

--------------------------------------------------------------------------------
-- Independent Audio Resolution (timeline mode)
-- Resolves all audio clips at playhead, builds source list, detects changes.
--------------------------------------------------------------------------------

--- Resolve audio clips at timeline frame and set audio sources.
-- @param timeline_frame number: current timeline frame
-- @return boolean: true if at least one audio clip is active
local function resolve_and_set_audio_sources(timeline_frame)
    assert(M.timeline_mode and M.sequence_id,
        "resolve_and_set_audio_sources: not in timeline mode")

    local playhead_rat = helpers.frame_to_rational(
        math.floor(timeline_frame), M.fps_num, M.fps_den)
    local audio_clips = timeline_resolver.resolve_all_audio_at_time(
        playhead_rat, M.sequence_id)

    -- Check if any track is soloed
    local any_soloed = false
    for _, ac in ipairs(audio_clips) do
        if ac.track.soloed then any_soloed = true; break end
    end

    -- Build source list for audio_playback
    local sources = {}
    for _, ac in ipairs(audio_clips) do
        -- Ensure media is in pool
        media_cache.ensure_audio_pooled(ac.media_path)

        -- Calculate source_offset_us: timeline_start_us - source_in_us
        -- playback_time - source_offset = source_decode_time
        -- At timeline_start, source_decode_time = source_in
        -- So: source_offset = timeline_start_us - source_in_us
        -- Each Rational carries its own fps — use to_seconds() for correct conversion.
        -- timeline_start is in timeline fps, source_in is in clip fps.
        local timeline_start_us = math.floor(ac.clip.timeline_start:to_seconds() * 1000000)
        local source_in_us = math.floor(ac.clip.source_in:to_seconds() * 1000000)
        local source_offset_us = timeline_start_us - source_in_us

        -- Effective volume respects solo/mute
        local effective_volume
        if any_soloed then
            effective_volume = ac.track.soloed and ac.track.volume or 0
        else
            effective_volume = ac.track.muted and 0 or ac.track.volume
        end

        -- Get media info for duration
        local entry_info = media_cache.ensure_audio_pooled(ac.media_path)

        sources[#sources + 1] = {
            path = ac.media_path,
            source_offset_us = source_offset_us,
            volume = effective_volume,
            duration_us = entry_info.duration_us,
        }
    end

    -- Detect change (compare clip ID sets)
    local new_ids = {}
    for _, ac in ipairs(audio_clips) do new_ids[ac.clip.id] = true end
    local changed = false
    local old_count = 0
    for _ in pairs(M.current_audio_clip_ids) do old_count = old_count + 1 end
    if #audio_clips ~= old_count then
        changed = true
    else
        for id in pairs(new_ids) do
            if not M.current_audio_clip_ids[id] then changed = true; break end
        end
    end

    if changed then
        M.current_audio_clip_ids = new_ids

        -- Lazy-init audio session on first audio clip in timeline mode.
        -- In source mode, init_audio_for_active_media handles this.
        if #sources > 0 and not audio_playback then
            local audio_pb = require("core.media.audio_playback")
            if qt_constants.SSE and qt_constants.AOP and not audio_pb.session_initialized then
                -- Use first source's info for session sample rate
                local first_info = media_cache.ensure_audio_pooled(sources[1].path)
                if first_info and first_info.has_audio then
                    audio_pb.init_session(first_info.audio_sample_rate, 2)
                    audio_pb.set_max_time(M.max_media_time_us)
                    audio_playback = audio_pb
                    logger.info("playback_controller",
                        "Lazy-init audio session for timeline mode")
                end
            elseif audio_pb.session_initialized then
                audio_playback = audio_pb
            end
        end

        if audio_playback and audio_playback.session_initialized then
            audio_playback.set_audio_sources(sources, media_cache)
        end
    end

    return #audio_clips > 0
end

--- Start audio at the correct position (unified, no mode branching).
local function start_audio()
    if not audio_playback or not audio_playback.is_ready() then return end
    -- Sources already set (by resolve_and_set_audio_sources or source load)
    local time_us = helpers.calc_time_us_from_frame(
        M.get_position(), M.fps_num, M.fps_den)
    helpers.sync_audio(audio_playback, M.direction, M.speed)
    audio_playback.seek(time_us)
    audio_playback.start()
end

local function stop_audio()
    helpers.stop_audio(audio_playback)
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
    M.set_position_silent(0)

    -- Compute max media time for audio clamp (frame-derived, not container metadata)
    M.max_media_time_us = calc_time_us_from_frame(total_frames - 1)

    -- Inform audio of max time (required before start)
    if audio_playback and audio_playback.session_initialized then
        audio_playback.set_max_time(M.max_media_time_us)
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
        local at_start = (M.latched_boundary == "start")
        local at_end = (M.latched_boundary == "end")
        local moving_away = (at_start and dir == 1) or (at_end and dir == -1)

        if moving_away then
            M.direction = dir
            M.speed = 1
            -- Get resume time, clear latch, restart audio
            local t_us = source_playback.get_unlatch_resume_time(audio_playback)
            M._clear_latch()
            if audio_playback and audio_playback.is_ready() then
                audio_playback.seek(t_us)
                audio_playback.set_speed(M.direction * M.speed)
                audio_playback.start()
            end
            logger.debug("playback_controller", "Unlatched and resumed")
            M._schedule_tick()
            return
        else
            return  -- Same direction as boundary, stay latched (no-op)
        end
    end

    local was_stopped = (M.state == "stopped")

    if M.state == "stopped" then
        M.direction = dir
        M.speed = 1
        M.state = "playing"
        M.transport_mode = "shuttle"
        M._last_committed_frame = math.floor(M.get_position())
        M._last_tick_frame = math.floor(M.get_position())

        -- Play mode for shuttle: full BGRA caching for sequential access
        qt_constants.EMP.SET_DECODE_MODE("play")

        logger.debug("playback_controller", string.format("Started shuttle %s at 1x", dir == 1 and "forward" or "reverse"))
    elseif M.direction == dir then
        if M.speed < 8 then
            M.speed = M.speed * 2
            logger.debug("playback_controller", string.format("Speed up to %dx", M.speed))
        end
    else
        if M.speed > 1 then
            M.speed = M.speed / 2
            logger.debug("playback_controller", string.format("Slowing to %dx", M.speed))
        elseif M.speed == 1 then
            M.stop()
            logger.debug("playback_controller", "Stopped (unwound to 0)")
            return
        elseif M.speed == 0.5 then
            M.stop()
            return
        end
    end

    M.transport_mode = "shuttle"

    -- In timeline mode, resolve_and_display handles prefetch with the correct
    -- source frame; get_position() returns a timeline frame which is wrong here.
    if not M.timeline_mode and media_cache.is_loaded() then
        media_cache.set_playhead(math.floor(M.get_position()), M.direction, M.speed)
    end

    if was_stopped then
        -- In timeline mode, resolve audio before starting
        if M.timeline_mode and M.sequence_id then
            resolve_and_set_audio_sources(M.get_position())
        end
        start_audio()
    else
        sync_audio()
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
    M.transport_mode = "shuttle"
    M._last_committed_frame = math.floor(M.get_position())
    M._last_tick_frame = math.floor(M.get_position())
    logger.debug("playback_controller", string.format("Slow play %s at 0.5x", dir == 1 and "forward" or "reverse"))

    if not M.timeline_mode and media_cache.is_loaded() then
        media_cache.set_playhead(math.floor(M.get_position()), M.direction, M.speed)
    end

    if was_stopped then
        if M.timeline_mode and M.sequence_id then
            resolve_and_set_audio_sources(M.get_position())
        end
        start_audio()
    else
        sync_audio()
    end

    M._schedule_tick()
end

--- Stop playback
function M.stop()
    M.state = "stopped"
    M.direction = 0
    M.speed = 1
    M.transport_mode = "none"
    M._last_committed_frame = nil
    M._tick_generation = M._tick_generation + 1
    M._last_tick_frame = nil
    M._clear_latch()

    stop_audio()

    -- Stop prefetch thread — set_playhead with direction=0 triggers READER_STOP_PREFETCH
    if not M.timeline_mode and media_cache.is_loaded() then
        media_cache.set_playhead(math.floor(M.get_position()), 0, 0)
    end

    -- Park mode: only BGRA-convert the target frame, skip intermediates
    qt_constants.EMP.SET_DECODE_MODE("park")

    logger.debug("playback_controller", "Stopped")
end

--- Play forward at 1x speed (Spacebar play)
function M.play()
    if M.state == "playing" then
        return
    end

    M.direction = 1
    M.speed = 1
    M.state = "playing"
    M.transport_mode = "play"
    M._last_committed_frame = math.floor(M.get_position())
    M._last_tick_frame = math.floor(M.get_position())
    M._clear_latch()

    -- Play mode: BGRA-convert all intermediates for sequential cache
    qt_constants.EMP.SET_DECODE_MODE("play")

    if not M.timeline_mode and media_cache.is_loaded() then
        media_cache.set_playhead(math.floor(M.get_position()), M.direction, M.speed)
    end

    -- In timeline mode, resolve audio before starting
    if M.timeline_mode and M.sequence_id then
        resolve_and_set_audio_sources(M.get_position())
    end

    start_audio()

    M._schedule_tick()
    logger.debug("playback_controller", "Play started at 1x forward")
end

--------------------------------------------------------------------------------
-- Timeline Playback Mode
--------------------------------------------------------------------------------

--- Enable or disable timeline playback mode
function M.set_timeline_mode(enabled, sequence_id, sequence_info)
    M.timeline_mode = enabled and true or false
    if enabled then
        assert(sequence_id and sequence_id ~= "",
            "playback_controller.set_timeline_mode: sequence_id required when enabling timeline mode")
        M.sequence_id = sequence_id
        M.current_clip_id = nil
        M.current_audio_clip_ids = {}

        -- Store timeline_state ref for get_position/set_position
        timeline_state_ref = require("ui.timeline.timeline_state")

        local fps_num, fps_den, total_frames
        if sequence_info then
            fps_num = sequence_info.fps_num
            fps_den = sequence_info.fps_den
            total_frames = sequence_info.total_frames
        else
            local rate = timeline_state_ref.get_sequence_frame_rate()
            if rate and rate.fps_numerator and rate.fps_denominator then
                fps_num = rate.fps_numerator
                fps_den = rate.fps_denominator
                total_frames = 86400 * fps_num / fps_den  -- 1 hour worth
            end
        end

        if fps_num and fps_den and fps_num > 0 and fps_den > 0 then
            M.set_source(total_frames or 86400, fps_num, fps_den)

            -- Set audio max time for timeline mode
            if audio_playback and audio_playback.session_initialized then
                audio_playback.set_max_time(M.max_media_time_us)
            end

            logger.debug("playback_controller",
                string.format("Timeline mode enabled for sequence %s (fps=%d/%d)", sequence_id, fps_num, fps_den))
        else
            logger.warn("playback_controller",
                string.format("Timeline mode enabled but no fps available for sequence %s", sequence_id))
        end
    else
        M.sequence_id = nil
        M.current_clip_id = nil
        M.current_audio_clip_ids = {}
        timeline_state_ref = nil
        logger.debug("playback_controller", "Timeline mode disabled")
    end
end

--- Set callback for timeline sync
function M.set_timeline_sync_callback(callback)
    M.timeline_sync_callback = callback
end

--- Seek to a Rational time position
function M.seek_to_rational(time_rat)
    assert(time_rat and time_rat.frames ~= nil,
        "playback_controller.seek_to_rational: time_rat must be a Rational")
    assert(M.fps_num and M.fps_den,
        "playback_controller.seek_to_rational: fps not set (call set_source first)")

    local frame_idx = helpers.rational_to_frame_clamped(time_rat, M.fps_num, M.fps_den, M.total_frames)
    M.seek(frame_idx)
end

--- Check if playback source is loaded
function M.has_source()
    return M.total_frames > 0 and M.fps_num and M.fps_num > 0
end

--- Convert frame index to Rational time
function M.frame_to_rational(frame_idx)
    assert(M.fps_num and M.fps_den, "playback_controller.frame_to_rational: fps not set")
    return helpers.frame_to_rational(frame_idx, M.fps_num, M.fps_den)
end

--------------------------------------------------------------------------------
-- Boundary Latch (source mode only - controller owns latch state)
--------------------------------------------------------------------------------

function M._clear_latch()
    M.latched = false
    M.latched_boundary = nil
end

--- Check if currently playing
function M.is_playing()
    return M.state == "playing"
end

--- Seek to specific frame
function M.seek(frame_idx)
    assert(frame_idx, "playback_controller.seek: frame_idx is nil")
    assert(frame_idx >= 0, "playback_controller.seek: frame_idx must be >= 0")

    local clamped = math.min(frame_idx, M.total_frames - 1)
    local clamped_int = math.floor(clamped)

    -- Skip redundant decode when stopped and already displaying this frame.
    -- Prevents double-decode when keyboard handler seeks directly and the
    -- debounced viewer listener fires again for the same position.
    if M.state ~= "playing" and clamped_int == M._last_committed_frame then
        return
    end

    M._clear_latch()

    -- Silent: in timeline mode, the caller already set
    -- timeline_state.playhead_position; in source mode, no listeners to fire.
    M.set_position_silent(clamped)
    M._last_committed_frame = clamped_int
    M._last_tick_frame = clamped_int

    -- If playing, stop audio first to flush hardware buffer.
    -- Without this, get_time_us() returns stale time on the next tick
    -- and overwrites the user's seek position.
    local was_playing = (M.state == "playing")
    if was_playing then
        stop_audio()
    end

    if M.timeline_mode and M.sequence_id then
        -- Timeline mode: resolve clip at position and display correct source frame
        if viewer_panel then
            local old_clip_id = M.current_clip_id
            local new_clip_id, source_time_us = timeline_playback.resolve_and_display(
                M.fps_num, M.fps_den, M.sequence_id, M.current_clip_id,
                nil, nil, viewer_panel, nil, math.floor(clamped))
            M.current_clip_id = new_clip_id

            -- Video clip switch: only activate video media (audio is independent)
            if M.current_clip_id ~= old_clip_id then
                -- init_audio_for_active_media is for source mode only.
                -- In timeline mode, audio is resolved independently below.
            end

            -- Resolve audio independently
            resolve_and_set_audio_sources(math.floor(clamped))
        end
    else
        -- Source mode: direct frame display
        if viewer_panel then
            viewer_panel.show_frame(math.floor(clamped))
        end
    end

    -- Restart audio at new position
    if was_playing then
        start_audio()
    else
        -- Parked: just seek audio for scrub
        local time_us = calc_time_us_from_frame(clamped)
        if audio_playback and audio_playback.is_ready() then
            audio_playback.seek(time_us)
        end
    end

    logger.debug("playback_controller", string.format("Seek to frame %d", math.floor(clamped)))
end

--------------------------------------------------------------------------------
-- Frame-Step Audio (Jog)
--------------------------------------------------------------------------------

--- Play a short audio burst for a single-frame step (arrow key jog).
-- Uses ~1.5x frame duration: long enough to be intelligible, short enough
-- that consecutive steps overlap by only ~15-20ms (inaudible as echo).
-- @param frame_idx number: the frame to play audio for
function M.play_frame_audio(frame_idx)
    if M.state == "playing" then return end
    if not audio_playback then return end
    if not audio_playback.is_ready() then return end
    if not audio_playback.play_burst then return end
    assert(M.fps_num and M.fps_den,
        "playback_controller.play_frame_audio: fps not set")

    -- In timeline mode, resolve audio sources at the stepped-to frame
    if M.timeline_mode and M.sequence_id then
        resolve_and_set_audio_sources(frame_idx)
    end

    local time_us = helpers.calc_time_us_from_frame(frame_idx, M.fps_num, M.fps_den)
    local frame_duration_us = helpers.calc_time_us_from_frame(1, M.fps_num, M.fps_den)
    -- 1.5x frame duration, clamped to [40ms, 60ms]
    local burst_us = math.max(40000, math.min(60000, math.floor(frame_duration_us * 1.5)))
    audio_playback.play_burst(time_us, burst_us)
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
-- Video Tick (coordinator - routes to source_playback or timeline_playback)
--------------------------------------------------------------------------------

--- Internal: tick function called by timer.
-- Builds tick_in snapshot, delegates to sub-module, commits result.
-- Controller owns all state mutations and the ordering invariant.
function M._tick()
    if M.state ~= "playing" then return end
    assert(viewer_panel, "playback_controller._tick: viewer_panel not set")
    assert(M.fps_num and M.fps_num > 0 and M.fps_den and M.fps_den > 0,
        "playback_controller._tick: fps must be set and positive")

    if M.timeline_mode and M.sequence_id then
        -- Detect external playhead move (frame-forward, ruler click, undo, etc.)
        -- Must come BEFORE same-frame skip: external moves override audio-derived position.
        local current_pos = M.get_position()
        local external_move = false
        if M._last_committed_frame ~= nil
           and math.floor(current_pos) ~= M._last_committed_frame then
            external_move = true
        end

        -- Same-frame skip: if audio hasn't advanced past the last displayed frame
        -- AND no external move occurred, skip this tick (avoids redundant decode).
        if not external_move
           and audio_playback and audio_playback.is_ready() and audio_playback.playing then
            local audio_time = audio_playback.get_time_us()
            local audio_frame = helpers.calc_frame_from_time_us(
                audio_time, M.fps_num, M.fps_den)
            if M._last_tick_frame ~= nil and audio_frame == M._last_tick_frame then
                M._schedule_tick()
                return
            end
        end

        if external_move then
            -- External move detected — re-anchor audio at new position
            local time_us = calc_time_us_from_frame(current_pos)
            if audio_playback and audio_playback.is_ready() then
                audio_playback.seek(time_us)
            end
            -- Resolve audio sources at new position
            resolve_and_set_audio_sources(math.floor(current_pos))
            -- Clear last_tick_frame so the tick proceeds after re-anchor
            M._last_tick_frame = nil
            logger.debug("playback_controller",
                string.format("External move detected: %d → %d, re-anchored audio",
                    M._last_committed_frame, math.floor(current_pos)))
        end

        -- Timeline mode: build tick_in, call tick, own the ordering
        local tick_in = {
            pos = current_pos,
            direction = M.direction,
            speed = M.speed,
            fps_num = M.fps_num,
            fps_den = M.fps_den,
            total_frames = M.total_frames,
            sequence_id = M.sequence_id,
            current_clip_id = M.current_clip_id,
        }
        local result = timeline_playback.tick(tick_in, audio_playback, viewer_panel)

        -- Video clip switch: only activate video media
        if result.current_clip_id ~= M.current_clip_id then
            -- No audio init on video clip switch — audio is resolved independently
        end
        M.current_clip_id = result.current_clip_id

        -- Resolve audio independently on every tick
        resolve_and_set_audio_sources(result.frame_idx)

        if result.continue then
            -- Ordering invariant: resolve already done inside tick → now commit position → sync
            M.set_position(result.new_pos)
            M._last_committed_frame = math.floor(result.new_pos)
            M._last_tick_frame = result.frame_idx
            if M.timeline_sync_callback then
                M.timeline_sync_callback(result.frame_idx)
            end
            M._schedule_tick()
        else
            M.set_position(result.new_pos)
            M._last_committed_frame = math.floor(result.new_pos)
            M._last_tick_frame = result.frame_idx
            M.stop()
        end
    else
        -- Source mode: same-frame skip
        if audio_playback and audio_playback.is_ready() and audio_playback.playing then
            local audio_time = audio_playback.get_media_time_us()
            local audio_frame = helpers.calc_frame_from_time_us(
                audio_time, M.fps_num, M.fps_den)
            if M._last_tick_frame ~= nil and audio_frame == M._last_tick_frame then
                M._schedule_tick()
                return
            end
        end

        -- Source mode: build tick_in, call tick, commit result
        local tick_in = {
            pos = M.get_position(),
            direction = M.direction,
            speed = M.speed,
            fps_num = M.fps_num,
            fps_den = M.fps_den,
            total_frames = M.total_frames,
            transport_mode = M.transport_mode,
            latched = M.latched,
            latched_boundary = M.latched_boundary,
        }
        local result = source_playback.tick(tick_in, audio_playback, viewer_panel)

        -- Controller commits state
        M.set_position(result.new_pos)
        M._last_tick_frame = math.floor(result.new_pos)
        M.latched = result.latched
        M.latched_boundary = result.latched_boundary
        if result.continue then
            M._schedule_tick()
        else
            M.stop()
        end
    end
end

--- Internal: schedule next timer tick
function M._schedule_tick()
    if M.state ~= "playing" then return end
    assert(M.fps and M.fps > 0, "playback_controller._schedule_tick: fps not set")

    local base_interval = math.floor(1000 / M.fps)
    local interval

    if M.speed < 1 then
        interval = math.floor(base_interval / M.speed)
    else
        interval = base_interval
    end

    interval = math.max(interval, 16)  -- ~60fps max

    local gen = M._tick_generation
    qt_create_single_shot_timer(interval, function()
        if M._tick_generation ~= gen then return end  -- stale tick, discard
        M._tick()
    end)
end

return M
