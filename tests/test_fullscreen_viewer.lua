--- Tests for fullscreen_viewer.lua state machine + frame mirror forwarding.
--
-- Mocks: qt_constants (minimal EMP/WIDGET/LAYOUT/DISPLAY/PROPERTIES stubs),
-- panel_manager (returns mock SequenceMonitors), focus_manager, Signals.
--
-- @file test_fullscreen_viewer.lua
require('test_env')

--------------------------------------------------------------------------------
-- Track calls to EMP surface functions for mirror verification
--------------------------------------------------------------------------------

local surface_calls = {}

local function reset_surface_calls()
    surface_calls = {}
end

local function record_surface_call(op, surface, ...)
    surface_calls[#surface_calls + 1] = {
        op = op,
        surface = surface,
        args = {...},
    }
end

--------------------------------------------------------------------------------
-- Mock widgets (just identity tables)
--------------------------------------------------------------------------------

local mock_window = { _name = "fullscreen_window" }
local mock_fs_surface = { _name = "fullscreen_surface" }
local mock_layout = { _name = "fullscreen_layout" }

-- Monitor video surfaces
local tl_surface = { _name = "timeline_video_surface" }
local src_surface = { _name = "source_video_surface" }

local widget_create_count = 0

--------------------------------------------------------------------------------
-- Mock qt_constants
--------------------------------------------------------------------------------

local mock_qt_constants = {
    WIDGET = {
        CREATE = function()
            widget_create_count = widget_create_count + 1
            return mock_window
        end,
        CREATE_GPU_VIDEO_SURFACE = function()
            return mock_fs_surface
        end,
        CREATE_LABEL = function() return { _name = "label" } end,
        CREATE_TIMELINE = function() return { _name = "mark_bar_widget" } end,
        SET_WINDOW_FLAGS = function() end,
    },
    LAYOUT = {
        CREATE_VBOX = function() return mock_layout end,
        SET_MARGINS = function() end,
        SET_SPACING = function() end,
        ADD_WIDGET = function() end,
        SET_ON_WIDGET = function() end,
        SET_STRETCH_FACTOR = function() end,
    },
    DISPLAY = {
        SHOW_FULLSCREEN = function() end,
        SHOW_NORMAL = function() end,
        SET_VISIBLE = function() end,
        SCREEN_GEOMETRY = function() return 0, 0, 1920, 1080 end,
    },
    PROPERTIES = {
        SET_STYLE = function() end,
        SET_TEXT = function() end,
        SET_GEOMETRY = function() end,
    },
    GEOMETRY = {
        SET_SIZE_POLICY = function() end,
    },
    CONTROL = {
        SET_WIDGET_SIZE_POLICY = function() end,
    },
    EMP = {
        SURFACE_SET_FRAME = function(surface, frame_handle)
            record_surface_call("SET_FRAME", surface, frame_handle)
        end,
        SURFACE_SET_ROTATION = function(surface, degrees)
            record_surface_call("SET_ROTATION", surface, degrees)
        end,
        SURFACE_SET_PAR = function(surface, num, den)
            record_surface_call("SET_PAR", surface, num, den)
        end,
        SURFACE_ON_READY = function(surface, callback)
            -- Store callback so tests can fire it to simulate Metal ready
            surface._on_ready_cb = callback
        end,
        SURFACE_ON_ERROR = function() end,
    },
}

--- Simulate Metal becoming ready on a surface (fires SURFACE_ON_READY callback).
local function fire_surface_ready(surface)
    if surface._on_ready_cb then
        surface._on_ready_cb()
    end
end

package.loaded["core.qt_constants"] = mock_qt_constants

--------------------------------------------------------------------------------
-- Mock Signals (capture project_changed handler)
--------------------------------------------------------------------------------

local signal_handlers = {}
local next_signal_id = 1

