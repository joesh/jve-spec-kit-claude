#!/usr/bin/env luajit
--- 019 T008d: timeline double-click dispatches OpenClipInSourceMonitor.
---
--- Per spec FR-026 + FR-027 + contracts/open_clip_in_source_monitor.md.
--- The Qt-bound mouse double-click event on the timeline view routes to
--- a Lua handler which:
---   * resolves the clip under the cursor (existing hit-test code path),
---   * dispatches `OpenClipInSourceMonitor` with that clip's ids on a real
---     timeline clip,
---   * rejects gap-as-clip rows (FR-027) — log event, no dispatch,
---   * no-ops on empty space — no dispatch (FR-027).
---
--- Tested via a new public method `M.handle_clip_double_click(view, x, y)`
--- exposed by timeline_view_input (introduced by T024 — Qt binding calls
--- this from the C++ side). Black-box: stubs the view's hit-test to
--- return known fixtures; captures command_manager dispatches.

require("test_env")

_G.qt_create_single_shot_timer = function() end
_G.qt_set_focus = function() end
_G.timeline = setmetatable({
    get_dimensions = function() return 1920, 200 end,
}, { __index = function() return function() end end })
package.loaded["ui.panel_manager"] = {
    get_active_sequence_monitor = function() return nil end,
}

-- Capture command_manager dispatches.
local dispatched = {}
local real_cm_loaded = package.loaded["core.command_manager"]
package.loaded["core.command_manager"] = {
    execute_interactive = function(name, args)
        table.insert(dispatched, { name = name, args = args })
        return { success = true }
    end,
}

local timeline_view_input = require("ui.timeline.view.timeline_view_input")

print("=== test_timeline_double_click_dispatches_open_clip.lua ===")

assert(type(timeline_view_input.handle_clip_double_click) == "function",
    string.format(
    "timeline_view_input must expose handle_clip_double_click(view, x, y) "
    .. "as the entry point Qt's MouseButtonDblClick dispatches into; got %s",
    type(timeline_view_input.handle_clip_double_click)))

-- View stub. The hit-test is the only behavior the handler needs from
-- the view; everything else is irrelevant to dispatch routing.
local function make_view(hit_result)
    return {
        state  = { selected_clips = {} },
        widget = "fake-widget",
        -- The handler's only real query: "what's under the cursor at
        -- (x, y)?" Stubbed to return one of: a real clip table, a
        -- gap-as-clip row (with is_gap=true), or nil for empty space.
        hit_test_clip = function(_x, _y) return hit_result end,
    }
end

-- ── Scenario 1: real clip → dispatch ─────────────────────────────────────────
do
    dispatched = {}
    local clip = {
        id                = "clip_alpha",
        project_id        = "proj_X",
        owner_sequence_id = "owner_seq_1",
        -- is_gap absent or false → real clip
    }
    local view = make_view(clip)

    timeline_view_input.handle_clip_double_click(view, 500, 100)

    assert(#dispatched == 1, string.format(
        "real-clip double-click must dispatch exactly one command; got %d",
        #dispatched))
    assert(dispatched[1].name == "OpenClipInSourceMonitor", string.format(
        "double-click dispatches OpenClipInSourceMonitor; got %q",
        tostring(dispatched[1].name)))
    assert(dispatched[1].args.clip_id == "clip_alpha",
        "dispatch must carry clip_id")
    assert(dispatched[1].args.project_id == "proj_X",
        "dispatch must carry project_id")
    assert(dispatched[1].args.sequence_id == "owner_seq_1", string.format(
        "dispatch sequence_id must be the OWNER sequence (where the clip lives); "
        .. "got %q", tostring(dispatched[1].args.sequence_id)))
    print("  ✓ real clip → OpenClipInSourceMonitor dispatched with correct ids")
end

-- ── Scenario 2: gap-as-clip → rejected (FR-027) ──────────────────────────────
do
    dispatched = {}
    local gap = {
        id                = "gap_xyz",
        project_id        = "proj_X",
        owner_sequence_id = "owner_seq_1",
        is_gap            = true,
    }
    local view = make_view(gap)

    timeline_view_input.handle_clip_double_click(view, 500, 100)

    assert(#dispatched == 0, string.format(
        "gap-as-clip double-click must NOT dispatch; got %d dispatches",
        #dispatched))
    print("  ✓ gap-as-clip rejected; no dispatch")
end

-- ── Scenario 3: empty space → no-op (FR-027) ─────────────────────────────────
do
    dispatched = {}
    local view = make_view(nil)  -- hit_test_clip returns nil

    timeline_view_input.handle_clip_double_click(view, 1500, 100)

    assert(#dispatched == 0, string.format(
        "double-click on empty timeline space must NOT dispatch; got %d",
        #dispatched))
    print("  ✓ empty space → no-op (no dispatch)")
end

-- Restore command_manager so other downstream tests (if any) see real one.
package.loaded["core.command_manager"] = real_cm_loaded

print("\n✅ test_timeline_double_click_dispatches_open_clip.lua passed")
