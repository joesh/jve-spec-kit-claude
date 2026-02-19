--- PlaybackEngine: instantiable playback controller for any sequence kind.
--
-- Replaces the singleton playback_controller. Each SequenceMonitor owns one instance.
--
-- Key design: NO sequence-kind branching. Masterclips and timelines use
-- identical code paths via Renderer (video) and TMB (audio).
--
-- Video path uses TimelineMediaBuffer (TMB) — a C++ class that owns readers,
-- caches frames, and pre-buffers at clip boundaries. Lua feeds clip windows
-- incrementally via _send_clips_to_tmb() and reads decoded frames via Renderer.
--
-- Unified tick combines source_playback boundary-latch logic and
-- timeline_playback audio-following/stuckness-detection into one algorithm.
--
-- Audio coordination: only one PlaybackEngine "owns" audio at a time.
-- activate_audio() / deactivate_audio() manage ownership.
--
-- Callbacks (set at construction):
--   on_show_frame(frame_handle, metadata)  — display decoded video frame
--   on_show_gap()                          — display black/gap
--   on_set_rotation(degrees)               — apply rotation for media
--   on_position_changed(frame)             — position update notification
--
-- @file playback_engine.lua

local logger = require("core.logger")
local qt_constants = require("core.qt_constants")
local Renderer = require("core.renderer")
local Sequence = require("models.sequence")
local helpers = require("core.playback.playback_helpers")

local PlaybackEngine = {}
PlaybackEngine.__index = PlaybackEngine

-- Class-level audio playback reference (singleton audio device)
local audio_playback = nil

--- Set class-level audio module reference.
-- @param ap audio_playback module
function PlaybackEngine.init_audio(ap)
    audio_playback = ap
    logger.debug("playback_engine", "Audio module initialized")
end

--- Get class-level audio module reference (for tests/inspection).
function PlaybackEngine.get_audio()
    return audio_playback
end

--------------------------------------------------------------------------------
-- Constructor
--------------------------------------------------------------------------------

--- Create a new PlaybackEngine instance.
-- @param config table:
--   on_show_frame     function(frame_handle, metadata)
--   on_show_gap       function()
--   on_set_rotation   function(degrees)
--   on_position_changed function(frame)
function PlaybackEngine.new(config)
    assert(type(config) == "table",
        "PlaybackEngine.new: config must be a table")
    assert(type(config.on_show_frame) == "function",
        "PlaybackEngine.new: on_show_frame callback required")
    assert(type(config.on_show_gap) == "function",
        "PlaybackEngine.new: on_show_gap callback required")
    assert(type(config.on_set_rotation) == "function",
        "PlaybackEngine.new: on_set_rotation callback required")
    assert(type(config.on_position_changed) == "function",
        "PlaybackEngine.new: on_position_changed callback required")

    local self = setmetatable({}, PlaybackEngine)

    -- Transport state
    self.state = "stopped"
    self.direction = 0
    self.speed = 1
    self._position = 0
    self.total_frames = 0
    self.fps_num = nil
    self.fps_den = nil
    self.fps = nil  -- fps_num/fps_den, for interval computation only
    self.max_media_time_us = 0
    self.transport_mode = "none"

    -- Boundary latch (shuttle mode)
    self.latched = false
    self.latched_boundary = nil

    -- Sequence state
    self.sequence_id = nil
    self.sequence = nil
    self.current_clip_id = nil
    self.current_audio_clip_ids = {}

    -- Config (immutable after construction)
    self._on_show_frame = config.on_show_frame
    self._on_show_gap = config.on_show_gap
    self._on_set_rotation = config.on_set_rotation
    self._on_position_changed = config.on_position_changed

    -- Tick state
    self._tick_generation = 0
    self._last_tick_frame = nil
    self._last_audio_frame = nil
    self._last_committed_frame = nil

    -- Audio ownership (only one engine owns audio at a time)
    self._audio_owner = false

    -- TMB (TimelineMediaBuffer) — owns video readers, cache, pre-buffer
    self._tmb = nil
    self._video_track_indices = {}   -- track indices for Renderer iteration
    self._audio_track_indices = {}   -- audio track indices for TMB audio path

    return self
end

--------------------------------------------------------------------------------
-- Sequence Loading
--------------------------------------------------------------------------------

