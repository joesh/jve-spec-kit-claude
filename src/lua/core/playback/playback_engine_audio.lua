--- core/playback/playback_engine_audio.lua — audio session lifecycle +
--- audio-mix push + boundary latch + frame-step audio.
---
--- Extracted from playback_engine.lua (2.6: file was 1842 lines). The
--- methods live on the PlaybackEngine class via `install(PlaybackEngine)`
--- so call sites — both internal (play/shuttle/seek) and external
--- (tests) — see no change. Each method is unchanged from its original
--- form; this file is a pure visual split.
---
--- Concerns owned by this module:
---   * Audio device handover (017 FR-011/FR-012): _ensure_audio_ownership,
---     _attach_audio_to_controller, _detach_audio_from_controller, the
---     activate/deactivate shims, shutdown_audio_session.
---   * Audio session config (sample rate, channel count, AOP/SSE wiring):
---     _init_audio_session, _configure_and_start_audio.
---   * Per-clip audio mix: _refresh_audio_mix, _build_audio_mix_params,
---     _push_all_audio_mix_params, _extract_clip_ids,
---     _if_clip_changed_update_audio_mix, _audio_clips_changed.
---   * Audio start/stop/sync transport edge: _start_audio, _stop_audio,
---     _sync_audio, _try_audio.
---   * Boundary latch (shuttle mode): _apply_latch, _clear_latch.
---   * Single-frame jog audio: play_frame_audio.
---
--- Cross-module deps shared with the engine: audio_playback (device
--- ownership + session), qt_constants.PLAYBACK (C++ binding), Signals
--- (track_mix_changed listener), helpers (frame ↔ µs math).

local Signals = require("core.signals")
local qt_constants = require("core.qt_constants")
local helpers = require("core.playback.playback_helpers")
local log = require("core.logger").for_area("ticks")
local audio_playback = require("core.media.audio_playback")

-- Output channel count threaded through TMB → SSE → AOP. Stereo today;
-- multichannel output requires plumbing Sequence.count_master_audio_channels
-- through these layers (see memory: project_multichannel_output_plumbing).
local OUTPUT_CHANNELS = 2

local M = {}

--- Test seam: PlaybackEngine.init_audio(mock_ap) reassigns
--- playback_engine.lua's module-local audio_playback. That setter must
--- also update this module's module-local — otherwise the extracted
--- methods continue to call the real device while playback_engine.lua
--- talks to the mock. init_audio calls this after updating its own
--- local; production code never invokes it.
function M.set_audio(ap)
    audio_playback = ap
end

function M.install(PlaybackEngine)

--------------------------------------------------------------------------------

--- Synchronous handover: if this engine isn't the current owner, halt the
--- prior owner and then acquire the device for this engine. Called from
--- play() and shuttle/slow_play before kicking the C++ transport.
function PlaybackEngine:_ensure_audio_ownership()
    if audio_playback.is_owner(self) then return end
    if audio_playback.current_owner() ~= nil then
        audio_playback.halt_current()
    end
    audio_playback.acquire_for(self)
    self:_attach_audio_to_controller()
end

--- Private: push the audio mix to TMB and wire C++ PlaybackController to
--- the AOP/SSE handles + connect track_mix_changed for live volume edits.
--- Called after acquire_for; idempotent.
function PlaybackEngine:_attach_audio_to_controller()
    self.current_audio_clip_ids = {}
    if self.sequence and self.fps_num then
        if audio_playback and not audio_playback.session_initialized then
            self:_init_audio_session()
        end
        if audio_playback and audio_playback.session_initialized then
            audio_playback.set_max_time(self.max_media_time_us)
        end
        self:_push_all_audio_mix_params()
    end

    if self._playback_controller and audio_playback
       and audio_playback.session_initialized
       and audio_playback.aop and audio_playback.sse then
        qt_constants.PLAYBACK.ACTIVATE_AUDIO(
            self._playback_controller,
            audio_playback.aop,
            audio_playback.sse,
            audio_playback.session_sample_rate,
            audio_playback.session_channels)
    end

    if self._track_mix_conn == nil then
        self._track_mix_conn = Signals.connect("track_mix_changed", function()
            self:_refresh_audio_mix()
        end)
    end
end

