#!/usr/bin/env luajit
-- Regression test: click-to-focus skips Qt focus steal when focus is already
-- inside the main window (FR for Inspector panel rewrite, feature 012).
-- Joe reported: clicking an Inspector field didn't land focus there because
-- the click-to-focus handler unconditionally called qt_set_focus on
-- focus_widgets[1] (scroll_area), stealing focus from the clicked line edit.
-- Fix: conditional steal — only fire when coming from outside main window.

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require("test_env")

-- ---------------------------------------------------------------
-- Stub Qt bindings: we only need to observe which functions fire.
-- ---------------------------------------------------------------
local qt_set_focus_calls = {}
_G.qt_set_focus = function(w) table.insert(qt_set_focus_calls, w) end

-- Installed by qt_install_panel_focus_filter at startup (a no-op here).
_G.qt_install_panel_focus_filter = function(_handler_name) end
_G.qt_register_panel_focus_widget = function(_w, _pid) end
_G.qt_set_focus_handler = function(_w, _h) end

-- Pre-existing Qt state access.
local focus_outside_main_window_flag = false
_G.qt_focus_outside_main_window = function() return focus_outside_main_window_flag end

-- Minimal stubs for ancillary bindings touched during register_panel.
_G.qt_set_widget_attribute = function() end
_G.qt_set_widget_contents_margins = function() end
_G.qt_set_widget_property = function() end

-- Replace ui_constants color lookup we don't care about.
package.loaded["core.ui_constants"] = {
    COLORS = {
        STATE_FOCUS = "#0078d4",
        SURFACE_CHROME = "#28282e",
    },
}

-- Stub selection_hub — focus_manager touches it in set_focused_panel.
package.loaded["ui.selection_hub"] = {
    set_active_panel = function(_) end,
}

require("ui.selection_hub")  -- ensure it's cached first
package.loaded["ui.focus_manager"] = nil
local focus_manager = require("ui.focus_manager")

-- ---------------------------------------------------------------
-- Test setup: register a fake panel, install click handler.
-- ---------------------------------------------------------------
local fake_primary_widget = {_kind = "primary"}
local fake_panel_widget   = {_kind = "panel"}

focus_manager.register_panel("inspector", fake_panel_widget, nil, "Inspector", {
    focus_widgets = { fake_primary_widget },
})

focus_manager.install_click_to_focus()
local handler = _G._panel_click_focus_handler
assert(type(handler) == "function",
    "focus_manager.install_click_to_focus did not install _panel_click_focus_handler")

local pass, fail = 0, 0
local function check(label, ok) if ok then pass = pass + 1 else fail = fail + 1; print("FAIL: " .. label) end end

print("=== focus_manager: conditional click-to-focus steal ===\n")

-- Case 1: focus already inside main window (cross_window = false).
-- Expectation: visual update only. qt_set_focus MUST NOT fire.
focus_outside_main_window_flag = false
qt_set_focus_calls = {}
handler("inspector")
check("within-main-window: qt_set_focus not called",
    #qt_set_focus_calls == 0)
check("within-main-window: panel is now focused",
    focus_manager.get_focused_panel() == "inspector")

-- Case 2: focus outside main window (floating tool window — cross_window = true).
-- Expectation: focus_panel IS called → qt_set_focus fires with primary widget.
focus_outside_main_window_flag = true
qt_set_focus_calls = {}
handler("inspector")
check("cross-window: qt_set_focus fires exactly once",
    #qt_set_focus_calls == 1)
check("cross-window: qt_set_focus targets primary widget (focus_widgets[1])",
    qt_set_focus_calls[1] == fake_primary_widget)

-- Case 3: unknown panel_id — handler is a no-op in either regime.
focus_outside_main_window_flag = false
qt_set_focus_calls = {}
handler("not_a_real_panel")
check("unknown panel_id: no qt_set_focus call (within)",
    #qt_set_focus_calls == 0)
focus_outside_main_window_flag = true
handler("not_a_real_panel")
check("unknown panel_id: no qt_set_focus call (cross)",
    #qt_set_focus_calls == 0)

-- Case 4: qt_focus_outside_main_window binding absent (older C++ build).
-- The handler must still behave safely — default to visual-only update.
_G.qt_focus_outside_main_window = nil
focus_outside_main_window_flag = false
qt_set_focus_calls = {}
handler("inspector")
check("binding-missing: defaults to within-window semantics (no steal)",
    #qt_set_focus_calls == 0)

print(string.format("\n--- %d passed, %d failed ---", pass, fail))
if fail > 0 then error(fail .. " failures") end
print("✅ test_inspector_focus_manager_click.lua passed")
