--- Audio Playback Controller
--
-- Integrates TMB (decode) -> SSE (time-stretch) -> AOP (output)
-- for pitch-preserving audio scrubbing at variable speeds.
--
-- **AUDIO IS MASTER CLOCK.** Video follows audio time via get_time_us().
-- SSE.SET_TARGET() is called ONLY on transport events (start, seek, speed change),
-- never during steady-state playback.
--
-- Time tracking uses epoch-based subtraction from AOP playhead, which is
-- FLUSH-agnostic (we don't assume FLUSH resets playhead).
--
-- TMB-BASED: apply_mix() configures which tracks to decode.
-- TMB decodes each track, audio_playback mixes with volume/solo/mute,
-- then pushes the mixed PCM to SSE for time-stretching.
--
-- LIFECYCLE:
--   SESSION (long-lived): init_session(rate, ch) opens AOP+SSE once.
--   MIX (per-clip-change): apply_mix(tmb, mix_params, edit_time_us)
--   TRANSPORT (per-event): start/stop/seek/set_speed as before.
--
-- @file audio_playback.lua

local ffi = require("ffi")
local logger = require("core.logger")
local qt_constants = require("core.qt_constants")
local project_gen = require("core.project_generation")
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

    -- MIX state (TMB-based)
    _tmb = nil,             -- TMB handle (decode source)
    _mix_params = nil,      -- array of {track_index, volume, muted, soloed}
    has_audio = false,
    _project_gen = -1,      -- sentinel: must call apply_mix before start()

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
-- Call this after reanchor + decode_mix_and_send_to_sse at any transport event.
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

    -- Verify actual sample rate matches requested (NSF: no silent rate mismatch)
    if qt_constants.AOP.SAMPLE_RATE then
        local actual_rate = qt_constants.AOP.SAMPLE_RATE(aop)
        local actual_channels = qt_constants.AOP.CHANNELS(aop)
        assert(actual_rate == sample_rate, string.format(
            "audio_playback.init_session: sample rate mismatch (requested %d, device gave %d)",
            sample_rate, actual_rate))
        logger.info("audio_playback", string.format(
            "AOP opened: %dHz %dch", actual_rate, actual_channels))
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
-- Mix Lifecycle (TMB-based, per-clip-change)
--------------------------------------------------------------------------------

--- Update audio mix params for TMB-based decode path.
-- Called by engine when clip set changes at edit boundaries.
-- @param tmb userdata: TMB handle (decode source)
-- @param mix_params array of {track_index, volume, muted, soloed}
-- @param edit_time_us number: timeline time of the edit boundary
function M.apply_mix(tmb, mix_params, edit_time_us)
    assert(M.session_initialized,
        "audio_playback.apply_mix: session not initialized")
    assert(tmb, "audio_playback.apply_mix: tmb is nil")
    assert(type(mix_params) == "table",
        "audio_playback.apply_mix: mix_params must be a table")
    assert(type(edit_time_us) == "number",
        "audio_playback.apply_mix: edit_time_us must be a number")

    local was_playing = M.playing

    -- Detect structural track changes (not just volume/mute/solo)
    local tracks_changed = false
    local old_params = M._mix_params or {}
    if #old_params ~= #mix_params then
        tracks_changed = true
    else
        for i, old in ipairs(old_params) do
            if old.track_index ~= mix_params[i].track_index then
                tracks_changed = true
                break
            end
        end
    end

    -- Store new state
    M._tmb = tmb
    M._mix_params = mix_params
    M.has_audio = #mix_params > 0
    M._project_gen = project_gen.current()

    if not tracks_changed then
        -- HOT SWAP: only volume/mute/solo changed. No SSE reset needed.
        -- Next decode_mix_and_send_to_sse will use new params.
        return
    end

    -- COLD PATH: track set changed — reset SSE and restart

    -- Clear PCM cache (stale data from previous track set)
    last_pcm_range = { start_us = 0, end_us = 0 }
    last_fetch_pb_start_us = nil

    if was_playing then
        M.media_time_us = edit_time_us
        M.playing = false
        M._cancel_pump()
        qt_constants.AOP.STOP(M.aop)
        qt_constants.AOP.FLUSH(M.aop)
    elseif edit_time_us then
        M.media_time_us = edit_time_us
    end

    -- Reset SSE (clear buffered audio from previous clips)
    qt_constants.SSE.RESET(M.sse)

    if was_playing and M.has_audio then
        M.media_time_us = math.max(0, math.min(edit_time_us, M.max_media_time_us))
        reanchor(M.media_time_us, M.speed, M.quality_mode)
        M.decode_mix_and_send_to_sse()
        advance_sse_past_codec_delay()
        qt_constants.AOP.START(M.aop)
        M.playing = true
        M._start_pump()
    end

    logger.debug("audio_playback", string.format(
        "apply_mix: %d track(s), tracks_changed=%s", #mix_params, tostring(tracks_changed)))
end

--- Decode all tracks from TMB, mix with volume, push to SSE.
-- Uses FFI to mix PcmChunk data (same pattern as mixer.lua mix_sources).
function M.decode_mix_and_send_to_sse()
    if not M._tmb or not M._mix_params or #M._mix_params == 0 then return end

    local current_us = M.get_time_us()
    local half = CFG.AUDIO_CACHE_HALF_WINDOW_US
    local pb_start = math.max(0, current_us - half)
    local pb_end = math.min(M.max_media_time_us, current_us + half)

    -- Skip if SSE already has data covering this window
    if last_pcm_range.start_us <= pb_start and last_pcm_range.end_us >= pb_end then
        return
    end

    -- Skip if pb_start unchanged from last fetch (dedup)
    if last_fetch_pb_start_us == pb_start then return end

    if pb_end <= pb_start then return end

    local EMP = qt_constants.EMP
    local channels = M.session_channels

    -- Determine solo state
    local any_solo = false
    for _, track in ipairs(M._mix_params) do
        if track.soloed then any_solo = true; break end
    end

    -- Decode each track from TMB, copy into Lua-owned FFI buffer, mix with volume
    local mix_buf = nil       -- ffi float array (owned by Lua GC)
    local mix_frames = 0
    local mix_start_us = pb_start

    for _, track in ipairs(M._mix_params) do
        -- Effective volume (solo/mute logic)
        local vol
        if any_solo then
            vol = track.soloed and track.volume or 0
        else
            vol = track.muted and 0 or track.volume
        end
        if vol == 0 then goto continue end

        local pcm = EMP.TMB_GET_TRACK_AUDIO(
            M._tmb, track.track_index, pb_start, pb_end,
            M.session_sample_rate, channels)
        if not pcm then goto continue end

        local info = EMP.PCM_INFO(pcm)
        local float_ptr = ffi.cast("float*", EMP.PCM_DATA_PTR(pcm))
        local n_samples = info.frames * channels

        if not mix_buf then
            -- First track: allocate mix buffer and copy scaled data
            mix_frames = info.frames
            mix_start_us = info.start_time_us
            mix_buf = ffi.new("float[?]", n_samples)
            if vol == 1.0 then
                ffi.copy(mix_buf, float_ptr, n_samples * ffi.sizeof("float"))
            else
                for i = 0, n_samples - 1 do
                    mix_buf[i] = float_ptr[i] * vol
                end
            end
        else
            -- Subsequent tracks: accumulate into mix buffer
            local n = math.min(info.frames, mix_frames) * channels
            for i = 0, n - 1 do
                mix_buf[i] = mix_buf[i] + float_ptr[i] * vol
            end
        end

        EMP.PCM_RELEASE(pcm)
        ::continue::
    end

    -- Push mixed audio to SSE
    if mix_buf and mix_frames > 0 then
        qt_constants.SSE.PUSH_PCM(M.sse, mix_buf, mix_frames, mix_start_us)
        -- start_us = actual PCM start (may differ from pb_start due to codec delay)
        -- This is needed by advance_sse_past_codec_delay to adjust SSE target.
        -- Dedup uses last_fetch_pb_start_us separately.
        last_pcm_range = {
            start_us = mix_start_us,
            end_us = pb_end,
            pcm_ptr = mix_buf,
            frames = mix_frames,
        }
        last_fetch_pb_start_us = pb_start
    end
end

--- Render time-stretched audio and write to output device.
-- Wraps SSE.RENDER_ALLOC + AOP.WRITE_F32 (Rule 2.5: named sub-function).
-- @param frames_needed number: frames to render from SSE
-- @return number: frames actually produced
function M.render_and_write_to_device(frames_needed)
    assert(frames_needed > 0,
        "audio_playback.render_and_write_to_device: frames_needed must be positive")
    local pcm, produced = qt_constants.SSE.RENDER_ALLOC(M.sse, frames_needed)
    assert(produced >= 0 and produced <= frames_needed,
        ("audio_playback.render_and_write_to_device: invalid produced=%d for requested=%d")
            :format(produced, frames_needed))
    if produced > 0 then
        qt_constants.AOP.WRITE_F32(M.aop, pcm, produced)
    end
    return produced
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

    M._tmb = nil
    M._mix_params = nil
    M.has_audio = false
    M._project_gen = -1
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
    project_gen.check(M._project_gen, "audio_playback.start")

    -- Reanchor at current media_time_us with current speed/mode
    reanchor(M.media_time_us, M.speed, M.quality_mode)

    -- Fill SSE with decoded audio from TMB
    M.decode_mix_and_send_to_sse()
    advance_sse_past_codec_delay()

    -- Pre-render some audio to AOP buffer before starting device
    local target_frames = (M.session_sample_rate * CFG.TARGET_BUFFER_MS) / 1000
    local prefill_frames = math.min(target_frames, CFG.MAX_RENDER_FRAMES)
    M.render_and_write_to_device(prefill_frames)

    -- Start AOP device
    qt_constants.AOP.START(M.aop)

    M.playing = true
    M._start_pump()

    logger.info("audio_playback", string.format(
        "Started at %.3fs, speed=%.2f, quality=Q%d",
        M.media_anchor_us / 1000000, M.speed, M.quality_mode))
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
        -- Fill SSE with decoded audio from TMB
        M.decode_mix_and_send_to_sse()
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
        -- Fill SSE with decoded audio from TMB
        M.decode_mix_and_send_to_sse()
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

    -- TMB handles clip boundaries internally; only clamp to sequence end
    local clip_end_us = M.max_media_time_us

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
        M.decode_mix_and_send_to_sse()
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
            "play_burst: t=%.3fs dur=%.1fms->%.1fms (clamped to clip_end %.3fs) frames=%d produced=%d",
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
        -- Fill SSE with decoded audio from TMB
        M.decode_mix_and_send_to_sse()

        -- Render time-stretched audio to output device
        local buffered0 = qt_constants.AOP.BUFFERED_FRAMES(M.aop)
        local target_frames = (M.session_sample_rate * CFG.TARGET_BUFFER_MS) / 1000
        local frames_needed = math.max(0, target_frames - buffered0)
        frames_needed = math.min(frames_needed, CFG.MAX_RENDER_FRAMES)

        if frames_needed > 0 then
            local produced = M.render_and_write_to_device(frames_needed)

            logger.debug("audio_playback", string.format(
                "Pump: needed=%d produced=%d SSE_time=%.3fs",
                frames_needed, produced,
                qt_constants.SSE.CURRENT_TIME_US(M.sse) / 1000000))

            -- SSE starvation logging (stuckness detection is in timeline_playback.tick)
            if qt_constants.SSE.STARVED(M.sse) then
                local render_pos = qt_constants.SSE.CURRENT_TIME_US(M.sse)
                logger.debug("audio_playback", ("SSE starved (render_pos=%.3fs, cache=[%.3fs,%.3fs], speed=%.2f)")
                    :format(render_pos / 1000000, last_pcm_range.start_us / 1000000,
                        last_pcm_range.end_us / 1000000, M.speed))
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
