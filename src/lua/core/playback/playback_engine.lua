--- PlaybackEngine: instantiable playback controller for any sequence kind.
--
-- Replaces the singleton playback_controller. Each SequenceMonitor owns one instance.
--
-- Key design: NO sequence-kind branching. Masterclips and timelines use
-- identical code paths via Renderer (video) and TMB (audio).
--
-- Video path uses TimelineMediaBuffer (TMB) — a C++ class that owns readers,
-- caches frames, and pre-buffers at clip boundaries. C++ PlaybackController
-- owns the prefetch algorithm; Lua provides clips via _provide_clips() callback.
--
-- Position advancement and frame display are driven entirely by C++
-- PlaybackController (CVDisplayLink tick). Lua owns transport state machine,
-- boundary latch logic, audio mix resolution, and clip window feeding.
--
-- Audio coordination: only one PlaybackEngine "owns" audio at a time.
-- activate_audio() / deactivate_audio() manage ownership.
--
-- Callbacks (set at construction):
--   on_show_frame(frame_handle, metadata)  — display decoded video frame
--   on_show_gap()                          — display black/gap
--   on_set_rotation(degrees)               — apply rotation for media
--   on_set_par(num, den)                   — apply pixel aspect ratio
--   on_position_changed(frame)             — position update notification
--
-- @file playback_engine.lua

local log = require("core.logger").for_area("ticks")
local qt_constants = require("core.qt_constants")
local Renderer = require("core.renderer")
local Sequence = require("models.sequence")
local helpers = require("core.playback.playback_helpers")
local Signals = require("core.signals")

local PlaybackEngine = {}
PlaybackEngine.__index = PlaybackEngine

-- Class-level audio playback reference (singleton audio device)
local audio_playback = nil

--- Set class-level audio module reference.
-- @param ap audio_playback module
function PlaybackEngine.init_audio(ap)
    audio_playback = ap
    log.event("Audio module initialized")
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
--   on_set_par        function(num, den)
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
    assert(type(config.on_set_par) == "function",
        "PlaybackEngine.new: on_set_par callback required")
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
    self._on_set_par = config.on_set_par
    self._on_position_changed = config.on_position_changed

    -- Seek dedup
    self._last_committed_frame = nil

    -- Audio ownership (only one engine owns audio at a time)
    self._audio_owner = false

    -- TMB (TimelineMediaBuffer) — owns video readers, cache, pre-buffer
    self._tmb = nil
    self._video_track_indices = {}   -- track indices for Renderer iteration
    self._audio_track_indices = {}   -- audio track indices for TMB audio path
    -- PlaybackController (C++ CVDisplayLink-driven playback)
    self._playback_controller = nil
    self._video_surface = nil

    return self
end

--------------------------------------------------------------------------------
-- Surface Setup (called after widget creation)
--------------------------------------------------------------------------------

--- Set video surface for C++ PlaybackController.
-- Must be called after the video surface widget is created.
-- @param surface userdata GPUVideoSurface widget
function PlaybackEngine:set_surface(surface)
    assert(surface, "PlaybackEngine:set_surface: surface is nil")
    self._video_surface = surface
    if self._playback_controller then
        qt_constants.PLAYBACK.SET_SURFACE(self._playback_controller, surface)
    end
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
    self.audio_sample_rate = info.audio_sample_rate
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

    -- PlaybackController setup.
    -- Track indices populated from DB. Clips loaded by first seek() via
    -- Park() → prefetchClips() → _provide_clips().
    self:_setup_playback_controller()
    self._video_track_indices = self.sequence:get_track_indices("VIDEO")
    self._audio_track_indices = self.sequence:get_track_indices("AUDIO")

    -- NOTE: No seek here. Caller (SequenceMonitor) is responsible for initial
    -- positioning via saved_playhead from DB. Hardcoding seek(0) is wrong when
    -- content starts at frame N (e.g., DRP imports with gaps before first clip).

    log.event("Loaded sequence %s (%s): %d frames @ %d/%d fps",
        sequence_id:sub(1, 8), info.kind,
        self.total_frames, self.fps_num, self.fps_den)
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

    log.event("Refreshed content bounds: %d frames, max_time=%.3fs",
        self.total_frames, self.max_media_time_us / 1000000)
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

