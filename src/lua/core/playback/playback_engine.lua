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
    self._tmb_clip_window = nil      -- {lo, hi, direction} — valid frame range for current clip feed

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
    -- Video track indices start empty — populated by caller's first seek()
    -- via _send_clips_to_tmb(real_frame). Do NOT pre-load clips here:
    -- hardcoding frame 0 poisons the clip window cache when the saved
    -- playhead is far from frame 0.
    self:_setup_playback_controller()

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
    self._tmb_clip_window = nil
end

--- Public: invalidate clip cache + re-feed TMB after timeline edits.
-- Called by views (sequence_monitor) on content_changed — encapsulates all
-- internal cache invalidation so views never touch engine privates.
function PlaybackEngine:notify_content_changed()
    self:_refresh_content_bounds()
    if self._playback_controller then
        qt_constants.PLAYBACK.INVALIDATE_CLIP_WINDOWS(self._playback_controller)
    end
    self._tmb_clip_window = nil
    if self._tmb then
        self:_send_clips_to_tmb(math.floor(self:get_position()))
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

    -- Configure: TMB, bounds, video tracks (empty until first seek)
    PLAYBACK.SET_TMB(pc, self._tmb)
    PLAYBACK.SET_BOUNDS(pc, self.total_frames, self.fps_num, self.fps_den)
    PLAYBACK.SET_VIDEO_TRACKS(pc, self._video_track_indices)

    -- Send initial clip window so C++ doesn't need to wait for NeedClips
    local w = self._tmb_clip_window
    if w and w.hi > w.lo then
        PLAYBACK.SET_CLIP_WINDOW(pc, "video", w.lo, w.hi)
        PLAYBACK.SET_CLIP_WINDOW(pc, "audio", w.lo, w.hi)
    end

    -- Wire surface if already set
    if self._video_surface then
        PLAYBACK.SET_SURFACE(pc, self._video_surface)
    end

    -- Wire NeedClips callback: C++ fires when approaching clip window edge
    local engine = self
    PLAYBACK.SET_NEED_CLIPS_CALLBACK(pc, function(frame, direction, track_type)
        engine:_on_need_clips(frame, direction, track_type)
    end)

    -- Wire PositionCallback: C++ fires coalesced position updates for UI
    PLAYBACK.SET_POSITION_CALLBACK(pc, function(frame, stopped)
        engine:_on_controller_position(frame, stopped)
    end)

    -- Wire ClipTransitionCallback: C++ fires when displayed clip changes
    PLAYBACK.SET_CLIP_TRANSITION_CALLBACK(pc, function(clip_id, rotation, par_num, par_den, is_offline)
        engine:_on_clip_transition(clip_id, rotation, par_num, par_den, is_offline)
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

--- NeedClips callback: C++ requests clips when approaching window edge.
function PlaybackEngine:_on_need_clips(frame, direction, track_type)
    assert(type(frame) == "number", string.format(
        "PlaybackEngine:_on_need_clips: frame must be number, got %s", type(frame)))
    assert(direction == 1 or direction == -1 or direction == 0, string.format(
        "PlaybackEngine:_on_need_clips: direction must be -1/0/1, got %s", tostring(direction)))
    assert(track_type == "video" or track_type == "audio", string.format(
        "PlaybackEngine:_on_need_clips: track_type must be 'video' or 'audio', got %s",
        tostring(track_type)))

    log.detail("NeedClips: frame=%d dir=%d type=%s", frame, direction, track_type)

    -- Update direction for clip window tracking
    self.direction = direction

    if track_type == "video" then
        self:_send_video_clips_to_tmb(frame)
    else
        self:_send_audio_clips_only(frame)
    end
end

--- Position callback from C++: update UI playhead.
function PlaybackEngine:_on_controller_position(frame, stopped)
    assert(type(frame) == "number", string.format(
        "PlaybackEngine:_on_controller_position: frame must be number, got %s", type(frame)))
    assert(type(stopped) == "boolean", string.format(
        "PlaybackEngine:_on_controller_position: stopped must be boolean, got %s", type(stopped)))

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
function PlaybackEngine:_on_clip_transition(clip_id, rotation, par_num, par_den, is_offline)
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

    if clip_id ~= self.current_clip_id then
        log.event("clip_transition: clip=%s rotation=%d par=%d/%d offline=%s",
            clip_id, rotation, par_num, par_den, tostring(is_offline))
        self.current_clip_id = clip_id
        -- Offline frames are upright with square pixels
        self._on_set_rotation(is_offline and 0 or rotation)
        self._on_set_par(
            is_offline and 1 or par_num,
            is_offline and 1 or par_den)
    end
end

--- Send only video clips to TMB (for NeedClips VIDEO callback).
function PlaybackEngine:_send_video_clips_to_tmb(frame)
    assert(self._tmb, "PlaybackEngine:_send_video_clips_to_tmb: no TMB (call load_sequence first)")
    assert(self.sequence, "PlaybackEngine:_send_video_clips_to_tmb: no sequence loaded")

    local EMP = qt_constants.EMP
    local current_entries = self.sequence:get_video_at(frame)

    local track_clips = {}
    for _, entry in ipairs(current_entries) do
        local idx = entry.track.track_index
        if not track_clips[idx] then
            track_clips[idx] = {}
        end
        track_clips[idx][#track_clips[idx] + 1] = self:_build_tmb_clip(entry, 1.0)
    end

    -- Lookahead: walk forward per-track to pre-load upcoming clips.
    -- Covers gaps, clip transitions, and rapid-cut sequences.
    self:_extend_video_lookahead(frame, track_clips)

    -- Feed to TMB
    local indices = {}
    for idx, clips in pairs(track_clips) do
        EMP.TMB_SET_TRACK_CLIPS(self._tmb, "video", idx, clips)
        indices[#indices + 1] = idx
    end
    table.sort(indices, function(a, b) return a > b end)
    self._video_track_indices = indices

    -- Update PlaybackController video tracks
    if self._playback_controller then
        qt_constants.PLAYBACK.SET_VIDEO_TRACKS(self._playback_controller, indices)
    end

    -- Compute clip window: MAX per-track end for C++ (prevents NeedClips thrashing).
    -- Gap safety handled by C++ deliverFrame invalidation.
    local window_lo = self.total_frames
    local window_hi = 0
    for _, clips in pairs(track_clips) do
        for _, clip_data in ipairs(clips) do
            window_lo = math.min(window_lo, clip_data.timeline_start)
            window_hi = math.max(window_hi, clip_data.timeline_start + clip_data.duration)
        end
    end

    -- Report clip window to C++
    if self._playback_controller and window_hi > window_lo then
        qt_constants.PLAYBACK.SET_CLIP_WINDOW(self._playback_controller, "video", window_lo, window_hi)
    end
end

--- Send only audio clips to TMB (for NeedClips AUDIO callback).
function PlaybackEngine:_send_audio_clips_only(frame)
    assert(self._tmb, "PlaybackEngine:_send_audio_clips_only: no TMB (call load_sequence first)")
    assert(self.sequence, "PlaybackEngine:_send_audio_clips_only: no sequence loaded")

    local EMP = qt_constants.EMP
    local audio_entries = self.sequence:get_audio_at(frame)

    local audio_track_clips = {}
    for _, entry in ipairs(audio_entries) do
        local idx = entry.track.track_index
        if not audio_track_clips[idx] then
            audio_track_clips[idx] = {}
        end
        local sr = self:_compute_audio_speed_ratio(entry)
        audio_track_clips[idx][#audio_track_clips[idx] + 1] = self:_build_tmb_clip(entry, sr)
    end

    -- Direction-aware next/prev
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
                audio_track_clips[idx][#audio_track_clips[idx] + 1] = self:_build_tmb_clip(ne, sr)
            end
        end
    end

    -- Gap: try next audio
    if #audio_entries == 0 then
        local next_audio = self.sequence:get_next_audio(frame)
        for _, ne in ipairs(next_audio or {}) do
            local idx = ne.track.track_index
            if not audio_track_clips[idx] then
                audio_track_clips[idx] = {}
            end
            local sr = self:_compute_audio_speed_ratio(ne)
            audio_track_clips[idx][#audio_track_clips[idx] + 1] = self:_build_tmb_clip(ne, sr)
        end
    end

    -- Feed to TMB
    local audio_indices = {}
    for idx, clips in pairs(audio_track_clips) do
        EMP.TMB_SET_TRACK_CLIPS(self._tmb, "audio", idx, clips)
        audio_indices[#audio_indices + 1] = idx
    end
    table.sort(audio_indices)
    self._audio_track_indices = audio_indices

    -- Compute audio clip window: union of ALL loaded clips (current + next).
    local window_lo = self.total_frames
    local window_hi = 0
    for _, clips in pairs(audio_track_clips) do
        for _, clip_data in ipairs(clips) do
            window_lo = math.min(window_lo, clip_data.timeline_start)
            window_hi = math.max(window_hi, clip_data.timeline_start + clip_data.duration)
        end
    end

    -- Report clip window to C++
    if self._playback_controller and window_hi > window_lo then
        qt_constants.PLAYBACK.SET_CLIP_WINDOW(self._playback_controller, "audio", window_lo, window_hi)
    end
end

--- Feed TMB with current + next clips for each video and audio track.
-- Builds a small clip window (2-3 clips per track) from sequence queries.
-- Skips re-query when playhead is still inside the cached clip window.
-- @param frame integer: current playhead frame
-- @return boolean: true if clips were re-queried (boundary crossing), false if cached
function PlaybackEngine:_send_clips_to_tmb(frame)
    assert(self._tmb, "PlaybackEngine:_send_clips_to_tmb: no TMB")
    assert(self.sequence, "PlaybackEngine:_send_clips_to_tmb: no sequence")

    -- Still inside the clip window TMB already has? Skip re-query.
    local w = self._tmb_clip_window
    if w and frame >= w.lo and frame < w.hi and self.direction == w.direction then
        return false  -- no boundary crossing
    end

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

    -- Lookahead: walk forward per-track to pre-load upcoming clips.
    -- Covers gaps, clip transitions, and rapid-cut sequences.
    self:_extend_video_lookahead(frame, track_clips)

    -- Feed each video track to TMB
    local indices = {}
    for idx, clips in pairs(track_clips) do
        EMP.TMB_SET_TRACK_CLIPS(self._tmb, "video", idx, clips)
        indices[#indices + 1] = idx
    end

    -- Sort indices descending: highest track_index = topmost = highest priority
    table.sort(indices, function(a, b) return a > b end)
    self._video_track_indices = indices

    -- Propagate video tracks to C++ controller (seek() calls this)
    if self._playback_controller then
        qt_constants.PLAYBACK.SET_VIDEO_TRACKS(self._playback_controller, indices)
    end

    -- ── Audio tracks ──
    local audio_track_clips = self:_send_audio_clips_to_tmb(frame, EMP)

    -- ── Compute clip windows from VIDEO clips ──
    -- Two windows serve different purposes:
    -- 1. Lua cache (_tmb_clip_window): MIN per-track end — tight, ensures seek
    --    re-queries when any track's loaded data is stale.
    -- 2. C++ SetClipWindow: MAX per-track end — wide, prevents NeedClips
    --    thrashing when a short track has no more clips to load.
    -- Gap safety: C++ deliverFrame invalidates windows on unexpected gaps,
    -- so the wide C++ window won't mask stale data during playback.
    local window_lo = self.total_frames or math.huge
    local cache_hi = math.huge   -- min per-track (for Lua seek cache)
    local cpp_hi = 0             -- max per-track (for C++ NeedClips timing)

    local has_clips = false
    for _, clips in pairs(track_clips) do
        if #clips > 0 then
            has_clips = true
            local track_lo = math.huge
            local track_hi = 0
            for _, clip_data in ipairs(clips) do
                track_lo = math.min(track_lo, clip_data.timeline_start)
                track_hi = math.max(track_hi, clip_data.timeline_start + clip_data.duration)
            end
            window_lo = math.min(window_lo, track_lo)
            cache_hi = math.min(cache_hi, track_hi)
            cpp_hi = math.max(cpp_hi, track_hi)
        end
    end
    if not has_clips then cache_hi = 0 end

    -- Output invariant: max >= min is a mathematical certainty
    assert(not has_clips or cpp_hi >= cache_hi, string.format(
        "PlaybackEngine:_send_clips_to_tmb: cpp_hi (%d) < cache_hi (%d) — impossible",
        cpp_hi, cache_hi))

    if has_clips and cache_hi > window_lo then
        self._tmb_clip_window = {
            lo = window_lo, hi = cache_hi, direction = self.direction,
        }
    else
        self._tmb_clip_window = nil
    end

    -- Report wide window to C++ (prevents NeedClips thrashing)
    if self._playback_controller and has_clips and cpp_hi > window_lo then
        local PLAYBACK = qt_constants.PLAYBACK
        PLAYBACK.SET_CLIP_WINDOW(self._playback_controller, "video", window_lo, cpp_hi)
    end

    -- Compute audio clip window separately (audio clips may span different range)
    local audio_lo, audio_hi = self.total_frames, 0
    for _, clips in pairs(audio_track_clips) do
        for _, clip_data in ipairs(clips) do
            audio_lo = math.min(audio_lo, clip_data.timeline_start)
            audio_hi = math.max(audio_hi, clip_data.timeline_start + clip_data.duration)
        end
    end
    if self._playback_controller and audio_hi > audio_lo then
        qt_constants.PLAYBACK.SET_CLIP_WINDOW(
            self._playback_controller, "audio", audio_lo, audio_hi)
    end

    return true  -- boundary crossing: clips were re-queried
end

--- Feed audio clips near the playhead to TMB (same pattern as video).
-- Called from _send_clips_to_tmb at clip boundaries.
-- @return audio_track_clips table {[track_idx] = {clip_data, ...}} for window union
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
    return audio_track_clips
end

-- Lookahead: walk forward per-track to ensure TMB has enough clips pre-loaded.
-- Without this, clip transitions cause 50-150ms decode stalls on the CVDisplayLink
-- thread when GetVideoFrame encounters a clip TMB hasn't been told about yet.
local VIDEO_LOOKAHEAD_FRAMES = 150  -- ~6s at 25fps

--- Extend track_clips with forward lookahead clips.
-- Walks each video track forward from its current frontier until
-- coverage reaches frame + VIDEO_LOOKAHEAD_FRAMES or no more clips exist.
-- @param frame number: current playhead position
-- @param track_clips table: {[track_index] = {clip_table, ...}} — modified in-place
function PlaybackEngine:_extend_video_lookahead(frame, track_clips)
    local target = frame + VIDEO_LOOKAHEAD_FRAMES

    -- Collect all clip_ids already in track_clips (for dedup)
    local seen = {}
    for _, clips in pairs(track_clips) do
        for _, clip_data in ipairs(clips) do
            seen[clip_data.clip_id] = true
        end
    end

    -- Iteratively walk forward using get_next_video until all tracks
    -- cover the lookahead window. Each call returns one clip per track.
    for _ = 1, 20 do  -- safety limit
        -- Find the minimum per-track frontier (least-covered track)
        local min_frontier = target
        if not next(track_clips) then
            -- No clips loaded yet (pure gap) — start from playhead
            min_frontier = frame
        else
            for _, clips in pairs(track_clips) do
                local track_frontier = frame
                for _, clip_data in ipairs(clips) do
                    local clip_end = clip_data.timeline_start + clip_data.duration
                    if clip_end > track_frontier then track_frontier = clip_end end
                end
                if track_frontier < min_frontier then min_frontier = track_frontier end
            end
        end

        if min_frontier >= target then break end

        -- Get next clip per track from the frontier
        local nexts = self.sequence:get_next_video(min_frontier)
        if not nexts or #nexts == 0 then break end

        local any_added = false
        for _, ne in ipairs(nexts) do
            if not seen[ne.clip.id] then
                local idx = ne.track.track_index
                if not track_clips[idx] then track_clips[idx] = {} end
                track_clips[idx][#track_clips[idx] + 1] = self:_build_tmb_clip(ne, 1.0)
                seen[ne.clip.id] = true
                any_added = true
            end
        end

        if not any_added then break end
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
    -- Stop all background decode work (prefetch threads + pre-buffer jobs).
    -- Prevents zombie HW decoders from competing for GPU decode engine.
    if self._tmb then
        qt_constants.EMP.TMB_PARK_READERS(self._tmb)
    end
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

    local was_playing = (self.state == "playing")
    if was_playing then
        self:_stop_audio()
    end

    -- Feed TMB clips for seek position
    if self._tmb then
        self:_send_clips_to_tmb(frame)
    end

    -- Delegate seek to C++ PlaybackController (handles frame display)
    assert(self._playback_controller,
        "PlaybackEngine:seek: _playback_controller required")
    qt_constants.PLAYBACK.SEEK(self._playback_controller, frame)

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
