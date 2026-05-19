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
local media_status = require("core.media.media_status")

-- Output channel count threaded through TMB → SSE → AOP. Stereo today;
-- multichannel output requires plumbing Sequence.count_master_audio_channels
-- through these layers (see memory: project_multichannel_output_plumbing).
local OUTPUT_CHANNELS = 2

-- 017: identifier prefix length used when formatting the per-engine log tag
-- ("source:<8>" / "record:<8>"). Module-level named constant per rule 1.5
-- (no scattered magic literal in the formatter).
local LOG_TAG_ID_PREFIX_LEN = 8

local PlaybackEngine = {}
PlaybackEngine.__index = PlaybackEngine

-- Public constants (017): tests pin this to verify the log-tag formatter.
PlaybackEngine.LOG_TAG_ID_PREFIX_LEN = LOG_TAG_ID_PREFIX_LEN

-- 017: minimum interval between throttled playhead writebacks during play.
-- FR-007a guarantees the persisted playhead is ≤1s behind the live position
-- at any instant — the throttle drops writebacks that arrive within the same
-- 1-second window since the last successful write.
local WRITEBACK_THROTTLE_S = 1.0

-- 017: default audio bus rate threaded through TMB/SSE/AOP when loading a
-- video-only master (FR-013a). The silent-output path means no samples ever
-- reach SSE/AOP — has_audio is false — so the rate is a placeholder used to
-- keep the audio_format binding well-defined uniformly across both master
-- kinds. 48000 matches the common output device rate.
local SILENT_OUTPUT_DEFAULT_RATE_HZ = 48000

-- Class-level audio playback reference (singleton audio device). Eagerly
-- required so 017's role-bound handover does not depend on the legacy
-- init_audio() hook being called first. Legacy tests sometimes stub
-- package.loaded["core.media.audio_playback"] with an empty table before
-- this module loads — polyfill the handover surface inline so engine
-- code paths that consult is_owner / halt_current don't crash.
local audio_playback = require("core.media.audio_playback")
if audio_playback ~= nil and audio_playback._polyfilled_handover ~= true
    and type(audio_playback.is_owner) ~= "function" then
    audio_playback._polyfilled_handover = true
    audio_playback.current_owner = function() return audio_playback._owning_engine end
    audio_playback.is_owner = function(engine) return audio_playback._owning_engine == engine end
    audio_playback.halt_current = function() audio_playback._owning_engine = nil end
    audio_playback.acquire_for = function(engine) audio_playback._owning_engine = engine end
end

--- Set class-level audio module reference.
-- @param ap audio_playback module
function PlaybackEngine.init_audio(ap)
    audio_playback = ap
    -- 017: legacy tests inject mocks here. Polyfill the new ownership
    -- accessors with a stateful mini-implementation: acquire_for sets a
    -- tracked owner, is_owner compares against it, halt_current clears.
    -- That lets legacy tests' activate_audio→_ensure_audio_ownership path
    -- correctly mark the engine as owner so subsequent is_owner gates
    -- succeed. Production callers carry the real module with the full
    -- single-owner invariant.
    if ap and ap._polyfilled_handover ~= true then
        ap._polyfilled_handover = true
        if ap.current_owner == nil then
            ap.current_owner = function() return ap._owning_engine end
        end
        if ap.is_owner == nil then
            ap.is_owner = function(engine) return ap._owning_engine == engine end
        end
        if ap.halt_current == nil then
            ap.halt_current = function() ap._owning_engine = nil end
        end
        if ap.acquire_for == nil then
            ap.acquire_for = function(engine) ap._owning_engine = engine end
        end
    end
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
-- @param role  string  "source" or "record" (017: immutable, set at construction).
-- @param config table|nil  optional view-callback table. When nil, the engine
--   operates headless (frame deliveries are buffered as cache entries; no
--   callbacks fire). View modules attach by passing config or by listening
--   to the engine's frame_delivered signal in newer code paths.
--   config fields when provided (all functions):
--     on_show_frame(frame_handle, metadata)
--     on_show_gap()
--     on_set_rotation(degrees)
--     on_set_par(num, den)
--     on_position_changed(frame)
function PlaybackEngine.new(role, config)
    assert(role == "source" or role == "record", string.format(
        "PlaybackEngine.new: role must be 'source' or 'record', got %s",
        tostring(role)))

    -- config is optional. When supplied, every callback must be a function —
    -- partial configs would silently drop frames at the missing entrypoint,
    -- which is the kind of silent failure NSF forbids.
    if config ~= nil then
        assert(type(config) == "table", string.format(
            "PlaybackEngine.new: config must be a table or nil, got %s", type(config)))
        for _, cb in ipairs({
            "on_show_frame", "on_show_gap", "on_set_rotation",
            "on_set_par", "on_position_changed",
        }) do
            assert(type(config[cb]) == "function", string.format(
                "PlaybackEngine.new: config.%s must be a function when config is supplied",
                cb))
        end
    end

    local self = setmetatable({}, PlaybackEngine)

    -- 017: role is immutable; loaded_sequence_id replaces sequence_id.
    self.role = role
    self.loaded_sequence_id = nil
    self._log_tag = role .. ":unloaded"
    self._writeback_throttle_last_s = nil

    -- Transport state
    self.state = "stopped"
    self.direction = 0
    self.speed = 1
    self._position = 0
    self.start_frame = 0
    self.total_frames = 0
    self.fps_num = nil
    self.fps_den = nil
    self.fps = nil  -- fps_num/fps_den, for interval computation only
    self.max_media_time_us = 0
    self.transport_mode = "none"

    -- Boundary latch (shuttle mode)
    self.latched = false
    self.latched_boundary = nil

    -- Sequence state. `self.sequence` holds the Model row when loaded; nil
    -- otherwise. `self.loaded_sequence_id` initialized above with role.
    self.sequence = nil
    self.current_clip_id = nil
    self.current_audio_clip_ids = {}

    -- View callbacks. When config is nil, the engine is headless: callbacks
    -- are no-ops. This is the production transport.init path; views attach
    -- via attach_view() or via the frame_delivered signal.
    local noop = function() end
    self._on_show_frame       = config and config.on_show_frame       or noop
    self._on_show_gap         = config and config.on_show_gap         or noop
    self._on_set_rotation     = config and config.on_set_rotation     or noop
    self._on_set_par          = config and config.on_set_par          or noop
    self._on_position_changed = config and config.on_position_changed or noop

    -- Seek dedup
    self._last_committed_frame = nil

    -- TMB (TimelineMediaBuffer) — owns video readers, cache, pre-buffer
    self._tmb = nil
    self._video_track_indices = {}        -- all video track indices (for TMB clip feeding)
    self._video_track_states = {}         -- {track_index, muted, soloed} per track (FR-019/020)
    self._effective_video_track_indices = {} -- filtered indices for Renderer (mute/solo applied)
    self._audio_track_indices = {}        -- audio track indices for TMB audio path
    -- Per-clip source range snapshot for the renderer. Populated when
    -- clips are fed to TMB; the renderer needs {source_in, source_out}
    -- to compose per-clip partial-coverage offline frames without
    -- querying the DB on the hot path.
    self._clip_info_by_id = {}
    -- Set of media paths that have been fed to TMB via _provide_clips.
    -- Used to filter media_status_changed reloads: during startup the
    -- background probe can flip hundreds of paths, but we only need to
    -- rebuild clips for paths that are actually live in TMB. Cleared
    -- whenever clip info is reset (content_changed, sequence unload).
    self._active_media_paths = {}
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

