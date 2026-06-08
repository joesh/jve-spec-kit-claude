--- SequenceMonitor: a video monitor that displays any sequence (masterclip or timeline).
--
-- Each instance owns:
-- - A PlaybackEngine for transport control
-- - A GPUVideoSurface for video frame display
-- - A mark bar for mark in/out range + playhead visualization
-- - A title label
--
-- Absorbs widget creation from viewer_panel.lua and playhead/mark state
-- management from source_viewer_state.lua. SequenceMonitor treats all sequence
-- kinds uniformly — masterclips and timelines use identical code paths.
--
-- Masterclip-specific behavior:
-- - Playhead persisted to DB via sequence record (debounced)
-- - Marks read/write via sequence record (get_in/get_out)
--
-- @file sequence_monitor.lua

local log = require("core.logger").for_area("video")
local qt_constants = require("core.qt_constants")
local Sequence = require("models.sequence")
local monitor_mark_bar = require("ui.monitor_mark_bar")
local database = require("core.database")
local project_gen = require("core.project_generation")
local view_grade_pull = require("core.view_grade_pull")

local Signals = require("core.signals")
local timecode = require("core.timecode")

local SequenceMonitor = {}
SequenceMonitor.__index = SequenceMonitor

-- Debounce interval for playhead persistence (ms)
local DEBOUNCE_MS = 200

--------------------------------------------------------------------------------
-- Constructor
--------------------------------------------------------------------------------

-- 017: map of view_id → role for monitors that don't explicitly carry one.
-- source-side widgets (top-left viewer + the timeline-panel source tab)
-- observe the source engine; everything else observes the record engine.
local VIEW_ID_TO_ROLE = {
    source_monitor   = "source",
    source_tab       = "source",
    timeline_monitor = "record",
    timeline         = "record",
}