--- Load a sequence for playback (any kind: masterclip or timeline).
-- @param sequence_id string
-- @param total_frames number optional override (caller-provided content end)
function PlaybackEngine:load_sequence(sequence_id, total_frames)
    assert(sequence_id and sequence_id ~= "",
        "PlaybackEngine:load_sequence: sequence_id required")

    self:stop()

    local info = Renderer.get_sequence_info(sequence_id)
    assert(info.fps_num and info.fps_num > 0, string.format(
        "PlaybackEngine:load_sequence: fps_num must be > 0 for %s, got %s",
        sequence_id, tostring(info.fps_num)))
    assert(info.fps_den and info.fps_den > 0, string.format(
        "PlaybackEngine:load_sequence: fps_den must be > 0 for %s, got %s",
        sequence_id, tostring(info.fps_den)))

    local seq = Sequence.load(sequence_id)
    assert(seq, string.format(
        "PlaybackEngine:load_sequence: sequence %s not found", sequence_id))

    self.sequence_id = sequence_id
    self.sequence = seq
    self.fps_num = info.fps_num
    self.fps_den = info.fps_den
    self.fps = info.fps_num / info.fps_den
    self.current_clip_id = nil
    self.current_audio_clip_ids = {}
    self._position = 0

    if total_frames and total_frames >= 1 then
        self.total_frames = total_frames
    else
        self.total_frames = math.max(1, self:_compute_content_end())
    end

    self.max_media_time_us = helpers.calc_time_us_from_frame(
        self.total_frames - 1, self.fps_num, self.fps_den)

    if self._audio_owner and audio_playback
       and audio_playback.session_initialized then
        audio_playback.set_max_time(self.max_media_time_us)
    end

    -- TMB lifecycle: close previous, create new
    self:_close_tmb()
    self:_create_tmb()

    -- Initial clip feed at starting position
    self:_send_clips_to_tmb(0)

    logger.debug("playback_engine", string.format(
        "Loaded sequence %s (%s): %d frames @ %d/%d fps",
        sequence_id:sub(1, 8), info.kind,
        self.total_frames, self.fps_num, self.fps_den))
end

--- Compute content end frame from sequence clips (max of timeline_start + duration).
-- Delegates to Sequence model (SQL isolation: only models/ execute SQL).
function PlaybackEngine:_compute_content_end()
    assert(self.sequence,
        "PlaybackEngine:_compute_content_end: no sequence loaded")
    return self.sequence:compute_content_end()
end

--- Refresh content bounds from database.
-- Recomputes total_frames and max_media_time_us from current sequence content.
-- Called at transport start (play/shuttle/slow_play) to pick up clip changes
-- since load_sequence was last called.
function PlaybackEngine:_refresh_content_bounds()
    if not self.sequence then return end

    local new_end = math.max(1, self:_compute_content_end())
    if new_end == self.total_frames then return end

    self.total_frames = new_end
    self.max_media_time_us = helpers.calc_time_us_from_frame(
        new_end - 1, self.fps_num, self.fps_den)

    if self._audio_owner and audio_playback
       and audio_playback.session_initialized then
        audio_playback.set_max_time(self.max_media_time_us)
    end

    logger.debug("playback_engine", string.format(
        "Refreshed content bounds: %d frames, max_time=%.3fs",
        self.total_frames, self.max_media_time_us / 1000000))
end

--------------------------------------------------------------------------------
-- TMB Lifecycle
--------------------------------------------------------------------------------

--- Create TMB instance and configure sequence rate + audio format.
function PlaybackEngine:_create_tmb()
    assert(self.fps_num and self.fps_den,
        "PlaybackEngine:_create_tmb: fps not set")

    local EMP = qt_constants.EMP
    self._tmb = EMP.TMB_CREATE(2)
    assert(self._tmb, "PlaybackEngine:_create_tmb: TMB_CREATE returned nil")

    EMP.TMB_SET_SEQUENCE_RATE(self._tmb, self.fps_num, self.fps_den)

    -- Audio format: 48kHz stereo F32 (standard output format)
    EMP.TMB_SET_AUDIO_FORMAT(self._tmb, 48000, 2)
end

--- Close TMB instance if active.
function PlaybackEngine:_close_tmb()
    if self._tmb then
        qt_constants.EMP.TMB_CLOSE(self._tmb)
        self._tmb = nil
    end
    self._video_track_indices = {}
    self._audio_track_indices = {}
