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
local tmb_clip_builder = require("core.playback.tmb_clip_builder")
local view_grade_pull = require("core.view_grade_pull")

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
    -- Mirror the reassignment into extension modules so methods defined
    -- there see the same audio handle.
    require("core.playback.playback_engine_audio").set_audio(ap)
    require("core.playback.playback_engine_transport").set_audio(ap)
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

    -- 017: role is immutable across the engine's lifetime; survives teardown.
    self.role = role

    -- View callbacks (set once at construction; survive teardown). When
    -- config is nil, the engine is headless: callbacks are no-ops. This
    -- is the production transport.init path; views attach via
    -- attach_view() or via the frame_delivered signal.
    local noop = function() end
    self._on_show_frame       = config and config.on_show_frame       or noop
    self._on_show_gap         = config and config.on_show_gap         or noop
    self._on_set_rotation     = config and config.on_set_rotation     or noop
    self._on_set_par          = config and config.on_set_par          or noop
    self._on_position_changed = config and config.on_position_changed or noop

    -- Video surface is bound externally via set_surface() and persists
    -- across teardown — the C++ widget outlives the engine's loaded state.
    self._video_surface = nil

    -- All other fields represent the unloaded-engine snapshot;
    -- teardown_engine resets them via the same helper.
    PlaybackEngine._init_unloaded_state(self)

    return self
end

--- Initialize the fields that describe an unloaded engine. Called by
--- PlaybackEngine.new for the initial state and by teardown_engine to
--- return a loaded engine to that same state. The fields NOT touched
--- here (role, view callbacks, video surface) persist across teardown.
function PlaybackEngine._init_unloaded_state(self)
    -- Sequence binding
    self.loaded_sequence_id = nil
    self.sequence = nil
    self._log_tag = self.role .. ":unloaded"
    self.current_clip_id = nil
    self.current_audio_clip_ids = {}
    self.fps_num = nil
    self.fps_den = nil
    self.fps = nil  -- fps_num/fps_den, for interval computation only
    self.audio_sample_rate = nil

    -- Transport state
    self.state = "stopped"
    self.direction = 0
    self.speed = 1
    self._position = 0
    self.start_frame = 0
    self.total_frames = 0
    self.max_media_time_us = 0
    self.transport_mode = "none"
    self.latched = false
    self.latched_boundary = nil

    -- Seek dedup + writeback throttle
    self._last_committed_frame = nil
    self._writeback_throttle_last_s = nil

    -- TMB (TimelineMediaBuffer) — owns video readers, cache, pre-buffer.
    -- Lua-side field; teardown_engine separately calls _close_tmb() to
    -- release the C++ object before nilling.
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

    -- PlaybackController (C++ CVDisplayLink-driven playback). Lua-side
    -- field; teardown_engine separately calls PLAYBACK.STOP + .CLOSE on
    -- the prior controller before nilling.
    self._playback_controller = nil
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
    -- Reset the seek-dedup guard. Without this, a stale value from a
    -- previous sequence (e.g. 45 from the master before we loaded a
    -- different one) makes the next seek(45) early-return at line
    -- ~1004 (`frame == self._last_committed_frame`) — set_position_silent
    -- is skipped and _position stays at start_frame instead of moving
    -- to the requested frame. Repro 2026-05-22: Shift+F lands engine at
    -- 0 instead of clip.source_in when source_viewer.load_clip's
    -- seek_to_frame(clip.source_in) collides with a stale dedup value.
    self._last_committed_frame = nil

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
    if type(Sequence.update_playhead) ~= "function" then return end  -- lint-allow: R004 legacy-test stub gate; production carries real Model
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
    self._tmb = EMP.TMB_CREATE()  -- hardware-adaptive: clamp(cores-2, 3, 16)
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
    -- Push the visible-track set to the C++ compositor so mute/solo takes effect
    -- during playback (deliverFrame composites from this; prefetch keeps every
    -- track decoded so unmute is instant). Park mode re-renders via the Lua
    -- renderer separately. Mirrors the Lua renderer's effective-index list.
    if self._playback_controller then
        qt_constants.PLAYBACK.SET_EFFECTIVE_VIDEO_TRACKS(
            self._playback_controller, self._effective_video_track_indices)
    end
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
    -- Spec 023 FR-016 (playback path): the per-clip CDL/LUT snapshots
    -- pushed into the controller are keyed by clip_id; on a clip-set
    -- reload the controller's TMB clip list is also cleared, so the
    -- snapshots must follow or stale entries would survive a blade /
    -- delete / re-edit that re-keys identity.
    if self._playback_controller then
        qt_constants.PLAYBACK.CLEAR_CLIP_GRADES(self._playback_controller)
    end
