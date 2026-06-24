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
-- Quality mode policy lives in its own module so the speed→mode mapping
-- can be exercised without the SSE/AOP/EMP require graph (audio_quality_mode
-- is pure-Lua, no Qt deps).
local quality_mode = require("core.media.audio_quality_mode")
local Q1                  = quality_mode.Q1
local Q2                  = quality_mode.Q2
local Q3_DECIMATE         = quality_mode.Q3_DECIMATE
local MAX_SPEED_STRETCHED = quality_mode.MAX_SPEED_STRETCHED
local MAX_SPEED_DECIMATE  = quality_mode.MAX_SPEED_DECIMATE

-- Synchronous drain timeout. Hard upper bound on how long halt_current()
-- waits for in-flight audio buffers to flush before asserting. Caller of
-- halt_current() does NOT pass this; the audio module owns the policy.
local AUDIO_HALT_TIMEOUT_MS = 100

-- Module-private: which PlaybackEngine currently owns the audio device.
-- Single owner at all times (FR-011). Accessed externally only via the
-- public accessors current_owner() and is_owner(engine).
local _owning_engine = nil

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
            vol = track.soloed and track.volume or 0  -- lint-allow: R010 Lua ternary (soloed ? volume : 0), not a missing-data fallback
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
            -- C++ AudioPump owns the SSE thread-affinity assert while running;
            -- a direct SSE.RESET from main here would trip it. The pump will
            -- be torn down through the controller's DeactivateAudio path
            -- (called by the engine framework on transport changes), whose
            -- exit ritual clears SSE owner. The next acquire_for re-initializes
            -- SSE state. AOP.STOP/FLUSH still run here because AOP lives on
            -- main throughout (see specs/017/audio-stack-lessons-and-future.md).
            M.playing = false
            qt_constants.AOP.STOP(M.aop)
            qt_constants.AOP.FLUSH(M.aop)
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

-- NOTE: dropping the already-mixed downstream tail on a solo/mute change lives
-- in C++ (PlaybackController::FlushAudioForMixChange) — the C++ clock is the
-- transport authority in the 017 two-engine model, so the flush must reanchor
-- off it, not off this module's stale anchor.

-- NOTE: PCM buffer management moved to C++ AudioPump in Phase 3.
-- C++ AudioPump owns the TMB→SSE→AOP pipeline with adaptive sleep
-- (2-15ms). The Lua-side decode_mix_and_send_to_sse / render_and_write_to_device
-- entrypoints are gone — there is nothing to expose from Lua.

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

--- Start audio playback (transport event). C++ AudioPump owns the
-- TMB→SSE→AOP pipeline; this Lua entry point sets up the Lua-side state
-- (reanchor, mark playing) and starts the AOP device. playback_engine
-- and playback_helpers are the production callers.
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

    -- audio_quality_mode.pick asserts the speed range (>= 0,
    -- <= MAX_SPEED_DECIMATE) and returns the band-appropriate mode.
    local new_mode = quality_mode.pick(math.abs(new_signed_speed))

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
-- C++ owns burst rendering via PLAYBACK.PLAY_BURST when the
-- PlaybackController is available with audio. The Lua entry point below
-- is the fallback for when no audio is loaded (tracks the stopped-state
-- position so the playhead stays in sync) and for unit tests that drive
-- audio_playback directly.
--------------------------------------------------------------------------------

--- Update stopped-state position at a given burst time. No decode/render
-- happens here — that's the C++ AudioPump path. playback_engine calls
-- this when its controller doesn't have audio (no media loaded yet).
-- @param time_us number: playback time to anchor at
-- @param duration_us number: burst length in microseconds (kept for API
--   parity with the C++ binding; not consumed by the Lua fallback)
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

    log.event("play_burst Lua fallback (no decode): t=%.3fs dur=%.1fms",
        time_us / 1000000, duration_us / 1000)
end

-- NOTE: Pump functions (_pump_tick, _start_pump, _cancel_pump) removed in Phase 3
-- C++ AudioPump now owns the TMB→SSE→AOP pipeline with dedicated thread

