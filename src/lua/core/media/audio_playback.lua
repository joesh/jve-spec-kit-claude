--- Audio Playback Controller
--
-- Phase 3: C++ AudioPump now owns TMB→SSE→AOP pipeline with dedicated thread.
-- Lua retains session lifecycle (init/shutdown) and mix configuration.
--
-- **AUDIO IS MASTER CLOCK.** Video follows audio time via C++ PlaybackClock.
-- SSE.SET_TARGET() is called ONLY on transport events (start, seek, speed change).
--
-- Time tracking uses epoch-based subtraction from AOP playhead via C++ PlaybackClock.
--
-- LIFECYCLE:
--   SESSION (long-lived): init_session(rate, ch) opens AOP+SSE once.
--   MIX (per-clip-change): apply_mix(tmb, mix_params, edit_time_us)
--   TRANSPORT: via PLAYBACK.ACTIVATE_AUDIO / PLAYBACK.DEACTIVATE_AUDIO
--
-- @file audio_playback.lua

local log = require("core.logger").for_area("audio")
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
    TARGET_BUFFER_MS = 200,
    PUMP_INTERVAL_HUNGRY_MS = 2,
    PUMP_INTERVAL_OK_MS = 15,
    MAX_RENDER_FRAMES = 4096,

    -- Mixed audio: forward-only lookahead pushed to SSE.
    -- C++ mix thread pre-fills MIX_LOOKAHEAD_US (2s) ahead autonomously.
    -- Lua requests match-sized chunks and refills when running low.
    MIX_LOOKAHEAD_US = 2000000,     -- 2s ahead (matches C++ MIX_LOOKAHEAD_US)
    MIX_REFILL_AT_US = 500000,      -- refill when <500ms of audio remains in SSE

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

-- NOTE: Internal state (pumping, last_pcm_range, burst_generation) removed in Phase 3
-- C++ AudioPump now owns TMB→SSE→AOP pipeline

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

    -- NOTE: PCM range cache cleared by C++ AudioPump on reanchor

    log.event("reanchor: t=%.3fs speed=%.2f Q%d",
        new_media_time_us / 1000000, new_signed_speed, new_quality_mode)
end

-- NOTE: advance_sse_past_codec_delay() removed in Phase 3
-- C++ AudioPump handles codec delay detection internally

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
        log.event("AOP opened: %dHz %dch", actual_rate, actual_channels)
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

    log.event("Session initialized: %dHz %dch", sample_rate, channels)
end

--------------------------------------------------------------------------------
-- Mix Lifecycle (TMB-based, per-clip-change)
--------------------------------------------------------------------------------

--- Compare two resolved param arrays for equality.
-- @param a array of {track_index, volume} (may be nil)
-- @param b array of {track_index, volume}
-- @return boolean
local function resolved_params_equal(a, b)
    if not a then return false end
    if #a ~= #b then return false end
    for i = 1, #a do
        if a[i].track_index ~= b[i].track_index then return false end
        if math.abs(a[i].volume - b[i].volume) > 0.001 then return false end
    end
    return true
end

-- Last resolved params sent to C++ (dedup: skip SetAudioMixParams when unchanged)
local last_sent_resolved = nil