--- Public: invalidate clip cache + re-feed TMB after timeline edits.
-- Called by views (sequence_monitor) on content_changed — encapsulates all
-- internal cache invalidation so views never touch engine privates.
function PlaybackEngine:notify_content_changed()
    self:_refresh_content_bounds()
    if self._playback_controller then
        qt_constants.PLAYBACK.RELOAD_ALL_CLIPS(self._playback_controller)
        self._video_track_indices = self.sequence:get_track_indices("VIDEO")
        self._audio_track_indices = self.sequence:get_track_indices("AUDIO")
    end
end

--------------------------------------------------------------------------------
-- PlaybackController Setup
--------------------------------------------------------------------------------

--- Create and configure C++ PlaybackController for CVDisplayLink-driven playback.
function PlaybackEngine:_setup_playback_controller()
    local PLAYBACK = qt_constants.PLAYBACK
    assert(PLAYBACK, "PlaybackEngine:_setup_playback_controller: PLAYBACK bindings required")

    -- Close previous controller if any
    if self._playback_controller then
        PLAYBACK.CLOSE(self._playback_controller)
        self._playback_controller = nil
    end

    -- Create new controller
    local pc = PLAYBACK.CREATE()
    assert(pc, "PlaybackEngine:_setup_playback_controller: CREATE returned nil")
    self._playback_controller = pc

    -- Configure: TMB, bounds
    PLAYBACK.SET_TMB(pc, self._tmb)
    PLAYBACK.SET_BOUNDS(pc, self.total_frames, self.fps_num, self.fps_den)

    -- Wire surface if already set
    if self._video_surface then
        PLAYBACK.SET_SURFACE(pc, self._video_surface)
    end

    -- Wire clip provider: C++ calls when prefetch frontier advances.
    -- Lua queries DB for clips in [from, to), adds to TMB via TMB_ADD_CLIPS.
    local engine = self
    PLAYBACK.SET_CLIP_PROVIDER(pc, function(from, to, track_type)
        engine:_provide_clips(from, to, track_type)
    end)

    -- Wire PositionCallback: C++ fires coalesced position updates for UI
    PLAYBACK.SET_POSITION_CALLBACK(pc, function(frame, stopped)
        engine:_on_controller_position(frame, stopped)
    end)

    -- Wire ClipTransitionCallback: C++ fires when displayed clip changes
    PLAYBACK.SET_CLIP_TRANSITION_CALLBACK(pc, function(clip_id, rotation, par_num, par_den, is_offline, media_path, frame)
        engine:_on_clip_transition(clip_id, rotation, par_num, par_den, is_offline, media_path, frame)
    end)

    -- Wire content_changed: invalidate clip windows when timeline edits occur.
    -- This ensures C++ re-queries clip data after insert/delete/ripple commands.
    if self._content_changed_conn then
        Signals.disconnect(self._content_changed_conn)
    end
    self._content_changed_conn = Signals.connect("content_changed", function(seq_id)
        if seq_id == engine.sequence_id then
            engine:notify_content_changed()
            log.event("Edit detected: invalidated clip windows")
        end
    end)

    log.event("PlaybackController created and configured")
end

