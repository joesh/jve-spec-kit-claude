--- SequenceView: a UI component that views any sequence (masterclip or timeline).
--
-- Each instance owns:
-- - A PlaybackEngine for transport control
-- - A GPUVideoSurface for video frame display
-- - A mark bar for mark in/out range + playhead visualization
-- - A title label
-- - A media_cache context for independent frame caching
--
-- Absorbs widget creation from viewer_panel.lua and playhead/mark state
-- management from source_viewer_state.lua. SequenceView treats all sequence
-- kinds uniformly — masterclips and timelines use identical code paths.
--
-- Masterclip-specific behavior:
-- - Playhead persisted to DB via sequence record (debounced)
-- - Marks read/write via stream clips (get_all_streams_in/out)
--
-- @file sequence_view.lua

local logger = require("core.logger")
local qt_constants = require("core.qt_constants")
local media_cache = require("core.media.media_cache")
local PlaybackEngine = require("core.playback.playback_engine")
local Renderer = require("core.renderer")
local Sequence = require("models.sequence")
local source_mark_bar = require("ui.source_mark_bar")
local database = require("core.database")

local SequenceView = {}
SequenceView.__index = SequenceView

-- Debounce interval for playhead persistence (ms)
local DEBOUNCE_MS = 200

--------------------------------------------------------------------------------
-- Constructor
--------------------------------------------------------------------------------

--- Create a new SequenceView instance.
-- @param config table:
--   view_id  string  unique identifier (e.g. "source_view", "timeline_view")
function SequenceView.new(config)
    assert(type(config) == "table",
        "SequenceView.new: config table required")
    assert(config.view_id and config.view_id ~= "",
        "SequenceView.new: view_id required")

    local self = setmetatable({}, SequenceView)

    self.view_id = config.view_id
    self.media_context_id = config.view_id

    -- Sequence state
    self.sequence_id = nil
    self.sequence = nil       -- Sequence model (for marks on masterclips)
    self.total_frames = 0
    self.playhead = 0
    self.fps_num = nil
    self.fps_den = nil

    -- Listener pattern (for mark bar redraws)
    self._listeners = {}

    -- Debounced playhead persistence
    self._persist_generation = 0

    -- Create media_cache context for this view
    media_cache.create_context(self.media_context_id)

    -- Create PlaybackEngine
    self.engine = PlaybackEngine.new({
        media_context_id = self.media_context_id,
        on_show_frame = function(fh, meta)
            self:_on_show_frame(fh, meta)
        end,
        on_show_gap = function()
            self:_on_show_gap()
        end,
        on_set_rotation = function(deg)
            self:_on_set_rotation(deg)
        end,
        on_position_changed = function(frame)
            self:_on_position_changed(frame)
        end,
    })

    -- Create widgets
    self:_create_widgets()

    return self
end

--------------------------------------------------------------------------------
-- Widget Creation (absorbed from viewer_panel.create)
--------------------------------------------------------------------------------

function SequenceView:_create_widgets()
    self._container = qt_constants.WIDGET.CREATE()
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
        "SequenceView: CREATE_GPU_VIDEO_SURFACE not available")
    self._video_surface = qt_constants.WIDGET.CREATE_GPU_VIDEO_SURFACE()
    assert(self._video_surface,
        "SequenceView: CREATE_GPU_VIDEO_SURFACE returned nil")

    -- Assert EMP bindings required by engine callbacks
    assert(qt_constants.EMP and qt_constants.EMP.SURFACE_SET_FRAME,
        "SequenceView: EMP.SURFACE_SET_FRAME not available")
    assert(qt_constants.EMP.SURFACE_SET_ROTATION,
        "SequenceView: EMP.SURFACE_SET_ROTATION not available")
    assert(qt_constants.PROPERTIES and qt_constants.PROPERTIES.SET_TEXT,
        "SequenceView: PROPERTIES.SET_TEXT not available")
    if qt_constants.GEOMETRY and qt_constants.GEOMETRY.SET_SIZE_POLICY then
        qt_constants.GEOMETRY.SET_SIZE_POLICY(
            self._video_surface, "Expanding", "Expanding")
    end
    qt_constants.LAYOUT.ADD_WIDGET(content_layout, self._video_surface)
    if qt_constants.LAYOUT.SET_STRETCH_FACTOR then
        qt_constants.LAYOUT.SET_STRETCH_FACTOR(
            content_layout, self._video_surface, 1)
    end

    -- Mark bar (ScriptableTimeline widget)
    assert(qt_constants.WIDGET.CREATE_TIMELINE,
        "SequenceView: CREATE_TIMELINE not available")
    local mark_bar_widget = qt_constants.WIDGET.CREATE_TIMELINE()
    assert(mark_bar_widget,
        "SequenceView: CREATE_TIMELINE returned nil")
    qt_constants.CONTROL.SET_WIDGET_SIZE_POLICY(
        mark_bar_widget, "Expanding", "Fixed")
    timeline.set_desired_height(mark_bar_widget, source_mark_bar.BAR_HEIGHT)
    qt_constants.LAYOUT.ADD_WIDGET(content_layout, mark_bar_widget)

    self._mark_bar = source_mark_bar.create(mark_bar_widget, {
        state_provider = self,
        has_clip = function() return self:has_clip() end,
        get_mark_in = function() return self:get_mark_in() end,
        get_mark_out = function() return self:get_mark_out() end,
        on_seek = function(frame) self:seek_to_frame(frame) end,
        on_listener = function(fn) self:add_listener(fn) end,
    })
    assert(self._mark_bar, string.format(
        "SequenceView(%s):_create_widgets: source_mark_bar.create returned nil",
        self.view_id))

    qt_constants.LAYOUT.SET_ON_WIDGET(content, content_layout)
    qt_constants.LAYOUT.ADD_WIDGET(layout, content)
    if qt_constants.LAYOUT.SET_STRETCH_FACTOR then
        qt_constants.LAYOUT.SET_STRETCH_FACTOR(layout, content, 1)
    end

    qt_constants.LAYOUT.SET_ON_WIDGET(self._container, layout)

    logger.info("sequence_view", string.format(
        "%s: widgets created", self.view_id))