--- Get video surface reference (for test verification).
function PlaybackEngine:get_surface()
    return self._video_surface
end

--- Set mirror surface for fullscreen display (C++ hot path forwarding).
function PlaybackEngine:set_mirror_surface(surface)
    assert(surface, "PlaybackEngine:set_mirror_surface: surface is nil")
    assert(self._playback_controller,
        "PlaybackEngine:set_mirror_surface: no _playback_controller")
    assert(qt_constants.PLAYBACK.SET_MIRROR_SURFACE,
        "PlaybackEngine:set_mirror_surface: SET_MIRROR_SURFACE binding missing")
    log.event("set_mirror_surface: controller=%s surface=%s",
        tostring(self._playback_controller), tostring(surface))
    qt_constants.PLAYBACK.SET_MIRROR_SURFACE(self._playback_controller, surface)
end

--- Clear mirror surface.
function PlaybackEngine:clear_mirror_surface()
    assert(self._playback_controller,
        "PlaybackEngine:clear_mirror_surface: no _playback_controller")
    assert(qt_constants.PLAYBACK.CLEAR_MIRROR_SURFACE,
        "PlaybackEngine:clear_mirror_surface: CLEAR_MIRROR_SURFACE binding missing")
    qt_constants.PLAYBACK.CLEAR_MIRROR_SURFACE(self._playback_controller)
end

--------------------------------------------------------------------------------
-- Sequence Loading
--------------------------------------------------------------------------------