--- DEPRECATED (017): legacy callers used activate_audio()/deactivate_audio()
--- to flip a per-engine _audio_owner flag. The 017 architecture replaces
--- those with audio_playback.halt_current()/acquire_for(self). These thin
--- shims keep ~20 legacy test sites green while production code moves to
--- the new API. New callers MUST use _ensure_audio_ownership (or, at the
--- module boundary, audio_playback.acquire_for) directly.
function PlaybackEngine:activate_audio()
    self:_ensure_audio_ownership()
end

function PlaybackEngine:deactivate_audio()
    if audio_playback.is_owner(self) then
        self:_detach_audio_from_controller()
        audio_playback.halt_current()
    end
end

--- Private: detach from audio path. Called when this engine releases
--- ownership (stop / shuttle-to-stop / unload).
function PlaybackEngine:_detach_audio_from_controller()
    if self._track_mix_conn then
        Signals.disconnect(self._track_mix_conn)
        self._track_mix_conn = nil
    end
    if self._playback_controller and qt_constants.PLAYBACK then
        qt_constants.PLAYBACK.DEACTIVATE_AUDIO(self._playback_controller)
    end
    self:_stop_audio()
end

--- Shutdown audio session entirely (app exit or project switch).
function PlaybackEngine.shutdown_audio_session()
    if audio_playback and audio_playback.session_initialized then
        audio_playback.shutdown_session()
        -- Keep module reference — guards check session_initialized and
        -- call _init_audio_session to re-init on next play.
        -- Nil'ing audio_playback here prevents recovery after project_changed.
    end
end

--------------------------------------------------------------------------------
-- Audio Helpers
--------------------------------------------------------------------------------

--- Audio call (fail-fast in development: errors propagate immediately).
-- @param fn_or_name  string method name on self, or function(engine)
function PlaybackEngine:_try_audio(fn_or_name)
    if not (audio_playback and audio_playback.is_owner(self)) then return end
    if type(fn_or_name) == "string" then
        self[fn_or_name](self)
    else
        fn_or_name(self)
    end
end

--- Configure audio sources and start playback (transport start).
function PlaybackEngine:_configure_and_start_audio()
    if not (audio_playback and audio_playback.is_owner(self)) then return end

    -- Ensure audio session is initialized before anything else.
    -- Session init was previously only reachable via _if_clip_changed_update_audio_mix,
    -- which gates on clip-change dedup. If no audio clips at the park position
    -- (empty→empty), init was never reached. Session init is a one-time setup
    -- that must happen on play start, not be gated on clip changes.
    if audio_playback and not audio_playback.session_initialized then
        self:_init_audio_session()
    end

    -- Push mix params for ALL audio tracks in the sequence to TMB.
    -- TMB's execute_mix_range iterates tracks and calls GetTrackAudio(track, t0, t1)
    -- which autonomously looks up clips at each position. TMB just needs track-level
    -- info (which tracks exist + volumes). Position-dependent filtering via
    -- _if_clip_changed_update_audio_mix would skip this entirely when no audio clips
    -- exist at the park position (empty→empty dedup → silence).
    self:_push_all_audio_mix_params()

    -- Ensure C++ knows about audio. activate_audio() may have run before the
    -- session was initialized, so ACTIVATE_AUDIO was skipped. Without this,
    -- m_has_audio stays false → prefillAudio skipped → pump never starts.
    if self._playback_controller and audio_playback
       and audio_playback.session_initialized
       and audio_playback.aop and audio_playback.sse then
        if not qt_constants.PLAYBACK.HAS_AUDIO(self._playback_controller) then
            log.event("_configure_and_start_audio: late ACTIVATE_AUDIO")
            qt_constants.PLAYBACK.ACTIVATE_AUDIO(
                self._playback_controller,
                audio_playback.aop,
                audio_playback.sse,
                audio_playback.session_sample_rate,
                audio_playback.session_channels)
        end
    else
        -- If C++ PlaybackController exists AND audio session fully initialized
        -- (aop+sse present) but we still couldn't ACTIVATE_AUDIO, that's a
        -- broken invariant — C++ won't know about audio, pump never starts.
        local has_full_audio = audio_playback
            and audio_playback.session_initialized
            and audio_playback.aop
            and audio_playback.sse
        if self._playback_controller and has_full_audio then
            assert(false, string.format(
                "PlaybackEngine:_configure_and_start_audio: "
                .. "audio fully initialized but ACTIVATE_AUDIO unreachable "
                .. "(pc=%s aop=%s sse=%s)",
                tostring(self._playback_controller),
                tostring(audio_playback.aop),
                tostring(audio_playback.sse)))
        else
            log.event("_configure_and_start_audio: cannot activate (pc=%s ap=%s init=%s aop=%s sse=%s)",
                tostring(self._playback_controller ~= nil),
                tostring(audio_playback ~= nil),
                tostring(audio_playback and audio_playback.session_initialized),
                tostring(audio_playback and audio_playback.aop ~= nil),
                tostring(audio_playback and audio_playback.sse ~= nil))
        end
    end

    self:_start_audio()