end

--- Public: invalidate clip cache + re-feed TMB after timeline edits.
-- Called by views (sequence_monitor) on content_changed — encapsulates all
-- internal cache invalidation so views never touch engine privates.
function PlaybackEngine:notify_content_changed()
    self:_refresh_content_bounds()
    -- Signal-driven entry: unloaded engine has no TMB/controller to reload.
    -- Per the lifecycle invariant, `loaded_sequence_id == nil` iff
    -- `_playback_controller == nil`.
    if self.loaded_sequence_id == nil then return end
    self:_reset_clip_snapshots()
    qt_constants.PLAYBACK.RELOAD_ALL_CLIPS(self._playback_controller)
    self._video_track_indices = self.sequence:get_track_indices("VIDEO")
    table.sort(self._video_track_indices, function(a, b) return a > b end)
    self._audio_track_indices = self.sequence:get_track_indices("AUDIO")
    self:_refresh_video_track_states()
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
    rewire("_grades_changed_conn",         "grades_changed",
           "_on_grades_changed_signal")

    log.event("PlaybackController created and configured")
end

-- Per-kind dispatch for _provide_clips. Video and audio walk the same
-- loop body — the asymmetries (which sequence accessor, audio's reverse-
-- clip sign flip, video-only renderer snapshot, opposite track-index
-- sort) live here so the loop body stays branch-free.
local TRACK_KIND_DISPATCH = {
    video = {
        get_entries    = function(seq, from, to) return seq:get_video_in_range(from, to) end,
        compute_speed  = function(engine, entry) return engine:_compute_video_speed_ratio(entry) end,
        snapshot_clip  = true,
        indices_field  = "_video_track_indices",
        index_sort_cmp = function(a, b) return a > b end,   -- video tracks: higher index = lower layer
    },
    audio = {
        get_entries    = function(seq, from, to) return seq:get_audio_in_range(from, to) end,
        -- Audio conform ratio is always positive (seq_fps / media_fps).
        -- Multiply by retime direction: -1 for reverse clips (source_in > source_out).
        compute_speed  = function(engine, entry)
            local s = engine:_compute_audio_speed_ratio(entry)
            if entry.source_in and entry.source_out
                and entry.source_out < entry.source_in then
                s = -s
            end
            return s
        end,
        snapshot_clip  = false,
        indices_field  = "_audio_track_indices",
        index_sort_cmp = function(a, b) return a < b end,
    },
}