end

--- Feed TMB with current + next clips for each video and audio track.
-- Builds a small clip window (2-3 clips per track) from sequence queries.
-- Called every frame during playback (lightweight: reuses existing SQL queries).
-- @param frame integer: current playhead frame
function PlaybackEngine:_send_clips_to_tmb(frame)
    assert(self._tmb, "PlaybackEngine:_send_clips_to_tmb: no TMB")
    assert(self.sequence, "PlaybackEngine:_send_clips_to_tmb: no sequence")

    local EMP = qt_constants.EMP

    -- Get current clips per track
    local current_entries = self.sequence:get_video_at(frame)

    -- Build track_index → clip list mapping
    local track_clips = {}   -- {[track_index] = {clip_table, ...}}

    for _, entry in ipairs(current_entries) do
        local idx = entry.track.track_index
        if not track_clips[idx] then
            track_clips[idx] = {}
        end
        track_clips[idx][#track_clips[idx] + 1] = self:_build_tmb_clip(entry, 1.0)
    end

    -- Get next clips (direction-aware) and add to same track
    local next_entries
    if #current_entries > 0 then
        -- Use clip end frame of first entry as boundary for next lookup
        for _, entry in ipairs(current_entries) do
            local clip_end = entry.clip.timeline_start + entry.clip.duration
            local nexts
            if self.direction >= 0 then
                nexts = self.sequence:get_next_video(clip_end)
            else
                nexts = self.sequence:get_prev_video(entry.clip.timeline_start)
            end
            for _, ne in ipairs(nexts) do
                local idx = ne.track.track_index
                if not track_clips[idx] then
                    track_clips[idx] = {}
                end
                -- Avoid duplicate clip_ids
                local dominated = false
                for _, existing in ipairs(track_clips[idx]) do
                    if existing.clip_id == ne.clip.id then
                        dominated = true
                        break
                    end
                end
                if not dominated then
                    track_clips[idx][#track_clips[idx] + 1] = self:_build_tmb_clip(ne, 1.0)
                end
            end
        end
    end

    -- If no current entries but we have a direction, try finding next clip ahead
    if #current_entries == 0 then
        next_entries = self.sequence:get_next_video(frame)
        for _, ne in ipairs(next_entries or {}) do
            local idx = ne.track.track_index
            if not track_clips[idx] then
                track_clips[idx] = {}
            end
            track_clips[idx][#track_clips[idx] + 1] = self:_build_tmb_clip(ne, 1.0)
        end
    end

    -- Feed each video track to TMB
    local indices = {}
    for idx, clips in pairs(track_clips) do
        EMP.TMB_SET_TRACK_CLIPS(self._tmb, "video", idx, clips)
        indices[#indices + 1] = idx
    end

    -- Sort indices (lowest = topmost = highest priority)
    table.sort(indices)
    self._video_track_indices = indices

    -- ── Audio tracks ──
    self:_send_audio_clips_to_tmb(frame, EMP)
end

--- Feed audio clips near the playhead to TMB (same pattern as video).
-- Called from _send_clips_to_tmb every tick.
function PlaybackEngine:_send_audio_clips_to_tmb(frame, EMP)
    local audio_entries = self.sequence:get_audio_at(frame)

    -- Build track_index → clip list mapping
    local audio_track_clips = {}

    for _, entry in ipairs(audio_entries) do
        local idx = entry.track.track_index
        if not audio_track_clips[idx] then
            audio_track_clips[idx] = {}
        end
        local sr = self:_compute_audio_speed_ratio(entry)
        audio_track_clips[idx][#audio_track_clips[idx] + 1] =
            self:_build_tmb_clip(entry, sr)
    end

    -- Direction-aware next/prev for pre-buffer
    for _, entry in ipairs(audio_entries) do
        local clip_end = entry.clip.timeline_start + entry.clip.duration
        local nexts
        if self.direction >= 0 then
            nexts = self.sequence:get_next_audio(clip_end)
        else
            nexts = self.sequence:get_prev_audio(entry.clip.timeline_start)
        end
        for _, ne in ipairs(nexts) do
            local idx = ne.track.track_index
            if not audio_track_clips[idx] then
                audio_track_clips[idx] = {}
            end
            local dominated = false
            for _, existing in ipairs(audio_track_clips[idx]) do
                if existing.clip_id == ne.clip.id then
                    dominated = true
                    break
                end
            end
            if not dominated then
                local sr = self:_compute_audio_speed_ratio(ne)
                audio_track_clips[idx][#audio_track_clips[idx] + 1] =
                    self:_build_tmb_clip(ne, sr)
            end
        end
    end

    -- Gap: no current audio entries → try finding next clip ahead
    if #audio_entries == 0 then
        local next_audio = self.sequence:get_next_audio(frame)
        for _, ne in ipairs(next_audio or {}) do
            local idx = ne.track.track_index
            if not audio_track_clips[idx] then
                audio_track_clips[idx] = {}
            end
            local sr = self:_compute_audio_speed_ratio(ne)
            audio_track_clips[idx][#audio_track_clips[idx] + 1] =
                self:_build_tmb_clip(ne, sr)
        end
    end

    -- Feed each audio track to TMB
    local audio_indices = {}
    for idx, clips in pairs(audio_track_clips) do
        EMP.TMB_SET_TRACK_CLIPS(self._tmb, "audio", idx, clips)
        audio_indices[#audio_indices + 1] = idx
    end
    table.sort(audio_indices)
    self._audio_track_indices = audio_indices
end

--- Build a TMB clip table from a sequence entry (get_video_at/get_audio_at result).
-- @param entry table: {media_path, clip, track, ...}
-- @param speed_ratio number: conform ratio (1.0 for video, seq_fps/media_fps for audio)
-- @return table matching TMB_SET_TRACK_CLIPS format
function PlaybackEngine:_build_tmb_clip(entry, speed_ratio)
    local clip = entry.clip
    assert(clip.rate, string.format(
        "PlaybackEngine:_build_tmb_clip: clip %s missing rate", clip.id))
    assert(type(speed_ratio) == "number" and speed_ratio > 0, string.format(
        "PlaybackEngine:_build_tmb_clip: clip %s speed_ratio must be > 0, got %s",
        clip.id, tostring(speed_ratio)))

    return {
        clip_id = clip.id,
        media_path = entry.media_path,
        timeline_start = clip.timeline_start,
        duration = clip.duration,
        source_in = clip.source_in,
        rate_num = clip.rate.fps_numerator,
        rate_den = clip.rate.fps_denominator,
        speed_ratio = speed_ratio,
    }
end

--- Compute audio conform speed_ratio: seq_fps / media_video_fps.
-- When media_video_fps >= 1000 (audio-only) or matches seq_fps, returns 1.0.
-- @param entry table: audio entry from get_audio_at (has media_fps_num/den)
-- @return number: speed_ratio > 0
function PlaybackEngine:_compute_audio_speed_ratio(entry)
    local media_fps_num = entry.media_fps_num
    local media_fps_den = entry.media_fps_den
    if not media_fps_num or not media_fps_den or media_fps_den == 0 then
        return 1.0
    end
    local media_video_fps = media_fps_num / media_fps_den
    -- Audio-only media (rate >= 1000) or matching fps → no conform
    if media_video_fps >= 1000 then return 1.0 end
    local seq_fps = self.fps_num / self.fps_den
    if math.abs(media_video_fps - seq_fps) < 0.01 then return 1.0 end
    return seq_fps / media_video_fps
end

--------------------------------------------------------------------------------
-- Position Accessors
--------------------------------------------------------------------------------

function PlaybackEngine:get_position()
    return self._position
end

--- Set position and fire callback.
function PlaybackEngine:set_position(v)
    self._position = v
    self._on_position_changed(math.floor(v))
end

--- Set position without firing callback (avoids re-entrant listener loops).
function PlaybackEngine:set_position_silent(v)
    self._position = v
end

--------------------------------------------------------------------------------
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
            local t_us = 0
            if audio_playback and audio_playback.is_ready() then
                t_us = audio_playback.get_media_time_us()
            end
            self:_clear_latch()
            if audio_playback and audio_playback.is_ready() then
                audio_playback.seek(t_us)
                audio_playback.set_speed(dir * 1)
                audio_playback.start()
            end
            self:_schedule_tick()
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
        self._last_tick_frame = math.floor(self:get_position())
        qt_constants.EMP.SET_DECODE_MODE("play")
    elseif self.direction == dir then
        if self.speed < 8 then
            self.speed = self.speed * 2
        end
    else
        if self.speed > 1 then
            self.speed = self.speed / 2
        elseif self.speed == 1 then
            self:stop()
            return
        elseif self.speed == 0.5 then
            self:stop()
            return
        end
    end

    self.transport_mode = "shuttle"

    if was_stopped then
        self:_try_audio("_configure_and_start_audio")
    else
        self:_try_audio("_sync_audio")
    end

    self:_schedule_tick()
end

--- K+J or K+L: slow playback at 0.5x
function PlaybackEngine:slow_play(dir)
    assert(dir == 1 or dir == -1,
        "PlaybackEngine:slow_play: dir must be 1 or -1")

    self:_refresh_content_bounds()

    self.direction = dir
    self.speed = 0.5
    self.state = "playing"
    self.transport_mode = "shuttle"
    self._last_committed_frame = math.floor(self:get_position())
    self._last_tick_frame = math.floor(self:get_position())

    qt_constants.EMP.SET_DECODE_MODE("play")
    self:_try_audio("_configure_and_start_audio")
    self:_schedule_tick()
end

--- Play forward at 1x speed (spacebar).
function PlaybackEngine:play()
    if self.state == "playing" then return end

    self:_refresh_content_bounds()

    self.direction = 1
    self.speed = 1
    self.state = "playing"
    self.transport_mode = "play"
    self._last_committed_frame = math.floor(self:get_position())
    self._last_tick_frame = math.floor(self:get_position())
    self:_clear_latch()

    qt_constants.EMP.SET_DECODE_MODE("play")
    self:_try_audio("_configure_and_start_audio")
    self:_schedule_tick()
end

--- Stop playback.
function PlaybackEngine:stop()
    self.state = "stopped"
    self.direction = 0
    self.speed = 1
    self.transport_mode = "none"
    self._last_committed_frame = nil
    self._tick_generation = self._tick_generation + 1
    self._last_tick_frame = nil
    self._last_audio_frame = nil
    self:_clear_latch()

    self:_stop_audio()
    -- TMB stays alive across stop/play — no need to re-create
    qt_constants.EMP.SET_DECODE_MODE("park")
end

--- Seek to specific frame.
function PlaybackEngine:seek(frame_idx)
    assert(frame_idx, "PlaybackEngine:seek: frame_idx is nil")
    assert(frame_idx >= 0, "PlaybackEngine:seek: frame_idx must be >= 0")
    assert(self.sequence, "PlaybackEngine:seek: no sequence loaded")
    assert(self.fps_num and self.fps_den,
        "PlaybackEngine:seek: fps not set (call load_sequence first)")

    local frame = math.floor(frame_idx)

    -- Skip redundant decode when parked
    if self.state ~= "playing" and frame == self._last_committed_frame then
        return
    end

    self:_clear_latch()
    self:set_position_silent(frame)
    self._last_committed_frame = frame
    self._last_tick_frame = frame
    self._last_audio_frame = nil

    local was_playing = (self.state == "playing")
    if was_playing then
        self:_stop_audio()
    end

    -- Feed TMB clips for seek position + display via Renderer
    if self._tmb then
        self:_send_clips_to_tmb(frame)
    end
    self:_display_frame(frame)

    -- Audio resolve + restart/scrub (non-fatal: must not prevent seek)
    self:_try_audio(function(eng)
        eng:_if_clip_changed_update_audio_mix(frame)
        if was_playing then
            eng:_start_audio()
        else
            local time_us = helpers.calc_time_us_from_frame(
                frame, eng.fps_num, eng.fps_den)
            if audio_playback and audio_playback.is_ready() then
                audio_playback.seek(time_us)
            end
        end
    end)
end

--- Seek to frame (convenience wrapper with type assertion).
function PlaybackEngine:seek_to_frame(frame)
    assert(type(frame) == "number",
        "PlaybackEngine:seek_to_frame: frame must be number")
    assert(self.fps_num and self.fps_den,
        "PlaybackEngine:seek_to_frame: fps not set")
    self:seek(math.floor(frame))
end

function PlaybackEngine:is_playing()
    return self.state == "playing"
end

function PlaybackEngine:has_source()
    return self.total_frames > 0 and self.fps_num and self.fps_num > 0
end

function PlaybackEngine:get_status()
    if self.state == "stopped" then return "stopped" end
    local dir_str = self.direction == 1 and ">" or "<"
    return string.format("%s %.1fx", dir_str, self.speed)
end

--- Calculate frame from microseconds (delegates to helpers).
function PlaybackEngine:calc_frame_from_time_us(t_us)
    assert(self.fps_num and self.fps_den,
        "PlaybackEngine:calc_frame_from_time_us: fps not set")
    return helpers.calc_frame_from_time_us(t_us, self.fps_num, self.fps_den)
end

--------------------------------------------------------------------------------
-- Audio Ownership
--------------------------------------------------------------------------------

--- Claim audio output for this engine instance.
-- Updates max_media_time_us on the shared audio device (each engine has
-- different content length) and clears stale clip ID cache to force
-- a fresh resolve (the shared device may have another engine's sources).
function PlaybackEngine:activate_audio()
    self._audio_owner = true
    self.current_audio_clip_ids = {}
    if self.sequence and self.fps_num then
        if audio_playback and audio_playback.session_initialized then
            audio_playback.set_max_time(self.max_media_time_us)
        end
        self:_if_clip_changed_update_audio_mix(math.floor(self._position))
    end
end

--- Release audio output.
function PlaybackEngine:deactivate_audio()
    self._audio_owner = false
    self:_stop_audio()
end

--- Shutdown audio session entirely (app exit or project switch).
function PlaybackEngine.shutdown_audio_session()
    if audio_playback and audio_playback.session_initialized then
        audio_playback.shutdown_session()
        audio_playback = nil
    end
end

--- Destroy engine: close TMB + stop audio.
function PlaybackEngine:destroy()
    self:stop()
    self:_close_tmb()
end

--------------------------------------------------------------------------------
-- Unified Tick
--
-- Single algorithm for all sequence kinds. Combines:
-- - source_playback boundary-latch logic (shuttle latches at ends)
-- - timeline_playback audio-following + stuckness detection
-- - Renderer for video display (no mode branching)
-- - Mixer for audio resolution (no mode branching)
--------------------------------------------------------------------------------

function PlaybackEngine:_tick()
    if self.state ~= "playing" then return end
    assert(self.sequence,
        "PlaybackEngine:_tick: no sequence loaded")
    assert(self.fps_num and self.fps_num > 0
       and self.fps_den and self.fps_den > 0,
        "PlaybackEngine:_tick: fps must be set and positive")

    -- 1. Latched: keep displaying boundary frame, keep ticking
    if self.latched then
        self:_display_frame(math.floor(self._position))
        self:_schedule_tick()
        return
    end

    -- 2. Frame advancement with audio-following and stuckness detection
    local pos, audio_frame = self:_advance_position()

    -- Update audio tracker (only when audio was driving, not stuck).
    -- Keeping this separate from _last_tick_frame prevents oscillation:
    -- frame-based advance changes _last_tick_frame but must NOT reset
    -- the audio stuckness tracker.
    if audio_frame ~= nil then
        self._last_audio_frame = audio_frame
    end

    -- 3. Clamp to valid range
    pos = math.max(0, math.min(pos, self.total_frames - 1))

    -- 4. Boundary detection
    local hit_start = (self.direction < 0 and pos <= 0)
    local hit_end = (self.direction > 0 and pos >= self.total_frames - 1)

    if hit_start or hit_end then
        local boundary_frame = hit_start and 0 or (self.total_frames - 1)

        if self.transport_mode == "shuttle" then
            -- Shuttle: latch at boundary, keep ticking
            self:_apply_latch(boundary_frame)
            self:set_position(boundary_frame)
            self._last_committed_frame = math.floor(boundary_frame)
            self._last_tick_frame = math.floor(boundary_frame)
            self:_schedule_tick()
        else
            -- Play: stop at boundary
            self:_display_frame(math.floor(boundary_frame))
            self:set_position(boundary_frame)
            self._last_committed_frame = math.floor(boundary_frame)
            self._last_tick_frame = math.floor(boundary_frame)
            self:stop()
        end
        return
    end

    -- 5. Pre-buffer hint + clip feed + decode via TMB
    local frame_idx = math.floor(pos)

    if self._tmb and self.direction ~= 0 then
        qt_constants.EMP.TMB_SET_PLAYHEAD(
            self._tmb, frame_idx, self.direction, self.speed)
    end
    if self._tmb then
        self:_send_clips_to_tmb(frame_idx)
    end

    self:_display_frame(frame_idx)

    -- 6-7. Audio resolve + gap-entry start (non-fatal: must not kill video tick loop)
    if self._audio_owner then
        self:_try_audio(function(eng)
            if frame_idx ~= eng._last_tick_frame then
                eng:_if_clip_changed_update_audio_mix(frame_idx)
            end
            if audio_playback and audio_playback.has_audio and not audio_playback.playing then
                eng:_start_audio()
            end
        end)
    end

    -- 8. Commit position
    self:set_position(pos)
    self._last_committed_frame = math.floor(pos)
    self._last_tick_frame = frame_idx

    self:_schedule_tick()
end

--- Advance position: audio-following with stuckness detection.
-- @return new_pos, audio_frame_or_nil
--   audio_frame is non-nil only when audio is actively driving (for tracker).
function PlaybackEngine:_advance_position()
    local audio_can_drive = self._audio_owner
        and audio_playback and audio_playback.is_ready()
        and audio_playback.playing and audio_playback.has_audio

    if audio_can_drive then
        local audio_time_us = audio_playback.get_time_us()
        local audio_frame = helpers.calc_frame_from_time_us(
            audio_time_us, self.fps_num, self.fps_den)

        if self._last_audio_frame ~= nil
           and audio_frame == self._last_audio_frame then
            -- Audio stuck (J-cut, gap, exhaustion): frame-based advance
            return self._position + (self.direction * self.speed), nil
        else
            -- Audio advancing: video follows audio time
            return audio_frame, audio_frame
        end
    else
        -- No audio: frame-based advance
        return self._position + (self.direction * self.speed), nil
    end
end

--- Display frame via Renderer (TMB path). Handles clip switch and gap detection.
function PlaybackEngine:_display_frame(frame_idx)
    assert(self.sequence,
        "PlaybackEngine:_display_frame: no sequence loaded")
    assert(self._tmb,
        "PlaybackEngine:_display_frame: no TMB")

    local frame_handle, metadata = Renderer.get_video_frame(
        self._tmb, self._video_track_indices, frame_idx)

    if frame_handle then
        assert(metadata, string.format(
            "PlaybackEngine:_display_frame: Renderer returned frame but nil metadata at frame %d",
            frame_idx))

        local is_offline = metadata.offline

        -- Detect clip switch -> rotation callback
        if metadata.clip_id ~= self.current_clip_id then
            self.current_clip_id = metadata.clip_id
            -- Offline frames are upright (composed at 0 degrees)
            self._on_set_rotation(is_offline and 0 or metadata.rotation)
        end

        self._on_show_frame(frame_handle, metadata)
    else
        -- Gap at playhead
        self._on_show_gap()
        self.current_clip_id = nil
    end
end

--------------------------------------------------------------------------------
-- Audio Helpers
--------------------------------------------------------------------------------

--- Non-fatal audio call: logs error but does not crash video playback.
-- @param fn_or_name  string method name on self, or function(engine)
function PlaybackEngine:_try_audio(fn_or_name)
    if not self._audio_owner then return end
    local ok, err
    if type(fn_or_name) == "string" then
        ok, err = pcall(self[fn_or_name], self)
    else
        ok, err = pcall(fn_or_name, self)
    end
    if not ok then
        logger.error("playback_engine", "audio failed: " .. tostring(err))
    end
end

--- Configure audio sources and start playback (transport start).
function PlaybackEngine:_configure_and_start_audio()
    if not self._audio_owner then return end
    self:_if_clip_changed_update_audio_mix(math.floor(self:get_position()))
    self:_start_audio()
end

--- Start audio at current position.
function PlaybackEngine:_start_audio()
    if not self._audio_owner then return end
    if not audio_playback or not audio_playback.is_ready() then return end

    local time_us = helpers.calc_time_us_from_frame(
        self:get_position(), self.fps_num, self.fps_den)
    helpers.sync_audio(audio_playback, self.direction, self.speed)
    audio_playback.seek(time_us)
    audio_playback.start()
end

function PlaybackEngine:_stop_audio()
    helpers.stop_audio(audio_playback)
end

function PlaybackEngine:_sync_audio()
    helpers.sync_audio(audio_playback, self.direction, self.speed)
end

--- Detect clip changes at frame and update audio_playback mix params.
-- Called every frame during playback. Common case (no edit boundary) returns early.
function PlaybackEngine:_if_clip_changed_update_audio_mix(frame)
    if not self._audio_owner then return end
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

--- Extract clip ID set from audio entries (for change detection).
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
        params[#params + 1] = {
            track_index = entry.track.track_index,
            volume = entry.clip.volume or 1.0,
            muted = entry.track.muted or false,
            soloed = entry.track.soloed or false,
        }
    end
    return params
end

--- Init audio session using stored sample rate (no media_cache dependency).
function PlaybackEngine:_init_audio_session()
    if not (qt_constants.SSE and qt_constants.AOP) then return end

    local audio_pb = require("core.media.audio_playback")
    if audio_pb.session_initialized then
        audio_playback = audio_pb
        return
    end

    assert(self.audio_sample_rate and self.audio_sample_rate > 0, string.format(
        "PlaybackEngine:_init_audio_session: audio_sample_rate not set (got %s)",
        tostring(self.audio_sample_rate)))

    audio_pb.init_session(self.audio_sample_rate, 2)
    audio_pb.set_max_time(self.max_media_time_us)
    audio_playback = audio_pb
    logger.info("playback_engine",
        "Init audio session: sr=" .. self.audio_sample_rate)
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
    local t_us = helpers.calc_time_us_from_frame(
        boundary_frame, self.fps_num, self.fps_den)

    if audio_playback and audio_playback.max_media_time_us then
        t_us = math.max(0, math.min(t_us, audio_playback.max_media_time_us))
    else
        t_us = math.max(0, t_us)
    end

    if audio_playback and audio_playback.is_ready()
       and audio_playback.latch then
        audio_playback.latch(t_us)
    end

    self:_display_frame(boundary_frame)

    self.latched = true
    self.latched_boundary = (boundary_frame == 0) and "start" or "end"

    logger.debug("playback_engine", string.format(
        "Latched at %s boundary (frame %d)",
        self.latched_boundary, boundary_frame))
end

function PlaybackEngine:_clear_latch()
    self.latched = false
    self.latched_boundary = nil
end

--------------------------------------------------------------------------------
-- Tick Scheduling
--------------------------------------------------------------------------------

function PlaybackEngine:_schedule_tick()
    if self.state ~= "playing" then return end
    assert(self.fps and self.fps > 0,
        "PlaybackEngine:_schedule_tick: fps not set")

    local base_interval = math.floor(1000 / self.fps)
    local interval

    if self.speed < 1 then
        interval = math.floor(base_interval / self.speed)
    else
        interval = base_interval
    end

    interval = math.max(interval, 16)  -- ~60fps cap

    local gen = self._tick_generation
    local engine = self
    qt_create_single_shot_timer(interval, function()
        if engine._tick_generation ~= gen then return end
        engine:_tick()
    end)
end

--------------------------------------------------------------------------------
-- Frame Step Audio (Jog)
--------------------------------------------------------------------------------

--- Play short audio burst for single-frame step (arrow key jog).
function PlaybackEngine:play_frame_audio(frame_idx)
    if self.state == "playing" then return end
    if not self._audio_owner then return end
    if not audio_playback then return end
    if not audio_playback.is_ready() then return end
    if not audio_playback.play_burst then return end
    assert(self.fps_num and self.fps_den,
        "PlaybackEngine:play_frame_audio: fps not set")

    -- Resolve audio sources at the stepped-to frame
    self:_if_clip_changed_update_audio_mix(frame_idx)

    local time_us = helpers.calc_time_us_from_frame(
        frame_idx, self.fps_num, self.fps_den)
    local frame_duration_us = helpers.calc_time_us_from_frame(
        1, self.fps_num, self.fps_den)
    -- 1.5x frame duration, clamped to [40ms, 60ms]
    local burst_us = math.max(40000, math.min(60000,
        math.floor(frame_duration_us * 1.5)))
    audio_playback.play_burst(time_us, burst_us)
end

--------------------------------------------------------------------------------
-- Project change: tear down audio session (prevents stale sources from
-- previous project being used after media_cache clears its pool).
--------------------------------------------------------------------------------
local Signals = require("core.signals")
Signals.connect("project_changed", PlaybackEngine.shutdown_audio_session, 5)

return PlaybackEngine