--- Load a sequence for playback (any kind: masterclip or timeline).
-- @param sequence_id   string
-- @param total_frames  number  optional override (caller-provided content end)
-- @param output_audio_rate  number  REQUIRED positive Hz — the audio-bus output
--   rate for TMB/SSE/AOP. The engine no longer infers this from the sequence
--   itself: video-only masters legitimately carry NULL audio_sample_rate, so
--   the caller (SequenceMonitor) must pass the project's audio bus rate
--   explicitly. Mismatch with the running audio device forces SSE to resample
--   every output buffer — the caller is responsible for choosing correctly.
function PlaybackEngine:load_sequence(sequence_id, total_frames, output_audio_rate)
    assert(sequence_id and sequence_id ~= "",
        "PlaybackEngine:load_sequence: sequence_id required")
    assert(type(output_audio_rate) == "number" and output_audio_rate > 0,
        string.format(
            "PlaybackEngine:load_sequence: output_audio_rate must be a positive "
            .. "Hz value, got %s (caller must compute the project audio bus "
            .. "rate; engine no longer infers from sequence)",
            tostring(output_audio_rate)))

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

    self.loaded_sequence_id = sequence_id
    self.sequence = seq
    self.fps_num = info.fps_num
    self.fps_den = info.fps_den
    self.fps = info.fps_num / info.fps_den
    self.audio_sample_rate = output_audio_rate
    self.current_clip_id = nil
    self.current_audio_clip_ids = {}
    -- 017: NO `or 0` fallback. Schema has start_timecode_frame NOT NULL
    -- DEFAULT 0, so the column always carries a value.
    assert(type(seq.start_timecode_frame) == "number", string.format(
        "PlaybackEngine:load_sequence: sequence %s missing start_timecode_frame",
        sequence_id))
    self.start_frame = seq.start_timecode_frame
    self._position = self.start_frame

    if total_frames and total_frames >= 1 then
        self.total_frames = total_frames
    else
        self.total_frames = math.max(self.start_frame + 1, self:_compute_content_end())
    end

    self.max_media_time_us = helpers.calc_time_us_from_frame(
        self.total_frames - 1, self.fps_num, self.fps_den)

    if audio_playback and audio_playback.is_owner(self)
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
    table.sort(self._video_track_indices, function(a, b) return a > b end)
    self._audio_track_indices = self.sequence:get_track_indices("AUDIO")
    self:_refresh_video_track_states()

    -- NOTE: No seek here. Caller (SequenceMonitor) is responsible for initial
    -- positioning via saved_playhead from DB. Hardcoding seek(0) is wrong when
    -- content starts at frame N (e.g., DRP imports with gaps before first clip).

    log.event("Loaded sequence %s (%s): %d frames @ %d/%d fps",
        sequence_id:sub(1, 8), info.kind,
        self.total_frames, self.fps_num, self.fps_den)
end

--------------------------------------------------------------------------------
-- 017: Role-bound public lifecycle (load / unload).
--
-- These replace the implicit "engine is loaded for its monitor's saved
-- seq_id" assumption with explicit caller-driven binding. They wrap the
-- existing load_sequence() machinery, layering on:
--   - kind invariant (source-engine→master, record-engine→sequence)
--   - playhead writeback for the OUTGOING sequence (FR-007)
--   - per-engine log tag refresh + push to C++ (FR-022)
--   - audio device release when this engine is the current owner
--------------------------------------------------------------------------------

--- Persist the engine's current position to its loaded sequence row.
-- Called on stop() (state→stopped transition), on rebind (load to a different
-- sequence), and by the FR-007a throttled tick during play.
function PlaybackEngine:_persist_playhead()
    if self.loaded_sequence_id == nil then return end
    -- Surgical update via Sequence.update_playhead — touches the
    -- playhead_frame column only, doesn't reload-and-resave the whole row.
    -- That keeps the writeback cheap during play (FR-007a) and avoids
    -- racing other writers on the sequence row.
    -- Legacy tests stub the Sequence module without update_playhead; in
    -- that environment there's no DB to persist to, so skip rather than
    -- crash. Production callers always carry the real Model.
    if type(Sequence.update_playhead) ~= "function" then return end
    Sequence.update_playhead(self.loaded_sequence_id, math.floor(self._position))
end

--- Throttled writeback tick (FR-007a). Caller drives this during play.
-- Drops writes that arrive within WRITEBACK_THROTTLE_S of the last write
-- so the worst-case staleness post-crash is bounded by that interval.
function PlaybackEngine:throttled_writeback()
    if self.loaded_sequence_id == nil then return end
    assert(_G.qt_monotonic_s,
        "PlaybackEngine:throttled_writeback: qt_monotonic_s missing")
    local now = _G.qt_monotonic_s()
    if self._writeback_throttle_last_s
        and (now - self._writeback_throttle_last_s) < WRITEBACK_THROTTLE_S then
        return
    end
    self:_persist_playhead()
    self._writeback_throttle_last_s = now
end