--------------------------------------------------------------------------------
-- Two-engine handover (017): single-owner audio device.
--
-- The audio device is owned at any moment by AT MOST one PlaybackEngine
-- (the "source-role" engine or the "record-role" engine). The two invariants
-- are observable from outside this module:
--   I1 (no-overlap): no sample-instant carries audio produced by both engines.
--   I2 (audio-before-video): on handover, the new engine's audio device is
--       fully acquired before any video frame for that engine is delivered.
--
-- Caller protocol from engine:play():
--   1. if is_owner(self) → no-op (already owns).
--   2. else if current_owner() ~= nil → halt_current() (sync; returns when no
--      further samples will be produced).
--   3. acquire_for(self) (sync; configures device for self.sequence's bus rate
--      or silent-output path for video-only masters per FR-013a).
--
-- The pair (halt_current, acquire_for) replaces the older activate/deactivate
-- methods that lived on PlaybackEngine. Engines do NOT carry a `_audio_owner`
-- flag; ownership is structurally `audio_playback.is_owner(self)`.
--------------------------------------------------------------------------------

--- Return the engine currently owning the audio device, or nil.
function M.current_owner()
    return _owning_engine
end

--- True iff `engine` is the current owner. Asserts on bad input.
function M.is_owner(engine)
    assert(engine ~= nil, "audio_playback.is_owner: engine must not be nil")
    return _owning_engine == engine
end

--- Pure C++ wrapper: drain in-flight audio. Returns ok, err per existing
--- FFI conventions. Bounded by AUDIO_HALT_TIMEOUT_MS internally.
--- @return boolean ok, string|nil err
function M._ffi_drain(timeout_ms)
    assert(type(timeout_ms) == "number" and timeout_ms > 0, string.format(
        "audio_playback._ffi_drain: timeout_ms must be positive number, got %s",
        tostring(timeout_ms)))
    -- In Phase 3, the C++ AudioPump runs autonomously. Synchronous drain is
    -- achieved by stopping the AOP device (which immediately ceases sample
    -- production from the OS mixer perspective) and flushing its queue. The
    -- audio is master clock — once AOP.STOP returns, no further samples
    -- reach the speakers from this owner.
    if not M.session_initialized or not M.aop then return true end
    qt_constants.AOP.STOP(M.aop)
    qt_constants.AOP.FLUSH(M.aop)
    return true
end

--- Pure C++ wrapper: acquire device at the given rate/channels for this
--- engine's sequence. Returns ok, err. Asserts on bad input.
--- @return boolean ok, string|nil err
function M._ffi_acquire(rate_hz, channels)
    assert(type(rate_hz) == "number" and rate_hz > 0, string.format(
        "audio_playback._ffi_acquire: rate_hz must be positive number, got %s",
        tostring(rate_hz)))
    assert(type(channels) == "number" and channels > 0, string.format(
        "audio_playback._ffi_acquire: channels must be positive number, got %s",
        tostring(channels)))
    if not M.session_initialized then
        M.init_session(rate_hz, channels)
        return true
    end
    -- Session already initialized at a (possibly different) rate. The OS
    -- mixer handles resampling; we do not tear down and reopen on every
    -- handover — that would introduce a click. Tests assert the same
    -- rate is used; production paths route through TMB's audio_format.
    return true
end

--- Pure C++ wrapper: acquire device in silent-output mode for a video-only
--- master (FR-013a). No samples will be produced; the device is held so
--- the handover protocol still runs uniformly.
function M._ffi_configure_silent()
    -- Silent-output is the absence of audio sources at the TMB layer. The
    -- AOP device may stay open; the AudioPump simply receives no mix
    -- params, so no samples reach SSE/AOP. has_audio drives this:
    M.has_audio = false
    return true
end