--- Clip provider callback: C++ requests clips for a range.
-- Queries DB for clips in [from, to), converts to TMB format, adds via TMB_ADD_CLIPS.
function PlaybackEngine:_provide_clips(from, to, track_type)
    assert(type(from) == "number", string.format(
        "PlaybackEngine:_provide_clips: from must be number, got %s", type(from)))
    assert(type(to) == "number", string.format(
        "PlaybackEngine:_provide_clips: to must be number, got %s", type(to)))
    assert(track_type == "video" or track_type == "audio", string.format(
        "PlaybackEngine:_provide_clips: track_type must be 'video' or 'audio', got %s",
        tostring(track_type)))

    local entries
    if track_type == "video" then
        entries = self.sequence:get_video_in_range(from, to)
    else
        entries = self.sequence:get_audio_in_range(from, to)
    end

    local EMP = qt_constants.EMP
    for _, entry in ipairs(entries) do
        local speed = (track_type == "video")
            and self:_compute_video_speed_ratio(entry)
            or self:_compute_audio_speed_ratio(entry)
        local clip = self:_build_tmb_clip(entry, speed)
        local track_idx = entry.track.track_index
        EMP.TMB_ADD_CLIPS(self._tmb, track_type, track_idx, {clip})

        -- Track indices: ensure this track is known
        if track_type == "video" then
            local found = false
            for _, idx in ipairs(self._video_track_indices) do
                if idx == track_idx then found = true; break end
            end
            if not found then
                self._video_track_indices[#self._video_track_indices + 1] = track_idx
                table.sort(self._video_track_indices, function(a, b) return a > b end)
            end
        else
            local found = false
            for _, idx in ipairs(self._audio_track_indices) do
                if idx == track_idx then found = true; break end
            end
            if not found then
                self._audio_track_indices[#self._audio_track_indices + 1] = track_idx
                table.sort(self._audio_track_indices)
            end
        end
    end
end

--- Position callback from C++: update UI playhead.
-- Callbacks arrive via dispatch_async (GCD main queue). After engine:stop()
-- sets state="stopped", stale coalesced callbacks from the old play session
-- may still be queued. Filter them: stopped=false + state="stopped" = stale.
function PlaybackEngine:_on_controller_position(frame, stopped)
    assert(type(frame) == "number", string.format(
        "PlaybackEngine:_on_controller_position: frame must be number, got %s", type(frame)))
    assert(type(stopped) == "boolean", string.format(
        "PlaybackEngine:_on_controller_position: stopped must be boolean, got %s", type(stopped)))

    -- Stale callback from previous play session: dispatched before Stop()
    -- but delivered after engine:stop() set state="stopped". Ignore.
    if not stopped and self.state == "stopped" then
        log.detail("_on_controller_position: stale callback frame=%d (stopped=false, state=stopped) — ignored",
            frame)
        return
    end

    self._position = frame
    self._on_position_changed(frame)

    if stopped then
        self.state = "stopped"
        self.direction = 0
        self:_stop_audio()
    elseif self.transport_mode == "shuttle" and not self.latched then
        -- Boundary latch detection (migrated from deleted Lua _tick)
        local hit_start = (self.direction < 0 and frame <= 0)
        local hit_end = (self.direction > 0 and frame >= self.total_frames - 1)
        if hit_start or hit_end then
            self:_apply_latch(frame)
        end
    end
end

--- Clip transition callback from C++: update rotation/PAR.
--- Apply rotation and PAR from metadata to the view.
-- Offline frames are upright with square pixels; online use media metadata.
function PlaybackEngine:_apply_rotation_par(metadata)
    assert(type(metadata.offline) == "boolean",
        "PlaybackEngine:_apply_rotation_par: metadata.offline must be boolean")
    assert(type(metadata.rotation) == "number",
        "PlaybackEngine:_apply_rotation_par: metadata.rotation required")
    assert(type(metadata.par_num) == "number" and metadata.par_num >= 1,
        "PlaybackEngine:_apply_rotation_par: metadata.par_num must be >= 1")
    assert(type(metadata.par_den) == "number" and metadata.par_den >= 1,
        "PlaybackEngine:_apply_rotation_par: metadata.par_den must be >= 1")

    local is_offline = metadata.offline
    self._on_set_rotation(is_offline and 0 or metadata.rotation)
    self._on_set_par(
        is_offline and 1 or metadata.par_num,
        is_offline and 1 or metadata.par_den)
end

--- Callback from C++ deliverFrame: fires during playback when the displayed
-- clip changes. During playback, online frames are pushed directly by C++
-- (surface.setFrame). For offline clips, we pull through Renderer so that
-- offline_frame_cache composes the "Media Offline" / "Codec Unavailable" frame.
--
-- @param frame int64 — the exact timeline frame from C++ deliverFrame. Using this
--   instead of self._position avoids the stale-position bug: self._position is
--   updated via coalesced reports (~4Hz), so at the transition moment it still
--   points to the PREVIOUS clip → TMB returns that clip's frame → freeze.
function PlaybackEngine:_on_clip_transition(clip_id, rotation, par_num, par_den, is_offline, media_path, frame)
    assert(type(clip_id) == "string", string.format(
        "PlaybackEngine:_on_clip_transition: clip_id must be string, got %s", type(clip_id)))
    assert(type(rotation) == "number", string.format(
        "PlaybackEngine:_on_clip_transition: rotation must be number, got %s", type(rotation)))
    assert(type(par_num) == "number" and par_num >= 1, string.format(
        "PlaybackEngine:_on_clip_transition: par_num must be >= 1, got %s", tostring(par_num)))
    assert(type(par_den) == "number" and par_den >= 1, string.format(
        "PlaybackEngine:_on_clip_transition: par_den must be >= 1, got %s", tostring(par_den)))
    assert(type(is_offline) == "boolean", string.format(
        "PlaybackEngine:_on_clip_transition: is_offline must be boolean, got %s", type(is_offline)))
    assert(type(media_path) == "string", string.format(
        "PlaybackEngine:_on_clip_transition: media_path must be string, got %s", type(media_path)))
    assert(type(frame) == "number", string.format(
        "PlaybackEngine:_on_clip_transition: frame must be number, got %s", type(frame)))
    assert(frame >= 0, string.format(
        "PlaybackEngine:_on_clip_transition: frame must be >= 0, got %d", frame))

    if clip_id ~= self.current_clip_id then
        log.event("clip_transition: clip=%s rotation=%d par=%d/%d offline=%s frame=%d",
            clip_id, rotation, par_num, par_den, tostring(is_offline), frame)
        self.current_clip_id = clip_id

        local metadata = {
            offline = is_offline,
            rotation = rotation,
            par_num = par_num,
            par_den = par_den,
            clip_id = clip_id,
            media_path = media_path,
        }
        self:_apply_rotation_par(metadata)

        -- Offline during playback: pull through Renderer at the EXACT frame
        -- from C++ deliverFrame (not self._position which may be stale)
        if is_offline then
            self:_display_frame_from_renderer(frame)
        end
    end
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

--- Compute video speed_ratio from clip's source range vs timeline duration.
-- When source_out - source_in == duration, speed is 1.0 (no change).
-- Otherwise, speed = source_range / timeline_duration (< 1.0 = slow motion).
-- @param entry table: video entry from get_video_at (has .clip with source_in/source_out/duration)
-- @return number: speed_ratio > 0
function PlaybackEngine:_compute_video_speed_ratio(entry)
    local clip = entry.clip
    assert(clip.source_out ~= nil,
        "_compute_video_speed_ratio: clip.source_out is nil (clip_id=" .. tostring(clip.id) .. ")")
    assert(clip.source_in ~= nil,
        "_compute_video_speed_ratio: clip.source_in is nil (clip_id=" .. tostring(clip.id) .. ")")
    assert(clip.duration ~= nil,
        "_compute_video_speed_ratio: clip.duration is nil (clip_id=" .. tostring(clip.id) .. ")")
    local source_range = clip.source_out - clip.source_in
    assert(source_range > 0, string.format(
        "_compute_video_speed_ratio: source_range must be positive, got %d (clip_id=%s, source_out=%d, source_in=%d)",
        source_range, tostring(clip.id), clip.source_out, clip.source_in))
    assert(clip.duration > 0, string.format(
        "_compute_video_speed_ratio: clip.duration must be positive, got %d (clip_id=%s)",
        clip.duration, tostring(clip.id)))
    local ratio = source_range / clip.duration
    assert(ratio > 0 and ratio < 100, string.format(
        "_compute_video_speed_ratio: ratio out of sane range: %.4f (clip_id=%s, source_range=%d, duration=%d)",
        ratio, tostring(clip.id), source_range, clip.duration))
    -- Near 1.0 = no speed change (avoid floating-point noise)
    if math.abs(ratio - 1.0) < 0.001 then
        return 1.0
    end
    return ratio
end

--- Compute audio conform speed_ratio: seq_fps / media_video_fps.
-- When media_video_fps >= 1000 (audio-only) or matches seq_fps, returns 1.0.
-- @param entry table: audio entry from get_audio_at (has media_fps_num/den)
-- @return number: speed_ratio > 0
function PlaybackEngine:_compute_audio_speed_ratio(entry)
    local media_fps_num = entry.media_fps_num
    local media_fps_den = entry.media_fps_den
    assert(type(media_fps_num) == "number", string.format(
        "PlaybackEngine:_compute_audio_speed_ratio: missing media_fps_num (got %s)",
        type(media_fps_num)))
    assert(type(media_fps_den) == "number" and media_fps_den > 0, string.format(
        "PlaybackEngine:_compute_audio_speed_ratio: invalid media_fps_den=%s",
        tostring(media_fps_den)))
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

    self:_refresh_content_bounds()

    self.direction = dir
    self.speed = 0.5
    self.state = "playing"
    self.transport_mode = "shuttle"
    self._last_committed_frame = math.floor(self:get_position())

    qt_constants.EMP.SET_DECODE_MODE("play")
    self:_try_audio("_configure_and_start_audio")

    -- Delegate to C++ PlaybackController
    assert(self._playback_controller,
        "PlaybackEngine:slow_play: _playback_controller required")
    local PLAYBACK = qt_constants.PLAYBACK
    PLAYBACK.SET_SHUTTLE_MODE(self._playback_controller, true)
    PLAYBACK.PLAY(self._playback_controller, dir, 0.5)
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
    self:_clear_latch()

    qt_constants.EMP.SET_DECODE_MODE("play")
    self:_try_audio("_configure_and_start_audio")

    -- Delegate to C++ PlaybackController
    assert(self._playback_controller,
        "PlaybackEngine:play: _playback_controller required")
    local PLAYBACK = qt_constants.PLAYBACK
    PLAYBACK.SET_SHUTTLE_MODE(self._playback_controller, false)
    PLAYBACK.PLAY(self._playback_controller, 1, 1.0)
end

--- Stop playback.
function PlaybackEngine:stop()
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

    self:_stop_audio()
    -- TMB stays alive across stop/play — no need to re-create
    qt_constants.EMP.SET_DECODE_MODE("park")
    -- Stop all background decode work (REFILL workers + pre-buffer jobs).
    -- Prevents zombie HW decoders from competing for GPU decode engine.
    if self._tmb then
        qt_constants.EMP.TMB_PARK_READERS(self._tmb)
    end
end

--- Seek to specific frame.
--- Pull frame from Renderer and display via View callbacks.
-- Shared by seek (park mode) and _on_clip_transition (playback offline).
-- Renderer handles online/offline/gap routing through offline_frame_cache.
function PlaybackEngine:_display_frame_from_renderer(frame)
    assert(self._tmb, "PlaybackEngine:_display_frame_from_renderer: no TMB")

    local frame_handle, metadata = Renderer.get_video_frame(
        self._tmb, self._video_track_indices, frame)

    if frame_handle then
        self:_apply_rotation_par(metadata)
        self._on_show_frame(frame_handle, metadata)
    else
        self._on_show_gap()
    end
end

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

    local was_playing = (self.state == "playing")
    if was_playing then
        self:_stop_audio()
    end

    -- Park: set position + prime TMB (no display from C++)
    -- Park() internally calls prefetchClips() which loads clips via _provide_clips.
    assert(self._playback_controller,
        "PlaybackEngine:seek: _playback_controller required")
    qt_constants.PLAYBACK.PARK(self._playback_controller, frame)

    -- Pull: Lua queries TMB via Renderer, handles online/offline/gap
    self:_display_frame_from_renderer(frame)

    -- Audio resolve + restart (non-fatal: must not prevent seek)
    self:_try_audio(function(eng)
        eng:_if_clip_changed_update_audio_mix(frame)
        if was_playing then
            eng:_start_audio()
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

--- MVC pull: clear seek dedup and re-seek so View can pull current frame.
-- Called when the View's render surface becomes ready, or when model content
-- changes at the parked playhead position (insert/delete at playhead).
-- The seek dedup guard (_last_committed_frame) prevents redundant decodes
-- during normal scrubbing, but here we WANT to re-decode because either
-- the surface wasn't ready before or the content changed under us.
function PlaybackEngine:on_model_changed(frame)
    log.event("on_model_changed: frame=%s state=%s", tostring(frame), tostring(self.state))
    self._last_committed_frame = nil  -- clear dedup so seek() re-decodes
    self:seek(frame)
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

    -- Wire C++ PlaybackController to audio devices (Phase 3)
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

    -- Listen for mid-playback mute/solo/volume changes
    self._track_mix_conn = Signals.connect("track_mix_changed", function()
        self:_refresh_audio_mix()
    end)
end

--- Release audio output.
function PlaybackEngine:deactivate_audio()
    if self._track_mix_conn then
        Signals.disconnect(self._track_mix_conn)
        self._track_mix_conn = nil
    end
    -- Disconnect C++ audio pump (Phase 3)
    if self._playback_controller and qt_constants.PLAYBACK then
        qt_constants.PLAYBACK.DEACTIVATE_AUDIO(self._playback_controller)
    end
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

--- Destroy engine: close TMB + PlaybackController + stop audio.
function PlaybackEngine:destroy()
    if self._track_mix_conn then
        Signals.disconnect(self._track_mix_conn)
        self._track_mix_conn = nil
    end
    if self._content_changed_conn then
        Signals.disconnect(self._content_changed_conn)
        self._content_changed_conn = nil
    end
    self:stop()
    self:_close_tmb()

    -- Close PlaybackController
    if self._playback_controller then
        qt_constants.PLAYBACK.CLOSE(self._playback_controller)
        self._playback_controller = nil
    end
end

-- NOTE: _tick(), _advance_position(), _display_frame() DELETED.
-- C++ displayLinkTick / deliverFrame owns position advancement and frame display.
-- Latch detection migrated to _on_controller_position() above.

--------------------------------------------------------------------------------
-- Audio Helpers
--------------------------------------------------------------------------------

--- Audio call (fail-fast in development: errors propagate immediately).
-- @param fn_or_name  string method name on self, or function(engine)
function PlaybackEngine:_try_audio(fn_or_name)
    if not self._audio_owner then return end
    if type(fn_or_name) == "string" then
        self[fn_or_name](self)
    else
        fn_or_name(self)
    end
end

--- Configure audio sources and start playback (transport start).
function PlaybackEngine:_configure_and_start_audio()
    if not self._audio_owner then return end
    self:_if_clip_changed_update_audio_mix(math.floor(self:get_position()))
    self:_start_audio()
end

--- Start audio at current position.
-- When C++ PlaybackController is active, it owns audio transport
-- (Flush/Reset/SetTarget/Start happen in C++ Play/SetSpeed).
function PlaybackEngine:_start_audio()
    if not self._audio_owner then return end
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

--- Refresh audio mix volumes immediately (mid-playback mute/solo/volume change).
-- Re-reads track state from DB and pushes to audio_playback.
-- Unlike _if_clip_changed_update_audio_mix, skips the clip-change check.
function PlaybackEngine:_refresh_audio_mix()
    if not self._audio_owner then return end  -- signal fires for all engines
    assert(self.sequence,
        "PlaybackEngine:_refresh_audio_mix: audio owner has no sequence")
    if not (audio_playback and audio_playback.session_initialized) then return end

    local frame = math.floor(self._position)
    local entries = self.sequence:get_audio_at(frame)
    local mix_params = self:_build_audio_mix_params(entries)
    audio_playback.refresh_mix_volumes(mix_params)
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
    if not self._audio_owner then return end
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

--------------------------------------------------------------------------------
-- Project change: tear down audio session (prevents stale sources from
-- previous project being used after media_cache clears its pool).
--------------------------------------------------------------------------------
Signals.connect("project_changed", PlaybackEngine.shutdown_audio_session, 5)

return PlaybackEngine