package.loaded["core.signals"] = {
    connect = function(signal_name, handler, priority)
        local id = next_signal_id
        next_signal_id = next_signal_id + 1
        signal_handlers[#signal_handlers + 1] = {
            id = id, signal = signal_name, handler = handler, priority = priority or 100,
        }
        return id
    end,
    disconnect = function() end,
    emit = function(signal_name, ...)
        -- Sort by priority, fire matching handlers
        local matching = {}
        for _, h in ipairs(signal_handlers) do
            if h.signal == signal_name then
                matching[#matching + 1] = h
            end
        end
        table.sort(matching, function(a, b) return a.priority < b.priority end)
        for _, h in ipairs(matching) do
            h.handler(...)
        end
    end,
}

local Signals = require("core.signals")

--------------------------------------------------------------------------------
-- Mock logger
--------------------------------------------------------------------------------

package.loaded["core.logger"] = {
    for_area = function()
        return {
            detail = function() end,
            event = function() end,
            warn = function() end,
            error = function() end,
        }
    end,
}

--------------------------------------------------------------------------------
-- Mock project_generation
--------------------------------------------------------------------------------

package.loaded["core.project_generation"] = {
    current = function() return 1 end,
}

--------------------------------------------------------------------------------
-- Mock focus_manager
--------------------------------------------------------------------------------

local _focused_panel = "timeline_monitor"

package.loaded["ui.focus_manager"] = {
    get_focused_panel = function() return _focused_panel end,
    on_focus_change = function() end,
    focus_panel = function() end,
}

--------------------------------------------------------------------------------
-- Mock PlaybackEngine (tracks C++ mirror surface calls)
--------------------------------------------------------------------------------

local engine_mirror_calls = {}

local function reset_engine_mirror_calls()
    engine_mirror_calls = {}
end

package.loaded["core.playback.playback_engine"] = {
    new = function(config)
        return {
            _config = config,
            load_sequence = function() end,
            stop = function() end,
            seek = function() end,
            destroy = function() end,
            is_playing = function() return false end,
            on_model_changed = function(self, playhead)
                -- Simulate: engine re-pulls frame → calls on_show_frame callback
                if self._config and self._config.on_show_frame then
                    self._config.on_show_frame("frame_at_" .. tostring(playhead), {})
                end
            end,
            set_surface = function() end,
            notify_content_changed = function() end,
            total_frames = 100,
            fps_num = 24,
            fps_den = 1,
            deactivate_audio = function() end,
            activate_audio = function() end,
            set_mirror_surface = function(self, surface)
                engine_mirror_calls[#engine_mirror_calls + 1] = {
                    op = "set", engine = self, surface = surface,
                }
            end,
            clear_mirror_surface = function(self)
                engine_mirror_calls[#engine_mirror_calls + 1] = {
                    op = "clear", engine = self,
                }
            end,
        }
    end,
}

--------------------------------------------------------------------------------
-- Mock database + Sequence (needed by SequenceMonitor constructor)
--------------------------------------------------------------------------------

package.loaded["core.database"] = {
    has_connection = function() return false end,
}

package.loaded["models.sequence"] = {
    load = function()
        return {
            name = "test",
            kind = "timeline",
            playhead_position = 0,
            mark_in = nil,
            mark_out = nil,
            is_masterclip = function() return false end,
            get_in = function() return nil end,
            get_out = function() return nil end,
            save = function() end,
        }
    end,
}

--------------------------------------------------------------------------------
-- Mock monitor_mark_bar + timeline (needed by SequenceMonitor widget creation)
--------------------------------------------------------------------------------

-- Stub the timeline C binding that SequenceMonitor uses for mark bar height
_G.timeline = {
    set_desired_height = function() end,
}

package.loaded["ui.monitor_mark_bar"] = {
    BAR_HEIGHT = 20,
    create = function()
        return { _name = "mock_mark_bar" }
    end,
}

--------------------------------------------------------------------------------
-- Create real SequenceMonitors (tests the actual mirror forwarding code)
--------------------------------------------------------------------------------

-- Override CREATE_GPU_VIDEO_SURFACE to return per-monitor surfaces
local surface_index = 0
local surfaces = { tl_surface, src_surface, mock_fs_surface }
mock_qt_constants.WIDGET.CREATE_GPU_VIDEO_SURFACE = function()
    surface_index = surface_index + 1
    return surfaces[surface_index] or { _name = "extra_surface_" .. surface_index }
end

local SequenceMonitor = require("ui.sequence_monitor")

local tl_monitor = SequenceMonitor.new({ view_id = "timeline_monitor" })
local src_monitor = SequenceMonitor.new({ view_id = "source_monitor" })

-- Verify surfaces assigned correctly
assert(tl_monitor._video_surface == tl_surface,
    "timeline_monitor should have tl_surface")
assert(src_monitor._video_surface == src_surface,
    "source_monitor should have src_surface")

-- Load sequences so on_model_changed doesn't bail (sequence_id guard)
tl_monitor:load_sequence("seq_timeline_001")
src_monitor:load_sequence("seq_source_001")

--------------------------------------------------------------------------------
-- Mock panel_manager (returns our real SequenceMonitors)
--------------------------------------------------------------------------------

local monitors = {
    timeline_monitor = tl_monitor,
    source_monitor = src_monitor,
}

package.loaded["ui.panel_manager"] = {
    get_sequence_monitor = function(view_id)
        assert(view_id and view_id ~= "", "get_sequence_monitor: view_id required")
        local sm = monitors[view_id]
        assert(sm, "get_sequence_monitor: no monitor for " .. tostring(view_id))
        return sm
    end,
    get_active_sequence_monitor = function()
        return monitors[_focused_panel] or tl_monitor
    end,
}

--------------------------------------------------------------------------------
-- NOW load the module under test (after all mocks are in place)
--------------------------------------------------------------------------------

-- Reset surface creation index so fullscreen_viewer gets mock_fs_surface
surface_index = 2  -- next call will return surfaces[3] = mock_fs_surface

local fullscreen_viewer = require("ui.fullscreen_viewer")

print("--- test_fullscreen_viewer.lua ---")

--------------------------------------------------------------------------------
-- Test 1: Initial state
--------------------------------------------------------------------------------

print("  test: initial state is inactive")
assert(fullscreen_viewer.is_active() == false, "should start inactive")
assert(fullscreen_viewer.get_current_view_id() == nil, "no current view_id")

--------------------------------------------------------------------------------
-- Test 2: enter() activates with correct view_id
--------------------------------------------------------------------------------

print("  test: enter() activates fullscreen")
reset_surface_calls()
fullscreen_viewer.enter("timeline_monitor")
assert(fullscreen_viewer.is_active() == true, "should be active after enter")
assert(fullscreen_viewer.get_current_view_id() == "timeline_monitor",
    "view_id should be timeline_monitor")

-- Verify mirror was installed on timeline_monitor
assert(tl_monitor._frame_mirror ~= nil, "timeline_monitor should have frame mirror")
assert(src_monitor._frame_mirror == nil, "source_monitor should NOT have frame mirror")

--------------------------------------------------------------------------------
-- Test 3: Frame mirror forwarding during enter (on_model_changed push)
--------------------------------------------------------------------------------

print("  test: enter() defers frame push until Metal ready")
-- Frame push is deferred via SURFACE_ON_READY — no calls yet
local pre_ready_calls = {}
for _, c in ipairs(surface_calls) do
    if c.op == "SET_FRAME" then
        pre_ready_calls[#pre_ready_calls + 1] = c
    end
end
assert(#pre_ready_calls == 0, string.format(
    "expected 0 SET_FRAME calls before ready, got %d", #pre_ready_calls))

-- Now simulate Metal becoming ready on the fullscreen surface
reset_surface_calls()
fire_surface_ready(tl_monitor._frame_mirror)

local frame_calls = {}
for _, c in ipairs(surface_calls) do
    if c.op == "SET_FRAME" then
        frame_calls[#frame_calls + 1] = c
    end
end
assert(#frame_calls >= 2, string.format(
    "expected at least 2 SET_FRAME calls after ready (main + mirror), got %d", #frame_calls))

--------------------------------------------------------------------------------
-- Test 4: Frame mirror forwarding on show_frame
--------------------------------------------------------------------------------

print("  test: _on_show_frame forwards to mirror")
reset_surface_calls()
local fake_frame = { _name = "test_frame_42" }
tl_monitor:_on_show_frame(fake_frame, {})

-- Should have 2 SET_FRAME calls: one for main surface, one for mirror
local main_call, mirror_call
for _, c in ipairs(surface_calls) do
    if c.op == "SET_FRAME" and c.surface == tl_surface then
        main_call = c
    elseif c.op == "SET_FRAME" and c.surface == tl_monitor._frame_mirror then
        mirror_call = c
    end
end
assert(main_call, "SET_FRAME should be called on main surface")
assert(mirror_call, "SET_FRAME should be called on mirror surface")
assert(main_call.args[1] == fake_frame, "main surface should get the frame")
assert(mirror_call.args[1] == fake_frame, "mirror surface should get the frame")

--------------------------------------------------------------------------------
-- Test 5: _on_show_gap forwards to mirror
--------------------------------------------------------------------------------

print("  test: _on_show_gap forwards to mirror")
reset_surface_calls()
tl_monitor:_on_show_gap()

local gap_calls = {}
for _, c in ipairs(surface_calls) do
    if c.op == "SET_FRAME" and c.args[1] == nil then
        gap_calls[#gap_calls + 1] = c
    end
end
assert(#gap_calls >= 2, string.format(
    "expected at least 2 nil-frame calls (main + mirror), got %d", #gap_calls))

--------------------------------------------------------------------------------
-- Test 6: _on_set_rotation forwards to mirror
--------------------------------------------------------------------------------

print("  test: _on_set_rotation forwards to mirror")
reset_surface_calls()
tl_monitor:_on_set_rotation(90)

local rot_calls = {}
for _, c in ipairs(surface_calls) do
    if c.op == "SET_ROTATION" then
        rot_calls[#rot_calls + 1] = c
    end
end
assert(#rot_calls == 2, string.format(
    "expected 2 SET_ROTATION calls, got %d", #rot_calls))

--------------------------------------------------------------------------------
-- Test 7: _on_set_par forwards to mirror
--------------------------------------------------------------------------------

print("  test: _on_set_par forwards to mirror")
reset_surface_calls()
tl_monitor:_on_set_par(16, 15)

local par_calls = {}
for _, c in ipairs(surface_calls) do
    if c.op == "SET_PAR" then
        par_calls[#par_calls + 1] = c
    end
end
assert(#par_calls == 2, string.format(
    "expected 2 SET_PAR calls, got %d", #par_calls))

--------------------------------------------------------------------------------
-- Test 8: switch_viewer clears old mirror, sets new
--------------------------------------------------------------------------------

print("  test: switch_viewer swaps mirror between monitors")
reset_surface_calls()
fullscreen_viewer.switch_viewer("source_monitor")

assert(fullscreen_viewer.get_current_view_id() == "source_monitor",
    "view_id should be source_monitor after switch")
assert(tl_monitor._frame_mirror == nil,
    "timeline_monitor mirror should be cleared after switch")
assert(src_monitor._frame_mirror ~= nil,
    "source_monitor should have frame mirror after switch")

-- Verify frame push happened on source_monitor
local switch_frame_calls = {}
for _, c in ipairs(surface_calls) do
    if c.op == "SET_FRAME" then
        switch_frame_calls[#switch_frame_calls + 1] = c
    end
end
assert(#switch_frame_calls >= 1, "switch_viewer should push current frame")

--------------------------------------------------------------------------------
-- Test 9: switch_viewer no-op when same view_id
--------------------------------------------------------------------------------

print("  test: switch_viewer no-op for same view_id")
reset_surface_calls()
fullscreen_viewer.switch_viewer("source_monitor")
-- Should be a no-op, no calls
assert(#surface_calls == 0, "switch_viewer with same view_id should be no-op")

--------------------------------------------------------------------------------
-- Test 10: exit() clears state
--------------------------------------------------------------------------------

print("  test: exit() deactivates and clears mirror")
fullscreen_viewer.exit()
assert(fullscreen_viewer.is_active() == false, "should be inactive after exit")
assert(fullscreen_viewer.get_current_view_id() == nil, "view_id should be nil after exit")
assert(src_monitor._frame_mirror == nil, "source_monitor mirror should be cleared after exit")

--------------------------------------------------------------------------------
-- Test 11: exit() when inactive is no-op
--------------------------------------------------------------------------------

print("  test: exit() when inactive is safe no-op")
fullscreen_viewer.exit()  -- should not error
assert(fullscreen_viewer.is_active() == false)

--------------------------------------------------------------------------------
-- Test 12: toggle() enters and exits
--------------------------------------------------------------------------------

print("  test: toggle() enters when inactive, exits when active")
fullscreen_viewer.toggle("timeline_monitor")
assert(fullscreen_viewer.is_active() == true, "toggle should enter")
assert(fullscreen_viewer.get_current_view_id() == "timeline_monitor")

fullscreen_viewer.toggle("timeline_monitor")
assert(fullscreen_viewer.is_active() == false, "toggle should exit")

--------------------------------------------------------------------------------
-- Test 13: No mirror forwarding when mirror not set
--------------------------------------------------------------------------------

print("  test: no forwarding when mirror not set")
assert(tl_monitor._frame_mirror == nil, "precondition: no mirror")
reset_surface_calls()
tl_monitor:_on_show_frame({ _name = "lone_frame" }, {})

-- Should only have 1 SET_FRAME (main surface only)
local lone_calls = {}
for _, c in ipairs(surface_calls) do
    if c.op == "SET_FRAME" then
        lone_calls[#lone_calls + 1] = c
    end
end
assert(#lone_calls == 1, string.format(
    "without mirror, expected 1 SET_FRAME call, got %d", #lone_calls))

--------------------------------------------------------------------------------
-- Test 14: project_changed exits fullscreen
--------------------------------------------------------------------------------

print("  test: project_changed signal exits fullscreen")
fullscreen_viewer.enter("timeline_monitor")
assert(fullscreen_viewer.is_active() == true, "precondition: active")

Signals.emit("project_changed", "new_project_123")
assert(fullscreen_viewer.is_active() == false,
    "project_changed should exit fullscreen")

--------------------------------------------------------------------------------
-- Test 15: enter() asserts when already active
--------------------------------------------------------------------------------

print("  test: enter() asserts when already active")
fullscreen_viewer.enter("timeline_monitor")
local ok, err = pcall(fullscreen_viewer.enter, "source_monitor")
assert(not ok, "enter() while active should assert")
assert(err:find("already active"), "error should mention already active")
fullscreen_viewer.exit()  -- cleanup

--------------------------------------------------------------------------------
-- Test 16: switch_viewer asserts when not active
--------------------------------------------------------------------------------

print("  test: switch_viewer asserts when not active")
local ok2, err2 = pcall(fullscreen_viewer.switch_viewer, "source_monitor")
assert(not ok2, "switch_viewer while inactive should assert")
assert(err2:find("not active"), "error should mention not active")

--------------------------------------------------------------------------------
-- Test 17: enter() installs C++ mirror surface on engine
--------------------------------------------------------------------------------

print("  test: enter() installs C++ mirror surface on engine")
reset_engine_mirror_calls()
fullscreen_viewer.enter("timeline_monitor")

-- Should have called set_mirror_surface on the timeline engine
local set_calls = {}
for _, c in ipairs(engine_mirror_calls) do
    if c.op == "set" then set_calls[#set_calls + 1] = c end
end
assert(#set_calls == 1, string.format(
    "expected 1 set_mirror_surface call on enter, got %d", #set_calls))
assert(set_calls[1].engine == tl_monitor.engine,
    "set_mirror_surface should be called on timeline engine")

--------------------------------------------------------------------------------
-- Test 18: exit() clears C++ mirror surface
--------------------------------------------------------------------------------

print("  test: exit() clears C++ mirror surface on engine")
reset_engine_mirror_calls()
fullscreen_viewer.exit()

local clear_calls = {}
for _, c in ipairs(engine_mirror_calls) do
    if c.op == "clear" then clear_calls[#clear_calls + 1] = c end
end
assert(#clear_calls == 1, string.format(
    "expected 1 clear_mirror_surface call on exit, got %d", #clear_calls))
assert(clear_calls[1].engine == tl_monitor.engine,
    "clear_mirror_surface should be called on timeline engine")

--------------------------------------------------------------------------------
-- Test 19: switch_viewer moves C++ mirror between engines
--------------------------------------------------------------------------------

print("  test: switch_viewer moves C++ mirror surface between engines")
fullscreen_viewer.enter("timeline_monitor")
reset_engine_mirror_calls()
fullscreen_viewer.switch_viewer("source_monitor")

-- Should clear old engine, set new engine
local sw_clear, sw_set = {}, {}
for _, c in ipairs(engine_mirror_calls) do
    if c.op == "clear" then sw_clear[#sw_clear + 1] = c end
    if c.op == "set" then sw_set[#sw_set + 1] = c end
end
assert(#sw_clear == 1, string.format(
    "expected 1 clear on switch, got %d", #sw_clear))
assert(sw_clear[1].engine == tl_monitor.engine,
    "clear should target old (timeline) engine")
assert(#sw_set == 1, string.format(
    "expected 1 set on switch, got %d", #sw_set))
assert(sw_set[1].engine == src_monitor.engine,
    "set should target new (source) engine")

fullscreen_viewer.exit()  -- cleanup

--------------------------------------------------------------------------------
-- Test 20: enter() asserts on nil view_id
--------------------------------------------------------------------------------

print("  test: enter() asserts on nil view_id")
local ok3, err3 = pcall(fullscreen_viewer.enter, nil)
assert(not ok3, "enter(nil) should assert")
assert(err3:find("view_id required"), "error should mention view_id, got: " .. tostring(err3))

--------------------------------------------------------------------------------
-- Test 21: enter() asserts on empty view_id
--------------------------------------------------------------------------------

print("  test: enter() asserts on empty view_id")
local ok4, err4 = pcall(fullscreen_viewer.enter, "")
assert(not ok4, "enter('') should assert")
assert(err4:find("view_id required"), "error should mention view_id, got: " .. tostring(err4))

--------------------------------------------------------------------------------
-- Test 22: switch_viewer() asserts on nil view_id
--------------------------------------------------------------------------------

print("  test: switch_viewer() asserts on nil view_id")
fullscreen_viewer.enter("timeline_monitor")
local ok5, err5 = pcall(fullscreen_viewer.switch_viewer, nil)
assert(not ok5, "switch_viewer(nil) should assert")
assert(err5:find("view_id required"), "error should mention view_id, got: " .. tostring(err5))
fullscreen_viewer.exit()

--------------------------------------------------------------------------------
-- Test 23: switch_viewer() asserts on empty view_id
--------------------------------------------------------------------------------

print("  test: switch_viewer() asserts on empty view_id")
fullscreen_viewer.enter("timeline_monitor")
local ok6, err6 = pcall(fullscreen_viewer.switch_viewer, "")
assert(not ok6, "switch_viewer('') should assert")
assert(err6:find("view_id required"), "error should mention view_id, got: " .. tostring(err6))
fullscreen_viewer.exit()

--------------------------------------------------------------------------------
-- Test 24: SURFACE_ON_READY fires after exit (race condition → safe no-op)
--------------------------------------------------------------------------------

print("  test: SURFACE_ON_READY after exit is safe no-op")
fullscreen_viewer.enter("timeline_monitor")
local race_surface = tl_monitor._frame_mirror
assert(race_surface, "mirror should be set")
fullscreen_viewer.exit()
-- Now fire ready on the orphaned surface — should not error
fire_surface_ready(race_surface)
assert(fullscreen_viewer.is_active() == false, "should still be inactive")

--------------------------------------------------------------------------------
-- Test 25: clear_frame_mirror when no mirror is safe no-op
--------------------------------------------------------------------------------

print("  test: clear_frame_mirror when no mirror is no-op")
assert(tl_monitor._frame_mirror == nil, "precondition: no mirror")
tl_monitor:clear_frame_mirror()  -- should not error
assert(tl_monitor._frame_mirror == nil)

--------------------------------------------------------------------------------
-- Test 26: set_frame_mirror(nil) asserts
--------------------------------------------------------------------------------

print("  test: set_frame_mirror(nil) asserts")
local ok7, err7 = pcall(function()
    tl_monitor:set_frame_mirror(nil)
end)
assert(not ok7, "set_frame_mirror(nil) should assert")
assert(err7:find("surface required"), "error should mention surface, got: " .. tostring(err7))

--------------------------------------------------------------------------------
-- Test 27: ToggleFullscreenView command (enter with focus)
--------------------------------------------------------------------------------

print("  test: ToggleFullscreenView command enters for focused viewer")
-- Load the command module
local toggle_cmd = require("core.commands.toggle_fullscreen_view")
local reg = toggle_cmd.register({}, {}, nil)
assert(reg.executor, "command should have executor")
assert(reg.spec.undoable == false, "command should be non-undoable")

-- Focus is on timeline_monitor (set at top of file)
_focused_panel = "timeline_monitor"
reg.executor({})
assert(fullscreen_viewer.is_active() == true, "command should enter fullscreen")
assert(fullscreen_viewer.get_current_view_id() == "timeline_monitor",
    "should fullscreen timeline_monitor when focused")

-- Toggle again exits
reg.executor({})
assert(fullscreen_viewer.is_active() == false, "command should exit fullscreen")

--------------------------------------------------------------------------------
-- Test 28: ToggleFullscreenView defaults to timeline_monitor for non-viewer panels
--------------------------------------------------------------------------------

print("  test: ToggleFullscreenView defaults to timeline_monitor for non-viewer focus")
_focused_panel = "project_browser"
reg.executor({})
assert(fullscreen_viewer.is_active() == true)
assert(fullscreen_viewer.get_current_view_id() == "timeline_monitor",
    "non-viewer focus should default to timeline_monitor")
fullscreen_viewer.exit()

--------------------------------------------------------------------------------
-- Test 29: ToggleFullscreenView enters source_monitor when focused
--------------------------------------------------------------------------------

print("  test: ToggleFullscreenView enters source_monitor when focused")
_focused_panel = "source_monitor"
reg.executor({})
assert(fullscreen_viewer.is_active() == true)
assert(fullscreen_viewer.get_current_view_id() == "source_monitor",
    "should fullscreen source_monitor when focused")
fullscreen_viewer.exit()

print("✅ test_fullscreen_viewer.lua passed")
