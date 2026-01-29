--- Audio Playback Controller
--
-- Integrates EMP (decode) -> SSE (time-stretch) -> AOP (output)
-- for pitch-preserving audio scrubbing at variable speeds.
--
-- **AUDIO IS MASTER CLOCK.** Video follows audio time via get_media_time_us().
-- SSE.SET_TARGET() is called ONLY on transport events (start, seek, speed change),
-- never during steady-state playback.
--
-- Time tracking uses epoch-based subtraction from AOP playhead, which is
-- FLUSH-agnostic (we don't assume FLUSH resets playhead).
--
-- NOTE: Audio decoding uses a SEPARATE EMP asset/reader from video
-- (managed by media_cache) to prevent seek conflicts corrupting h264 decoder.
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
    -- State
    initialized = false,
    playing = false,

    -- Handles
    aop = nil,          -- AOP device handle
    sse = nil,          -- SSE engine handle
    media_cache = nil,  -- Reference to media_cache (owns audio asset/reader)

    -- Media info
    has_audio = false,
    sample_rate = 48000,
    channels = 2,
    duration_us = 0,
    fps_num = 30,
    fps_den = 1,

    -- Transport state (signed speed: negative = reverse)
    media_time_us = 0,      -- Current position when stopped
    speed = 1.0,            -- Signed speed (negative = reverse)
    quality_mode = Q1,      -- 1=Q1, 2=Q2, 3=Q3_DECIMATE

    -- Epoch-based time tracking (audio is master clock)
    media_anchor_us = 0,         -- Media time at last reanchor
    aop_epoch_playhead_us = 0,   -- AOP playhead reading at last reanchor
    max_media_time_us = 0,       -- Frame-derived max (set by controller)

    -- Export constants for tests/external access
    Q1 = Q1,
    Q2 = Q2,
    Q3_DECIMATE = Q3_DECIMATE,
    MAX_SPEED_STRETCHED = MAX_SPEED_STRETCHED,
    MAX_SPEED_DECIMATE = MAX_SPEED_DECIMATE,
}

-- Internal state
local pumping = false        -- Re-entrancy guard
local last_pcm_range = { start_us = 0, end_us = 0 }

--------------------------------------------------------------------------------
-- Time Utilities (epoch-based, FLUSH-agnostic)
--------------------------------------------------------------------------------

--- Clamp media time to valid range [0, max_media_time_us]
-- @param t Media time in microseconds
-- @return Clamped time
local function clamp_media_us(t)
    assert(M.max_media_time_us and M.max_media_time_us >= 0,
        "audio_playback.clamp_media_us: missing or invalid max_media_time_us")
    if t < 0 then return 0 end
    if t > M.max_media_time_us then return M.max_media_time_us end
    return t
end