end

--------------------------------------------------------------------------------
-- Sequence Loading
--------------------------------------------------------------------------------

--- Load a sequence (any kind: masterclip or timeline).
-- @param sequence_id string
-- @param opts table optional: { total_frames = number }
function SequenceView:load_sequence(sequence_id, opts)
    assert(sequence_id and sequence_id ~= "", string.format(
        "SequenceView(%s):load_sequence: sequence_id required, got %s",
        self.view_id, tostring(sequence_id)))

    -- Save current masterclip playhead before switching
    if self.sequence and self.sequence:is_masterclip() then
        self:save_playhead_to_db()
    end

    opts = opts or {}

    -- Load sequence model
    local seq = Sequence.load(sequence_id)
    assert(seq, string.format(
        "SequenceView:load_sequence: sequence %s not found", sequence_id))

    self.sequence_id = sequence_id
    self.sequence = seq

    -- Load engine (sets fps, total_frames, resets position)
    self.engine:load_sequence(sequence_id, opts.total_frames)

    -- Sync state from engine
    self.total_frames = self.engine.total_frames
    self.fps_num = self.engine.fps_num
    self.fps_den = self.engine.fps_den
    self.playhead = 0

    -- For masterclips: restore playhead from DB
    if seq:is_masterclip() then
        local saved_playhead = seq.playhead_position or 0
        if saved_playhead > 0 and saved_playhead < self.total_frames then
            self.playhead = saved_playhead
            self.engine:seek(saved_playhead)
        else
            self.engine:seek(0)
        end
    else
        self.engine:seek(0)
    end

    -- Update title
    local title = seq:is_masterclip() and "Source" or "Timeline"
    self:_set_title(string.format("%s: %s", title, seq.name or sequence_id))

    self:_notify()

    logger.info("sequence_view", string.format(
        "%s: loaded %s %s (%d frames @ %d/%d fps)",
        self.view_id, seq.kind or "?", sequence_id:sub(1, 8),
        self.total_frames, self.fps_num, self.fps_den))
end

--- Unload current sequence.
function SequenceView:unload()
    if self.sequence and self.sequence:is_masterclip() then
        self:save_playhead_to_db()
    end

    self.engine:stop()
    self.sequence_id = nil
    self.sequence = nil
    self.total_frames = 0
    self.playhead = 0
    self.fps_num = nil
    self.fps_den = nil

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
function SequenceView:seek_to_frame(frame)
    assert(type(frame) == "number", string.format(
        "SequenceView(%s):seek_to_frame: frame must be number, got %s",
        self.view_id, type(frame)))
    assert(self.sequence_id, string.format(
        "SequenceView(%s):seek_to_frame: no sequence loaded",
        self.view_id))

    if self.engine:is_playing() then
        self.engine:stop()
    end
    self.engine:seek(frame)

    -- engine:seek uses set_position_silent (no callback), update manually
    local clamped = math.max(0, math.min(
        math.floor(frame), self.total_frames - 1))
    self.playhead = clamped
    if self.sequence and self.sequence:is_masterclip() then
        self:_schedule_persist()
    end
    self:_notify()
end

--------------------------------------------------------------------------------
-- Widget Accessors
--------------------------------------------------------------------------------

--- Get container widget for layout embedding.
function SequenceView:get_widget()
    return self._container
end

--- Get title widget.
function SequenceView:get_title_widget()
    return self._title_label
end

--- Get video surface widget.
function SequenceView:get_video_surface()
    return self._video_surface
end

--------------------------------------------------------------------------------
-- State Provider Interface (for mark bar)
--------------------------------------------------------------------------------

--- Check if a sequence is loaded.
function SequenceView:has_clip()
    return self.sequence_id ~= nil
end

--- Get mark in (video frame). Masterclip only.
-- @return number|nil
function SequenceView:get_mark_in()
    if not self.sequence then return nil end
    if not self.sequence:is_masterclip() then return nil end
    return self.sequence:get_all_streams_in()
end