--- Halt the current owner's audio output synchronously. No-op when no owner.
--- Bounded by AUDIO_HALT_TIMEOUT_MS internally; asserts on timeout with
--- elapsed + role context for diagnosis.
function M.halt_current()
    if _owning_engine == nil then return end
    assert(_G.qt_monotonic_s, "audio_playback.halt_current: qt_monotonic_s missing (test_env or C++ binding required)")
    local start_s = _G.qt_monotonic_s()
    local ok, err = M._ffi_drain(AUDIO_HALT_TIMEOUT_MS)
    assert(ok, string.format(
        "audio_playback.halt_current: drain failed for engine[%s,%s]: %s",
        tostring(_owning_engine.role),
        tostring(_owning_engine.loaded_sequence_id),
        tostring(err)))
    local elapsed_ms = (_G.qt_monotonic_s() - start_s) * 1000
    assert(elapsed_ms <= AUDIO_HALT_TIMEOUT_MS, string.format(
        "audio_playback.halt_current: drain exceeded %dms (took %.1fms) for engine[%s,%s]",
        AUDIO_HALT_TIMEOUT_MS, elapsed_ms,
        tostring(_owning_engine.role),
        tostring(_owning_engine.loaded_sequence_id)))
    -- Drop ownership AFTER the device is quiet — invariant I1.
    M.playing = false
    M._tmb = nil
    M._mix_params = nil
    M.has_audio = false
    _owning_engine = nil
    log.event("halt_current: drain ok in %.1fms", elapsed_ms)
end

--- Acquire the audio device for `engine`. Engine must have a non-nil
--- `loaded_sequence_id` and a `sequence` row reachable via the Model.
--- Asserts on bad input or if another engine already owns the device
--- (caller must halt_current first).
function M.acquire_for(engine)
    assert(type(engine) == "table", string.format(
        "audio_playback.acquire_for: engine must be a table, got %s",
        type(engine)))
    assert(engine.role == "source" or engine.role == "record", string.format(
        "audio_playback.acquire_for: engine.role must be 'source'|'record', got %s",
        tostring(engine.role)))
    assert(engine.loaded_sequence_id ~= nil, string.format(
        "audio_playback.acquire_for: engine[%s] has no loaded_sequence_id",
        engine.role))
    assert(_owning_engine == nil, string.format(
        "audio_playback.acquire_for: another engine[%s,%s] already owns device — "
        .. "caller must halt_current() first",
        tostring(_owning_engine and _owning_engine.role),
        tostring(_owning_engine and _owning_engine.loaded_sequence_id)))

    -- Derive bus rate from the engine's sequence row. For video-only
    -- masters (audio_sample_rate is nil), take the silent-output path.
    local seq = engine.sequence
    if seq and seq.audio_sample_rate and seq.audio_sample_rate > 0 then
        local ok, err = M._ffi_acquire(seq.audio_sample_rate, 2)
        assert(ok, string.format(
            "audio_playback.acquire_for: _ffi_acquire failed: %s", tostring(err)))
        M.has_audio = true
    else
        M._ffi_configure_silent()
    end
    _owning_engine = engine
    M.playing = true
    -- Start the audio device here (audio path only) so M.playing semantics
    -- match device state (consumers gate on M.playing). The first sink is
    -- created on this Lua/main thread, which is required: QAudioSink on
    -- macOS needs a Qt event loop on its owner thread and only main has one
    -- (see specs/017/audio-stack-lessons-and-future.md). PlaybackController's
    -- prefillAudio path will Flush+Start it again at Play time — a no-op
    -- stop+restart on the same owner thread. Skip for video-only/silent
    -- masters: M.aop is nil and there is no sink to start.
    if M.has_audio then
        assert(M.aop,
            "audio_playback.acquire_for: has_audio=true but M.aop is nil — "
            .. "_ffi_acquire did not populate the device handle")
        qt_constants.AOP.START(M.aop)
    end
    log.event("acquire_for: engine[%s,%s] (has_audio=%s)",
        engine.role,
        tostring(engine.loaded_sequence_id):sub(1, 8),
        tostring(M.has_audio))
end

return M
