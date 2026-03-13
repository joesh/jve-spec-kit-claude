--- FullscreenViewer: output-only fullscreen video surface.
--
-- Creates a second GPUVideoSurface in a borderless fullscreen window.
-- The active SequenceMonitor mirrors its frames to this surface.
-- All input (keyboard, transport) continues through the main window.
--
-- Two mirror paths:
-- 1. Lua mirror (SequenceMonitor._frame_mirror): park mode / seek / model changes
-- 2. C++ mirror (PlaybackController.m_mirror_surface): CVDisplayLink playback hot path
--
-- @file fullscreen_viewer.lua
local log = require("core.logger").for_area("video")
local qt_constants = require("core.qt_constants")
local panel_manager = require("ui.panel_manager")
local Signals = require("core.signals")

local M = {}

-- State
local _active = false
local _current_view_id = nil
local _window = nil
local _surface = nil
-- Qt::Window | Qt::FramelessWindowHint | Qt::WindowStaysOnTopHint | Qt::WindowDoesNotAcceptFocus
local FRAMELESS_ONTOP_FLAGS = 0x00000001 + 0x00000800 + 0x00040000 + 0x00200000  -- 0x240801

--------------------------------------------------------------------------------
-- Internal helpers
--------------------------------------------------------------------------------

local function get_monitor(view_id)
    local monitor = panel_manager.get_sequence_monitor(view_id)
    assert(monitor, string.format(
        "fullscreen_viewer.get_monitor: no monitor for view_id=%s", tostring(view_id)))
    return monitor
end

--- Install both Lua and C++ mirror paths on a monitor.
local function install_mirror(monitor, surface)
    -- Lua path: park mode forwarding via SequenceMonitor callbacks
    monitor:set_frame_mirror(surface)
    -- C++ path: PlaybackController hot path forwarding during playback
    assert(monitor.engine, "install_mirror: monitor has no engine")
    assert(monitor.engine.set_mirror_surface,
        "install_mirror: engine missing set_mirror_surface")
    monitor.engine:set_mirror_surface(surface)
end

--- Remove both Lua and C++ mirror paths from a monitor.
local function remove_mirror(monitor)
    -- Lua path
    monitor:clear_frame_mirror()
    -- C++ path
    assert(monitor.engine, "remove_mirror: monitor has no engine")
    monitor.engine:clear_mirror_surface()
end

--- Push current frame/rotation/PAR from monitor to fullscreen surface.
local function push_current_state(monitor)
    -- If playing, the C++ mirror path handles ongoing frames — but we still
    -- need to push the current parked frame if stopped.
    if not monitor.engine:is_playing() then
        monitor:on_model_changed()
    end
    -- Either way, the C++ mirror is already installed, so the next deliverFrame
    -- will forward to the fullscreen surface.
    log.event("fullscreen: push_current_state playing=%s",
        tostring(monitor.engine:is_playing()))
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