end

--- Start audio at current position.
-- When C++ PlaybackController is active, it owns audio transport
-- (Flush/Reset/SetTarget/Start happen in C++ Play/SetSpeed).
function PlaybackEngine:_start_audio()
    if not (audio_playback and audio_playback.is_owner(self)) then return end
    if self._playback_controller then return end  -- C++ owns transport
    if not audio_playback or not audio_playback.is_ready() then return end

    local time_us = helpers.calc_time_us_from_frame(
        self:get_position(), self.fps_num, self.fps_den)
    helpers.sync_audio(audio_playback, self.direction, self.speed)
    audio_playback.seek(time_us)
    audio_playback.start()
end

function PlaybackEngine:_stop_audio()
    if self._playback_controller then return end  -- C++ owns transport
    helpers.stop_audio(audio_playback)
end

function PlaybackEngine:_sync_audio()
    if self._playback_controller then return end  -- C++ owns transport
    helpers.sync_audio(audio_playback, self.direction, self.speed)
end

--- Detect clip changes at frame and update audio_playback mix params.
-- Called every frame during playback. Common case (no edit boundary) returns early.
function PlaybackEngine:_if_clip_changed_update_audio_mix(frame)
    if not (audio_playback and audio_playback.is_owner(self)) then return end
    assert(self.sequence,
        "PlaybackEngine:_if_clip_changed_update_audio_mix: no sequence loaded")

    local entries = self.sequence:get_audio_at(frame)
    local clip_ids = self:_extract_clip_ids(entries)

    -- Common case: same clips as last frame → nothing to do
    if not self:_audio_clips_changed(clip_ids) then return end

    -- Lazy-init audio session (uses stored sample rate, no media_cache probe)
    if not (audio_playback and audio_playback.session_initialized) then
        self:_init_audio_session()
    end

    if audio_playback and audio_playback.session_initialized then
        self.current_audio_clip_ids = clip_ids
        local mix_params = self:_build_audio_mix_params(entries)
        local edit_time_us = helpers.calc_time_us_from_frame(
            frame, self.fps_num, self.fps_den)
        audio_playback.apply_mix(self._tmb, mix_params, edit_time_us)
    end
end

--- Refresh audio mix volumes immediately (mid-playback mute/solo/volume change).
-- Re-reads track state from DB and pushes to audio_playback.
-- Unlike _if_clip_changed_update_audio_mix, skips the clip-change check.
function PlaybackEngine:_refresh_audio_mix()
    if not (audio_playback and audio_playback.is_owner(self)) then return end  -- signal fires for all engines
    assert(self.sequence,
        "PlaybackEngine:_refresh_audio_mix: audio owner has no sequence")
    if not (audio_playback and audio_playback.session_initialized) then return end

    local frame = math.floor(self._position)
    local entries = self.sequence:get_audio_at(frame)
    local mix_params = self:_build_audio_mix_params(entries)
    audio_playback.refresh_mix_volumes(mix_params)
end