--- Resolve solo/mute into effective volumes, send to TMB as mix params.
-- Called on apply_mix (both hot and cold paths) so C++ knows about volume changes.
-- Skips C++ call when resolved params are identical to last send (prevents
-- mix cache nuke at clip boundaries where track set/volumes haven't changed).
local function send_mix_params_to_tmb()
    if not M._tmb or not M._mix_params or not M.session_initialized then return end

    local any_solo = false
    for _, track in ipairs(M._mix_params) do
        if track.soloed then any_solo = true; break end
    end

    local resolved = {}
    for _, track in ipairs(M._mix_params) do
        local vol
        if any_solo then
            vol = track.soloed and track.volume or 0
        else
            vol = track.muted and 0 or track.volume
        end
        resolved[#resolved + 1] = { track_index = track.track_index, volume = vol }
    end

    -- Skip C++ call if resolved params unchanged (prevents mix cache nuke
    -- at audio clip boundaries where only the clip_id changed, not the tracks)
    if resolved_params_equal(last_sent_resolved, resolved) then return end
    last_sent_resolved = resolved

    qt_constants.EMP.TMB_SET_AUDIO_MIX_PARAMS(
        M._tmb, resolved, M.session_sample_rate, M.session_channels)
end

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

    -- Always push resolved volumes to C++ (both hot and cold paths)
    -- so the autonomous mix thread uses current solo/mute/volume state.
    send_mix_params_to_tmb()

    if was_playing then
        if not M.has_audio then
            -- All audio tracks removed mid-playback — stop audio output.
            -- NOTE: C++ AudioPump will detect this via TMB state
            M.playing = false
            qt_constants.AOP.STOP(M.aop)
            qt_constants.AOP.FLUSH(M.aop)
            qt_constants.SSE.RESET(M.sse)
        end
        -- TMB handles clip transitions autonomously in C++.
        -- send_mix_params_to_tmb() already invalidated the C++ mix cache.
        -- C++ AudioPump continues — next pump iteration fetches fresh data.
        log.event("apply_mix: %d track(s), tracks_changed=%s",
            #mix_params, tostring(tracks_changed))
        return
    end

    -- Stopped: store position, reset SSE for next start
    if tracks_changed then
        qt_constants.SSE.RESET(M.sse)
    end
    if edit_time_us then
        M.media_time_us = edit_time_us
    end

    log.event("apply_mix: %d track(s), tracks_changed=%s",
        #mix_params, tostring(tracks_changed))
end

--- Refresh mix volumes mid-playback (mute/solo/volume change, same track set).
-- Sends updated volumes to TMB so C++ AudioPump uses new levels.
-- @param mix_params array of {track_index, volume, muted, soloed}
function M.refresh_mix_volumes(mix_params)
    assert(M.session_initialized,
        "audio_playback.refresh_mix_volumes: session not initialized")
    assert(type(mix_params) == "table",
        "audio_playback.refresh_mix_volumes: mix_params must be a table")

    M._mix_params = mix_params
    M.has_audio = #mix_params > 0
    send_mix_params_to_tmb()
    -- NOTE: C++ AudioPump detects volume changes via TMB mix params

    log.event("refresh_mix_volumes: %d track(s)", #mix_params)
end

-- NOTE: PCM buffer management moved to C++ AudioPump in Phase 3.
-- C++ AudioPump now owns the TMB→SSE→AOP pipeline with adaptive sleep (2-15ms).
-- Stub functions kept for test backward-compatibility.

--- STUB: decode_mix_and_send_to_sse (moved to C++ AudioPump)
-- Tests may call this but it's a no-op since C++ owns the pump.
-- Mark as "_phase3_stub" so tests know to skip related assertions.
M._phase3_stub = true

function M.decode_mix_and_send_to_sse()
    -- No-op: C++ AudioPump handles TMB→SSE push
end

--- STUB: render_and_write_to_device (moved to C++ AudioPump)
function M.render_and_write_to_device(_frames_needed)
    -- No-op: C++ AudioPump handles SSE→AOP render
    return 0
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
    log.event("max_time set to %.3fs", max_us / 1000000)
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
    last_sent_resolved = nil

    M._tmb = nil
    M._mix_params = nil
    M.has_audio = false
    M._project_gen = -1
    M.session_initialized = false
    M.session_sample_rate = 0
    M.session_channels = 0

    log.event("Session shutdown")
end

--------------------------------------------------------------------------------
-- Transport Control (these are transport events -> call reanchor)
--------------------------------------------------------------------------------

--- Start audio playback (transport event)
-- NOTE: In Phase 3, C++ AudioPump owns the TMB→SSE→AOP pipeline.
-- This Lua function is retained for direct tests and legacy callers.
-- For normal playback, playback_engine uses PLAYBACK.ACTIVATE_AUDIO + controller:Play()
function M.start()
    assert(M.session_initialized,
        "audio_playback.start: session not initialized")
    if not M.has_audio then
        log.event("start() called but no audio sources - skipping")
        return
    end
    if M.playing then
        log.event("start() called but already playing - skipping")
        return
    end

    assert(M.max_media_time_us >= 0,
        "audio_playback.start: max_media_time_us not set (call set_max_time first)")
    project_gen.check(M._project_gen, "audio_playback.start")

    -- Reanchor at current media_time_us with current speed/mode
    reanchor(M.media_time_us, M.speed, M.quality_mode)

    -- Start AOP device (C++ AudioPump handles decode→stretch→output)
    qt_constants.AOP.START(M.aop)

    M.playing = true

    log.event("Started at %.3fs, speed=%.2f, quality=Q%d",
        M.media_anchor_us / 1000000, M.speed, M.quality_mode)
end

--- Stop audio playback (transport event)
-- NOTE: In Phase 3, C++ AudioPump owns the pump loop.
-- This Lua function is retained for direct tests and legacy callers.
function M.stop()
    if not M.session_initialized then
        log.event("stop() called but no session - skipping")
        return
    end
    if not M.playing then
        return  -- Idempotent, no need to log
    end

    -- Capture heard time BEFORE stopping
    local heard_time = M.get_time_us()

    M.playing = false

    if M.aop then
        qt_constants.AOP.STOP(M.aop)
        qt_constants.AOP.FLUSH(M.aop)
    end

    -- Store captured time for resume
    M.media_time_us = heard_time
    M.media_anchor_us = heard_time

    log.event("Stopped at %.3fs", heard_time / 1000000)
end

--- Seek to position (transport event)
-- @param time_us Playback time in microseconds
function M.seek(time_us)
    assert(type(time_us) == "number", "audio_playback.seek: time_us must be number")

    if not M.session_initialized then
        log.event("seek() called but no session - storing time only")
        M.media_time_us = time_us
        return
    end
    if not M.has_audio then
        log.event("seek() called but no audio - storing time only")
        M.media_time_us = time_us
        return
    end

    if M.playing then
        -- Reanchor while playing (transport event)
        -- C++ AudioPump handles decode→stretch→output
        reanchor(time_us, M.speed, M.quality_mode)
    else
        -- Just update stopped-state position
        M.media_time_us = clamp_media_us(time_us)
        M.media_anchor_us = M.media_time_us
    end

    log.event("Seek to %.3fs", time_us / 1000000)
end

--- Latch at boundary (transport event)
-- Freezes audio output at specified time. Called when shuttle hits boundary.
-- @param time_us Playback time to freeze at (frame-derived, not sampled)
function M.latch(time_us)
    assert(M.session_initialized, "audio_playback.latch: session not initialized")
    assert(type(time_us) == "number" and time_us >= 0,
        ("audio_playback.latch: invalid time_us=%s"):format(tostring(time_us)))

    -- Flush queued audio (C++ AudioPump will stop when it sees playing = false)
    if M.aop then
        qt_constants.AOP.STOP(M.aop)
        qt_constants.AOP.FLUSH(M.aop)
    end

    -- Set stopped state with frozen time
    M.playing = false
    M.media_time_us = time_us
    M.media_anchor_us = time_us

    log.event("Latched at %.3fs", time_us / 1000000)
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
    -- C++ AudioPump handles decode→stretch→output
    local old_mode = M.quality_mode
    if new_mode ~= old_mode or new_signed_speed ~= M.speed then
        local current_media_us = M.get_time_us()
        reanchor(current_media_us, new_signed_speed, new_mode)
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
-- NOTE: Phase 3 moved burst rendering to C++ via PLAYBACK.PLAY_BURST.
-- playback_engine now calls that directly. This stub remains for tests.
--------------------------------------------------------------------------------

--- Play a short audio burst at a given time.
-- NOTE: In Phase 3, burst rendering moved to C++ via PLAYBACK.PLAY_BURST.
-- playback_engine calls that binding directly when controller has audio.
-- This Lua function is retained as a stub for backward compatibility with tests.
-- @param time_us number: playback time to play at
-- @param duration_us number: burst length in microseconds (typically 1 frame)
function M.play_burst(time_us, duration_us)
    if not M.session_initialized then return end
    if not M.has_audio then return end
    if M.playing then return end

    assert(type(time_us) == "number",
        "audio_playback.play_burst: time_us must be number")
    assert(type(duration_us) == "number" and duration_us > 0,
        "audio_playback.play_burst: duration_us must be positive number")

    -- Store stopped-state position at burst time
    M.media_time_us = clamp_media_us(time_us)

    log.event("play_burst (stub): t=%.3fs dur=%.1fms - use PLAYBACK.PLAY_BURST for audio",
        time_us / 1000000, duration_us / 1000)
end

-- NOTE: Pump functions (_pump_tick, _start_pump, _cancel_pump) removed in Phase 3
-- C++ AudioPump now owns the TMB→SSE→AOP pipeline with dedicated thread

return M
