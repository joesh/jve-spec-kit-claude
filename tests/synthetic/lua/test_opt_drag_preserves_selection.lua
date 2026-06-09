#!/usr/bin/env luajit
--- Regression: starting an Opt/Alt drag (duplicate) on an ALREADY-SELECTED
--- clip must NOT change the selection. Pressing Opt to begin a duplicate-drag
--- previously re-ran SelectClips with the Alt modifier, which EXPANDS the
--- selection to the whole link group — so a deliberate partial selection
--- (e.g. a video clip + ONE audio clip of a 3-member group) got clobbered
--- into the full group, and the duplicate copied clips the user never
--- selected.
---
--- Domain rule (Joe, 2026-05-28): Opt-drag duplicates EXACTLY the current
--- selection. Alt-CLICK expansion of an UNSELECTED clip is unchanged.
---
--- Black-box: drives the real mouse-press handler and checks whether a
--- SelectClips command is dispatched. No assertions about internals.

require("test_env")

-- Stub the harness surfaces the press path touches (mirrors
-- test_timeline_double_click_dispatches_open_clip.lua's approach).
_G.timeline = setmetatable({
    get_dimensions = function() return 2000, 200 end,
}, { __index = function() return function() end end })
_G.qt_set_focus = function() end
_G.qt_create_single_shot_timer = function(_, cb) if cb then cb() end end

package.loaded["ui.focus_manager"] = {
    set_focused_panel = function() end,
}

local dispatched = {}
package.loaded["core.command_manager"] = {
    execute_interactive = function(name, args)
        table.insert(dispatched, { name = name, args = args })
        return { success = true }
    end,
}

local input = require("ui.timeline.view.timeline_view_input")

print("=== test_opt_drag_preserves_selection.lua ===")

-- One clip spanning frames 100..300 (pixels 100..300 with 1px=1frame). A
-- click at x=200 lands dead-center, clear of edge zones, so the press routes
-- to clip selection (not edge picking).
local CLIP = { id = "cv", sequence_start = 100, duration = 200, is_gap = false }

local function make_view(selected)
    return {
        widget = "w",
        render = function() end,
        get_track_id_at_y = function() return "trk1" end,
        state = {
            get_selected_clips = function() return selected end,
            get_project_id = function() return "proj" end,
            get_tab_strip = function()
                return {
                    active_sequence_id = function() return "seq" end,
                    track_clip_index = function() return { CLIP } end,
                }
            end,
            pixel_to_time = function(x) return x end,
            time_to_pixel = function(t) return t end,
            get_playhead_position = function() return 0 end,
        },
    }
end

local function count_dispatched(name)
    local n = 0
    for _, d in ipairs(dispatched) do if d.name == name then n = n + 1 end end
    return n
end

local LEFT = 1

-- ── Scenario A: Opt-drag-start on an ALREADY-SELECTED clip ───────────────
-- Must preserve the selection: NO SelectClips dispatch (no alt-expansion).
do
    dispatched = {}
    local view = make_view({ CLIP })  -- clip is already selected
    input.handle_mouse(view, "press", 200, 100, LEFT, { alt = true })

    assert(count_dispatched("SelectClips") == 0, string.format(
        "Opt-press on an already-selected clip must NOT re-run SelectClips "
        .. "(would expand selection to the link group); got %d dispatch(es)",
        count_dispatched("SelectClips")))
    assert(view.potential_drag and view.potential_drag.type == "clips",
        "a clip drag must be armed")
    local armed = false
    for _, c in ipairs(view.potential_drag.clips or {}) do
        if c.id == "cv" then armed = true end
    end
    assert(armed, "armed drag must carry the existing selection")
    print("  ✓ opt-press on selected clip preserves selection (no SelectClips)")
end

-- ── Scenario B: Opt-click on an UNSELECTED clip ──────────────────────────
-- Selection changes → SelectClips IS dispatched (alt-expansion preserved).
do
    dispatched = {}
    local view = make_view({})  -- nothing selected yet
    input.handle_mouse(view, "press", 200, 100, LEFT, { alt = true })

    assert(count_dispatched("SelectClips") == 1, string.format(
        "Opt-click on an unselected clip must dispatch SelectClips "
        .. "(selection change + alt-expansion); got %d", count_dispatched("SelectClips")))
    print("  ✓ opt-click on unselected clip still dispatches SelectClips")
end

print("\n✅ test_opt_drag_preserves_selection.lua passed")
