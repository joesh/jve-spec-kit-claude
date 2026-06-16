#!/usr/bin/env luajit
--- Blanking the timeline body (no displayed tab) must be a tolerated view
--- state, not a crash trigger.
---
--- Repro (TSO 2026-06-15): pressing ` (ToggleSourceRecordTab) from the
--- record tab with no source master loaded blanks the body. Two view-layer
--- paths then asserted on the now-nil displayed cache:
---
---   1. command_manager.execute_interactive runs the post-command viewport
---      policy, which calls viewport_state.surface_playhead(). With the body
---      blanked, surface_playhead hit cache_strict -> assert -> the command
---      itself crashed ("shortcut handler ToggleSourceRecordTab: ...
---      surface_playhead: no displayed tab (cache nil)").
---
---   2. Every subsequent ruler repaint asserted at timeline_ruler render
---      ("viewport_start_time is nil"), a runaway LUA CALLBACK ERROR cascade.
---
--- Both are blank-panel states the view layer must absorb (the public
--- viewport getters already return nil for "blank panel"; the surfacing
--- entry points and the ruler render must honour that, not assert).

require("test_env")

_G.qt_create_single_shot_timer  = function(_d, cb) if cb then cb() end end
_G.qt_set_focus_handler         = function() end
_G.qt_set_widget_attribute      = function() end
_G.qt_set_widget_contents_margins = function() end
_G.qt_set_widget_property       = function() end
_G.qt_set_widget_stylesheet     = function() end
_G.qt_set_focus                 = function() end

package.loaded["ui.selection_hub"] = { set_active_panel = function() end }

print("=== test_blank_body_tolerates_surface_and_ruler.lua ===")

local database        = require("core.database")
local timeline_state  = require("ui.timeline.timeline_state")
local focus_manager   = require("ui.focus_manager")
local command_manager = require("core.command_manager")

local DB = "/tmp/jve/test_blank_body_tolerates_surface_and_ruler.db"
os.remove(DB); os.remove(DB .. "-wal"); os.remove(DB .. "-shm")
os.execute("mkdir -p /tmp/jve")
assert(database.init(DB))
local conn = database.get_connection()
conn:exec(require("import_schema"))
local now = os.time()
conn:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at)
    VALUES ('p', 'P', 'resample', %d, %d)
]], now, now))
-- Non-trivial playhead (matches the real TSO: parked at frame 90973) so the
-- post-command policy sees the playhead change number -> nil and actually
-- fires surface_playhead. A zero playhead would be a degenerate value.
conn:exec(string.format([[
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator,
        fps_denominator, audio_sample_rate, width, height,
        playhead_frame, view_start_frame, view_duration_frames,
        created_at, modified_at)
    VALUES ('rec', 'p', 'Rec', 'sequence', 25, 1, 48000, 1920, 1080,
        90973, 90000, 1505, %d, %d)
]], now, now))

timeline_state.reset()
timeline_state.init("rec", "p")
command_manager.init("rec", "p")

focus_manager.register_panel("timeline", {_id=1}, nil, "Timeline")

-- Sanity: the record tab is displayed and parked at the fixture playhead.
assert(timeline_state.get_playhead_position() == 90973,
    "fixture: record tab must be displayed and parked at 90973")

-- -------------------------------------------------------------------------
-- Drive the real toggle to reach the blank body. From the record tab with
-- no source master loaded, ToggleSourceRecordTab clears the displayed tab.
-- (The test harness wraps tests in a "script" command event, so the
-- post-command viewport policy that calls surface_playhead in production is
-- intentionally suppressed here — command_manager.lua opts scripted contexts
-- out of UI repainting. We therefore exercise the surfacing entry points
-- DIRECTLY below: those are the exact calls the policy makes after an
-- interactive action, and the calls that asserted in the TSO.)
-- -------------------------------------------------------------------------
local ok, err = pcall(command_manager.execute_interactive, "ToggleSourceRecordTab", {})
assert(ok, string.format("ToggleSourceRecordTab execute failed: %s", tostring(err)))

-- The body is now blank: the public getters report nil (no displayed tab).
assert(timeline_state.get_viewport_start_time() == nil,
    "after blanking, viewport_start_time must read nil (blank panel)")
assert(timeline_state.get_playhead_position() == nil,
    "after blanking, playhead_position must read nil (blank panel)")
print("  \u{2713} ToggleSourceRecordTab blanks the body (getters read nil)")

-- -------------------------------------------------------------------------
-- Path 1: the view-layer surfacing entry points the post-command policy
-- invokes (surface_playhead on execute, surface_range on undo/redo) must
-- no-op on a blank body, not assert on the nil displayed cache.
-- -------------------------------------------------------------------------
assert(timeline_state.surface_playhead() == false,
    "surface_playhead on a blank body must no-op (return false), not assert")
-- Non-trivial, in-order frames (surface_range asserts end >= start before
-- it ever looks at the cache, so the values must be a valid range).
assert(timeline_state.surface_range(120, 480) == false,
    "surface_range on a blank body must no-op (return false), not assert")
print("  \u{2713} surface_playhead / surface_range no-op on blank body")

-- -------------------------------------------------------------------------
-- Path 2: the ruler must repaint a blank body without asserting. Stub the
-- C++ `timeline` drawing binding (the binding boundary, same seam the qt_*
-- stubs above use) and render against the now-blank state_module.
-- -------------------------------------------------------------------------
local draw_calls = { rects = 0, updates = 0 }
_G.timeline = {
    get_dimensions          = function() return 1375, 32 end,
    clear_commands          = function() end,
    set_pan_offset_px       = function() end,
    add_rect                = function() draw_calls.rects = draw_calls.rects + 1 end,
    add_line                = function() end,
    add_text                = function() end,
    add_triangle            = function() end,
    update                  = function() draw_calls.updates = draw_calls.updates + 1 end,
    set_lua_state           = function() end,
    set_mouse_event_handler = function() end,
    set_resize_event_handler = function() end,
}

local timeline_ruler = require("ui.timeline.timeline_ruler")
-- M.create runs an initial render() during construction; with a blank body
-- that initial render is exactly the repaint that crashed in the TSO.
local ok_ruler, ruler_or_err = pcall(timeline_ruler.create, {_widget = true}, timeline_state)
assert(ok_ruler, string.format(
    "timeline_ruler.create must repaint a blank body without asserting, "
    .. "but it crashed: %s", tostring(ruler_or_err)))

-- A blank ruler still paints its chrome (background + baseline) so stale
-- content doesn't linger; it just stops before the viewport-dependent ticks.
assert(draw_calls.rects >= 2 and draw_calls.updates >= 1,
    "blank ruler must still paint background chrome and flush an update")

-- An explicit repaint after blanking (the cascade in the TSO was repeated
-- single-shot repaints) must also be clean.
local ok_render = pcall(ruler_or_err.render)
assert(ok_render, "explicit ruler.render() on a blank body must not assert")
print("  \u{2713} ruler repaints blank body without asserting")

-- -------------------------------------------------------------------------
-- Path 3: a mouse press on the blanked timeline body must be an inert
-- no-op, not a crash. The view's input handler hit-tests then grabs the
-- playhead, and get_playhead_position()/time_to_pixel assert on the nil
-- displayed cache (TSO 2026-06-15: "time_to_pixel: no displayed tab" via
-- TimelineRenderer.mouse_press). The `timeline` binding stub from Path 2
-- supplies get_dimensions; the only view collaborator we provide is the
-- honest "no track at any y" answer for an empty timeline.
-- -------------------------------------------------------------------------
local view_input = require("ui.timeline.view.timeline_view_input")
local view = {
    state             = timeline_state,
    widget            = {_widget = true},
    pending_gap_click = nil,
    get_track_id_at_y = function() return nil end,  -- blank body: no track
    render            = function() end,
}
-- Left button (1); non-trivial widget-local coords inside a 1375px ruler.
local ok_press, press_err = pcall(view_input.handle_mouse, view, "press", 640, 200, 1, {})
assert(ok_press, string.format(
    "a left-press on the blanked timeline body must no-op, not assert: %s",
    tostring(press_err)))
print("  \u{2713} mouse press on blank body is an inert no-op")

print("\n\u{2705} test_blank_body_tolerates_surface_and_ruler.lua passed")