--- Get mark out (video frame). Masterclip only.
-- @return number|nil
function SequenceView:get_mark_out()
    if not self.sequence then return nil end
    if not self.sequence:is_masterclip() then return nil end
    return self.sequence:get_all_streams_out()
end

--- Set mark in at frame (masterclip only).
function SequenceView:set_mark_in(frame)
    assert(frame ~= nil, string.format(
        "SequenceView(%s):set_mark_in: frame is nil", self.view_id))
    assert(self.sequence and self.sequence:is_masterclip(), string.format(
        "SequenceView(%s):set_mark_in: no masterclip loaded (seq=%s)",
        self.view_id, tostring(self.sequence_id)))
    self.sequence:set_all_streams_in(math.floor(frame))
    self:_notify()
end

--- Set mark out at frame (masterclip only).
function SequenceView:set_mark_out(frame)
    assert(frame ~= nil, string.format(
        "SequenceView(%s):set_mark_out: frame is nil", self.view_id))
    assert(self.sequence and self.sequence:is_masterclip(), string.format(
        "SequenceView(%s):set_mark_out: no masterclip loaded (seq=%s)",
        self.view_id, tostring(self.sequence_id)))
    self.sequence:set_all_streams_out(math.floor(frame))
    self:_notify()
end

--- Clear marks (reset to full duration, masterclip only).
-- Uses total_frames (computed at load time from original stream clip extent)
-- rather than current source_out (which may have been narrowed by set_mark_out).
function SequenceView:clear_marks()
    assert(self.sequence and self.sequence:is_masterclip(), string.format(
        "SequenceView(%s):clear_marks: no masterclip loaded (seq=%s)",
        self.view_id, tostring(self.sequence_id)))
    assert(self.total_frames > 0, string.format(
        "SequenceView(%s):clear_marks: total_frames must be > 0, got %d",
        self.view_id, self.total_frames))

    self.sequence:set_all_streams_in(0)
    self.sequence:set_all_streams_out(self.total_frames)

    self:_notify()
end

--- Set playhead (clamped, schedules persist for masterclips).
function SequenceView:set_playhead(frame)
    assert(frame ~= nil, string.format(
        "SequenceView(%s):set_playhead: frame is nil", self.view_id))
    local clamped = math.max(0, math.min(
        math.floor(frame), math.max(0, self.total_frames - 1)))
    if clamped == self.playhead then return end

    self.playhead = clamped
    self:_notify()
    if self.sequence and self.sequence:is_masterclip() then
        self:_schedule_persist()
    end
end

--------------------------------------------------------------------------------
-- Listener Pattern
--------------------------------------------------------------------------------

--- Add listener for state changes (redraws, playhead updates).
function SequenceView:add_listener(fn)
    assert(type(fn) == "function", string.format(
        "SequenceView(%s):add_listener: fn must be function, got %s",
        self.view_id, type(fn)))
    self._listeners[#self._listeners + 1] = fn
end

--- Remove listener.
function SequenceView:remove_listener(fn)
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
function SequenceView:save_playhead_to_db()
    if not self.sequence then return end
    if not self.sequence:is_masterclip() then return end
    if not database.has_connection() then return end

    self.sequence.playhead_position = self.playhead
    self.sequence:save()
end

function SequenceView:_schedule_persist()
    self._persist_generation = self._persist_generation + 1
    local gen = self._persist_generation

    if not database.has_connection() then return end

    if _G.qt_create_single_shot_timer then
        _G.qt_create_single_shot_timer(DEBOUNCE_MS, function()
            if gen ~= self._persist_generation then return end
            self:save_playhead_to_db()
        end)
    else
        self:save_playhead_to_db()
    end
end

--------------------------------------------------------------------------------
-- Engine Callbacks
--------------------------------------------------------------------------------

function SequenceView:_on_show_frame(frame_handle, metadata)
    qt_constants.EMP.SURFACE_SET_FRAME(self._video_surface, frame_handle)
end

function SequenceView:_on_show_gap()
    qt_constants.EMP.SURFACE_SET_FRAME(self._video_surface, nil)
end

function SequenceView:_on_set_rotation(degrees)
    qt_constants.EMP.SURFACE_SET_ROTATION(self._video_surface, degrees)
end

--- Called by engine during playback ticks (set_position fires this).
function SequenceView:_on_position_changed(frame)
    self.playhead = math.floor(frame)
    if self.sequence and self.sequence:is_masterclip() then
        self:_schedule_persist()
    end
    self:_notify()
end

--------------------------------------------------------------------------------
-- Internal
--------------------------------------------------------------------------------

function SequenceView:_set_title(text)
    qt_constants.PROPERTIES.SET_TEXT(self._title_label, text)
end

function SequenceView:_notify()
    for _, fn in ipairs(self._listeners) do
        fn()
    end
end

--- Clean up resources.
function SequenceView:destroy()
    if self.sequence and self.sequence:is_masterclip() then
        self:save_playhead_to_db()
    end
    self.engine:stop()
    media_cache.destroy_context(self.media_context_id)
    self._listeners = {}
end

return SequenceView