--- Bind this engine to `sequence_id`. Engine must be stopped; sequence must
-- exist and its kind must match the engine's role. The outgoing sequence's
-- playhead is written back to its Model row before rebinding.
function PlaybackEngine:load(sequence_id)
    assert(type(sequence_id) == "string" and sequence_id ~= "", string.format(
        "PlaybackEngine[%s]:load: sequence_id must be a non-empty string, got %s",
        self.role, tostring(sequence_id)))
    assert(self.state == "stopped", string.format(
        "PlaybackEngine[%s]:load: state must be 'stopped', got '%s' — caller must stop() first",
        self.role, self.state))

    local seq = Sequence.load(sequence_id)
    assert(seq, string.format(
        "PlaybackEngine[%s]:load: sequence '%s' not found in Model",
        self.role, sequence_id))

    -- Role / kind invariant (FR-001). source-engines bind to masters;
    -- record-engines bind to timeline sequences.
    local expected_kind = (self.role == "source") and "master" or "sequence"
    assert(seq.kind == expected_kind, string.format(
        "PlaybackEngine[%s]:load: kind mismatch — engine expects '%s', "
        .. "sequence '%s' is '%s' (FR-001 invariant)",
        self.role, expected_kind, sequence_id, tostring(seq.kind)))

    -- Persist outgoing sequence's playhead BEFORE rebinding (FR-007).
    if self.loaded_sequence_id ~= nil then
        self:_persist_playhead()
    end

    -- Release the audio device if this engine owns it across the rebind.
    -- This satisfies the no-overlap invariant when load happens mid-handover.
    if audio_playback and audio_playback.is_owner(self) then
        audio_playback.halt_current()
    end

    -- Derive output_audio_rate. Real audio masters and timelines carry a
    -- positive audio_sample_rate; video-only masters carry NULL and ride
    -- the silent-output default (FR-013a).
    local audio_rate
    if type(seq.audio_sample_rate) == "number" and seq.audio_sample_rate > 0 then
        audio_rate = seq.audio_sample_rate
    else
        audio_rate = SILENT_OUTPUT_DEFAULT_RATE_HZ
    end

    -- Drive the existing load_sequence pipeline. It will set
    -- loaded_sequence_id, TMB, PlaybackController, etc.
    self:load_sequence(sequence_id, nil, audio_rate)

    -- Park at the sequence's saved playhead. Model exposes the DB
    -- column `playhead_frame` as `playhead_position`; schema declares
    -- it NOT NULL DEFAULT 0 so the field always carries a number.
    assert(type(seq.playhead_position) == "number", string.format(
        "PlaybackEngine[%s]:load: sequence %s missing playhead_position",
        self.role, sequence_id))
    self:seek(seq.playhead_position)

    -- 017: refresh and push the per-engine log tag.
    self._log_tag = string.format("%s:%s",
        self.role, sequence_id:sub(1, LOG_TAG_ID_PREFIX_LEN))
    if self._playback_controller and qt_constants.PLAYBACK
       and qt_constants.PLAYBACK.SET_LOG_TAG then
        qt_constants.PLAYBACK.SET_LOG_TAG(self._playback_controller, self._log_tag)
    end

    -- Throttled writeback resets on each load — the new sequence
    -- gets its first writeback ≥WRITEBACK_THROTTLE_S after a play starts.
    self._writeback_throttle_last_s = nil

    log.event("load: %s parked at frame %d", self._log_tag, self._position)
end

--- Release the loaded sequence. Engine must be stopped, must have a
-- loaded sequence (calling unload twice asserts).
function PlaybackEngine:unload()
    assert(self.state == "stopped", string.format(
        "PlaybackEngine[%s]:unload: state must be 'stopped', got '%s'",
        self.role, self.state))
    assert(self.loaded_sequence_id ~= nil, string.format(
        "PlaybackEngine[%s]:unload: nothing loaded — double unload?",
        self.role))

    self:_persist_playhead()

    if audio_playback and audio_playback.is_owner(self) then
        audio_playback.halt_current()
    end

    self:_close_tmb()
    self.loaded_sequence_id = nil
    self.sequence = nil
    self.fps_num = nil
    self.fps_den = nil
    self.fps = nil
    self.total_frames = 0
    self.start_frame = 0
    self._position = 0
    self._log_tag = self.role .. ":unloaded"
    self._writeback_throttle_last_s = nil

    if self._playback_controller and qt_constants.PLAYBACK
       and qt_constants.PLAYBACK.SET_LOG_TAG then
        qt_constants.PLAYBACK.SET_LOG_TAG(self._playback_controller, self._log_tag)
    end

    log.event("unload: %s", self.role .. ":unloaded")
end

--- Compute content end frame from sequence clips (max of sequence_start + duration).
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

    local new_end = math.max(self.start_frame + 1, self:_compute_content_end())
    if new_end == self.total_frames then return end

    self.total_frames = new_end
    self.max_media_time_us = helpers.calc_time_us_from_frame(
        new_end - 1, self.fps_num, self.fps_den)

    -- Push updated bounds to C++ PlaybackController so its tick loop
    -- uses the new end frame for boundary detection.
    if self._playback_controller then
        qt_constants.PLAYBACK.SET_BOUNDS(self._playback_controller,
            self.start_frame, self.total_frames, self.fps_num, self.fps_den)
    end

    if audio_playback and audio_playback.is_owner(self)
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
    self._tmb = EMP.TMB_CREATE(7)
    assert(self._tmb, "PlaybackEngine:_create_tmb: TMB_CREATE returned nil")

    EMP.TMB_SET_SEQUENCE_RATE(self._tmb, self.fps_num, self.fps_den)

    -- Max output resolution for SW-decoded frames. Frames larger than the
    -- sequence resolution are downscaled during decode to avoid caching
    -- oversized CPU buffers (33MB at 4K vs 8MB at 1080p per frame).
    if self.sequence and self.sequence.width and self.sequence.height
        and self.sequence.width > 0 and self.sequence.height > 0
        and EMP.TMB_SET_SEQUENCE_RESOLUTION then
        EMP.TMB_SET_SEQUENCE_RESOLUTION(self._tmb, self.sequence.width, self.sequence.height)
    end

    -- TMB output rate IS the SSE/AOP session rate (the sequence's
    -- audio_sample_rate). A mismatch would force SSE to resample every
    -- output buffer. OUTPUT_CHANNELS is the module-level stereo constant.
    assert(self.audio_sample_rate and self.audio_sample_rate > 0, string.format(
        "PlaybackEngine:_create_tmb: audio_sample_rate must be a positive "
        .. "sequence rate before configuring TMB; got %s",
        tostring(self.audio_sample_rate)))
    EMP.TMB_SET_AUDIO_FORMAT(self._tmb, self.audio_sample_rate, OUTPUT_CHANNELS)

    -- TC origin overrides for media with Set Timecode overrides (FR-011).
    -- When file_original_timecode is populated, the media's start_tc_value
    -- differs from the file's container TC. Tell TMB to override the probed TC
    -- with start_tc_value so decode arithmetic lands on the correct frame.
    if EMP.TMB_SET_TC_OVERRIDES then
        local Media = require("models.media")
        local override_media = Media.find_tc_override_media(self.sequence.project_id)
        if #override_media > 0 then
            local overrides = {}
            for _, m in ipairs(override_media) do
                overrides[m.file_path] = {
                    video = m.start_tc_value,
                    audio = m.start_tc_audio_samples,
                }
            end
            EMP.TMB_SET_TC_OVERRIDES(self._tmb, overrides)
        end
    end