--- Enter fullscreen mode for the given viewer.
-- @param view_id string  "source_monitor" or "timeline_monitor"
function M.enter(view_id)
    assert(view_id and view_id ~= "",
        "fullscreen_viewer.enter: view_id required")
    assert(not _active,
        "fullscreen_viewer.enter: already active, call exit() first")

    local monitor = get_monitor(view_id)

    -- Create GPUVideoSurface directly as a top-level borderless window.
    -- WindowDoesNotAcceptFocus keeps keyboard focus on the main window
    -- so focus_manager callbacks fire normally (audio follows focus, etc.).
    _surface = qt_constants.WIDGET.CREATE_GPU_VIDEO_SURFACE()
    assert(_surface, "fullscreen_viewer.enter: CREATE_GPU_VIDEO_SURFACE returned nil")
    qt_constants.WIDGET.SET_WINDOW_FLAGS(_surface, FRAMELESS_ONTOP_FLAGS)

    -- Cover the full primary screen
    local sx, sy, sw, sh = qt_constants.DISPLAY.SCREEN_GEOMETRY()
    assert(sw > 0 and sh > 0,
        string.format("fullscreen_viewer.enter: bad screen geometry %dx%d", sw, sh))
    qt_constants.PROPERTIES.SET_GEOMETRY(_surface, sx, sy, sw, sh)
    qt_constants.DISPLAY.SET_VISIBLE(_surface, true)
    _window = _surface  -- same widget, kept for exit() cleanup

    -- Install both Lua + C++ mirror paths
    install_mirror(monitor, _surface)

    _current_view_id = view_id
    _active = true

    -- Defer frame push until Metal layer is ready (avoids CAMetalLayer 0x0 error).
    -- Same pattern as SequenceMonitor._create_widgets SURFACE_ON_READY.
    assert(qt_constants.EMP.SURFACE_ON_READY,
        "fullscreen_viewer.enter: SURFACE_ON_READY binding required")
    log.event("fullscreen: waiting for SURFACE_ON_READY on %s", tostring(_surface))
    qt_constants.EMP.SURFACE_ON_READY(_surface, function()
        log.event("fullscreen: SURFACE_ON_READY fired, active=%s view=%s",
            tostring(_active), tostring(_current_view_id))
        if not _active then return end  -- exited before Metal was ready
        assert(_current_view_id,
            "fullscreen_viewer: SURFACE_ON_READY fired but no _current_view_id")
        local cur_monitor = get_monitor(_current_view_id)
        push_current_state(cur_monitor)
    end)

    log.event("fullscreen: entered for %s", view_id)
end

--- Exit fullscreen mode.
function M.exit()
    if not _active then return end

    -- Remove mirror from current monitor (both Lua + C++ paths).
    -- This MUST succeed — a dangling m_mirror_surface in C++ would crash
    -- on the next deliverFrame after the fullscreen surface is destroyed.
    assert(_current_view_id,
        "fullscreen_viewer.exit: active but no _current_view_id")
    local monitor = get_monitor(_current_view_id)
    remove_mirror(monitor)

    -- Hide fullscreen window (skip showNormal — it triggers unnecessary resize)
    if _window then
        qt_constants.DISPLAY.SET_VISIBLE(_window, false)
    end

    _active = false
    _current_view_id = nil
    _window = nil
    _surface = nil

    log.event("fullscreen: exited")
end

--- Toggle fullscreen for the given viewer.
-- @param view_id string  "source_monitor" or "timeline_monitor"
function M.toggle(view_id)
    if _active then
        M.exit()
    else
        M.enter(view_id)
    end
end

--- Switch which viewer is mirrored to fullscreen (called on focus change).
-- @param view_id string  "source_monitor" or "timeline_monitor"
function M.switch_viewer(view_id)
    assert(_active, "fullscreen_viewer.switch_viewer: not active")
    assert(view_id and view_id ~= "",
        "fullscreen_viewer.switch_viewer: view_id required")

    if view_id == _current_view_id then return end

    -- Disconnect mirror from old monitor WITHOUT clearing the surface to black.
    -- The old frame stays visible until the new monitor's frame overwrites it.
    local old_monitor = get_monitor(_current_view_id)
    old_monitor._frame_mirror = nil
    assert(old_monitor.engine, "switch_viewer: old monitor has no engine")
    old_monitor.engine:clear_mirror_surface()

    -- Install mirror on new monitor
    local new_monitor = get_monitor(view_id)
    install_mirror(new_monitor, _surface)
    _current_view_id = view_id

    -- Push current frame from new monitor
    push_current_state(new_monitor)

    log.event("fullscreen: switched to %s", view_id)
end

--- Check if fullscreen is active.
-- @return boolean
function M.is_active()
    return _active
end

--- Get current view_id (for testing).
-- @return string|nil
function M.get_current_view_id()
    return _current_view_id
end

--------------------------------------------------------------------------------
-- project_changed: exit fullscreen before anything else tears down
--------------------------------------------------------------------------------

Signals.connect("project_changed", function(_new_project_id)
    if _active then
        M.exit()
    end
end, 5)  -- priority 5: before playback_controller (10)

return M