-- Add track_idx to indices array if not already present; keep sorted.
local function register_track_index(indices, track_idx, sort_cmp)
    for _, idx in ipairs(indices) do
        if idx == track_idx then return end
    end
    indices[#indices + 1] = track_idx
    table.sort(indices, sort_cmp)
end

--- Clip provider callback: C++ requests clips for a range.
-- Queries DB for clips in [from, to), converts to TMB format, adds via TMB_ADD_CLIPS.
function PlaybackEngine:_provide_clips(from, to, track_type)
    assert(type(from) == "number", string.format(
        "PlaybackEngine:_provide_clips: from must be number, got %s", type(from)))
    assert(type(to) == "number", string.format(
        "PlaybackEngine:_provide_clips: to must be number, got %s", type(to)))
    local dispatch = TRACK_KIND_DISPATCH[track_type]
    assert(dispatch, string.format(
        "PlaybackEngine:_provide_clips: track_type must be 'video' or 'audio', got %s",
        tostring(track_type)))

    local entries = dispatch.get_entries(self.sequence, from, to)
    local indices = self[dispatch.indices_field]
    local EMP = qt_constants.EMP

    -- Long-standing diagnostic at ticks:detail. When "video shows gap but
    -- F-key finds a clip there" recurs (or its audio twin), this reveals
    -- whether the Lua model returned the clip and TMB rejected it, or
    -- whether the model itself never surfaced the clip for this range.
    -- Entry shape (set by filter_and_finalize in sequence.lua:891): every
    -- field below is contract-stable — track_index, sequence_start,
    -- duration, clip_id, media_path. log.detail short-circuits internally
    -- when ticks:detail is off (one FFI predicate).
    log.detail("_provide_clips %s [%d..%d) returned %d entries",
        track_type, from, to, #entries)
    for _, entry in ipairs(entries) do
        log.detail("  entry: track=%d start=%d dur=%d clip=%s path=%s",
            entry.track_index, entry.sequence_start, entry.duration,
            tostring(entry.clip_id), tostring(entry.media_path))
    end

    for _, entry in ipairs(entries) do
        local speed = dispatch.compute_speed(self, entry)
        local clip = self:_build_tmb_clip(entry, speed)
        EMP.TMB_ADD_CLIPS(self._tmb, track_type, entry.track_index, {clip})
        -- Record that this path is live in TMB so the media_status_changed
        -- listener can skip reloads for paths we never sent to the decoder.
        self._active_media_paths[entry.media_path] = true
        -- Snapshot source range for the renderer so it can compose per-clip
        -- partial-coverage frames without hitting the DB. Video-only —
        -- audio clips don't compose an offline frame on the render path.
        if dispatch.snapshot_clip then
            self._clip_info_by_id[clip.clip_id] = {
                source_in  = entry.source_in,
                source_out = entry.source_out,
            }
            -- Spec 023 FR-016 (playback path): project the per-clip CDL/LUT
            -- into the C++ controller so deliverFrame applies it on the
            -- clip-boundary transition. Video-only — audio has no surface.
            self:_push_clip_grade_snapshot(clip.clip_id)
        end
        register_track_index(indices, entry.track_index, dispatch.index_sort_cmp)
    end
end

--- Project the per-clip display grade (CDL + LUT) into the C++
--- PlaybackController so deliverFrame applies it synchronously at each
--- clip-boundary transition (spec 023 FR-016 playback path).
---
--- The View's per-show-frame pull (SequenceMonitor:_on_show_frame) only
--- fires in park mode. During playback the C++ deliverFrame pushes frames
--- directly to the surface with no Lua roundtrip; without this snapshot
--- the surface would keep the previously-set CDL across clip boundaries.
---
--- Pulled fresh every call — no Lua-side grade cache (the per-clip indexed
--- SELECT is dwarfed by decode cost; see view_grade_pull header).
function PlaybackEngine:_push_clip_grade_snapshot(clip_id)
    assert(type(clip_id) == "string" and clip_id ~= "",
        "PlaybackEngine:_push_clip_grade_snapshot: clip_id required")
    assert(self._playback_controller,
        "PlaybackEngine:_push_clip_grade_snapshot: called without a playback controller")
    local stages = view_grade_pull.pull_for_clip(clip_id)
    local cdl     = stages and stages.cdl
    local lut_ref = stages and stages.lut_ref
    qt_constants.PLAYBACK.SET_CLIP_GRADE(
        self._playback_controller, clip_id, cdl, lut_ref)
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
        -- Position reports are coalesced and dispatched async to the main
        -- queue (reportPosition's dispatch_async): a report queued by a
        -- Stop can drain AFTER a subsequent Play in the same runloop turn
        -- (fast J-K-L, scripted stop+play). The report's `stopped` flag is
        -- a snapshot from queue time — re-check the controller's CURRENT
        -- truth at delivery and drop the stale report if it is playing
        -- again. A report draining after the controller is already gone
        -- (teardown) has nothing to re-check; for that case "stopped" is
        -- the truth — fall through.
        if self._playback_controller
            and qt_constants.PLAYBACK.IS_PLAYING(self._playback_controller) then
            log.event("_on_controller_position: stale stopped report "
                .. "(frame=%d) dropped — controller is playing again", frame)
            return
        end
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

--- Build a TMB ClipInfo row from a resolver entry. Thin delegate to
-- core.playback.tmb_clip_builder.build_clip (pure helper, extracted for
-- 2.6 file-size + 2.21 testability). speed_ratio is computed by the
-- _compute_*_speed_ratio methods below from the same entry.
function PlaybackEngine:_build_tmb_clip(entry, speed_ratio)
    return tmb_clip_builder.build_clip(entry, speed_ratio)
end

--- Compute video speed_ratio from clip's source range vs timeline duration.
-- Thin delegate to tmb_clip_builder.compute_video_speed_ratio.
function PlaybackEngine:_compute_video_speed_ratio(entry)
    return tmb_clip_builder.compute_video_speed_ratio(entry)
end

--- Compute audio conform speed_ratio: seq_fps / media_video_fps. Thin
-- delegate to tmb_clip_builder.compute_audio_speed_ratio; seq fps is
-- passed explicitly (statically-verifiable arg vs. implicit self capture).
function PlaybackEngine:_compute_audio_speed_ratio(entry)
    return tmb_clip_builder.compute_audio_speed_ratio(entry, self.fps_num, self.fps_den)
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
    -- Signal-driven entry: content_changed broadcasts to all engines.
    -- An unloaded engine has no sequence to re-seek into; documented no-op
    -- (mirrors notify_content_changed). Per the lifecycle invariant,
    -- `loaded_sequence_id == nil` iff `_playback_controller == nil`.
    if self.loaded_sequence_id == nil then return end
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
    -- Show the quarter-step ladder rungs (1.25x/1.75x) faithfully without
    -- padding the whole/half speeds: format to 2 decimals, then trim a
    -- single trailing zero so "1.00"→"1.0", "1.50"→"1.5", "1.25"→"1.25".
    local speed_str = string.format("%.2f", self.speed):gsub("0$", "")
    return string.format("%s %sx", dir_str, speed_str)
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

--- Disconnect all signal handlers wired by `_setup_playback_controller`
--- + the track-mix handler installed at construction. Idempotent: each
--- conn field is nilled after disconnect, so subsequent calls are no-ops.
--- Called from both `destroy` (app shutdown) and `teardown_engine`
--- (project switch) — both must shed handlers or stale signals will
--- fire on an unloaded engine between teardown and the next load_sequence.
local function disconnect_signal_handlers(self)
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
    if self._grades_changed_conn then
        Signals.disconnect(self._grades_changed_conn)
        self._grades_changed_conn = nil
    end
end

--- Destroy engine: close TMB + PlaybackController + stop audio.
function PlaybackEngine:destroy()
    disconnect_signal_handlers(self)
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


--- Per-engine teardown: stop and close this engine's PlaybackController
--- and TMB, and return the engine to the same state as a
--- freshly-constructed one (sequence binding + transport state cleared
--- via _init_unloaded_state). Called by transport on project_changed.
---
--- Invariant: `loaded_sequence_id ~= nil` ⟺ `_playback_controller ~= nil`.
--- Both fields are set together in `load_sequence` and cleared together
--- here. Callers that ask "is this engine bound to a sequence?" check
--- `loaded_sequence_id`; the controller is an internal C++ object and
--- not consulted at the public boundary.
function PlaybackEngine.teardown_engine(engine)
    assert(engine ~= nil, "PlaybackEngine.teardown_engine: engine is nil")

    -- Shed signal handlers so stale signals (content_changed, media_*,
    -- track_preference_changed, track_mix, grades_changed) don't fire on
    -- this engine between teardown and the next load_sequence — and don't
    -- leak if no new sequence loads at all (e.g. close-all-projects flow).
    disconnect_signal_handlers(engine)

    -- Release C++ objects (PlaybackController, TMB) before nilling the
    -- Lua-side fields in _init_unloaded_state. pcall the controller's
    -- STOP/CLOSE so a STOP failure doesn't skip CLOSE — we want the C++
    -- object closed and the Lua ref nilled regardless. NSF: surface
    -- failures via log.warn (actionable diagnostic), not silently absorb.
    if engine._playback_controller then
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
    end
    engine:_close_tmb()

    PlaybackEngine._init_unloaded_state(engine)
end

-- Install the audio-session lifecycle, audio-mix push, boundary latch,
-- and frame-step audio methods onto PlaybackEngine. These methods are
-- defined in playback_engine_audio.lua but live on this class — moved
-- there purely for file-size (2.6) without changing the method surface.
require("core.playback.playback_engine_audio").install(PlaybackEngine)

-- Install signal-handler methods for track preferences, content edits,
-- in-place media rewrites, and offline/online file-status flips. Defined
-- in playback_engine_signals.lua (extracted for 2.6).
require("core.playback.playback_engine_signals").install(PlaybackEngine)

-- Install the transport state machine (shuttle, slow_play, play, stop).
-- Defined in playback_engine_transport.lua (extracted for 2.6).
require("core.playback.playback_engine_transport").install(PlaybackEngine)

return PlaybackEngine