--- Attach this view to `engine`: install the view's callback table onto the
--- engine's _on_* fields so engine ticks render here, and wire the surface
--- if one has been created. Used by the constructor (when transport is
--- already bootstrapped) AND by the transport_ready listener (the first-
--- time bind, when monitors were constructed before transport.init ran).
--- Requires self._cb_table to be set first.
local function bind_to_engine(self, engine)
    assert(engine ~= nil, "SequenceMonitor:bind_to_engine: engine is nil")
    assert(self._cb_table, "SequenceMonitor:bind_to_engine: _cb_table must be "
        .. "built before binding (constructor populates it)")
    assert(type(engine.set_surface) == "function", string.format(
        "SequenceMonitor:bind_to_engine: engine %s lacks set_surface method "
        .. "— real PlaybackEngine and test stubs must implement it",
        tostring(engine)))
    self.engine = engine
    engine._on_show_frame       = self._cb_table.on_show_frame
    engine._on_show_gap         = self._cb_table.on_show_gap
    engine._on_set_rotation     = self._cb_table.on_set_rotation
    engine._on_set_par          = self._cb_table.on_set_par
    engine._on_position_changed = self._cb_table.on_position_changed
    -- Surface may not exist yet on the bootstrapped-constructor path
    -- (widget creation runs after the constructor's engine bind);
    -- _create_widgets re-attaches once the surface is built. On the
    -- transport_ready path widgets exist already so this branch fires.
    if self._video_surface then
        engine:set_surface(self._video_surface)
    end
end

--- Create a new SequenceMonitor instance.
-- @param config table:
--   view_id  string  unique identifier (e.g. "source_monitor", "timeline_monitor")
--   role     string|nil  "source"|"record" (017). When nil, derived from view_id.
function SequenceMonitor.new(config)
    assert(type(config) == "table",
        "SequenceMonitor.new: config table required")
    assert(config.view_id and config.view_id ~= "",
        "SequenceMonitor.new: view_id required")

    local self = setmetatable({}, SequenceMonitor)

    self:_init_state(config)

    -- Create widgets. config.headless = true skips Qt widget construction
    -- for unit tests that exercise the view-state surface (bound_engine,
    -- cached_frame_for, etc.) without bootstrapping the full editor UI.
    if config.headless ~= true then
        self:_create_widgets()
    end

    self:_wire_signals()

    return self
end

function SequenceMonitor:_init_state(config)
    self.view_id = config.view_id

    -- 017: role binds this view to a specific engine. Explicit config.role
    -- wins; otherwise derive from view_id via VIEW_ID_TO_ROLE. Unknown
    -- view_ids (legacy unit tests using ad-hoc names) default to "record"
    -- so their construction doesn't break; production code paths always
    -- pass a recognized view_id or an explicit role.
    if config.role ~= nil then
        assert(config.role == "source" or config.role == "record", string.format(
            "SequenceMonitor.new: role must be 'source'|'record', got %s",
            tostring(config.role)))
        self.role = config.role
    else
        self.role = VIEW_ID_TO_ROLE[config.view_id] or "record"
    end

    -- 017: per-view frame cache, keyed by sequence_id, for FR-016 view-glass
    -- behavior. cleared on widget destroy.
    self._cached_frames = {}

    -- Sequence state
    self.sequence_id = nil
    self.sequence = nil       -- Sequence model (for marks on masterclips)
    self.start_frame = 0      -- absolute TC start (from sequence.start_timecode_frame)
    self.total_frames = 0     -- absolute TC end (exclusive)
    self.playhead = 0
    self.fps_num = nil
    self.fps_den = nil

    -- Mark bar viewport (ephemeral, resets on load_sequence)
    self.viewport_start = 0
    self.viewport_duration = 0

    -- Listener pattern (for mark bar redraws)
    self._listeners = {}

    -- Debounced playhead persistence
    self._persist_generation = 0
    self._project_gen = project_gen.current()

    -- Frame mirror: secondary GPUVideoSurface that receives the same frames
    self._frame_mirror = nil

    -- 017 resource model: engines are role-bound singletons owned by
    -- core.playback.transport. Views are pure glass — they observe whichever
    -- canonical engine matches their role.
    local transport = require("core.playback.transport")
    
    self._cb_table = {
        on_show_frame       = function(fh, meta) self:_on_show_frame(fh, meta) end,
        on_show_gap         = function()         self:_on_show_gap() end,
        on_set_rotation     = function(deg)      self:_on_set_rotation(deg) end,
        on_set_par          = function(num, den) self:_on_set_par(num, den) end,
        on_position_changed = function(frame)    self:_on_position_changed(frame) end,
    }
    if transport.is_bootstrapped() then
        bind_to_engine(self, transport.engine_for_role(self.role))
    else
        -- Pre-transport: engine stays nil. transport_ready listener binds
        -- the canonical role engine when transport.init runs.
        self.engine = nil
    end
end

function SequenceMonitor:_wire_signals()
    -- Re-read marks from model when mark commands execute
    self._marks_changed_id = Signals.connect("marks_changed", function(sequence_id)
        if self.sequence and self.sequence_id == sequence_id then
            local fresh = Sequence.load(sequence_id)
            assert(fresh, string.format(
                "SequenceMonitor:marks_changed: Sequence.load(%s) returned nil",
                tostring(sequence_id)))
            self.sequence.mark_in = fresh.mark_in
            self.sequence.mark_out = fresh.mark_out
            self:_notify()
        end
    end)

    -- Seek when SetPlayhead command targets this sequence.
    -- Skip if playhead hasn't moved — flush_state_to_db re-persists the current
    -- position which emits playhead_changed; seeking on that would stop playback.
    self._playhead_changed_id = Signals.connect("playhead_changed", function(sequence_id, frame)
        if self.sequence_id == sequence_id and type(frame) == "number"
           and frame ~= self.playhead then
            self:seek_to_frame(frame)
        end
    end)

    -- Refresh content bounds when clips change (insert, delete, undo, redo)
    -- Priority 110: run AFTER PlaybackEngine's own content_changed handler (100)
    -- so that self.engine.total_frames is already updated.
    self._content_changed_id = Signals.connect("content_changed", function(sequence_id)
        if self.sequence_id == sequence_id then
            self.total_frames = self.engine.total_frames
            -- Clamp viewport to new total_frames
            local physical = self.total_frames - self.start_frame
            if self.viewport_duration > physical then
                self.viewport_duration = physical
            end
            if self.viewport_start + self.viewport_duration > self.total_frames then
                self.viewport_start = math.max(self.start_frame, self.total_frames - self.viewport_duration)
            end
            -- MVC pull: re-read playhead from THIS sequence's row, not from
            -- timeline_state. timeline_state.playhead_position is a single
            -- global cursor for whichever tab is displayed; it does NOT
            -- track per-sequence. After a DRP import (or any background
            -- content_changed on a not-currently-displayed sequence), the
            -- global cursor can hold a stale value from a different
            -- sequence — seeking the engine to it then trips the
            -- start-boundary assert (TSO 2026-05-20: frame=116 below
            -- start_frame=89750 after DRP import).
            local seq = require('models.sequence').load(sequence_id)
            assert(seq, string.format(
                "SequenceMonitor.content_changed: sequence %s not found", sequence_id))
            local model_playhead = seq.playhead_position
            assert(type(model_playhead) == "number", string.format(
                "SequenceMonitor.content_changed: sequence %s missing playhead_position",
                sequence_id))
            if model_playhead ~= self.playhead then
                self.playhead = model_playhead
            end
            self:on_model_changed()
            self:_notify()
        end
    end, 110)

    -- Clear stale frame on project switch
    self._project_changed_id = Signals.connect("project_changed", function(_new_project_id)
        qt_constants.EMP.SURFACE_SET_FRAME(self._video_surface, nil)
        if self._frame_mirror then
            qt_constants.EMP.SURFACE_SET_FRAME(self._frame_mirror, nil)
        end
    end, 50)

    -- Bind to the role-bound transport engine once transport.init has
    -- constructed the singletons.
    self._transport_ready_id = Signals.connect("transport_ready", function()
        local canonical = require("core.playback.transport").engine_for_role(self.role)
        if canonical == self.engine then return end
        bind_to_engine(self, canonical)
    end, 60)

    -- SyncGradesFromResolve (spec 023 FR-016/FR-017) writes clip_grade
    -- rows out-of-band from any content/playhead change.
    self._grades_changed_id = Signals.connect("grades_changed", function(sequence_id)
        if self.sequence_id ~= sequence_id then return end
        self:on_model_changed()
    end)

    -- Media file bytes changed (in-place rewrite) OR status flipped
    -- Priority 110: PlaybackEngine's subscribers run at default 100 —
    -- we MUST fire after them.
    local function on_media_event(path) self:_on_media_event(path) end
    self._media_status_changed_id =
        Signals.connect("media_status_changed", on_media_event, 110)
    self._media_content_changed_id =
        Signals.connect("media_content_changed", on_media_event, 110)
end

--- True when at least one clip at the current playhead references
--- `media_path`. Used to filter media_status_changed / content_changed
--- refreshes — bg probe can fire hundreds of flips per second at
--- startup, but only flips that touch the displayed frame need a
--- re-pull.
--------------------------------------------------------------------------------
-- 017: Public view-glass surface (FR-015, FR-016).
--
-- bound_engine()           → the engine this view observes (role-bound).
-- cached_frame_for(seq_id) → the last frame this view received for seq_id,
--                            preserved across engine rebind so a parked
--                            view continues to show its content.
-- should_show_placeholder(seq_id) → true when no cached frame exists yet
--                            for seq_id on this view (case c).
-- _accept_frame / _on_engine_rebind are private hooks the engine layer
--   invokes to update the cache.
--------------------------------------------------------------------------------

function SequenceMonitor:bound_engine()
    return self.engine
end

function SequenceMonitor:cached_frame_for(sequence_id)
    if self._cached_frames == nil then return nil end
    local entry = self._cached_frames[sequence_id]
    if entry == nil then return nil end
    return entry.frame_handle
end

function SequenceMonitor:should_show_placeholder(sequence_id)
    return self:cached_frame_for(sequence_id) == nil
end

function SequenceMonitor:_accept_frame(frame_handle, metadata, sequence_id)
    assert(frame_handle ~= nil, "SequenceMonitor:_accept_frame: frame_handle required")
    assert(type(metadata) == "table", "SequenceMonitor:_accept_frame: metadata table required")
    assert(type(sequence_id) == "string" and sequence_id ~= "",
        "SequenceMonitor:_accept_frame: sequence_id required")
    if self._cached_frames == nil then self._cached_frames = {} end
    self._cached_frames[sequence_id] = {
        frame_handle = frame_handle,
        metadata = metadata,
    }
end

function SequenceMonitor:_on_engine_rebind(_new_sequence_id)
    -- Cache survives rebind by design (FR-016 case b). The new sequence's
    -- frame, when delivered, lands under its own key in _cached_frames.
end

function SequenceMonitor:_path_affects_current_frame(media_path)
    assert(type(media_path) == "string" and media_path ~= "", string.format(
        "SequenceMonitor:_path_affects_current_frame: media_path must be non-empty string, got %s",
        type(media_path)))
    if not self.sequence or not self.playhead then return false end
    for _, entry in ipairs(self.sequence:get_video_at(self.playhead)) do
        if entry.media_path == media_path then return true end
    end
    for _, entry in ipairs(self.sequence:get_audio_at(self.playhead)) do
        if entry.media_path == media_path then return true end
    end
    return false
end

--- Shared handler for media_status_changed and media_content_changed.
--- Priority-110 wiring in `new()` guarantees this fires AFTER
--- PlaybackEngine has invalidated TMB caches, so on_model_changed
--- pulls fresh decode output.
function SequenceMonitor:_on_media_event(media_path)
    assert(type(media_path) == "string" and media_path ~= "", string.format(
        "SequenceMonitor:_on_media_event: media_path must be non-empty string, got %s",
        type(media_path)))
    if self:_path_affects_current_frame(media_path) then
        self:on_model_changed()
    end
end

--------------------------------------------------------------------------------
-- Widget Creation (absorbed from viewer_panel.create)
--------------------------------------------------------------------------------

function SequenceMonitor:_create_widgets()
    self._container = qt_constants.WIDGET.CREATE()
    -- Opaque background prevents resize artifacts (transparent children leave ghost pixels)
    qt_constants.PROPERTIES.SET_STYLE(self._container, [[
        QWidget { background: #2b2b2b; }
    ]])
    local layout = qt_constants.LAYOUT.CREATE_VBOX()
    if qt_constants.LAYOUT.SET_SPACING then
        qt_constants.LAYOUT.SET_SPACING(layout, 0)
    end
    if qt_constants.LAYOUT.SET_MARGINS then
        qt_constants.LAYOUT.SET_MARGINS(layout, 0, 0, 0, 0)
    end

    -- Title label
    self._title_label = qt_constants.WIDGET.CREATE_LABEL(self.view_id)
    qt_constants.PROPERTIES.SET_STYLE(self._title_label, [[
        QLabel {
            background: #3a3a3a;
            color: white;
            padding: 4px;
            font-size: 12px;
        }
    ]])
    qt_constants.LAYOUT.ADD_WIDGET(layout, self._title_label)

    -- Content container (black background for video)
    local content = qt_constants.WIDGET.CREATE()
    if qt_constants.GEOMETRY and qt_constants.GEOMETRY.SET_SIZE_POLICY then
        qt_constants.GEOMETRY.SET_SIZE_POLICY(content, "Expanding", "Expanding")
    end
    if qt_constants.PROPERTIES and qt_constants.PROPERTIES.SET_STYLE then
        qt_constants.PROPERTIES.SET_STYLE(content, [[
            QWidget {
                background: #000000;
                border: 1px solid #1f1f1f;
            }
        ]])
    end

    local content_layout = qt_constants.LAYOUT.CREATE_VBOX()
    if qt_constants.LAYOUT.SET_MARGINS then
        qt_constants.LAYOUT.SET_MARGINS(content_layout, 0, 0, 0, 0)
    end
    if qt_constants.LAYOUT.SET_SPACING then
        qt_constants.LAYOUT.SET_SPACING(content_layout, 0)
    end

    -- GPU video surface
    assert(qt_constants.WIDGET.CREATE_GPU_VIDEO_SURFACE,
        "SequenceMonitor: CREATE_GPU_VIDEO_SURFACE not available")
    self._video_surface = qt_constants.WIDGET.CREATE_GPU_VIDEO_SURFACE()
    assert(self._video_surface,
        "SequenceMonitor: CREATE_GPU_VIDEO_SURFACE returned nil")

    -- Assert EMP bindings required by engine callbacks
    assert(qt_constants.EMP and qt_constants.EMP.SURFACE_SET_FRAME,
        "SequenceMonitor: EMP.SURFACE_SET_FRAME not available")
    assert(qt_constants.EMP.SURFACE_SET_ROTATION,
        "SequenceMonitor: EMP.SURFACE_SET_ROTATION not available")
    assert(qt_constants.EMP.SURFACE_SET_PAR,
        "SequenceMonitor: EMP.SURFACE_SET_PAR not available")
    assert(qt_constants.PROPERTIES and qt_constants.PROPERTIES.SET_TEXT,
        "SequenceMonitor: PROPERTIES.SET_TEXT not available")
    if qt_constants.GEOMETRY and qt_constants.GEOMETRY.SET_SIZE_POLICY then
        qt_constants.GEOMETRY.SET_SIZE_POLICY(
            self._video_surface, "Expanding", "Expanding")
    end
    qt_constants.LAYOUT.ADD_WIDGET(content_layout, self._video_surface)
    if qt_constants.LAYOUT.SET_STRETCH_FACTOR then
        qt_constants.LAYOUT.SET_STRETCH_FACTOR(
            content_layout, self._video_surface, 1)
    end

    -- Wire video surface to PlaybackEngine for C++ CVDisplayLink playback.
    -- 017: self.engine is nil during the pre-transport window (layout.lua
    -- constructs monitors at app launch, before transport.init runs).
    -- The transport_ready listener below re-runs set_surface on the
    -- canonical engine once it exists; the surface stays on
    -- self._video_surface in the meantime.
    if self.engine and self.engine.set_surface then
        self.engine:set_surface(self._video_surface)
    end

    -- MVC pull: when Metal backend becomes render-ready, pull current frame.
    -- Fixes startup race where engine:seek() fires before Metal is initialized,
    -- dropping the initial frame silently.
    if qt_constants.EMP.SURFACE_ON_READY then
        qt_constants.EMP.SURFACE_ON_READY(self._video_surface, function()
            self:on_model_changed()
        end)
    end

    -- MVC: surface error callback — view learns about render failures
    -- (unsupported pixel format, texture creation failure) instead of
    -- silently showing stale content.
    if qt_constants.EMP.SURFACE_ON_ERROR then
        qt_constants.EMP.SURFACE_ON_ERROR(self._video_surface, function(error_msg)
            log.warn("surface error: %s", error_msg)
            self._surface_error = error_msg
            self:_notify()
        end)
    end

    -- Timecode display row: playhead TC (left) + duration (right)
    -- Positioned between video surface and mark bar (above the scrub bar)
    self:_create_tc_row(content_layout)

    -- Mark bar (ScriptableTimeline widget)
    assert(qt_constants.WIDGET.CREATE_TIMELINE,
        "SequenceMonitor: CREATE_TIMELINE not available")
    local mark_bar_widget = qt_constants.WIDGET.CREATE_TIMELINE()
    assert(mark_bar_widget,
        "SequenceMonitor: CREATE_TIMELINE returned nil")
    qt_constants.CONTROL.SET_WIDGET_SIZE_POLICY(
        mark_bar_widget, "Expanding", "Fixed")
    timeline.set_desired_height(mark_bar_widget, monitor_mark_bar.BAR_HEIGHT)
    qt_constants.LAYOUT.ADD_WIDGET(content_layout, mark_bar_widget)

    self._mark_bar = monitor_mark_bar.create(mark_bar_widget, {
        state_provider  = self,
        has_clip        = function() return self:has_clip() end,
        get_mark_in     = function() return self:get_mark_in() end,
        get_mark_out    = function() return self:get_mark_out() end,
        on_seek         = function(frame) self:seek_to_frame(frame) end,
        on_listener     = function(fn) self:add_listener(fn) end,
        monitor_view_id = self.view_id,
    })
    assert(self._mark_bar, string.format(
        "SequenceMonitor(%s):_create_widgets: monitor_mark_bar.create returned nil",
        self.view_id))

    qt_constants.LAYOUT.SET_ON_WIDGET(content, content_layout)
    qt_constants.LAYOUT.ADD_WIDGET(layout, content)
    if qt_constants.LAYOUT.SET_STRETCH_FACTOR then
        qt_constants.LAYOUT.SET_STRETCH_FACTOR(layout, content, 1)
    end

    qt_constants.LAYOUT.SET_ON_WIDGET(self._container, layout)

    log.event("%s: widgets created", self.view_id)
end

--------------------------------------------------------------------------------
-- Sequence Loading
--------------------------------------------------------------------------------

--- Resolve the audio bus output rate to thread into PlaybackEngine for `seq`.
--
-- Delegates the actual resolution to `core.audio_bus_rate.pick_for_monitor`
-- (pure model-layer helper, fully unit-tested). This wrapper only injects
-- the timeline_state's active sequence id and the DB connection.
local audio_bus_rate = require("core.audio_bus_rate")
local function resolve_output_audio_rate(seq)
    local timeline_state = require("ui.timeline.timeline_state")
    return audio_bus_rate.pick_for_monitor(
        seq,
        timeline_state.get_active_sequence_id(),
        Sequence.load,
        Sequence.find_first_record_audio_rate)
end

--- Load a sequence (any kind: masterclip or timeline).
-- @param sequence_id string
-- @param opts table optional: { total_frames = number }
function SequenceMonitor:load_sequence(sequence_id, opts)
    assert(sequence_id and sequence_id ~= "", string.format(
        "SequenceMonitor(%s):load_sequence: sequence_id required, got %s",
        self.view_id, tostring(sequence_id)))

    self:_save_current_playhead(sequence_id)

    opts = opts or {}
    local seq = Sequence.load(sequence_id)
    assert(seq, string.format(
        "SequenceMonitor:load_sequence: sequence %s not found", sequence_id))

    self:_sync_model(seq)
    self:_sync_engine(sequence_id, opts, seq)
    self:_init_viewport()
    self:_restore_playhead(seq)
    self:_update_title(seq)

    self:_notify()

    log.event("%s: loaded %s %s (%d frames @ %d/%d fps)",
        self.view_id, seq.kind or "?", sequence_id:sub(1, 8),
        self.total_frames, self.fps_num, self.fps_den)
end

function SequenceMonitor:_save_current_playhead(new_sequence_id)
    -- Save current masterclip playhead before switching to a DIFFERENT sequence.
    -- Skip when reloading the same sequence: external writers (e.g. MatchFrame)
    -- may have updated marks+playhead in DB — saving stale in-memory state would
    -- clobber those fresh values.
    if self.sequence and self.sequence:is_master()
       and self.sequence_id ~= new_sequence_id then
        self:save_playhead_to_db()
    end
end

function SequenceMonitor:_sync_model(seq)
    self.sequence_id = seq.id
    self.sequence = seq
    self._project_gen = project_gen.current()
end

function SequenceMonitor:_sync_engine(sequence_id, opts, seq)
    -- Resolve the audio bus rate THIS monitor will output at. Engine no longer
    -- infers from the sequence — it requires an explicit positive rate.
    local output_audio_rate = resolve_output_audio_rate(seq)

    -- Load engine (sets fps, total_frames, resets position)
    self.engine:load_sequence(sequence_id, opts.total_frames, output_audio_rate)

    -- Sync state from engine
    self.start_frame = self.engine.start_frame or 0
    self.total_frames = self.engine.total_frames
    self.fps_num = self.engine.fps_num
    self.fps_den = self.engine.fps_den
end

function SequenceMonitor:_init_viewport()
    -- Reset viewport to full extent (zoom-to-fit)
    self.viewport_start = self.start_frame
    self.viewport_duration = self.total_frames - self.start_frame
end

function SequenceMonitor:_restore_playhead(seq)
    -- Restore playhead from DB (both masterclips and timelines).
    -- Sequence.load() asserts playhead_position is NOT NULL — no fallback.
    local saved_playhead = seq.playhead_position
    assert(type(saved_playhead) == "number", string.format(
        "SequenceMonitor(%s):load_sequence: playhead_position must be number, got %s (seq=%s)",
        self.view_id, type(saved_playhead), seq.id:sub(1, 8)))
    -- Preserve the user's saved playhead in self.playhead (the value mirrored
    -- back into timeline_state and re-persisted on tab swap). monitor.playhead
    -- has no upper clamp — matches set_playhead/seek_to_frame contract
    -- (test_sequence_monitor.lua: "no upper clamp — playhead free beyond
    -- content"). Engine seek requires frame >= start_frame; clamp only that
    -- floor for the engine call so a saved value below the sequence's TC
    -- origin doesn't trip engine:seek's assert.
    self.playhead = saved_playhead
    local engine_target = saved_playhead
    if engine_target < self.start_frame then
        log.warn("load_sequence(%s): saved playhead %d below start_frame %d; "
            .. "seeking engine to start (self.playhead preserved at saved value)",
            seq.id:sub(1, 8), saved_playhead, self.start_frame)
        engine_target = self.start_frame
    end
    self.engine:seek(engine_target)
end

function SequenceMonitor:_update_title(seq)
    -- Update title
    local kind_label = seq:is_master() and "Source" or "Timeline"
    self:_set_title(string.format("%s: %s", kind_label, seq.name or seq.id))
end

--- Unload current sequence.
function SequenceMonitor:unload()
    if self.sequence and self.sequence:is_master() then
        self:save_playhead_to_db()
    end

    self.engine:stop()
    self.sequence_id = nil
    self.sequence = nil
    self.start_frame = 0
    self.total_frames = 0
    self.playhead = 0
    self.fps_num = nil
    self.fps_den = nil
    self.viewport_start = 0
    self.viewport_duration = 0

    -- Clear video
    self:_on_show_gap()
    self:_set_title(self.view_id)
    self:_notify()
end

--------------------------------------------------------------------------------
-- Seek / Transport
--------------------------------------------------------------------------------

--- Seek to frame (for mark bar clicks and external callers).
-- Stops playback if playing, displays frame, updates playhead.
function SequenceMonitor:seek_to_frame(frame)
    assert(type(frame) == "number", string.format(
        "SequenceMonitor(%s):seek_to_frame: frame must be number, got %s",
        self.view_id, type(frame)))
    assert(self.sequence_id, string.format(
        "SequenceMonitor(%s):seek_to_frame: no sequence loaded",
        self.view_id))

    if self.engine:is_playing() then
        self.engine:stop()
    end
    self.engine:seek(frame)

    -- engine:seek uses set_position_silent (no callback), update manually
    self.playhead = math.max(self.start_frame, math.floor(frame))
    self:_ensure_playhead_visible()
    if self.sequence and self.sequence:is_master() then
        self:_schedule_persist()
    end
    self:_notify()
end

--------------------------------------------------------------------------------
-- Widget Accessors
--------------------------------------------------------------------------------

--- Get container widget for layout embedding.
--- Return the sequence_id currently loaded in this monitor, or nil if none.
-- For the source_monitor, this is the master sequence id of the loaded clip.
function SequenceMonitor:get_loaded_master_seq_id()
    return self.sequence_id
end

function SequenceMonitor:get_widget()
    return self._container
end

--- Get title widget.
function SequenceMonitor:get_title_widget()
    return self._title_label
end

--- Get video surface widget.
function SequenceMonitor:get_video_surface()
    return self._video_surface
end

--- Set a secondary GPUVideoSurface that receives mirrored frames.
-- Used by fullscreen viewer to display the same content on a second surface.
function SequenceMonitor:set_frame_mirror(surface)
    assert(surface, string.format(
        "SequenceMonitor(%s):set_frame_mirror: surface required", self.view_id))
    self._frame_mirror = surface
end

--- Clear the frame mirror and blank the mirror surface.
function SequenceMonitor:clear_frame_mirror()
    if self._frame_mirror then
        qt_constants.EMP.SURFACE_SET_FRAME(self._frame_mirror, nil)
    end
    self._frame_mirror = nil
end

--------------------------------------------------------------------------------
-- State Provider Interface (for mark bar)
--------------------------------------------------------------------------------

--- Check if a sequence is loaded.
function SequenceMonitor:has_clip()
    return self.sequence_id ~= nil
end

--- Get mark in (video frame). Works on any sequence kind.
--- In live-bound mode (spec 019 FR-016d), the source monitor's mark
--- bar shows the loaded CLIP's source_in — pulled from effective_source's
--- override slot (which source_viewer.load_clip wrote into). Staged
--- mode and the record monitor fall through to the sequence row's
--- persisted mark_in.
-- @return number|nil
function SequenceMonitor:get_mark_in()
    if not self.sequence then return nil end
    local override_in = require("core.effective_source")
        .get_source_marks_for(self.sequence.id)
    if override_in ~= nil then return override_in end
    return self.sequence:get_in()
end

--- Compute the playback range as (range_start, range_end). Branches on
--- the source_viewer's mode (spec 019 FR-016e):
---   * live_bound_clip → [start_frame, total_frames) — marks ignored,
---     because in live-bound mode the marks ARE the clip's source_in/out
---     (edit bounds), not playback bounds.
---   * staged_sequence / neutral (anything else) → existing convention
---     [mark_in or start_frame, mark_out or total_frames).
--- Consumers (the playback engine + the duration-label site at
--- sequence_monitor.lua:1021-1024) read from this single accessor so the
--- divergence has one home.
function SequenceMonitor:get_playback_range()
    -- Plain require: ui.source_viewer is loaded at panel init, well before
    -- any monitor calls get_playback_range. A genuine cycle would be a
    -- wiring bug worth crashing on, not a "silent staged fallback" case.
    local sv = require("ui.source_viewer")
    if sv.get_mode() == "live_bound_clip" then
        return self.start_frame, self.total_frames
    end
    local mark_in  = self.sequence and self.sequence.mark_in or nil
    local mark_out = self.sequence and self.sequence.mark_out or nil
    return mark_in or self.start_frame, mark_out or self.total_frames
end

--- Get mark out (video frame). Works on any sequence kind.
--- In live-bound mode (spec 019 FR-016d), reads from effective_source's
--- override slot — mirrors get_mark_in above.
-- @return number|nil
function SequenceMonitor:get_mark_out()
    if not self.sequence then return nil end
    local _, override_out = require("core.effective_source")
        .get_source_marks_for(self.sequence.id)
    if override_out ~= nil then return override_out end
    return self.sequence:get_out()
end

--- Set playhead (clamped, schedules persist for masterclips).
function SequenceMonitor:set_playhead(frame)
    assert(frame ~= nil, string.format(
        "SequenceMonitor(%s):set_playhead: frame is nil", self.view_id))
    local pos = math.max(self.start_frame, math.floor(frame))
    if pos == self.playhead then return end

    self.playhead = pos
    self:_ensure_playhead_visible()
    self:_notify()
    if self.sequence and self.sequence:is_master() then
        self:_schedule_persist()
    end
end

--------------------------------------------------------------------------------
-- Viewport (Mark Bar Zoom)
--------------------------------------------------------------------------------

-- Minimum viewport size in frames (~1 second at 30fps)
local MIN_VIEWPORT_FRAMES = 30

--- Get current viewport start frame.
function SequenceMonitor:get_viewport_start()
    return self.viewport_start
end

--- Get current viewport duration in frames.
function SequenceMonitor:get_viewport_duration()
    return self.viewport_duration
end

--- Set viewport with clamping, notify listeners.
function SequenceMonitor:set_viewport(start, duration)
    assert(type(start) == "number" and type(duration) == "number",
        string.format("SequenceMonitor(%s):set_viewport: start/duration must be numbers",
            self.view_id))
    local total = self.total_frames
    local physical = total - self.start_frame
    if physical <= 0 then return end

    -- Clamp duration
    duration = math.max(MIN_VIEWPORT_FRAMES, math.min(duration, physical))
    duration = math.floor(duration)

    -- Clamp start
    start = math.max(self.start_frame, math.min(start, total - duration))
    start = math.floor(start)

    self.viewport_start = start
    self.viewport_duration = duration

    -- Postcondition: viewport must be within sequence bounds
    assert(self.viewport_start >= self.start_frame and self.viewport_start + self.viewport_duration <= total,
        string.format("SequenceMonitor(%s):set_viewport: postcondition failed: [%d, %d+%d=%d] > total=%d",
            self.view_id, self.viewport_start, self.viewport_start, self.viewport_duration,
            self.viewport_start + self.viewport_duration, total))

    self:_notify()
end

--- Zoom by factor, centered on playhead.
-- factor < 1 zooms in (reduce viewport), factor > 1 zooms out (increase viewport).
function SequenceMonitor:zoom_by(factor)
    assert(type(factor) == "number" and factor > 0,
        string.format("SequenceMonitor(%s):zoom_by: factor must be positive number, got %s",
            self.view_id, tostring(factor)))
    local physical = self.total_frames - self.start_frame
    if physical <= 0 then return end

    local new_dur = math.floor(self.viewport_duration * factor)
    new_dur = math.max(MIN_VIEWPORT_FRAMES, math.min(new_dur, physical))

    -- Center on playhead
    local new_start = self.playhead - math.floor(new_dur / 2)
    new_start = math.max(self.start_frame, math.min(new_start, self.total_frames - new_dur))

    self.viewport_start = math.floor(new_start)
    self.viewport_duration = new_dur

    -- Postcondition: viewport must be within sequence bounds
    assert(self.viewport_start >= self.start_frame and self.viewport_start + self.viewport_duration <= self.total_frames,
        string.format("SequenceMonitor(%s):zoom_by: postcondition failed: [%d, %d+%d=%d] > total=%d",
            self.view_id, self.viewport_start, self.viewport_start, self.viewport_duration,
            self.viewport_start + self.viewport_duration, self.total_frames))

    self:_notify()
end

--- Reset viewport to full extent (zoom-to-fit).
function SequenceMonitor:zoom_to_fit()
    self.viewport_start = self.start_frame
    self.viewport_duration = self.total_frames - self.start_frame
    self:_notify()
end

--- Ensure playhead is visible within viewport. Shifts viewport if needed.
function SequenceMonitor:_ensure_playhead_visible()
    local physical_frames = self.total_frames - self.start_frame
    if physical_frames <= 0 or self.viewport_duration >= physical_frames then
        return  -- Full extent, playhead always visible
    end
    local vp_end = self.viewport_start + self.viewport_duration
    if self.playhead < self.viewport_start then
        self.viewport_start = self.playhead
    elseif self.playhead >= vp_end then
        self.viewport_start = self.playhead - self.viewport_duration + 1
    end
    -- Re-clamp
    self.viewport_start = math.max(self.start_frame, math.min(
        self.viewport_start, self.total_frames - self.viewport_duration))
end

--------------------------------------------------------------------------------
-- Listener Pattern
--------------------------------------------------------------------------------

--- Add listener for state changes (redraws, playhead updates).
function SequenceMonitor:add_listener(fn)
    assert(type(fn) == "function", string.format(
        "SequenceMonitor(%s):add_listener: fn must be function, got %s",
        self.view_id, type(fn)))
    self._listeners[#self._listeners + 1] = fn
end

--- Remove listener.
function SequenceMonitor:remove_listener(fn)
    for i = #self._listeners, 1, -1 do
        if self._listeners[i] == fn then
            table.remove(self._listeners, i)
            return true
        end
    end
    return false
end

--------------------------------------------------------------------------------
-- Playhead Persistence (masterclip only)
--------------------------------------------------------------------------------

--- Save playhead to DB (for masterclip sequences).
function SequenceMonitor:save_playhead_to_db()
    if not self.sequence then return end
    if not self.sequence:is_master() then return end
    if not database.has_connection() then return end

    -- Clamp before writing — playhead can drift to total_frames after
    -- advance_playhead or content changes. Clamp to valid range.
    if self.total_frames > self.start_frame then
        if self.playhead >= self.total_frames then
            self.playhead = self.total_frames - 1
        elseif self.playhead < self.start_frame then
            self.playhead = self.start_frame
        end
    end
    -- Surgical UPDATE — touches only playhead_frame. Full Sequence:save()
    -- would re-bind every column on the cached sequence object, which
    -- triggers spurious FK failures if any of those cached fields are
    -- stale (e.g., project_id from a prior project). The playhead persist
    -- must not be coupled to the validity of unrelated fields.
    self.sequence.playhead_position = self.playhead
    Sequence.update_playhead(self.sequence.id, self.playhead)
end

function SequenceMonitor:_schedule_persist()
    self._persist_generation = self._persist_generation + 1
    local gen = self._persist_generation
    local pgen = self._project_gen

    if not database.has_connection() then return end

    if _G.qt_create_single_shot_timer then
        _G.qt_create_single_shot_timer(DEBOUNCE_MS, function()
            if gen ~= self._persist_generation then return end
            if pgen ~= project_gen.current() then return end  -- project changed
            self:save_playhead_to_db()
        end)
    else
        self:save_playhead_to_db()
    end
end

--------------------------------------------------------------------------------
-- MVC Pull: View re-pulls frame from model
--------------------------------------------------------------------------------

--- Called when the View should re-display the current frame.
-- Two triggers: (1) surface becomes render-ready (Metal initialized),
-- (2) content changes at parked playhead (insert/delete at playhead).
-- No-op during playback (C++ CVDisplayLink push path handles that).
function SequenceMonitor:on_model_changed()
    if not self.sequence_id then return end
    if self.engine:is_playing() then return end
    self.engine:on_model_changed(self.playhead)
end

--------------------------------------------------------------------------------
-- Engine Callbacks
--------------------------------------------------------------------------------

function SequenceMonitor:_on_show_frame(frame_handle, metadata)
    self._frame_count = (self._frame_count or 0) + 1
    if self._frame_count % 30 == 0 then
        log.detail("show_frame: view=%s count=%d", self.view_id, self._frame_count)
    end
    -- Clear surface error on successful frame delivery (error callback fires
    -- from C++ *before* setFrame returns when format is unsupported, so a
    -- successful setFrame means the error is resolved).
    if self._surface_error then
        self._surface_error = nil
        self:_notify()
    end
    -- MVC pull: ask the model for this clip's display grade, push to the
    -- surface BEFORE the frame so the shader's CDL uniform is in place
    -- when the new frame draws (spec 023 T032 / FR-016).
    self:_apply_clip_grade(metadata and metadata.clip_id)
    qt_constants.EMP.SURFACE_SET_FRAME(self._video_surface, frame_handle)
    if self._frame_mirror then
        qt_constants.EMP.SURFACE_SET_FRAME(self._frame_mirror, frame_handle)
    end
end

--- Pull display grade for clip_id and push to the surface(s).
--- nil clip_id ⇒ gap or no active clip ⇒ clear grade (passthrough).
--- No clip_id cache: caching by clip_id alone hid SyncGradesFromResolve
--- updates (cache key unchanged when the underlying row mutated). The
--- per-frame ClipGrade.load is one indexed SELECT and is dwarfed by
--- decode cost; if it ever shows on a profile, invalidate on the
--- grades_changed signal we already wire below rather than reintroducing
--- a key-only cache.
function SequenceMonitor:_apply_clip_grade(clip_id)
    -- view_grade_pull is a thin wrapper over the model; the model owns
    -- SQL access (SQL-isolation policy in core/database.lua). The view
    -- does not touch the connection.
    local stages = view_grade_pull.pull_for_clip(clip_id)
    local cdl     = stages and stages.cdl     or nil
    local lut_ref = stages and stages.lut_ref or nil
    -- FR-016: apply CDL, then LUT if present. Either stage is a no-op
    -- when its arg is nil (SURFACE_SET_* with nil clears the stage).
    qt_constants.EMP.SURFACE_SET_GRADE(self._video_surface, cdl)
    qt_constants.EMP.SURFACE_SET_LUT3D(self._video_surface, lut_ref)
    if self._frame_mirror then
        qt_constants.EMP.SURFACE_SET_GRADE(self._frame_mirror, cdl)
        qt_constants.EMP.SURFACE_SET_LUT3D(self._frame_mirror, lut_ref)
    end
end

function SequenceMonitor:_on_show_gap()
    log.event("show_gap: view=%s", self.view_id)
    -- Drop any previously-pushed grade so the next graded clip's grade
    -- doesn't linger across the gap (T032 / FR-016).
    self:_apply_clip_grade(nil)
    qt_constants.EMP.SURFACE_SET_FRAME(self._video_surface, nil)
    if self._frame_mirror then
        qt_constants.EMP.SURFACE_SET_FRAME(self._frame_mirror, nil)
    end
end

function SequenceMonitor:_on_set_rotation(degrees)
    qt_constants.EMP.SURFACE_SET_ROTATION(self._video_surface, degrees)
    if self._frame_mirror then
        qt_constants.EMP.SURFACE_SET_ROTATION(self._frame_mirror, degrees)
    end
end

function SequenceMonitor:_on_set_par(num, den)
    qt_constants.EMP.SURFACE_SET_PAR(self._video_surface, num, den)
    if self._frame_mirror then
        qt_constants.EMP.SURFACE_SET_PAR(self._frame_mirror, num, den)
    end
end

--- Called by engine during playback ticks (set_position fires this).
function SequenceMonitor:_on_position_changed(frame)
    self.playhead = math.floor(frame)
    self:_ensure_playhead_visible()
    if self.sequence and self.sequence:is_master() then
        self:_schedule_persist()
    end
    self:_notify()
end

--------------------------------------------------------------------------------
-- Internal
--------------------------------------------------------------------------------

local TC_STYLE = [[
    QLabel {
        background: #2b2b2b;
        color: #cccccc;
        padding: 2px 6px;
        font-family: "Menlo", "Monaco", monospace;
        font-size: 11px;
    }
]]

function SequenceMonitor:_create_tc_row(parent_layout)
    local row_layout = qt_constants.LAYOUT.CREATE_HBOX()
    if qt_constants.LAYOUT.SET_MARGINS then
        qt_constants.LAYOUT.SET_MARGINS(row_layout, 0, 0, 0, 0)
    end
    if qt_constants.LAYOUT.SET_SPACING then
        qt_constants.LAYOUT.SET_SPACING(row_layout, 0)
    end

    -- Playhead TC (left-aligned)
    self._tc_playhead_label = qt_constants.WIDGET.CREATE_LABEL("00:00:00:00")
    qt_constants.PROPERTIES.SET_STYLE(self._tc_playhead_label, TC_STYLE)
    if qt_constants.PROPERTIES.SET_ALIGNMENT then
        qt_constants.PROPERTIES.SET_ALIGNMENT(
            self._tc_playhead_label, qt_constants.PROPERTIES.ALIGN_LEFT)
    end
    qt_constants.LAYOUT.ADD_WIDGET(row_layout, self._tc_playhead_label)

    -- Duration (right-aligned)
    self._tc_duration_label = qt_constants.WIDGET.CREATE_LABEL("--")
    qt_constants.PROPERTIES.SET_STYLE(self._tc_duration_label, TC_STYLE)
    if qt_constants.PROPERTIES.SET_ALIGNMENT then
        qt_constants.PROPERTIES.SET_ALIGNMENT(
            self._tc_duration_label, qt_constants.PROPERTIES.ALIGN_RIGHT)
    end
    qt_constants.LAYOUT.ADD_WIDGET(row_layout, self._tc_duration_label)

    -- Wrap in a container widget
    local tc_row_widget = qt_constants.WIDGET.CREATE()
    qt_constants.LAYOUT.SET_ON_WIDGET(tc_row_widget, row_layout)
    qt_constants.CONTROL.SET_WIDGET_SIZE_POLICY(tc_row_widget, "Expanding", "Fixed")
    qt_constants.LAYOUT.ADD_WIDGET(parent_layout, tc_row_widget)
end

function SequenceMonitor:_update_tc_display()
    if not self._tc_playhead_label then return end

    -- Playhead TC
    if self.sequence_id and self.fps_num and self.fps_den then
        local tc_str = timecode.format_ruler_label(self.playhead, {
            fps_numerator = self.fps_num,
            fps_denominator = self.fps_den,
        })
        qt_constants.PROPERTIES.SET_TEXT(self._tc_playhead_label, tc_str)
    else
        qt_constants.PROPERTIES.SET_TEXT(self._tc_playhead_label, "00:00:00:00")
    end

    -- Duration: NLE-standard measurement
    -- Both marks: in→out. Only in: in→end. Only out: start→out. Neither: total.
    if not self._tc_duration_label then return end
    if self.sequence_id and self.fps_num and self.fps_den then
        local mark_in = self:get_mark_in()
        local mark_out = self:get_mark_out()
        local range_start = mark_in or self.start_frame
        local range_end = mark_out or self.total_frames
        local dur_frames = range_end - range_start
        local dur_str = timecode.format_ruler_label(dur_frames, {
            fps_numerator = self.fps_num,
            fps_denominator = self.fps_den,
        })
        qt_constants.PROPERTIES.SET_TEXT(self._tc_duration_label, dur_str)
    else
        qt_constants.PROPERTIES.SET_TEXT(self._tc_duration_label, "--")
    end
end

function SequenceMonitor:_set_title(text)
    qt_constants.PROPERTIES.SET_TEXT(self._title_label, text)
end

function SequenceMonitor:_notify()
    self:_update_tc_display()
    for _, fn in ipairs(self._listeners) do
        fn()
    end
end

--- Clean up resources.
function SequenceMonitor:destroy()
    if self.sequence and self.sequence:is_master() then
        self:save_playhead_to_db()
    end
    self:clear_frame_mirror()
    self.engine:destroy()
    self._listeners = {}
    if self._marks_changed_id then
        Signals.disconnect(self._marks_changed_id)
        self._marks_changed_id = nil
    end
    if self._playhead_changed_id then
        Signals.disconnect(self._playhead_changed_id)
        self._playhead_changed_id = nil
    end
    if self._content_changed_id then
        Signals.disconnect(self._content_changed_id)
        self._content_changed_id = nil
    end
    if self._transport_ready_id then
        Signals.disconnect(self._transport_ready_id)
        self._transport_ready_id = nil
    end
    if self._project_changed_id then
        Signals.disconnect(self._project_changed_id)
        self._project_changed_id = nil
    end
    if self._media_status_changed_id then
        Signals.disconnect(self._media_status_changed_id)
        self._media_status_changed_id = nil
    end
    if self._media_content_changed_id then
        Signals.disconnect(self._media_content_changed_id)
        self._media_content_changed_id = nil
    end
    if self._grades_changed_id then
        Signals.disconnect(self._grades_changed_id)
        self._grades_changed_id = nil
    end
end

return SequenceMonitor
