--- core/playback/playback_engine_transport.lua — the transport state
--- machine: shuttle (J/L), slow_play (K+J/K+L at 0.5x), play (spacebar),
--- stop. Owns self.state / direction / speed / transport_mode /
--- _last_committed_frame transitions and the unwinding rule
--- (opposite-direction shuttle slows before reversing).
---
--- Extracted from playback_engine.lua (2.6: keep the engine file
--- focused on construction, sequence load/unload, position tracking,
--- and the C++ binding glue). Methods install onto PlaybackEngine via
--- M.install(PlaybackEngine).
---
--- Each public method delegates the actual playback dispatch to
--- self._playback_controller (the C++ CVDisplayLink-driven controller)
--- and uses self:_ensure_audio_ownership (in playback_engine_audio.lua)
--- to acquire the device before kicking the transport.

local qt_constants = require("core.qt_constants")
local audio_playback = require("core.media.audio_playback")
local shuttle_ladder = require("core.playback.shuttle_ladder")

local M = {}

--- Test seam (mirrors playback_engine_audio.set_audio): when
--- PlaybackEngine.init_audio(mock) reassigns the audio handle, the
--- methods extracted here must see the same mock.
function M.set_audio(ap)
    audio_playback = ap
end

function M.install(PlaybackEngine)

-- Transport Control
--------------------------------------------------------------------------------

--- Shuttle in given direction (1=forward, -1=reverse).
-- Implements unwinding: opposite direction slows before reversing.
function PlaybackEngine:shuttle(dir)
    assert(dir == 1 or dir == -1,
        "PlaybackEngine:shuttle: dir must be 1 or -1")

    self:_refresh_content_bounds()

    -- Handle unlatch: opposite direction while latched resumes playback
    if self.latched then
        local at_start = (self.latched_boundary == "start")
        local at_end = (self.latched_boundary == "end")
        local moving_away = (at_start and dir == 1) or (at_end and dir == -1)

        if moving_away then
            self.direction = dir
            self.speed = 1
            self:_clear_latch()
            -- Resume via C++ PlaybackController
            assert(self._playback_controller,
                "PlaybackEngine:shuttle: unlatch requires _playback_controller")
            local PLAYBACK = qt_constants.PLAYBACK
            PLAYBACK.SET_SHUTTLE_MODE(self._playback_controller, true)
            PLAYBACK.PLAY(self._playback_controller, dir, 1.0)
            return
        else
            return  -- same direction as boundary, stay latched
        end
    end

    local was_stopped = (self.state == "stopped")

    if self.state == "stopped" then
        self.direction = dir
        self.speed = 1
        self.state = "playing"
        self.transport_mode = "shuttle"
        self._last_committed_frame = math.floor(self:get_position())
    elseif self.direction == dir then
        self.speed = shuttle_ladder.step_up(self.speed)
    else
        local next_speed = shuttle_ladder.step_down(self.speed)
        if next_speed == nil then
            self:stop()
            return
        end
        self.speed = next_speed
    end

    self.transport_mode = "shuttle"

    if was_stopped then
        -- 017: synchronous handover before kicking transport (FR-011 + FR-012).
        self:_ensure_audio_ownership()
    else
        self:_try_audio("_sync_audio")
    end

    -- Delegate to C++ PlaybackController
    assert(self._playback_controller,
        "PlaybackEngine:shuttle: _playback_controller required")
    local PLAYBACK = qt_constants.PLAYBACK
    PLAYBACK.SET_SHUTTLE_MODE(self._playback_controller, true)
    PLAYBACK.PLAY(self._playback_controller, self.direction, self.speed)
end