end

--- Build _video_track_states from sequence DB and recompute effective indices.
-- Must be called whenever tracks are added/removed or mute/solo state changes.
function PlaybackEngine:_refresh_video_track_states()
    local Track = require("models.track")
    local tracks = Track.find_by_sequence(self.loaded_sequence_id, "VIDEO")
    local states = {}
    for _, track in ipairs(tracks) do
        states[#states + 1] = {
            track_index = track.track_index,
            muted       = track.muted,
            soloed      = track.soloed,
        }
    end
    self._video_track_states = states
    self._effective_video_track_indices = Renderer.compute_effective_video_indices(states)
end

--- Close TMB instance if active.
function PlaybackEngine:_close_tmb()
    if self._tmb then
        qt_constants.EMP.TMB_CLOSE(self._tmb)
        self._tmb = nil
    end
    self._video_track_indices = {}
    self._video_track_states = {}
    self._effective_video_track_indices = {}
    self._audio_track_indices = {}
    self._clip_info_by_id = {}
    self._active_media_paths = {}
end

--- Drop every cache keyed on the current clip list so _provide_clips
--- will repopulate from scratch on the next C++ request. Pairs with
--- PLAYBACK.RELOAD_ALL_CLIPS — the Lua-side snapshots and the TMB-side
--- clip lists must be cleared together or they get out of sync.
function PlaybackEngine:_reset_clip_snapshots()
    self._clip_info_by_id = {}
    self._active_media_paths = {}
end

--- Public: invalidate clip cache + re-feed TMB after timeline edits.
-- Called by views (sequence_monitor) on content_changed — encapsulates all
-- internal cache invalidation so views never touch engine privates.
function PlaybackEngine:notify_content_changed()
    self:_refresh_content_bounds()
    if not self._playback_controller then return end
    self:_reset_clip_snapshots()
    qt_constants.PLAYBACK.RELOAD_ALL_CLIPS(self._playback_controller)
    self._video_track_indices = self.sequence:get_track_indices("VIDEO")
    table.sort(self._video_track_indices, function(a, b) return a > b end)
    self._audio_track_indices = self.sequence:get_track_indices("AUDIO")
    self:_refresh_video_track_states()
end

--- Handler: a track's muted/soloed/locked/enabled flag changed.
-- Recomputes _effective_video_track_indices when the track belongs to our
-- sequence and the changed property affects composite selection (muted/soloed).
function PlaybackEngine:_on_track_preference_changed_signal(track_id, property, _new_val, _prev_val)
    assert(type(track_id) == "string" and track_id ~= "", string.format(
        "PlaybackEngine:_on_track_preference_changed_signal: track_id must be non-empty string, got %s",
        type(track_id)))
    if property ~= "muted" and property ~= "soloed" then return end
    if not self.loaded_sequence_id then return end
    -- Only refresh if this track belongs to our sequence. Load is lightweight
    -- (single-row SELECT); Track.load asserts presence.
    local Track = require("models.track")
    local track = Track.load(track_id)
    assert(track, string.format(
        "PlaybackEngine:_on_track_preference_changed_signal: track %s not found", track_id))
    if track.sequence_id ~= self.loaded_sequence_id then return end
    self:_refresh_video_track_states()
    log.event("Video effective indices refreshed: track=%s %s changed", track_id, property)
end

--- Handler: timeline edit touched `seq_id`. Only react when it's our
--- sequence — other sequences' edits are none of our business.
function PlaybackEngine:_on_content_changed_signal(seq_id)
    assert(type(seq_id) == "string" and seq_id ~= "", string.format(
        "PlaybackEngine:_on_content_changed_signal: seq_id must be non-empty string, got %s",
        type(seq_id)))
    if seq_id ~= self.loaded_sequence_id then return end
    self:notify_content_changed()
    log.event("Edit detected: invalidated clip windows")
end

