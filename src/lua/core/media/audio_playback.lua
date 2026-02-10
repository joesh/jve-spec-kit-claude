--- Audio Playback Controller
--
-- Integrates EMP (decode) -> SSE (time-stretch) -> AOP (output)
-- for pitch-preserving audio scrubbing at variable speeds.
--
-- **AUDIO IS MASTER CLOCK.** Video follows audio time via get_time_us().
-- SSE.SET_TARGET() is called ONLY on transport events (start, seek, speed change),
-- never during steady-state playback.
--
-- Time tracking uses epoch-based subtraction from AOP playhead, which is
-- FLUSH-agnostic (we don't assume FLUSH resets playhead).
--
-- COORDINATE-AGNOSTIC: audio_playback tracks "playback time" — whatever the
-- controller sets. In source mode, playback time IS source time (offset=0).
-- In timeline mode, playback time IS timeline time; each audio source has its
-- own source_offset_us to convert playback_time → source_decode_time.
--
-- MULTI-SOURCE: set_audio_sources() configures multiple audio sources.
-- Sources are decoded independently, mixed in Lua, then pushed to SSE as
-- a single mixed PCM stream. SSE time-stretch operates on the mixed output.
--
-- LIFECYCLE:
--   SESSION (long-lived): init_session(rate, ch) opens AOP+SSE once.
--   SOURCES (per-resolve): set_audio_sources(sources, cache) sets audio list.
--   TRANSPORT (per-event): start/stop/seek/set_speed as before.
--
-- @file audio_playback.lua

local logger = require("core.logger")
local qt_constants = require("core.qt_constants")

-- Quality mode constants (match SSE C++ enum)
local Q1 = 1          -- Editor mode: 0.25x-4x
local Q2 = 2          -- Extreme slomo: down to 0.10x
local Q3_DECIMATE = 3 -- High-speed: >4x up to 16x, no pitch correction

-- Speed range constants (match SSE C++ constants)
local MAX_SPEED_STRETCHED = 4.0  -- Max speed for pitch-corrected playback
local MAX_SPEED_DECIMATE = 16.0  -- Max speed for decimate mode

-- Centralized configuration constants (no scattered literals)
local CFG = {
    TARGET_BUFFER_MS = 100,
    PUMP_INTERVAL_HUNGRY_MS = 2,
    PUMP_INTERVAL_OK_MS = 15,
    MAX_RENDER_FRAMES = 4096,

    -- Audio cache window: SYMMETRIC bidirectional (both directions equal)
    -- This enables reverse playback without constant AAC decoder seeks.
    -- 10 seconds total = ~4MB at 48kHz stereo float32 (cheap to cache)
    -- Half-window = 5 seconds in each direction from playhead
    AUDIO_CACHE_HALF_WINDOW_US = 5000000,  -- 5 seconds each direction

    -- Audio output latency compensation (Qt buffer + CoreAudio + driver + DAC)
    -- This is the delay between when Qt consumes audio and when it reaches ears.
    -- Components: Qt internal buffer (~50ms) + CoreAudio (~20ms) + speakers (~15ms)
    -- Built-in speakers add extra processing latency vs external interfaces.
    OUTPUT_LATENCY_US = 150000,  -- 150ms
}

local M = {
    -- SESSION state (long-lived, opened once)
    session_initialized = false,
    aop = nil,              -- AOP device handle
    sse = nil,              -- SSE engine handle
    session_sample_rate = 0, -- rate AOP was opened at (e.g. 48000)
    session_channels = 0,    -- channels AOP was opened at (2)

    -- SOURCE state (multi-source)
    audio_sources = {},     -- list of {path, source_offset_us, volume, duration_us}
    media_cache_ref = nil,  -- media_cache module reference (for get_audio_pcm_for_path)
    has_audio = false,

    -- TRANSPORT state (per-event, unchanged)
    playing = false,
    media_time_us = 0,      -- Current position when stopped (playback time)
    speed = 1.0,            -- Signed speed (negative = reverse)
    quality_mode = Q1,      -- 1=Q1, 2=Q2, 3=Q3_DECIMATE

    -- Epoch-based time tracking (audio is master clock)
    media_anchor_us = 0,         -- Playback time at last reanchor
    aop_epoch_playhead_us = 0,   -- AOP playhead reading at last reanchor
    max_media_time_us = 0,       -- Max playback time (set by controller)

    -- Export constants for tests/external access
    Q1 = Q1,
    Q2 = Q2,
    Q3_DECIMATE = Q3_DECIMATE,
    MAX_SPEED_STRETCHED = MAX_SPEED_STRETCHED,
    MAX_SPEED_DECIMATE = MAX_SPEED_DECIMATE,
}

-- Internal state
local pumping = false        -- Re-entrancy guard
local burst_generation = 0   -- Monotonic counter; stop-timer only fires if gen matches
local last_pcm_range = { start_us = 0, end_us = 0 }
local last_fetch_pb_start_us = nil  -- pb_start from the last actual fetch (nil = no prior fetch)

--- Invalidate cache if it extends past clip boundary.
-- Catches stale cache from FPS calculation fixes or clip boundary changes.
-- @param clip_end_us number: clip boundary in microseconds
-- @return boolean: true if cache was invalidated
local function invalidate_stale_cache(clip_end_us)
    if last_pcm_range.end_us > clip_end_us + 1000 then  -- 1ms tolerance
        logger.debug("audio_playback", string.format(
            "Invalidating stale cache: cache_end=%.3fs > clip_end=%.3fs",
            last_pcm_range.end_us / 1000000, clip_end_us / 1000000))
        last_pcm_range = { start_us = 0, end_us = 0 }
        last_fetch_pb_start_us = nil
        return true
    end
    return false
end

--- Get minimum clip_end_us from current sources.
-- Used to clamp audio to clip boundaries.
-- @return number: clip end in microseconds
local function get_min_clip_end_us()
    if #M.audio_sources == 0 then return M.max_media_time_us end
    local min_end = M.max_media_time_us
    for _, src in ipairs(M.audio_sources) do
        if src.clip_end_us and src.clip_end_us < min_end then
            min_end = src.clip_end_us
        end
    end
    return min_end
end

--- Clamp time to source boundaries based on playback direction.
-- When entering a clip from the right (reverse), clamp to clip_end.
-- When entering from the left (forward), clamp to clip_start.
-- @param time_us number: time to clamp
-- @param sources table: list of audio sources
-- @param speed number: signed speed (negative = reverse)
-- @return number: clamped time
local function clamp_to_source_boundaries(time_us, sources, speed)
    if #sources == 0 then return time_us end

    -- Compute the intersection of all clip boundaries
    local max_start = 0
    local min_end = M.max_media_time_us
    for _, src in ipairs(sources) do
        if src.clip_start_us and src.clip_start_us > max_start then
            max_start = src.clip_start_us
        end
        if src.clip_end_us and src.clip_end_us < min_end then
            min_end = src.clip_end_us
        end
    end

    -- Clamp based on direction
    if speed < 0 and time_us > min_end then
        -- Reverse playback entering clip from right edge
        logger.debug("audio_playback", string.format(
            "Clamping restart time from %.3fs to clip_end %.3fs (reverse entry)",
            time_us / 1000000, min_end / 1000000))
        return min_end
    elseif speed > 0 and time_us < max_start then
        -- Forward playback entering clip from left edge
        logger.debug("audio_playback", string.format(
            "Clamping restart time from %.3fs to clip_start %.3fs (forward entry)",
            time_us / 1000000, max_start / 1000000))
        return max_start
    end

    return time_us
end

--- Trim frames to not exceed clip boundary.
-- The decoder may return more frames than requested (AAC packet alignment).
-- @param pb_actual_start number: playback start time in us
-- @param pb_actual_end number: playback end time in us (from decoder)
-- @param frames number: frame count from decoder
-- @param clip_end_us number: clip boundary in us
-- @param log_label string: label for debug log ("PCM" or "mixed PCM")
-- @return frames_to_push, clamped_end
local function trim_frames_to_clip_end(pb_actual_start, pb_actual_end, frames, clip_end_us, log_label)
    if pb_actual_end <= clip_end_us then
        return frames, pb_actual_end
    end

    local clamped_end = clip_end_us
    local usable_duration_us = clip_end_us - pb_actual_start
    local frames_to_push
    if usable_duration_us > 0 then
        frames_to_push = math.floor(usable_duration_us * M.session_sample_rate / 1000000)
    else
        frames_to_push = 0
    end
    logger.debug("audio_playback", string.format(
        "Trimming %s: decoder returned %.3fs, clamped to clip_end %.3fs (%d→%d frames)",
        log_label, pb_actual_end / 1000000, clip_end_us / 1000000, frames, frames_to_push))
    return frames_to_push, clamped_end
end

--------------------------------------------------------------------------------
-- Time Utilities (epoch-based, FLUSH-agnostic)
--------------------------------------------------------------------------------

--- Clamp playback time to valid range [0, max_media_time_us]
-- @param t Playback time in microseconds
-- @return Clamped time
local function clamp_media_us(t)
    assert(M.max_media_time_us and M.max_media_time_us >= 0,
        "audio_playback.clamp_media_us: missing or invalid max_media_time_us")
    if t < 0 then return 0 end
    if t > M.max_media_time_us then return M.max_media_time_us end
    return t
end

--- Get current playback time from AOP playhead (audio is master clock)
-- Uses epoch-based subtraction: media_anchor + (playhead - epoch) * speed
-- This is FLUSH-agnostic (doesn't assume FLUSH resets playhead).
-- Includes output latency compensation so video matches what user actually hears.
-- @return Current playback time in microseconds
function M.get_time_us()
    if not M.session_initialized or not M.playing then
        assert(M.media_time_us ~= nil, "audio_playback.get_time_us: missing media_time_us")
        return M.media_time_us
    end

    assert(M.aop, "audio_playback.get_time_us: aop is nil while playing")

    local playhead_us = qt_constants.AOP.PLAYHEAD_US(M.aop)
    assert(playhead_us >= M.aop_epoch_playhead_us,
        ("audio_playback.get_time_us: playhead went backwards (playhead=%d epoch=%d)")
            :format(playhead_us, M.aop_epoch_playhead_us))

    local elapsed_us = playhead_us - M.aop_epoch_playhead_us

    -- Compensate for audio output latency (OS mixer + driver + DAC)
    -- The playhead reports audio consumed by OS, but there's additional delay
    -- before it reaches the speakers. Subtract this to sync video with heard audio.
    local compensated_elapsed_us = math.max(0, elapsed_us - CFG.OUTPUT_LATENCY_US)

    local delta = compensated_elapsed_us * M.speed

    -- Symmetric rounding: floor for positive, ceil for negative
    local result
    if M.speed >= 0 then
        result = M.media_anchor_us + math.floor(delta)
    else
        result = M.media_anchor_us + math.ceil(delta)
    end

    return clamp_media_us(result)
end

--- Backward-compat alias (callers that haven't been updated yet)
function M.get_media_time_us()
    return M.get_time_us()
end

--------------------------------------------------------------------------------
-- Transport Helpers (transport events only)
--------------------------------------------------------------------------------

--- Reanchor time tracking (called ONLY on transport events)
-- Transport events: start, seek, speed change (including direction flip)
-- @param new_media_time_us Target playback time
-- @param new_signed_speed Signed speed (negative = reverse)
-- @param new_quality_mode Quality mode (Q1 or Q2)
local function reanchor(new_media_time_us, new_signed_speed, new_quality_mode)
    assert(type(new_media_time_us) == "number",
        "audio_playback.reanchor: media_time_us must be number")
    assert(type(new_signed_speed) == "number",
        "audio_playback.reanchor: signed_speed must be number")
    assert(new_quality_mode ~= nil,
        "audio_playback.reanchor: missing quality_mode")
    assert(M.aop and M.sse,
        "audio_playback.reanchor: missing aop/sse")

    new_media_time_us = clamp_media_us(new_media_time_us)

    M.media_anchor_us = new_media_time_us
    M.media_time_us = new_media_time_us  -- stopped-state value
    M.speed = new_signed_speed
    M.quality_mode = new_quality_mode

    -- Flush queued audio (doesn't reset playhead)
    qt_constants.AOP.FLUSH(M.aop)
    -- Record epoch for playhead delta calculation
    M.aop_epoch_playhead_us = qt_constants.AOP.PLAYHEAD_US(M.aop)

    -- Reset SSE and set target (transport event = SET_TARGET is valid)
    qt_constants.SSE.RESET(M.sse)
    qt_constants.SSE.SET_TARGET(M.sse, new_media_time_us, new_signed_speed, new_quality_mode)

    -- Clear cached PCM range (will refetch around new position)
    last_pcm_range = { start_us = 0, end_us = 0 }
    last_fetch_pb_start_us = nil

    logger.debug("audio_playback", ("reanchor: t=%.3fs speed=%.2f Q%d")
        :format(new_media_time_us / 1000000, new_signed_speed, new_quality_mode))
end

--- Advance SSE past codec delay gap after pushing fresh PCM.
-- AAC decoder may return actual_start slightly after the requested start.
-- If SSE target sits in that gap, it has no data and starves permanently.
-- Call this after reanchor + _ensure_pcm_cache at any transport event.
local function advance_sse_past_codec_delay()
    local sse_time = qt_constants.SSE.CURRENT_TIME_US(M.sse)
    if sse_time < last_pcm_range.start_us then
        logger.info("audio_playback", string.format(
            "Codec delay: advancing SSE from %.3fs to %.3fs",
            sse_time / 1000000, last_pcm_range.start_us / 1000000))
        qt_constants.SSE.SET_TARGET(M.sse, last_pcm_range.start_us, M.speed, M.quality_mode)
    end
end

--------------------------------------------------------------------------------
-- Session Lifecycle (long-lived, opened once)
--------------------------------------------------------------------------------

--- Initialize audio session: opens AOP device + SSE engine.
-- Call once at startup or on first audio source. Persists across clip switches.
-- @param sample_rate Sample rate to open AOP at (e.g. 48000)
-- @param channels Channel count (e.g. 2)
function M.init_session(sample_rate, channels)
    assert(not M.session_initialized,
        "audio_playback.init_session: already session_initialized (call shutdown_session first)")
    assert(type(sample_rate) == "number" and sample_rate > 0,
        "audio_playback.init_session: sample_rate must be positive number")
    assert(type(channels) == "number" and channels > 0,
        "audio_playback.init_session: channels must be positive number")

    -- Open AOP device
    local aop, err = qt_constants.AOP.OPEN(sample_rate, channels, CFG.TARGET_BUFFER_MS)
    assert(aop, "audio_playback.init_session: AOP.OPEN failed: " .. tostring(err))
    M.aop = aop

    -- Check actual sample rate (device may not support requested rate)
    if qt_constants.AOP.SAMPLE_RATE then
        local actual_rate = qt_constants.AOP.SAMPLE_RATE(aop)
        local actual_channels = qt_constants.AOP.CHANNELS(aop)
        if actual_rate ~= sample_rate then
            logger.warn("audio_playback", string.format(
                "Sample rate mismatch! Requested %d, got %d.",
                sample_rate, actual_rate))
        end
        logger.info("audio_playback", string.format(
            "AOP opened: %dHz %dch (requested: %dHz %dch)",
            actual_rate, actual_channels, sample_rate, channels))
    end

    -- Create SSE engine at session rate
    local sse = qt_constants.SSE.CREATE({
        sample_rate = sample_rate,
        channels = channels,
        block_frames = 512,  -- WSOLA processing block
    })
    assert(sse, "audio_playback.init_session: SSE.CREATE returned nil")
    M.sse = sse

    M.session_sample_rate = sample_rate
    M.session_channels = channels
    M.session_initialized = true

    -- Reset transport defaults
    M.aop_epoch_playhead_us = 0
    M.speed = 1.0
    M.quality_mode = Q1

    logger.info("audio_playback", string.format(
        "Session initialized: %dHz %dch", sample_rate, channels))
end

--------------------------------------------------------------------------------
-- Source Lifecycle (multi-source, replaces switch_source)
--------------------------------------------------------------------------------

--- Set audio sources for playback. THE ONLY way to configure audio.
-- Stops pump, resets SSE, stores new sources list. Restarts if was playing.
-- Source mode: one entry with source_offset_us=0.
-- Timeline mode: N entries, each with own offset.
-- @param sources list of {path, source_offset_us, volume, duration_us}
-- @param cache media_cache module reference (has get_audio_pcm_for_path)
-- @param restart_time_us number|nil: optional time to restart at (for sync with video)
function M.set_audio_sources(sources, cache, restart_time_us)
    assert(M.session_initialized,
        "audio_playback.set_audio_sources: session not initialized (call init_session first)")
    assert(type(sources) == "table",
        "audio_playback.set_audio_sources: sources must be a table")
    assert(cache, "audio_playback.set_audio_sources: cache is nil")
    assert(cache.get_audio_pcm_for_path,
        "audio_playback.set_audio_sources: cache missing get_audio_pcm_for_path")

    local was_playing = M.playing

    -- Detect if sources changed in a way that requires buffer flush.
    -- This includes: path changes, offset changes (edit points), count changes, duration changes.
    -- Volume-only changes can use hot swap; everything else needs cold path.
    local sources_changed = false
    local old_count = M.audio_sources and #M.audio_sources or 0
    local new_count = #sources

    if old_count ~= new_count then
        -- Different number of sources
        sources_changed = true
    elseif old_count > 0 then
        -- Same count, check each source for path, offset, or duration changes
        for i, old_src in ipairs(M.audio_sources) do
            local new_src = sources[i]
            if not new_src then
                sources_changed = true
                break
            end
            -- Check path
            if old_src.path ~= new_src.path then
                sources_changed = true
                break
            end
            -- Check source_offset (edit point within same file)
            if old_src.source_offset_us ~= new_src.source_offset_us then
                sources_changed = true
                break
            end
            -- Check duration (clip length changed)
            if old_src.duration_us ~= new_src.duration_us then
                sources_changed = true
                break
            end
        end
    end

    if M.playing and #sources > 0 and not sources_changed then
        -- HOT SWAP: update sources without interrupting the audio pipeline.
        -- Only safe when sources haven't changed structurally (just volume updates).
        -- Don't stop AOP, don't reset SSE, don't cancel the pump.
        -- SSE.PushSourcePcm replaces overlapping chunks automatically,
        -- so the next _ensure_pcm_cache (from the running pump) will push
        -- new source data that seamlessly replaces old source data.

        -- Snapshot current time and re-epoch (keeps get_time_us accurate)
        M.media_time_us = M.get_time_us()
        M.media_anchor_us = M.media_time_us
        M.aop_epoch_playhead_us = qt_constants.AOP.PLAYHEAD_US(M.aop)

        M.audio_sources = sources
        M.media_cache_ref = cache
        M.has_audio = true

        -- Clear stale PCM cache and push new source data immediately.
        -- AOP+SSE continue playing old audio during the decode below;
        -- once new PCM is pushed, SSE replaces overlapping chunks seamlessly.
        last_pcm_range = { start_us = 0, end_us = 0 }
        last_fetch_pb_start_us = nil
        M._ensure_pcm_cache()
    else
        -- Cold path: sources changed, cleared, or not playing — full stop/restart
        if M.playing then
            -- Use explicit restart time if provided (for video sync),
            -- otherwise capture current audio time
            M.media_time_us = restart_time_us or M.get_time_us()
            M.playing = false
            M._cancel_pump()
            qt_constants.AOP.STOP(M.aop)
            qt_constants.AOP.FLUSH(M.aop)
        elseif restart_time_us then
            -- Not playing but restart time provided - use it
            M.media_time_us = restart_time_us
        end

        M.audio_sources = sources
        M.media_cache_ref = cache
        M.has_audio = #sources > 0

        -- Clear PCM cache (stale data from previous sources)
        last_pcm_range = { start_us = 0, end_us = 0 }
        last_fetch_pb_start_us = nil

        -- Reset SSE (clear buffered audio, keep engine alive)
        qt_constants.SSE.RESET(M.sse)

        if was_playing and M.has_audio then
            -- Clamp restart time to new source boundaries before reanchoring.
            -- Fixes: when entering a clip from the right edge (reverse playback),
            -- the old restart_time may be past the new clip's end boundary.
            M.media_time_us = clamp_to_source_boundaries(M.media_time_us, sources, M.speed)

            -- Restart playback with new sources
            reanchor(M.media_time_us, M.speed, M.quality_mode)
            M._ensure_pcm_cache()
            advance_sse_past_codec_delay()
            qt_constants.AOP.START(M.aop)
            M.playing = true
            M._start_pump()
        end
    end

    logger.debug("audio_playback", string.format(
        "Audio sources set: %d source(s)", #sources))
end

--- Switch source for source-mode playback.
-- Convenience wrapper around set_audio_sources for single-source playback.
-- @param cache media_cache module reference
function M.switch_source(cache)
    assert(M.session_initialized,
        "audio_playback.switch_source: session_initialized is false (call init_session first)")
    assert(cache, "audio_playback.switch_source: cache is nil")
    assert(cache.get_asset_info, "audio_playback.switch_source: cache must have get_asset_info")

    local info = cache.get_asset_info()
    assert(info, "audio_playback.switch_source: cache.get_asset_info() returned nil")

    if not info.has_audio then
        logger.info("audio_playback", "Source has no audio track")
        M.audio_sources = {}
        M.media_cache_ref = nil
        M.has_audio = false
        return
    end

    assert(cache.get_audio_reader, "audio_playback.switch_source: cache must have get_audio_reader")
    local audio_reader = cache.get_audio_reader()
    assert(audio_reader, "audio_playback.switch_source: cache has no audio_reader")

    -- Derive max_media_time_us from source
    local total_frames = math.floor(info.duration_us / 1000000 * info.fps_num / info.fps_den)
    local max_us = math.floor((total_frames - 1) * 1000000 * info.fps_den / info.fps_num)

    assert(cache.get_file_path, "audio_playback.switch_source: cache must have get_file_path")
    local file_path = cache.get_file_path()
    assert(file_path, "audio_playback.switch_source: cache.get_file_path() returned nil")

    cache.ensure_audio_pooled(file_path)

    -- Source mode: clip_end = full duration (play entire source)
    M.set_audio_sources({{
        path = file_path,
        source_offset_us = 0,
        volume = 1.0,
        duration_us = info.duration_us,
        clip_end_us = info.duration_us,  -- explicit: entire source
    }}, cache)

    M.max_media_time_us = max_us

    logger.info("audio_playback", string.format(
        "Source switched: duration=%.2fs (session=%dHz)",
        info.duration_us / 1000000, M.session_sample_rate))
end

--- Check if fully ready for playback (session + at least one audio source).
-- Use for query guards (e.g. "should video follow audio time?").
-- NOT for silently skipping transport calls — those assert session_initialized.
-- @return boolean
function M.is_ready()
    return M.session_initialized and M.has_audio
end

--- Set max playback time (called by playback_controller)
-- Required for time clamping.
-- @param max_us Maximum playback time in microseconds
function M.set_max_time(max_us)
    assert(type(max_us) == "number" and max_us >= 0,
        "audio_playback.set_max_time: max_us must be non-negative number")
    M.max_media_time_us = max_us
    logger.debug("audio_playback", ("max_time set to %.3fs"):format(max_us / 1000000))
end

--- Backward-compat alias
function M.set_max_media_time(max_us)
    M.set_max_time(max_us)
end

--- Shutdown audio session. Closes AOP+SSE, clears all state.
-- Housekeeping — OS reclaims resources on kill anyway.
function M.shutdown_session()
    M.stop()

    if M.aop then
        qt_constants.AOP.CLOSE(M.aop)
        M.aop = nil
    end

    if M.sse then
        qt_constants.SSE.CLOSE(M.sse)
        M.sse = nil
    end

    -- Clear ALL state
    last_pcm_range = { start_us = 0, end_us = 0 }
    last_fetch_pb_start_us = nil
    pumping = false
    M.audio_sources = {}
    M.media_cache_ref = nil
    M.has_audio = false
    M.session_initialized = false
    M.session_sample_rate = 0
    M.session_channels = 0

    logger.info("audio_playback", "Session shutdown")
end

--------------------------------------------------------------------------------
-- Transport Control (these are transport events -> call reanchor)
--------------------------------------------------------------------------------

--- Start audio playback (transport event)
function M.start()
    assert(M.session_initialized,
        "audio_playback.start: session not initialized")
    if not M.has_audio then
        logger.debug("audio_playback", "start() called but no audio sources - skipping")
        return
    end
    if M.playing then
        logger.debug("audio_playback", "start() called but already playing - skipping")
        return
    end

    assert(M.max_media_time_us >= 0,
        "audio_playback.start: max_media_time_us not set (call set_max_time first)")

    -- Reanchor at current media_time_us with current speed/mode
    reanchor(M.media_time_us, M.speed, M.quality_mode)

    -- Pre-fill PCM cache and push to SSE
    M._ensure_pcm_cache()
    advance_sse_past_codec_delay()

    -- Pre-render some audio to AOP buffer before starting device
    local target_frames = (M.session_sample_rate * CFG.TARGET_BUFFER_MS) / 1000
    local prefill_frames = math.min(target_frames, CFG.MAX_RENDER_FRAMES)
    local pcm, produced = qt_constants.SSE.RENDER_ALLOC(M.sse, prefill_frames)
    if produced > 0 then
        qt_constants.AOP.WRITE_F32(M.aop, pcm, produced)
    end

    -- Start AOP device
    qt_constants.AOP.START(M.aop)

    M.playing = true
    M._start_pump()

    logger.info("audio_playback", string.format(
        "Started at %.3fs, speed=%.2f, quality=Q%d, %d source(s)",
        M.media_anchor_us / 1000000, M.speed, M.quality_mode, #M.audio_sources))
end

--- Stop audio playback (transport event)
function M.stop()
    if not M.session_initialized then
        logger.debug("audio_playback", "stop() called but no session - skipping")
        return
    end
    if not M.playing then
        return  -- Idempotent, no need to log
    end

    -- Capture heard time BEFORE stopping
    local heard_time = M.get_time_us()

    M.playing = false
    M._cancel_pump()

    if M.aop then
        qt_constants.AOP.STOP(M.aop)
        qt_constants.AOP.FLUSH(M.aop)
    end

    -- Store captured time for resume
    M.media_time_us = heard_time
    M.media_anchor_us = heard_time

    logger.debug("audio_playback", ("Stopped at %.3fs"):format(heard_time / 1000000))
end

--- Seek to position (transport event)
-- @param time_us Playback time in microseconds
function M.seek(time_us)
    assert(type(time_us) == "number", "audio_playback.seek: time_us must be number")

    if not M.session_initialized then
        logger.debug("audio_playback", "seek() called but no session - storing time only")
        M.media_time_us = time_us
        return
    end
    if not M.has_audio then
        logger.debug("audio_playback", "seek() called but no audio - storing time only")
        M.media_time_us = time_us
        return
    end

    if M.playing then
        -- Reanchor while playing (transport event)
        reanchor(time_us, M.speed, M.quality_mode)
        -- Refill PCM cache and push to SSE
        M._ensure_pcm_cache()
        advance_sse_past_codec_delay()
    else
        -- Just update stopped-state position
        M.media_time_us = clamp_media_us(time_us)
        M.media_anchor_us = M.media_time_us
    end

    logger.debug("audio_playback", string.format("Seek to %.3fs", time_us / 1000000))
end

--- Latch at boundary (transport event)
-- Freezes audio output at specified time. Called when shuttle hits boundary.
-- @param time_us Playback time to freeze at (frame-derived, not sampled)
function M.latch(time_us)
    assert(M.session_initialized, "audio_playback.latch: session not initialized")
    assert(type(time_us) == "number" and time_us >= 0,
        ("audio_playback.latch: invalid time_us=%s"):format(tostring(time_us)))

    -- Cancel pump timer
    M._cancel_pump()

    -- Flush queued audio
    if M.aop then
        qt_constants.AOP.STOP(M.aop)
        qt_constants.AOP.FLUSH(M.aop)
    end

    -- Set stopped state with frozen time
    M.playing = false
    M.media_time_us = time_us
    M.media_anchor_us = time_us

    logger.debug("audio_playback", ("Latched at %.3fs"):format(time_us / 1000000))
end

--- Set playback speed (transport event if playing)
-- @param new_signed_speed Signed speed (negative = reverse)
function M.set_speed(new_signed_speed)
    assert(type(new_signed_speed) == "number",
        "audio_playback.set_speed: signed_speed must be number")

    local abs_speed = math.abs(new_signed_speed)

    -- Fail-fast for impossible UI speed
    assert(abs_speed <= MAX_SPEED_DECIMATE,
        ("audio_playback.set_speed: abs_speed %.1f exceeds MAX_SPEED_DECIMATE (16)"):format(abs_speed))

    -- Auto-select quality mode from abs(speed)
    -- Sub-1x: varispeed (Q3_DECIMATE) — natural pitch drop, no time-stretch
    -- Sub-0.25x: extreme slomo (Q2) — pitch-corrected, higher latency
    -- 1x-4x: editor (Q1) — pitch-corrected, low latency
    -- >4x: decimate (Q3_DECIMATE) — sample-skipping, no pitch correction
    local new_mode
    if abs_speed > MAX_SPEED_STRETCHED then
        new_mode = Q3_DECIMATE
    elseif abs_speed < 0.25 then
        new_mode = Q2
    elseif abs_speed < 1.0 then
        new_mode = Q3_DECIMATE
    else
        new_mode = Q1
    end

    if not M.playing then
        -- Just store for next start
        M.speed = new_signed_speed
        M.quality_mode = new_mode
        return
    end

    -- Playing: reanchor on mode transition or speed change
    local old_mode = M.quality_mode
    if new_mode ~= old_mode or new_signed_speed ~= M.speed then
        local current_media_us = M.get_time_us()
        reanchor(current_media_us, new_signed_speed, new_mode)
        -- Refill PCM cache for new direction/mode
        M._ensure_pcm_cache()
        advance_sse_past_codec_delay()
    else
        M.speed = new_signed_speed
        M.quality_mode = new_mode
    end
end

--- Get current playhead time from AOP (for diagnostics)
-- @return time_us
function M.get_playhead_us()
    assert(M.session_initialized and M.aop,
        "audio_playback.get_playhead_us: session not initialized or aop is nil")
    return qt_constants.AOP.PLAYHEAD_US(M.aop)
end

--- Check if had underrun
-- @return boolean
function M.had_underrun()
    assert(M.session_initialized and M.aop,
        "audio_playback.had_underrun: session not initialized or aop is nil")
    return qt_constants.AOP.HAD_UNDERRUN(M.aop)
end

--- Clear underrun flag
function M.clear_underrun()
    assert(M.session_initialized and M.aop,
        "audio_playback.clear_underrun: session not initialized or aop is nil")
    qt_constants.AOP.CLEAR_UNDERRUN(M.aop)
end

--------------------------------------------------------------------------------
-- Frame-Step Audio Burst (Jog)
-- Plays a short burst of audio for single-frame steps (arrow key jog).
-- Reanchors, decodes, renders, writes, starts AOP, schedules stop timer.
--------------------------------------------------------------------------------

--- Play a short audio burst at a given time.
-- Used for frame-step jog: plays ~1 frame of audio so user hears the frame.
-- Bails if not initialized, no audio, or currently playing.
-- @param time_us number: playback time to play at
-- @param duration_us number: burst length in microseconds (typically 1 frame)
function M.play_burst(time_us, duration_us)
    if not M.session_initialized then return end
    if not M.has_audio then return end
    if M.playing then return end

    -- Validate cache against clip boundary
    local clip_end_us = get_min_clip_end_us()
    invalidate_stale_cache(clip_end_us)

    -- DEBUG: Log clip boundary for diagnosis
    logger.debug("audio_playback", string.format(
        "play_burst clip_end=%.3fs, time=%.3fs, would_end=%.3fs, needs_clamp=%s",
        clip_end_us / 1000000, time_us / 1000000, (time_us + duration_us) / 1000000,
        tostring(time_us + duration_us > clip_end_us)))

    assert(type(time_us) == "number",
        "audio_playback.play_burst: time_us must be number")
    assert(type(duration_us) == "number" and duration_us > 0,
        "audio_playback.play_burst: duration_us must be positive number")

    -- Set up SSE at burst position WITHOUT flushing AOP yet.
    -- Old audio keeps playing while we render the new burst.
    local clamped = clamp_media_us(time_us)
    M.media_anchor_us = clamped
    M.media_time_us = clamped
    M.speed = 1.0
    M.quality_mode = Q1
    M.aop_epoch_playhead_us = qt_constants.AOP.PLAYHEAD_US(M.aop)
    qt_constants.SSE.RESET(M.sse)
    qt_constants.SSE.SET_TARGET(M.sse, clamped, 1.0, Q1)

    -- Re-push cached PCM to SSE (SSE.RESET cleared its buffer).
    -- If position is within existing cache, push only a small window (~200ms)
    -- around the burst position instead of the full ~10s cache.
    -- CRITICAL: clamp window to clip_end_us to prevent audio bleeding past edit points.
    if last_pcm_range.end_us > 0 and last_pcm_range.pcm_ptr
       and clamped >= last_pcm_range.start_us
       and clamped <= last_pcm_range.end_us then
        -- Compute sub-window: 200ms around burst position, clamped to clip boundary
        local window_us = 200000
        local win_start_us = math.max(last_pcm_range.start_us, clamped - window_us)
        local win_end_us = math.min(last_pcm_range.end_us, clamped + window_us, clip_end_us)

        -- Convert to frame offsets within the cached buffer
        local samples_per_us = M.session_sample_rate / 1000000
        local skip_frames = math.floor((win_start_us - last_pcm_range.start_us) * samples_per_us)
        local win_frames = math.floor((win_end_us - win_start_us) * samples_per_us)
        win_frames = math.min(win_frames, last_pcm_range.frames - skip_frames)

        if win_frames > 0 then
            -- Use C-side offset: PUSH_PCM(sse, ptr, total_frames, start_time, skip, max)
            qt_constants.SSE.PUSH_PCM(M.sse, last_pcm_range.pcm_ptr,
                last_pcm_range.frames, win_start_us, skip_frames, win_frames)
        end
    else
        last_pcm_range = { start_us = 0, end_us = 0 }
        last_fetch_pb_start_us = nil
        M._ensure_pcm_cache()
    end
    advance_sse_past_codec_delay()

    -- CRITICAL: Clamp burst duration to not extend past clip boundary.
    -- Without this, a burst starting near clip_end plays audio from the next clip.
    local max_burst_us = math.max(0, clip_end_us - clamped)
    local effective_burst_us = math.min(duration_us, max_burst_us)
    local burst_frames = math.ceil(M.session_sample_rate * effective_burst_us / 1000000)
    burst_frames = math.min(burst_frames, CFG.MAX_RENDER_FRAMES)
    local pcm, produced = qt_constants.SSE.RENDER_ALLOC(M.sse, burst_frames)

    if produced > 0 then
        -- Invalidate any pending burst stop timer before writing new audio
        burst_generation = burst_generation + 1
        local my_gen = burst_generation

        -- STOP device before flush: without this, the old burst continues playing
        -- while we write new audio, causing overlap at clip boundaries.
        -- FLUSH clears Qt buffer but can't recall audio already in OS/hardware buffer.
        qt_constants.AOP.STOP(M.aop)
        qt_constants.AOP.FLUSH(M.aop)
        qt_constants.AOP.WRITE_F32(M.aop, pcm, produced)
        qt_constants.AOP.START(M.aop)

        -- Schedule stop after burst completes (burst duration + 50ms safety margin).
        -- Only fires if no newer burst has started (generation check).
        local stop_delay_ms = math.ceil(duration_us / 1000) + 50
        qt_create_single_shot_timer(stop_delay_ms, function()
            if burst_generation ~= my_gen then return end
            qt_constants.AOP.STOP(M.aop)
            qt_constants.AOP.FLUSH(M.aop)
        end)
    end

    -- Store stopped-state position at burst time
    M.media_time_us = time_us

    if effective_burst_us < duration_us then
        logger.debug("audio_playback", string.format(
            "play_burst: t=%.3fs dur=%.1fms→%.1fms (clamped to clip_end %.3fs) frames=%d produced=%d",
            time_us / 1000000, duration_us / 1000, effective_burst_us / 1000,
            clip_end_us / 1000000, burst_frames, produced or 0))
    else
        logger.debug("audio_playback", string.format(
            "play_burst: t=%.3fs dur=%.1fms frames=%d produced=%d",
            time_us / 1000000, duration_us / 1000, burst_frames, produced or 0))
    end
end

--------------------------------------------------------------------------------
-- Internal: Audio Pump (buffer-driven, fail-fast)
-- PIN: Exactly one outstanding pump timer at a time
-- PIN: Next pump schedule occurs only at end of _pump_tick()
-- PIN: On stop/latch/seek/reanchor, outstanding pump timer is canceled
--------------------------------------------------------------------------------

--- Cancel pump scheduling
-- Note: We don't actually cancel the timer (Qt binding doesn't expose stop()).
-- Instead, _pump_tick() checks M.playing at entry and no-ops if stopped.
function M._cancel_pump()
    pumping = false
    -- Timer callback will no-op via M.playing check (can't stop Qt timers from Lua)
end

--- Start the audio pump timer
function M._start_pump()
    if pumping then return end
    M._pump_tick()
end

--- Ensure PCM cache covers current position.
-- Multi-source: decodes from each source, mixes, pushes mixed PCM to SSE.
-- Single-source: optimized path using direct decode.
-- PIN: Only refetch when playhead approaches cache edge AND more data exists.
function M._ensure_pcm_cache()
    assert(M.media_cache_ref,
        "audio_playback._ensure_pcm_cache: media_cache_ref is nil")

    local current_us = M.playing and M.get_time_us() or M.media_time_us

    -- Use EXPLICIT clip_end_us from engine (not computed here).
    -- The engine knows the sequence structure and computes boundaries correctly:
    --   clip_end_us = timeline_start + (source_out - source_in)
    -- Computing source_offset + duration here is WRONG when source_in > 0.
    local min_clip_end_us = M.max_media_time_us
    for _, src in ipairs(M.audio_sources) do
        assert(src.clip_end_us,
            "audio_playback._ensure_pcm_cache: source missing clip_end_us (engine must provide)")
        if src.clip_end_us < min_clip_end_us then
            min_clip_end_us = src.clip_end_us
        end
    end

    -- Validate cache against clip boundary
    invalidate_stale_cache(min_clip_end_us)

    -- Compute fetch window (needed for cache-hit suppression below)
    local half_window = CFG.AUDIO_CACHE_HALF_WINDOW_US
    local pb_start = math.max(0, current_us - half_window)
    local pb_end = math.min(min_clip_end_us, current_us + half_window)

    -- Check if playhead is within existing cache
    local codec_slack_us = 100000  -- 100ms slack for AAC encoder delay
    if last_pcm_range.end_us > 0 then
        local effective_start = last_pcm_range.start_us - codec_slack_us
        if current_us >= effective_start and current_us <= last_pcm_range.end_us then
            local margin_us = 1000000  -- 1 second safety margin
            local dist_to_start = current_us - last_pcm_range.start_us
            local dist_to_end = last_pcm_range.end_us - current_us
            local approaching_start = dist_to_start < margin_us
            local approaching_end = dist_to_end < margin_us
            local can_extend_start = last_pcm_range.start_us > codec_slack_us
            local can_extend_end = last_pcm_range.end_us < M.max_media_time_us

            -- Suppress approaching_start if previous fetch already requested as far
            -- back as we'd ask now but a source boundary constrained the result.
            -- Without this, multi-source mixing re-decodes every pump tick when a
            -- source starts near the playhead (its source_time begins at 0).
            if can_extend_start and last_fetch_pb_start_us
               and last_fetch_pb_start_us <= pb_start then
                can_extend_start = false
            end

            local need_refetch = (approaching_start and can_extend_start) or
                                 (approaching_end and can_extend_end)
            if not need_refetch then
                return  -- No refetch needed
            end
        end
    end

    if #M.audio_sources == 1 then
        -- Single-source fast path (most common: source mode, or timeline with 1 audio clip)
        local src = M.audio_sources[1]
        local src_start = math.max(0, pb_start - src.source_offset_us)
        -- Compute source end from clip_end_us (timeline boundary) and source_offset_us
        -- This correctly handles clips with source_in > 0
        local source_end_us = src.clip_end_us - src.source_offset_us
        local src_end = math.min(source_end_us, pb_end - src.source_offset_us)

        if src_end <= src_start then
            -- Source has no data in this range
            last_pcm_range = { start_us = pb_start, end_us = pb_end }
            return
        end

        logger.debug("audio_playback", string.format(
            "Fetching audio PCM: %.3fs - %.3fs (current=%.3fs, single source)",
            src_start / 1000000, src_end / 1000000, current_us / 1000000))

        local pcm_ptr, frames, actual_start = M.media_cache_ref.get_audio_pcm_for_path(
            src.path, src_start, src_end, M.session_sample_rate)

        assert(pcm_ptr, string.format(
            "audio_playback._ensure_pcm_cache: get_audio_pcm_for_path returned nil for '%s' [%.3fs, %.3fs]",
            src.path, src_start / 1000000, src_end / 1000000))
        assert(frames and frames > 0, string.format(
            "audio_playback._ensure_pcm_cache: get_audio_pcm_for_path returned %s frames",
            tostring(frames)))

        -- Convert source timestamps back to playback timestamps
        local pb_actual_start = actual_start + src.source_offset_us
        local pb_actual_end = pb_actual_start + (frames * 1000000 / M.session_sample_rate)

        -- Trim frames to not exceed clip boundary (decoder may return extra due to AAC alignment)
        local frames_to_push, clamped_end = trim_frames_to_clip_end(
            pb_actual_start, pb_actual_end, frames, min_clip_end_us, "PCM")

        last_pcm_range = {
            start_us = pb_actual_start,
            end_us = clamped_end,
            pcm_ptr = pcm_ptr,
            frames = frames_to_push,
        }

        -- Push to SSE with playback timestamps (trimmed to clip boundary)
        if frames_to_push > 0 then
            qt_constants.SSE.PUSH_PCM(M.sse, pcm_ptr, frames_to_push, pb_actual_start)
        end

        logger.debug("audio_playback", string.format(
            "Pushed PCM to SSE: %.3fs - %.3fs (%d frames, playback time)",
            pb_actual_start / 1000000, clamped_end / 1000000, frames_to_push))

    elseif #M.audio_sources > 1 then
        -- Multi-source mixing path
        local ffi = require("ffi")
        local mix_frames = nil
        local mix_buf = nil
        local mix_actual_start = pb_start

        for _, src in ipairs(M.audio_sources) do
            -- Convert playback range → source range
            local src_start = math.max(0, pb_start - src.source_offset_us)
            -- Compute source end from clip_end_us (timeline boundary) and source_offset_us
            local source_end_us = src.clip_end_us - src.source_offset_us
            local src_end = math.min(source_end_us, pb_end - src.source_offset_us)
            if src_end <= src_start then goto continue end

            local pcm_ptr, frames, actual_start = M.media_cache_ref.get_audio_pcm_for_path(
                src.path, src_start, src_end, M.session_sample_rate)

            if not pcm_ptr or not frames or frames <= 0 then
                logger.warn("audio_playback", string.format(
                    "Failed to decode audio for '%s' [%.3fs-%.3fs]",
                    src.path, src_start / 1000000, src_end / 1000000))
                goto continue
            end

            if not mix_buf then
                mix_frames = frames
                mix_buf = ffi.new("float[?]", frames * M.session_channels)
                ffi.fill(mix_buf, ffi.sizeof("float") * frames * M.session_channels, 0)
                mix_actual_start = actual_start + src.source_offset_us
            end

            -- Cast raw userdata to float* for sample-level access
            local float_ptr = ffi.cast("float*", pcm_ptr)

            -- Sum with volume scaling
            local n = math.min(frames, mix_frames) * M.session_channels
            local vol = src.volume
            for i = 0, n - 1 do
                mix_buf[i] = mix_buf[i] + float_ptr[i] * vol
            end

            ::continue::
        end

        if mix_buf and mix_frames and mix_frames > 0 then
            local mix_end = mix_actual_start + (mix_frames * 1000000 / M.session_sample_rate)

            -- Trim mixed frames to not exceed clip boundary
            local frames_to_push, clamped_end = trim_frames_to_clip_end(
                mix_actual_start, mix_end, mix_frames, min_clip_end_us, "mixed PCM")

            if frames_to_push > 0 then
                qt_constants.SSE.PUSH_PCM(M.sse, mix_buf, frames_to_push, mix_actual_start)
            end

            last_pcm_range = {
                start_us = mix_actual_start,
                end_us = clamped_end,
            }

            logger.debug("audio_playback", string.format(
                "Pushed mixed PCM to SSE: %.3fs - %.3fs (%d frames, %d sources)",
                mix_actual_start / 1000000, clamped_end / 1000000,
                frames_to_push, #M.audio_sources))
        else
            -- All sources had gaps
            last_pcm_range = { start_us = pb_start, end_us = pb_end }
        end
    end

    -- Record what we requested so the cache check can suppress
    -- futile backward-extension attempts on subsequent ticks
    last_fetch_pb_start_us = pb_start
end

--- Audio pump tick - buffer-driven, fail-fast
-- PIN: Pump scheduling only at end, after pumping = false
function M._pump_tick()
    if not M.playing then return end

    -- Re-entrancy guard (bug if pump timer overlaps)
    assert(not pumping, "audio_playback._pump_tick: re-entrant call (timer overlap bug)")
    pumping = true

    local next_interval_ms = CFG.PUMP_INTERVAL_OK_MS  -- Default

    -- Use xpcall for traceback, but rethrow on error (no swallowing)
    local ok, err = xpcall(function()
        -- Ensure PCM cache covers render position
        M._ensure_pcm_cache()

        -- Check buffer level and render if needed
        local buffered0 = qt_constants.AOP.BUFFERED_FRAMES(M.aop)
        local target_frames = (M.session_sample_rate * CFG.TARGET_BUFFER_MS) / 1000
        local frames_needed = math.max(0, target_frames - buffered0)
        frames_needed = math.min(frames_needed, CFG.MAX_RENDER_FRAMES)

        if frames_needed > 0 then
            local pcm, produced = qt_constants.SSE.RENDER_ALLOC(M.sse, frames_needed)

            -- Validate render output
            assert(produced >= 0 and produced <= frames_needed,
                ("audio_playback._pump_tick: invalid produced=%d for requested=%d")
                    :format(produced, frames_needed))

            if produced > 0 then
                local written = qt_constants.AOP.WRITE_F32(M.aop, pcm, produced)
                -- Log first few pumps for debugging
                logger.debug("audio_playback", string.format(
                    "Pump: needed=%d produced=%d written=%d SSE_time=%.3fs",
                    frames_needed, produced, written,
                    qt_constants.SSE.CURRENT_TIME_US(M.sse) / 1000000))
            end

            -- SSE starvation logging (NSF: always log, never silently clear)
            if qt_constants.SSE.STARVED(M.sse) then
                local render_pos = qt_constants.SSE.CURRENT_TIME_US(M.sse)
                local margin_us = 50000  -- 50ms margin for packet alignment
                local at_boundary = render_pos <= last_pcm_range.start_us + margin_us or
                                    render_pos >= last_pcm_range.end_us - margin_us
                if at_boundary then
                    logger.debug("audio_playback", ("SSE starved at boundary (render_pos=%.3fs, cache=[%.3fs,%.3fs], speed=%.2f)")
                        :format(render_pos / 1000000, last_pcm_range.start_us / 1000000,
                            last_pcm_range.end_us / 1000000, M.speed))
                else
                    logger.warn("audio_playback", ("SSE starved mid-cache (render_pos=%.3fs, cache=[%.3fs,%.3fs], speed=%.2f)")
                        :format(render_pos / 1000000, last_pcm_range.start_us / 1000000,
                            last_pcm_range.end_us / 1000000, M.speed))
                end
                qt_constants.SSE.CLEAR_STARVED(M.sse)
            end
        end

        -- Determine next interval based on buffer level AFTER render
        local buffered1 = qt_constants.AOP.BUFFERED_FRAMES(M.aop)
        if buffered1 < target_frames then
            next_interval_ms = CFG.PUMP_INTERVAL_HUNGRY_MS
        else
            next_interval_ms = CFG.PUMP_INTERVAL_OK_MS
        end
    end, debug.traceback)

    -- Clear pumping before scheduling next (so we're not "pumping" while timer is pending)
    pumping = false

    if not ok then error(err) end  -- rethrow with traceback (fail-fast, no swallowing)

    -- Schedule next tick ONLY here, at the end (after pumping = false)
    if M.playing then
        qt_create_single_shot_timer(next_interval_ms, function()
            M._pump_tick()
        end)
    end
end

return M