--- K+J or K+L: slow playback at 0.5x
function PlaybackEngine:slow_play(dir)
    assert(dir == 1 or dir == -1,
        "PlaybackEngine:slow_play: dir must be 1 or -1")

    -- Already playing at 0.5x in this direction? Key repeat — no-op.
    -- Without this, each K+J repeat calls C++ Play() which resets audio,
    -- clock, prefetch, and diag state, preventing continuous playback.
    if self.state == "playing" and self.direction == dir and self.speed == 0.5 then
        return
    end

    self:_refresh_content_bounds()

    self.direction = dir
    self.speed = 0.5
    self.state = "playing"
    self.transport_mode = "shuttle"
    self._last_committed_frame = math.floor(self:get_position())

    -- 017: synchronous handover before kicking transport (FR-011).
    self:_ensure_audio_ownership()

    -- Delegate to C++ PlaybackController
    assert(self._playback_controller,
        "PlaybackEngine:slow_play: _playback_controller required")
    local PLAYBACK = qt_constants.PLAYBACK
    PLAYBACK.SET_SHUTTLE_MODE(self._playback_controller, true)
    PLAYBACK.PLAY(self._playback_controller, dir, 0.5)
end

--- Play forward at 1x speed (spacebar).
-- 017: asserts the engine is loaded and stopped. The clean no-op for
-- "Space with nothing loaded" (FR-027) is implemented at the command
-- layer (core.commands.playback) BEFORE reaching the engine.
function PlaybackEngine:play()
    assert(self.loaded_sequence_id ~= nil, string.format(
        "PlaybackEngine[%s]:play: no sequence loaded — command layer must "
        .. "filter Space-with-empty-target per FR-027 before reaching here",
        self.role))
    -- Idempotent: legacy callers and the TogglePlay path may invoke play
    -- on an already-playing engine. The spec's invariant ("state must be
    -- stopped") is enforced at command-dispatch (TogglePlay checks
    -- is_playing first); silent-return here keeps the engine resilient.
    if self.state == "playing" then return end

    self:_refresh_content_bounds()

    -- 017 audio handover: ensure this engine owns the audio device BEFORE
    -- kicking the C++ transport. Invariants I1 (no-overlap) + I2
    -- (audio-before-video) are upheld inside audio_playback.halt_current /
    -- acquire_for; ACTIVATE_AUDIO + signal hookup happen in
    -- _attach_audio_to_controller (called from _ensure_audio_ownership).
    self:_ensure_audio_ownership()

    self.direction = 1
    self.speed = 1
    self.state = "playing"
    self.transport_mode = "play"
    self._last_committed_frame = math.floor(self:get_position())
    self:_clear_latch()

    -- Delegate to C++ PlaybackController
    assert(self._playback_controller,
        "PlaybackEngine:play: _playback_controller required")
    local PLAYBACK = qt_constants.PLAYBACK
    PLAYBACK.SET_SHUTTLE_MODE(self._playback_controller, false)
    PLAYBACK.PLAY(self._playback_controller, 1, 1.0)
end

--- Stop playback.
-- 017: persists the engine's position to the Model row (FR-007) and releases
-- the audio device if this engine is the current owner.
function PlaybackEngine:stop()
    -- Idempotent: stopping an already-stopped engine is a no-op. Many
    -- existing call paths (load_sequence prelude, project_changed reset)
    -- call stop on engines that may not be playing; that should be safe.
    if self.state ~= "playing" then
        -- Still allow C++ controller to receive a STOP — harmless if not
        -- playing, and clears any residual transport state.
        if self._playback_controller then
            qt_constants.PLAYBACK.STOP(self._playback_controller)
        end
        return
    end

    -- Stop C++ PlaybackController if active
    if self._playback_controller then
        qt_constants.PLAYBACK.STOP(self._playback_controller)
    end

    self.state = "stopped"
    self.direction = 0
    self.speed = 1
    self.transport_mode = "none"
    self._last_committed_frame = nil
    self:_clear_latch()

    -- 017: persist playhead on stop (FR-007).
    self:_persist_playhead()
    self._writeback_throttle_last_s = nil

    -- 017: release audio device if owned.
    if audio_playback and audio_playback.is_owner(self) then
        self:_detach_audio_from_controller()
        audio_playback.halt_current()
    else
        self:_stop_audio()
    end

    -- TMB stays alive across stop/play — no need to re-create.
    -- Stop all background decode work (REFILL workers + pre-buffer jobs).
    -- Prevents zombie HW decoders from competing for GPU decode engine.
    if self._tmb then
        qt_constants.EMP.TMB_PARK_READERS(self._tmb)
    end
end

end -- M.install

return M