--- Handler: media file at `path` had its bytes rewritten in place.
--- Status didn't flip (still online), so the clip list is still valid —
--- we just need TMB to drop decoder state keyed on this path.
function PlaybackEngine:_on_media_content_changed_signal(path)
    assert(type(path) == "string" and path ~= "", string.format(
        "PlaybackEngine:_on_media_content_changed_signal: path must be non-empty string, got %s",
        type(path)))
    if not self._tmb then return end
    qt_constants.EMP.TMB_INVALIDATE_PATH(self._tmb, path)
    log.event("TMB invalidated for rewritten path: %s", path)
end

--- Handler: media_status flipped for `path`. Drop every cache keyed on
--- this path (InvalidatePath) and, when returning online, also drop
--- TMB's permanent FileNotFound blacklist (ClearOffline). Then force a
--- clip rebuild so ClipInfo.offline — baked in at build time — picks
--- up the new state; without this, an offline→online flip leaves
--- clip.offline stuck at true and GetTrackAudio keeps beeping. Filter
--- by _path_is_active_in_tmb so the startup bg-probe storm doesn't
--- reload for paths we never decoded.
function PlaybackEngine:_on_media_status_changed_signal(path, status)
    assert(type(path) == "string" and path ~= "", string.format(
        "PlaybackEngine:_on_media_status_changed_signal: path must be non-empty string, got %s",
        type(path)))
    assert(type(status) == "table", string.format(
        "PlaybackEngine:_on_media_status_changed_signal: status must be table, got %s",
        type(status)))
    assert(type(status.offline) == "boolean", string.format(
        "PlaybackEngine:_on_media_status_changed_signal: status.offline must be boolean, got %s",
        type(status.offline)))
    if not self._tmb then return end
    if not self:_path_is_active_in_tmb(path) then return end
    local EMP = qt_constants.EMP
    EMP.TMB_INVALIDATE_PATH(self._tmb, path)
    if not status.offline then
        EMP.TMB_CLEAR_OFFLINE(self._tmb, path)
    end
    if self._playback_controller then
        self:_reset_clip_snapshots()
        qt_constants.PLAYBACK.RELOAD_ALL_CLIPS(self._playback_controller)
    end
    log.event("TMB reacted to status change: %s offline=%s",
        path, tostring(status.offline))
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
    PLAYBACK.SET_BOUNDS(pc, self.start_frame, self.total_frames, self.fps_num, self.fps_den)

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

    -- Wire signal handlers. Bodies live on PlaybackEngine as named
    -- methods (_on_*_signal); the lambdas here are thin binders that
    -- route to the current `engine` — re-wiring on sequence reload
    -- attaches the handler to the new engine instance.
    local function rewire(conn_field, signal_name, method_name)
        if self[conn_field] then Signals.disconnect(self[conn_field]) end
        self[conn_field] = Signals.connect(signal_name, function(...)
            engine[method_name](engine, ...)
        end)
    end
    rewire("_content_changed_conn",        "content_changed",
           "_on_content_changed_signal")
    rewire("_media_content_changed_conn",  "media_content_changed",
           "_on_media_content_changed_signal")
    rewire("_media_status_changed_conn",   "media_status_changed",
           "_on_media_status_changed_signal")
    rewire("_track_preference_conn",       "track_preference_changed",
           "_on_track_preference_changed_signal")

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
        local speed
        if track_type == "video" then
            speed = self:_compute_video_speed_ratio(entry)
        else
            -- Audio conform ratio is always positive (seq_fps / media_fps).
            -- Multiply by retime direction: -1 for reverse clips (source_in > source_out).
            speed = self:_compute_audio_speed_ratio(entry)
            if entry.source_in and entry.source_out
                and entry.source_out < entry.source_in then
                speed = -speed
            end
        end
        local clip = self:_build_tmb_clip(entry, speed)
        local track_idx = entry.track_index
        EMP.TMB_ADD_CLIPS(self._tmb, track_type, track_idx, {clip})
        -- Record that this path is live in TMB so the media_status_changed
        -- listener can skip reloads for paths we never sent to the decoder.
        self._active_media_paths[entry.media_path] = true
        -- Snapshot source range for the renderer so it can compose
        -- per-clip partial-coverage frames without hitting the DB. Only
        -- video clips need this — audio clips don't compose an offline
        -- frame on the render path.
        if track_type == "video" then
            self._clip_info_by_id[clip.clip_id] = {
                source_in  = entry.source_in,
                source_out = entry.source_out,
            }
        end

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

    -- Stale callback: C++ reportPosition uses dispatch_async, so callbacks
    -- arrive after Lua has already transitioned to stopped (via engine:stop()).
    -- Both play-tick callbacks (stopped=false) and the final Stop callback
    -- (stopped=true) can arrive after seek() has set _position to a new value.
    -- Overwriting _position here would cause stepping to jump backwards.
    if self.state == "stopped" then
        log.detail("_on_controller_position: stale callback frame=%d stopped=%s (state=stopped) — ignored",
            frame, tostring(stopped))
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
        local hit_start = (self.direction < 0 and frame <= self.start_frame)
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


