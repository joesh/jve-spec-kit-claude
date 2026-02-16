--- PlaybackEngine: instantiable playback controller for any sequence kind.
--
-- Replaces the singleton playback_controller. Each SequenceMonitor owns one instance.
--
-- Key design: NO sequence-kind branching. Masterclips and timelines use
-- identical code paths via Renderer (video) and Mixer (audio).
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
local media_cache = require("core.media.media_cache")
local Renderer = require("core.renderer")
local Mixer = require("core.mixer")
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
--   media_context_id  string   media_cache context for this view
--   on_show_frame     function(frame_handle, metadata)
--   on_show_gap       function()
--   on_set_rotation   function(degrees)
--   on_position_changed function(frame)
function PlaybackEngine.new(config)
    assert(type(config) == "table",
        "PlaybackEngine.new: config must be a table")
    assert(config.media_context_id,
        "PlaybackEngine.new: media_context_id required")
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
    self.media_context_id = config.media_context_id
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

    -- Lookahead pre-buffer state
    self._video_clip_bounds = nil       -- {start_frame, end_frame} from metadata
    self._pre_buffered_video_id = nil   -- clip_id of pre-buffered video clip
    self._pre_buffered_audio_ids = {}   -- {[clip_id] = true}
    self._current_audio_sources = nil   -- sources from last _resolve_and_set_audio

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

    -- Clear lookahead state (stale across stop/start cycles)
    self._current_audio_sources = nil
    self._pre_buffered_video_id = nil
    self._pre_buffered_audio_ids = {}

    self:_stop_audio()
    media_cache.stop_all_prefetch()
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

    -- Display via Renderer
    self:_display_frame(frame)

    -- Audio resolve + restart/scrub (non-fatal: must not prevent seek)
    self:_try_audio(function(eng)
        eng:_resolve_and_set_audio(frame)
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
        self:_resolve_and_set_audio(math.floor(self._position))
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

    -- 5. Display via Renderer
    local frame_idx = math.floor(pos)
    self:_display_frame(frame_idx)

    -- 6-7. Audio resolve + gap-entry start (non-fatal: must not kill video tick loop)
    if self._audio_owner then
        self:_try_audio(function(eng)
            if frame_idx ~= eng._last_tick_frame then
                eng:_resolve_and_set_audio(frame_idx)
            end
            if audio_playback and audio_playback.has_audio and not audio_playback.playing then
                eng:_start_audio()
            end
        end)
    end

    -- 8. Lookahead: pre-buffer next/prev clip near edit points
    self:_check_lookahead(frame_idx)

    -- 9. Commit position
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

--- Display frame via Renderer. Handles clip switch and gap detection.
function PlaybackEngine:_display_frame(frame_idx)
    assert(self.sequence,
        "PlaybackEngine:_display_frame: no sequence loaded")

    local frame_handle, metadata = Renderer.get_video_frame(
        self.sequence, frame_idx, self.media_context_id)

    if frame_handle then
        assert(metadata, string.format(
            "PlaybackEngine:_display_frame: Renderer returned frame but nil metadata at frame %d",
            frame_idx))
        -- Detect clip switch → rotation callback + reset lookahead
        if metadata.clip_id ~= self.current_clip_id then
            self.current_clip_id = metadata.clip_id
            self._on_set_rotation(metadata.rotation)
            -- Entering new clip: clear pre-buffer state from previous clip
            self._pre_buffered_video_id = nil
            self._pre_buffered_audio_ids = {}
        end

        -- Store clip bounds for lookahead (always, not just on clip switch)
        if metadata.clip_end_frame then
            self._video_clip_bounds = {
                start_frame = metadata.clip_start_frame,
                end_frame = metadata.clip_end_frame,
            }
        end

        self._on_show_frame(frame_handle, metadata)

        -- Notify prefetch of source-space position (use clip's rate for timestamp accuracy)
        if self.direction ~= 0 then
            media_cache.set_playhead(
                metadata.source_frame, self.direction, self.speed,
                self.media_context_id,
                metadata.clip_fps_num, metadata.clip_fps_den)
        end
    else
        -- Gap at playhead
        self._on_show_gap()
        self.current_clip_id = nil
    end
end

--------------------------------------------------------------------------------
-- Lookahead Pre-Buffer
--
-- Detects when playback approaches a clip boundary and pre-buffers the
-- next (or prev) clip's data. Video threshold: 1 second. Audio: 2 seconds.
-- Each clip is pre-buffered at most once (tracked by clip_id).
--------------------------------------------------------------------------------

--- Check proximity to clip boundaries and pre-buffer next/prev clip.
-- Called from _tick() after display and audio resolve.
-- @param frame_idx integer: current display frame
function PlaybackEngine:_check_lookahead(frame_idx)
    if not self.sequence then return end
    if self.direction == 0 then return end

    if self.direction > 0 then
        self:_lookahead_video_forward(frame_idx)
        self:_lookahead_audio_forward(frame_idx)
    else
        self:_lookahead_video_reverse(frame_idx)
        self:_lookahead_audio_reverse(frame_idx)
    end
end

--- Video lookahead (forward): pre-buffer when within 1 second of clip_end.
function PlaybackEngine:_lookahead_video_forward(frame_idx)
    if not self._video_clip_bounds then return end

    local threshold_frames = math.ceil(self.fps) -- 1 second
    local distance = self._video_clip_bounds.end_frame - frame_idx
    if distance > threshold_frames or distance <= 0 then return end

    -- Resolve next video clip at the boundary
    local entries = self.sequence:get_next_video(self._video_clip_bounds.end_frame)
    if #entries == 0 then return end

    local entry = entries[1]
    if self._pre_buffered_video_id == entry.clip.id then return end -- already done

    media_cache.pre_buffer(
        entry.media_path, entry.source_frame,
        entry.clip.rate.fps_numerator, entry.clip.rate.fps_denominator)
    self._pre_buffered_video_id = entry.clip.id

    logger.debug("playback_engine", string.format(
        "Video lookahead: pre-buffered '%s' at frame %d (boundary in %d frames)",
        entry.media_path, entry.source_frame, distance))
end

--- Video lookahead (reverse): pre-buffer when within 1 second of clip_start.
function PlaybackEngine:_lookahead_video_reverse(frame_idx)
    if not self._video_clip_bounds then return end

    local threshold_frames = math.ceil(self.fps)
    local distance = frame_idx - self._video_clip_bounds.start_frame
    if distance > threshold_frames or distance <= 0 then return end

    local entries = self.sequence:get_prev_video(self._video_clip_bounds.start_frame)
    if #entries == 0 then return end

    local entry = entries[1]
    if self._pre_buffered_video_id == entry.clip.id then return end

    media_cache.pre_buffer(
        entry.media_path, entry.source_frame,
        entry.clip.rate.fps_numerator, entry.clip.rate.fps_denominator)
    self._pre_buffered_video_id = entry.clip.id

    logger.debug("playback_engine", string.format(
        "Video lookahead (rev): pre-buffered '%s' at frame %d (boundary in %d frames)",
        entry.media_path, entry.source_frame, distance))
end

--- Audio lookahead (forward): pre-buffer when within 2 seconds of clip_end_us.
function PlaybackEngine:_lookahead_audio_forward(frame_idx)
    if not self._audio_owner then return end
    if not audio_playback then return end
    if not self._current_audio_sources or #self._current_audio_sources == 0 then return end

    local threshold_us = 2000000 -- 2 seconds
    local current_time_us = helpers.calc_time_us_from_frame(
        frame_idx, self.fps_num, self.fps_den)

    for _, src in ipairs(self._current_audio_sources) do
        if not src.clip_end_us then goto continue end

        local distance_us = src.clip_end_us - current_time_us
        if distance_us > threshold_us or distance_us <= 0 then goto continue end

        -- Already pre-buffered this audio clip?
        local src_id = src.clip_id or src.path
        if self._pre_buffered_audio_ids[src_id] then goto continue end

        -- Resolve next audio clip at the boundary frame.
        -- Round (not floor) to avoid losing the boundary due to us→frame truncation.
        -- Example: 100 frames @ 24fps → 4166666us → floor(99.999) = 99 (wrong).
        local boundary_frame = math.floor(
            src.clip_end_us * self.fps_num / (1000000 * self.fps_den) + 0.5)
        local entries = self.sequence:get_next_audio(boundary_frame)
        if #entries == 0 then goto continue end

        -- Build source for pre-buffer from resolved entry
        local entry = entries[1]
        assert(entry.source_time_us,
            "playback_engine._lookahead_audio_forward: entry missing source_time_us")

        local clip_start_us = helpers.calc_time_us_from_frame(
            entry.clip.timeline_start, self.fps_num, self.fps_den)
        local clip_end_us = helpers.calc_time_us_from_frame(
            entry.clip.timeline_start + entry.clip.duration, self.fps_num, self.fps_den)

        -- Compute conform speed_ratio (same logic as mixer.resolve_audio_sources)
        local media_video_fps = entry.media_fps_num and entry.media_fps_den
            and (entry.media_fps_num / entry.media_fps_den) or nil
        local seq_fps = self.fps_num / self.fps_den
        local pre_speed_ratio = 1.0
        if media_video_fps and media_video_fps < 1000
           and math.abs(media_video_fps - seq_fps) > 0.01 then
            pre_speed_ratio = seq_fps / media_video_fps
        end

        local pre_source = {
            path = entry.media_path,
            clip_start_us = clip_start_us,
            clip_end_us = clip_end_us,
            seek_us = entry.source_time_us,
            speed_ratio = pre_speed_ratio,
            volume = 1.0, -- Pre-buffer uses unity; real volume applied at playback
        }
        audio_playback.pre_buffer(pre_source, media_cache)
        self._pre_buffered_audio_ids[src_id] = true

        logger.debug("playback_engine", string.format(
            "Audio lookahead: pre-buffered '%s' (%.3fs from boundary)",
            entry.media_path, distance_us / 1000000))

        ::continue::
    end
end

--- Audio lookahead (reverse): pre-buffer when within 2 seconds of clip_start_us.
function PlaybackEngine:_lookahead_audio_reverse(frame_idx)
    if not self._audio_owner then return end
    if not audio_playback then return end
    if not self._current_audio_sources or #self._current_audio_sources == 0 then return end

    local threshold_us = 2000000
    local current_time_us = helpers.calc_time_us_from_frame(
        frame_idx, self.fps_num, self.fps_den)

    for _, src in ipairs(self._current_audio_sources) do
        if not src.clip_start_us then goto continue end

        local distance_us = current_time_us - src.clip_start_us
        if distance_us > threshold_us or distance_us <= 0 then goto continue end

        local src_id = src.clip_id or src.path
        if self._pre_buffered_audio_ids[src_id] then goto continue end

        local boundary_frame = math.floor(
            src.clip_start_us * self.fps_num / (1000000 * self.fps_den) + 0.5)
        local entries = self.sequence:get_prev_audio(boundary_frame)
        if #entries == 0 then goto continue end

        local entry = entries[1]
        assert(entry.source_time_us,
            "playback_engine._lookahead_audio_reverse: entry missing source_time_us")

        local clip_start_us = helpers.calc_time_us_from_frame(
            entry.clip.timeline_start, self.fps_num, self.fps_den)
        local clip_end_us = helpers.calc_time_us_from_frame(
            entry.clip.timeline_start + entry.clip.duration, self.fps_num, self.fps_den)

        -- Compute conform speed_ratio (same logic as mixer.resolve_audio_sources)
        local media_video_fps = entry.media_fps_num and entry.media_fps_den
            and (entry.media_fps_num / entry.media_fps_den) or nil
        local seq_fps = self.fps_num / self.fps_den
        local pre_speed_ratio = 1.0
        if media_video_fps and media_video_fps < 1000
           and math.abs(media_video_fps - seq_fps) > 0.01 then
            pre_speed_ratio = seq_fps / media_video_fps
        end

        local pre_source = {
            path = entry.media_path,
            clip_start_us = clip_start_us,
            clip_end_us = clip_end_us,
            seek_us = entry.source_time_us,
            speed_ratio = pre_speed_ratio,
            volume = 1.0, -- Pre-buffer uses unity; real volume applied at playback
        }
        audio_playback.pre_buffer(pre_source, media_cache)
        self._pre_buffered_audio_ids[src_id] = true

        logger.debug("playback_engine", string.format(
            "Audio lookahead (rev): pre-buffered '%s' (%.3fs from boundary)",
            entry.media_path, distance_us / 1000000))

        ::continue::
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
    self:_resolve_and_set_audio(math.floor(self:get_position()))
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

--- Resolve audio clips at frame via Mixer and update audio_playback if changed.
function PlaybackEngine:_resolve_and_set_audio(frame)
    if not self._audio_owner then return end
    assert(self.sequence,
        "PlaybackEngine:_resolve_and_set_audio: no sequence loaded")

    local sources, clip_ids = Mixer.resolve_audio_sources(
        self.sequence, frame, self.fps_num, self.fps_den, media_cache)
    assert(type(sources) == "table", string.format(
        "PlaybackEngine:_resolve_and_set_audio: Mixer returned non-table sources at frame %d",
        frame))
    assert(type(clip_ids) == "table", string.format(
        "PlaybackEngine:_resolve_and_set_audio: Mixer returned non-table clip_ids at frame %d",
        frame))

    -- Always store for lookahead (even if clips unchanged)
    self._current_audio_sources = sources

    -- Change detection: compare clip ID sets
    if not self:_audio_clips_changed(clip_ids) then return end

    -- Lazy-init audio session from first source
    if #sources > 0
       and not (audio_playback and audio_playback.session_initialized) then
        self:_try_init_audio_session(sources[1].path)
    end

    if audio_playback and audio_playback.session_initialized then
        self.current_audio_clip_ids = clip_ids
        local restart_time_us = helpers.calc_time_us_from_frame(
            frame, self.fps_num, self.fps_den)
        audio_playback.set_audio_sources(sources, media_cache, restart_time_us)
    end
end

--- Lazy-init audio session using sample rate from media file.
function PlaybackEngine:_try_init_audio_session(media_path)
    if not (qt_constants.SSE and qt_constants.AOP) then return end

    local audio_pb = require("core.media.audio_playback")
    if audio_pb.session_initialized then
        audio_playback = audio_pb
        return
    end

    -- Path was already pooled by Mixer.resolve_audio_sources — nil here is a bug
    local info = media_cache.ensure_audio_pooled(media_path)
    assert(info, string.format(
        "PlaybackEngine:_try_init_audio_session: ensure_audio_pooled returned nil for '%s' "
        .. "(path was already resolved by Mixer)", media_path))
    assert(info.has_audio, string.format(
        "PlaybackEngine:_try_init_audio_session: '%s' has no audio "
        .. "(should not have been in Mixer source list)", media_path))

    audio_pb.init_session(info.audio_sample_rate, 2)
    audio_pb.set_max_time(self.max_media_time_us)
    audio_playback = audio_pb
    logger.info("playback_engine",
        "Lazy-init audio session for " .. media_path)
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
    self:_resolve_and_set_audio(frame_idx)

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