--- Get current media time from AOP playhead (audio is master clock)
-- Uses epoch-based subtraction: media_anchor + (playhead - epoch) * speed
-- This is FLUSH-agnostic (doesn't assume FLUSH resets playhead).
-- Includes output latency compensation so video matches what user actually hears.
-- @return Current media time in microseconds
function M.get_media_time_us()
    if not M.initialized or not M.playing then
        assert(M.media_time_us ~= nil, "audio_playback.get_media_time_us: missing media_time_us")
        return M.media_time_us
    end

    assert(M.aop, "audio_playback.get_media_time_us: aop is nil while playing")

    local playhead_us = qt_constants.AOP.PLAYHEAD_US(M.aop)
    assert(playhead_us >= M.aop_epoch_playhead_us,
        ("audio_playback.get_media_time_us: playhead went backwards (playhead=%d epoch=%d)")
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

--------------------------------------------------------------------------------
-- Transport Helpers (transport events only)
--------------------------------------------------------------------------------

--- Reanchor time tracking (called ONLY on transport events)
-- Transport events: start, seek, speed change (including direction flip)
-- @param new_media_time_us Target media time
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

    logger.debug("audio_playback", ("reanchor: t=%.3fs speed=%.2f Q%d")
        :format(new_media_time_us / 1000000, new_signed_speed, new_quality_mode))
end

--------------------------------------------------------------------------------
-- Initialization
--------------------------------------------------------------------------------

--- Initialize audio playback with media_cache
-- @param cache media_cache module reference (has separate audio asset/reader)
-- @return true on success, nil + error on failure
function M.init(cache)
    assert(cache, "audio_playback.init: cache (media_cache) is nil")
    assert(cache.get_asset_info, "audio_playback.init: cache missing get_asset_info")
    assert(cache.get_audio_reader, "audio_playback.init: cache missing get_audio_reader")

    local info = cache.get_asset_info()
    assert(info, "audio_playback.init: cache.get_asset_info() returned nil")

    if not info.has_audio then
        logger.info("audio_playback", "Asset has no audio track")
        M.has_audio = false
        return true
    end

    -- Verify audio reader exists (created by media_cache with separate asset)
    local audio_reader = cache.get_audio_reader()
    assert(audio_reader, "audio_playback.init: media_cache has no audio_reader")

    M.media_cache = cache
    M.has_audio = true
    M.sample_rate = info.audio_sample_rate
    -- EMP resampler always outputs stereo regardless of source (see ffmpeg_resample.h)
    M.channels = 2
    M.duration_us = info.duration_us
    M.fps_num = info.fps_num
    M.fps_den = info.fps_den

    logger.info("audio_playback", "Using media_cache audio reader (separate format context)")

    -- Open AOP device
    local aop, err = qt_constants.AOP.OPEN(M.sample_rate, M.channels, CFG.TARGET_BUFFER_MS)
    if not aop then
        logger.error("audio_playback", "Failed to open audio device: " .. tostring(err))
        return nil, err
    end
    M.aop = aop

    -- Check actual sample rate (device may not support requested rate)
    -- Guard for tests that mock AOP without SAMPLE_RATE
    if qt_constants.AOP.SAMPLE_RATE then
        local actual_rate = qt_constants.AOP.SAMPLE_RATE(aop)
        local actual_channels = qt_constants.AOP.CHANNELS(aop)
        if actual_rate ~= M.sample_rate then
            logger.warn("audio_playback", string.format(
                "Sample rate mismatch! Requested %d, got %d. Audio will play at wrong speed!",
                M.sample_rate, actual_rate))
            -- TODO: Resample in SSE or use actual rate for time calculations
        end
        logger.info("audio_playback", string.format(
            "AOP opened: %dHz %dch (requested: %dHz %dch)",
            actual_rate, actual_channels, M.sample_rate, M.channels))
    end

    -- Create SSE engine (using MEDIA sample rate, not device rate)
    -- This is intentional - SSE time-tracks media position
    local sse = qt_constants.SSE.CREATE({
        sample_rate = M.sample_rate,
        channels = M.channels,
        block_frames = 512,  -- WSOLA processing block
    })
    assert(sse, "audio_playback.init: SSE.CREATE returned nil")
    M.sse = sse

    M.initialized = true
    M.media_time_us = 0
    M.media_anchor_us = 0
    M.aop_epoch_playhead_us = 0
    M.speed = 1.0
    M.quality_mode = Q1

    logger.info("audio_playback", string.format(
        "Initialized: %dHz %dch, duration=%.2fs",
        M.sample_rate, M.channels, M.duration_us / 1000000
    ))

    return true
end

--- Set max media time (called by playback_controller after set_source)
-- Required for time clamping.
-- @param max_us Maximum media time in microseconds (frame-derived)
function M.set_max_media_time(max_us)
    assert(type(max_us) == "number" and max_us >= 0,
        "audio_playback.set_max_media_time: max_us must be non-negative number")
    M.max_media_time_us = max_us
    logger.debug("audio_playback", ("max_media_time_us set to %.3fs"):format(max_us / 1000000))
end

--- Shutdown audio playback
function M.shutdown()
    M.stop()

    if M.aop then
        qt_constants.AOP.CLOSE(M.aop)
        M.aop = nil
    end

    if M.sse then
        qt_constants.SSE.CLOSE(M.sse)
        M.sse = nil
    end

    -- Clear local state (media_cache owns the audio reader, we don't close it)
    last_pcm_range = { start_us = 0, end_us = 0 }
    pumping = false
    M.media_cache = nil
    M.has_audio = false
    M.initialized = false

    logger.info("audio_playback", "Shutdown")
end

--------------------------------------------------------------------------------
-- Transport Control (these are transport events -> call reanchor)
--------------------------------------------------------------------------------

--- Start audio playback (transport event)
function M.start()
    if not M.initialized then
        logger.warn("audio_playback", "start() called but not initialized - skipping")
        return
    end
    if not M.has_audio then
        logger.debug("audio_playback", "start() called but no audio track - skipping")
        return
    end
    if M.playing then
        logger.debug("audio_playback", "start() called but already playing - skipping")
        return
    end

    assert(M.max_media_time_us >= 0,
        "audio_playback.start: max_media_time_us not set (call set_max_media_time first)")

    -- Reanchor at current media_time_us with current speed/mode
    reanchor(M.media_time_us, M.speed, M.quality_mode)

    -- Pre-fill PCM cache and push to SSE
    M._ensure_pcm_cache()

    -- Codec delay adjustment: if PCM starts after SSE target, advance SSE.
    -- This handles AAC frame alignment where actual_start > requested_start.
    -- SET_TARGET is allowed here because start() is a transport event.
    local sse_time = qt_constants.SSE.CURRENT_TIME_US(M.sse)
    if sse_time < last_pcm_range.start_us then
        logger.info("audio_playback", string.format(
            "Codec delay: advancing SSE from %.3fs to %.3fs",
            sse_time / 1000000, last_pcm_range.start_us / 1000000))
        qt_constants.SSE.SET_TARGET(M.sse, last_pcm_range.start_us, M.speed, M.quality_mode)
    end

    -- Pre-render some audio to AOP buffer before starting device
    local target_frames = (M.sample_rate * CFG.TARGET_BUFFER_MS) / 1000
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
        "Started at %.3fs, speed=%.2f, quality=Q%d, sample_rate=%d",
        M.media_anchor_us / 1000000, M.speed, M.quality_mode, M.sample_rate))
end

--- Stop audio playback (transport event)
function M.stop()
    if not M.initialized then
        logger.debug("audio_playback", "stop() called but not initialized - skipping")
        return
    end
    if not M.playing then
        return  -- Idempotent, no need to log
    end

    -- Capture heard time BEFORE stopping
    local heard_time = M.get_media_time_us()

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
-- @param time_us Media time in microseconds
function M.seek(time_us)
    assert(type(time_us) == "number", "audio_playback.seek: time_us must be number")

    if not M.initialized then
        logger.debug("audio_playback", "seek() called but not initialized - storing time only")
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
    else
        -- Just update stopped-state position
        M.media_time_us = clamp_media_us(time_us)
        M.media_anchor_us = M.media_time_us
    end

    logger.debug("audio_playback", string.format("Seek to %.3fs", time_us / 1000000))
end

--- Latch at boundary (transport event)
-- Freezes audio output at specified time. Called when shuttle hits boundary.
-- PIN: Side-effect limited - defined effects:
-- 1. Stop audio output (device or callback silenced)
-- 2. Cancel pump scheduling
-- 3. Flush AOP
-- 4. Set playing = false
-- 5. Set media_time_us = time_us
-- @param time_us Media time to freeze at (frame-derived, not sampled)
function M.latch(time_us)
    assert(M.initialized, "audio_playback.latch: not initialized")
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
    local new_mode
    if abs_speed > MAX_SPEED_STRETCHED then
        new_mode = Q3_DECIMATE
    elseif abs_speed < 0.25 then
        new_mode = Q2
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
        local current_media_us = M.get_media_time_us()
        reanchor(current_media_us, new_signed_speed, new_mode)
        -- Refill PCM cache for new direction/mode
        M._ensure_pcm_cache()
    else
        M.speed = new_signed_speed
        M.quality_mode = new_mode
    end
end

--- Get current playhead time from AOP (for diagnostics)
-- @return time_us (NSF: asserts if not initialized)
function M.get_playhead_us()
    assert(M.initialized and M.aop,
        "audio_playback.get_playhead_us: not initialized or aop is nil")
    return qt_constants.AOP.PLAYHEAD_US(M.aop)
end

--- Check if had underrun
-- @return boolean (NSF: asserts if not initialized)
function M.had_underrun()
    assert(M.initialized and M.aop,
        "audio_playback.had_underrun: not initialized or aop is nil")
    return qt_constants.AOP.HAD_UNDERRUN(M.aop)
end

--- Clear underrun flag
-- NSF: asserts if not initialized
function M.clear_underrun()
    assert(M.initialized and M.aop,
        "audio_playback.clear_underrun: not initialized or aop is nil")
    qt_constants.AOP.CLEAR_UNDERRUN(M.aop)
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

--- Ensure PCM cache covers current position
-- PIN: Only refetch when playhead approaches cache edge AND more data exists.
-- This prevents constant AAC decoder seeks which produce warnings and stall.
function M._ensure_pcm_cache()
    assert(M.media_cache, "audio_playback._ensure_pcm_cache: media_cache is nil")

    local current_us = M.playing and M.get_media_time_us() or M.media_time_us

    -- Check if playhead is within existing cache
    -- Allow 100ms slack at start for AAC encoder delay and latency compensation
    local codec_slack_us = 100000  -- 100ms slack for AAC encoder delay
    if last_pcm_range.end_us > 0 then
        local effective_start = last_pcm_range.start_us - codec_slack_us
        if current_us >= effective_start and current_us <= last_pcm_range.end_us then
            -- Within cache (with slack). Only refetch if approaching edge where more data exists.
            local margin_us = 1000000  -- 1 second safety margin

            -- Use actual cache bounds for margin check (not slack-adjusted)
            local dist_to_start = current_us - last_pcm_range.start_us
            local dist_to_end = last_pcm_range.end_us - current_us

            local approaching_start = dist_to_start < margin_us
            local approaching_end = dist_to_end < margin_us

            -- Can we extend cache in that direction?
            local can_extend_start = last_pcm_range.start_us > codec_slack_us
            local can_extend_end = last_pcm_range.end_us < M.duration_us

            local need_refetch = (approaching_start and can_extend_start) or
                                 (approaching_end and can_extend_end)

            if not need_refetch then
                return  -- No refetch needed
            end
        end
    end

    -- Need to fetch: request large symmetric window around current position
    local half_window = CFG.AUDIO_CACHE_HALF_WINDOW_US
    local cache_start = math.max(0, current_us - half_window)
    local cache_end = math.min(M.duration_us, current_us + half_window)

    logger.debug("audio_playback", string.format(
        "Fetching audio PCM: %.3fs - %.3fs (current=%.3fs, reason: %s)",
        cache_start / 1000000, cache_end / 1000000, current_us / 1000000,
        last_pcm_range.end_us == 0 and "initial" or "edge"
    ))

    -- Get PCM from media_cache (uses dedicated audio reader)
    local pcm_ptr, frames, actual_start = M.media_cache.get_audio_pcm(cache_start, cache_end)

    -- NSF: PCM fetch must succeed
    assert(pcm_ptr, string.format(
        "audio_playback._ensure_pcm_cache: get_audio_pcm returned nil ptr for range [%.3fs, %.3fs]",
        cache_start / 1000000, cache_end / 1000000))
    assert(frames and frames > 0, string.format(
        "audio_playback._ensure_pcm_cache: get_audio_pcm returned %s frames for range [%.3fs, %.3fs]",
        tostring(frames), cache_start / 1000000, cache_end / 1000000))

    -- Update our tracking of what we have
    last_pcm_range = {
        start_us = actual_start,
        end_us = actual_start + (frames * 1000000 / M.sample_rate),
        pcm_ptr = pcm_ptr,
        frames = frames,
    }

    -- Push to SSE
    qt_constants.SSE.PUSH_PCM(M.sse, pcm_ptr, frames, actual_start)

    logger.debug("audio_playback", string.format(
        "Pushed PCM to SSE: %.3fs - %.3fs (%d frames)",
        last_pcm_range.start_us / 1000000,
        last_pcm_range.end_us / 1000000,
        frames
    ))
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
        local target_frames = (M.sample_rate * CFG.TARGET_BUFFER_MS) / 1000
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
            -- Audio packets may not start exactly at requested times due to codec frame alignment.
            if qt_constants.SSE.STARVED(M.sse) then
                local render_pos = qt_constants.SSE.CURRENT_TIME_US(M.sse)
                -- Distinguish boundary starvation (expected) from mid-cache (unexpected)
                local margin_us = 50000  -- 50ms margin for packet alignment
                local at_boundary = render_pos <= last_pcm_range.start_us + margin_us or
                                    render_pos >= last_pcm_range.end_us - margin_us
                if at_boundary then
                    -- Boundary starvation (codec delay or end-of-media) - debug level
                    logger.debug("audio_playback", ("SSE starved at boundary (render_pos=%.3fs, cache=[%.3fs,%.3fs], speed=%.2f)")
                        :format(render_pos / 1000000, last_pcm_range.start_us / 1000000,
                            last_pcm_range.end_us / 1000000, M.speed))
                else
                    -- Mid-cache starvation is unexpected - warn level
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