--- True when `path` belongs to a clip that has been fed to TMB via
--- _provide_clips. media_status_changed handler uses this to skip the
--- expensive reload for paths that don't intersect our clip list —
--- the startup bg probe flips hundreds of paths that belong to other
--- sequences or aren't referenced at all.
---
--- Empty active set = TMB has received no clips yet; don't filter in
--- that case (first clip build will pick up the current status via
--- media_status.get, so we don't strictly need the reload, but also
--- it's a no-op on empty tracks — cheap).
function PlaybackEngine:_path_is_active_in_tmb(path)
    assert(type(path) == "string" and path ~= "", string.format(
        "PlaybackEngine:_path_is_active_in_tmb: path must be non-empty string, got %s",
        type(path)))
    local active = self._active_media_paths
    if not active or next(active) == nil then return true end
    return active[path] == true
end

--- Build a TMB clip table from a sequence entry (get_video_at/get_audio_at result).
-- @param entry table: {media_path, clip, track, ...}
-- @param speed_ratio number: conform ratio (1.0 for video, seq_fps/media_fps for audio)
-- @return table matching TMB_SET_TRACK_CLIPS format
function PlaybackEngine:_build_tmb_clip(entry, speed_ratio)
    assert(type(entry) == "table", string.format(
        "PlaybackEngine:_build_tmb_clip: entry must be table, got %s", type(entry)))
    assert(type(entry.media_path) == "string" and entry.media_path ~= "",
        "PlaybackEngine:_build_tmb_clip: entry.media_path must be non-empty string")
    assert(type(entry.fps_numerator) == "number"
        and type(entry.fps_denominator) == "number"
        and entry.fps_denominator > 0, string.format(
        "PlaybackEngine:_build_tmb_clip: clip %s missing fps_numerator / fps_denominator",
        tostring(entry.clip_id)))
    assert(type(speed_ratio) == "number" and speed_ratio ~= 0 and math.abs(speed_ratio) < 100, string.format(
        "PlaybackEngine:_build_tmb_clip: clip %s speed_ratio must be non-zero (|sr|<100), got %s",
        tostring(entry.clip_id), tostring(speed_ratio)))

    -- Resolve offline state from media_status — single source of truth.
    -- Was a direct io.open check here; that created two sources of
    -- truth for offline (this ad-hoc stat vs. the media_status cache
    -- bg probe + FS watcher maintain) and meant ClipInfo.offline
    -- could disagree with what the browser icon / timeline label
    -- displayed. If the path isn't registered yet (first clip build
    -- during sequence load, before bg probe lands), fall back to a
    -- one-shot stat so we don't default a legitimately-online clip
    -- to beeping on startup.
    local cached = media_status.get(entry.media_path)
    local is_offline
    if cached then
        is_offline = cached.offline
    else
        local f = io.open(entry.media_path, "r")
        is_offline = (f == nil)
        if f then f:close() end
    end

    return {
        clip_id        = entry.clip_id,
        media_path     = entry.media_path,
        sequence_start = entry.sequence_start,
        duration       = entry.duration,
        source_in      = entry.source_in,
        rate_num       = entry.fps_numerator,
        rate_den       = entry.fps_denominator,
        speed_ratio    = speed_ratio,
        offline        = is_offline,
        volume         = entry.volume,
    }
end

--- Compute video speed_ratio from clip's source range vs timeline duration.
-- When source_out - source_in == duration, speed is 1.0 (no change).
-- Otherwise, speed = source_range / sequence_duration (< 1.0 = slow motion).
function PlaybackEngine:_compute_video_speed_ratio(entry)
    assert(entry.source_out ~= nil,
        "_compute_video_speed_ratio: source_out is nil (clip_id="
        .. tostring(entry.clip_id) .. ")")
    assert(entry.source_in ~= nil,
        "_compute_video_speed_ratio: source_in is nil (clip_id="
        .. tostring(entry.clip_id) .. ")")
    assert(entry.duration ~= nil,
        "_compute_video_speed_ratio: duration is nil (clip_id="
        .. tostring(entry.clip_id) .. ")")
    -- source_range is signed: positive = forward, negative = reverse
    local source_range = entry.source_out - entry.source_in
    assert(source_range ~= 0, string.format(
        "_compute_video_speed_ratio: source_range must be non-zero, got %d "
        .. "(clip_id=%s, source_out=%d, source_in=%d)",
        source_range, tostring(entry.clip_id),
        entry.source_out, entry.source_in))
    assert(entry.duration > 0, string.format(
        "_compute_video_speed_ratio: duration must be positive, got %d "
        .. "(clip_id=%s)", entry.duration, tostring(entry.clip_id)))
    local ratio = source_range / entry.duration
    assert(math.abs(ratio) > 0 and math.abs(ratio) < 100, string.format(
        "_compute_video_speed_ratio: ratio out of sane range: %.4f "
        .. "(clip_id=%s, source_range=%d, duration=%d)",
        ratio, tostring(entry.clip_id), source_range, entry.duration))
    if math.abs(ratio - 1.0) < 0.001 then return 1.0 end
    if math.abs(ratio + 1.0) < 0.001 then return -1.0 end
    return ratio