--- Extract clip ID set from audio entries (for change detection).
--- Flush the audio pipeline so a mute/solo change is heard immediately.
-- _refresh_audio_mix updates the mix coefficients (and clears TMB's mix cache),
-- but ~2.6s of already-mixed PCM is queued downstream (SSE + AOP). Drop it so
-- the new mix takes effect at the playhead. Scoped to mute/solo toggles by the
-- caller — fader drags must NOT call this (they'd click on every delta).
function PlaybackEngine:_flush_audio_pipeline_for_mix_change()
    if not (audio_playback and audio_playback.is_owner(self)) then return end
    -- The C++ PlaybackController owns the live transport clock (017 two-engine
    -- model); the flush must run there, off the authoritative clock position.
    -- Doing it Lua-side off the stale audio anchor sent audio to a bogus
    -- position and raced the AudioPump's SSE render on the pump thread.
    assert(self._playback_controller,
        "PlaybackEngine:_flush_audio_pipeline_for_mix_change: audio owner has no playback controller")
    qt_constants.PLAYBACK.FLUSH_AUDIO_FOR_MIX_CHANGE(self._playback_controller)
end

-- @return table: {[clip_id] = true, ...}
function PlaybackEngine:_extract_clip_ids(entries)
    local ids = {}
    for _, entry in ipairs(entries) do
        ids[entry.clip.id] = true
    end
    return ids
end

--- Build per-track mix params from audio entries.
-- @return array of {track_index, volume, muted, soloed}
function PlaybackEngine:_build_audio_mix_params(entries)
    local params = {}
    for _, entry in ipairs(entries) do
        assert(type(entry.track.volume) == "number", string.format(
            "PlaybackEngine:_build_audio_mix_params: track %s missing volume",
            tostring(entry.track.id)))
        assert(type(entry.track.muted) == "boolean", string.format(
            "PlaybackEngine:_build_audio_mix_params: track %s muted must be boolean, got %s",
            tostring(entry.track.id), type(entry.track.muted)))
        assert(type(entry.track.soloed) == "boolean", string.format(
            "PlaybackEngine:_build_audio_mix_params: track %s soloed must be boolean, got %s",
            tostring(entry.track.id), type(entry.track.soloed)))
        params[#params + 1] = {
            track_index = entry.track.track_index,
            volume = entry.track.volume,
            muted = entry.track.muted,
            soloed = entry.track.soloed,
        }
    end
    return params
end

--- Push mix params for ALL audio tracks in the sequence to TMB.
-- Unlike _if_clip_changed_update_audio_mix (which builds params from clips at a
-- specific frame), this builds params from the track list itself. TMB handles
-- position-dependent clip lookup autonomously via GetTrackAudio.
function PlaybackEngine:_push_all_audio_mix_params()
    if not (audio_playback and audio_playback.session_initialized) then return end
    assert(self._tmb,
        "PlaybackEngine:_push_all_audio_mix_params: TMB is nil (session initialized but TMB not set)")
    assert(self.sequence,
        "PlaybackEngine:_push_all_audio_mix_params: no sequence loaded")

    local Track = require("models.track")
    local tracks = Track.find_by_sequence(self.sequence.id, "AUDIO")
    local mix_params = {}
    for _, track in ipairs(tracks) do
        assert(type(track.volume) == "number", string.format(
            "PlaybackEngine:_push_all_audio_mix_params: track %s missing volume",
            tostring(track.id)))
        mix_params[#mix_params + 1] = {
            track_index = track.track_index,
            volume = track.volume,
            muted = track.muted,
            soloed = track.soloed,
        }
    end

    local edit_time_us = helpers.calc_time_us_from_frame(
        math.floor(self:get_position()), self.fps_num, self.fps_den)
    audio_playback.apply_mix(self._tmb, mix_params, edit_time_us)
end

--- True when any AUDIO track in the loaded sequence is soloed. Lets the mute
--- path skip the mix-change flush: with a solo active, solo trumps mute, so
--- toggling any track's mute changes nothing audible — no tail to drop.
function PlaybackEngine:_any_audio_track_soloed()
    assert(self.sequence, "PlaybackEngine:_any_audio_track_soloed: no sequence loaded")
    local Track = require("models.track")
    for _, track in ipairs(Track.find_by_sequence(self.sequence.id, "AUDIO")) do
        if track.soloed then return true end
    end
    return false
end

--- Init audio session using stored sample rate (no media_cache dependency).
function PlaybackEngine:_init_audio_session()
    if not (qt_constants.SSE and qt_constants.AOP) then
        log.event("_init_audio_session: SSE/AOP not available (SSE=%s AOP=%s)",
            tostring(qt_constants.SSE ~= nil), tostring(qt_constants.AOP ~= nil))
        return
    end

    local audio_pb = require("core.media.audio_playback")
    if audio_pb.session_initialized then
        audio_playback = audio_pb
        return
    end

    assert(self.audio_sample_rate and self.audio_sample_rate > 0, string.format(
        "PlaybackEngine:_init_audio_session: audio_sample_rate not set (got %s)",
        tostring(self.audio_sample_rate)))

    -- OUTPUT_CHANNELS is the module-level stereo constant; AOP and SSE
    -- open at the same channel count TMB renders at.
    audio_pb.init_session(self.audio_sample_rate, OUTPUT_CHANNELS)
    audio_pb.set_max_time(self.max_media_time_us)
    audio_playback = audio_pb
    log.event("Init audio session: sr=%s", tostring(self.audio_sample_rate))
end

--- Compare clip ID sets for change detection.
function PlaybackEngine:_audio_clips_changed(new_ids)
    assert(type(new_ids) == "table",
        "PlaybackEngine:_audio_clips_changed: new_ids must be a table")
    local old_count = 0
    for _ in pairs(self.current_audio_clip_ids) do old_count = old_count + 1 end
    local new_count = 0
    for _ in pairs(new_ids) do new_count = new_count + 1 end

    if old_count ~= new_count then return true end
    for id in pairs(new_ids) do
        if not self.current_audio_clip_ids[id] then return true end
    end
    return false
end

--------------------------------------------------------------------------------
-- Boundary Latch (shuttle mode)
--------------------------------------------------------------------------------

--- Apply latch effects at boundary frame.
function PlaybackEngine:_apply_latch(boundary_frame)
    assert(boundary_frame >= 0, string.format(
        "_apply_latch: boundary_frame=%d must be >= 0", boundary_frame))
    local t_us = helpers.calc_time_us_from_frame(
        boundary_frame, self.fps_num, self.fps_den)
    assert(t_us >= 0, string.format(
        "_apply_latch: calc_time_us returned %d for boundary_frame=%d — math bug",
        t_us, boundary_frame))

    if audio_playback and audio_playback.max_media_time_us then
        t_us = math.min(t_us, audio_playback.max_media_time_us)
    end

    if audio_playback and audio_playback.is_ready()
       and audio_playback.latch then
        audio_playback.latch(t_us)
    end

    -- NOTE: no _display_frame here — C++ deliverFrame handles display.

    self.latched = true
    self.latched_boundary = (boundary_frame == 0) and "start" or "end"

    log.event("Latched at %s boundary (frame %d)",
        self.latched_boundary, boundary_frame)
end

function PlaybackEngine:_clear_latch()
    self.latched = false
    self.latched_boundary = nil
end

-- NOTE: _schedule_tick() DELETED. C++ CVDisplayLink drives tick loop.

--------------------------------------------------------------------------------
-- Frame Step Audio (Jog)
--------------------------------------------------------------------------------

--- Play short audio burst for single-frame step (arrow key jog).
function PlaybackEngine:play_frame_audio(frame_idx)
    if self.state == "playing" then return end
    if not (audio_playback and audio_playback.is_owner(self)) then return end
    assert(self.fps_num and self.fps_den,
        "PlaybackEngine:play_frame_audio: fps not set")

    -- Resolve audio sources at the stepped-to frame
    self:_if_clip_changed_update_audio_mix(frame_idx)

    -- C++ path: use PlaybackController's PlayBurst (Phase 3)
    if self._playback_controller and qt_constants.PLAYBACK
       and qt_constants.PLAYBACK.HAS_AUDIO(self._playback_controller) then
        local frame_duration_us = helpers.calc_time_us_from_frame(
            1, self.fps_num, self.fps_den)
        local burst_ms = math.max(40, math.min(60,
            math.floor(frame_duration_us * 1.5 / 1000)))
        qt_constants.PLAYBACK.PLAY_BURST(
            self._playback_controller, frame_idx, 1, burst_ms)
        return
    end

    -- Fallback: Lua path for when PlaybackController not available
    if not audio_playback then return end
    if not audio_playback.is_ready() then return end
    if not audio_playback.play_burst then return end

    local time_us = helpers.calc_time_us_from_frame(
        frame_idx, self.fps_num, self.fps_den)
    local frame_duration_us = helpers.calc_time_us_from_frame(
        1, self.fps_num, self.fps_den)
    -- 1.5x frame duration, clamped to [40ms, 60ms]
    local burst_us = math.max(40000, math.min(60000,
        math.floor(frame_duration_us * 1.5)))
    audio_playback.play_burst(time_us, burst_us)
end

end -- M.install

return M