end

--- Compute audio conform speed_ratio: seq_fps / media_video_fps.
-- When media_video_fps >= 1000 (audio-only) or matches seq_fps, returns 1.0.
function PlaybackEngine:_compute_audio_speed_ratio(entry)
    assert(type(entry.fps_numerator) == "number", string.format(
        "PlaybackEngine:_compute_audio_speed_ratio: missing fps_numerator (got %s)",
        type(entry.fps_numerator)))
    assert(type(entry.fps_denominator) == "number" and entry.fps_denominator > 0,
        string.format(
        "PlaybackEngine:_compute_audio_speed_ratio: invalid fps_denominator=%s",
        tostring(entry.fps_denominator)))
    local media_video_fps = entry.fps_numerator / entry.fps_denominator
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

--- Seek to specific frame.
--- Pull frame from Renderer and display via View callbacks.
-- Shared by seek (park mode) and _on_clip_transition (playback offline).
-- Renderer handles online/offline/gap routing through offline_frame_cache.
function PlaybackEngine:_display_frame_from_renderer(frame)
    assert(self._tmb, "PlaybackEngine:_display_frame_from_renderer: no TMB")

    local frame_handle, metadata = Renderer.get_video_frame(
        self._tmb, self._effective_video_track_indices, frame, self._clip_info_by_id)

    if frame_handle then
        self:_apply_rotation_par(metadata)
        self._on_show_frame(frame_handle, metadata)
    else
        self._on_show_gap()
    end
end

function PlaybackEngine:seek(frame_idx)
    assert(frame_idx, "PlaybackEngine:seek: frame_idx is nil")
    assert(self.sequence, "PlaybackEngine:seek: no sequence loaded")
    assert(self.fps_num and self.fps_den,
        "PlaybackEngine:seek: fps not set (call load_sequence first)")

    local frame = math.floor(frame_idx)
    -- Mirror the C++ Park assertion (`frame >= m_start_frame`) one layer
    -- up with Lua-side context: role, loaded sequence id, attempted frame,
    -- required start_frame. Without this, a bad caller (deferred timer
    -- that captured a stale playhead, or any path that hands seek() a
    -- pre-clamp value) crashes deep in C++ where the actionable info is
    -- absent. The previous `frame_idx >= 0` gate let frame=0 through for
    -- sequences with TC origin > 0 (TSO 2026-05-17).
    assert(frame >= self.start_frame, string.format(
        "PlaybackEngine[%s]:seek: frame=%d is below start_frame=%d "
        .. "(loaded_sequence_id=%s) — bad caller passed a frame "
        .. "outside the sequence's content range",
        tostring(self.role), frame, self.start_frame,
        tostring(self.loaded_sequence_id)))

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
-- Audio Ownership (017)
--
-- The legacy activate_audio()/deactivate_audio() public methods are GONE.
-- Ownership is now structural: audio_playback._owning_engine identifies the
-- single owner; engines query `audio_playback.is_owner(self)`. The private
-- helpers below handle C++ binding wiring + per-engine signal subscriptions,
-- but the high-level handover (halt prior owner, acquire device) is the
-- contract of audio_playback.halt_current / audio_playback.acquire_for.
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
    if self._media_content_changed_conn then
        Signals.disconnect(self._media_content_changed_conn)
        self._media_content_changed_conn = nil
    end
    if self._media_status_changed_conn then
        Signals.disconnect(self._media_status_changed_conn)
        self._media_status_changed_conn = nil
    end
    if self._track_preference_conn then
        Signals.disconnect(self._track_preference_conn)
        self._track_preference_conn = nil
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
    log.event("_push_all_audio_mix_params: %d tracks", #mix_params)
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

--- Per-engine teardown: stop and close this engine's PlaybackController
--- and reset transport state. Called by transport (the resource
--- orchestrator) once per role-bound engine on project_changed.
function PlaybackEngine.teardown_engine(engine)
    assert(engine ~= nil, "PlaybackEngine.teardown_engine: engine is nil")
    if engine._playback_controller then
        -- pcall both C++ calls so a failure in STOP doesn't skip CLOSE
        -- (we want the controller closed and the ref nilled regardless).
        -- NSF: surface failures via log.warn rather than silently absorb
        -- — a STOP/CLOSE error during project-change cleanup is
        -- actionable diagnostic information, not noise to discard.
        local stop_ok, stop_err = pcall(
            qt_constants.PLAYBACK.STOP, engine._playback_controller)
        if not stop_ok then
            log.warn("teardown_engine: PLAYBACK.STOP failed for role=%s: %s",
                tostring(engine.role), tostring(stop_err))
        end
        local close_ok, close_err = pcall(
            qt_constants.PLAYBACK.CLOSE, engine._playback_controller)
        if not close_ok then
            log.warn("teardown_engine: PLAYBACK.CLOSE failed for role=%s: %s",
                tostring(engine.role), tostring(close_err))
        end
        engine._playback_controller = nil
    end
    engine.state = "stopped"
    engine.direction = 0
    engine.speed = 1
    engine._last_committed_frame = nil
end

return PlaybackEngine
