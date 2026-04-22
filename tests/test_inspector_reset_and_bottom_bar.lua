#!/usr/bin/env luajit
-- Retroactive test: bottom-bar visibility follows ui_state.mode (Apply +
-- Reset buttons appear only in multi_edit), and reset_pending reverts all
-- dirty fields while clearing the error banner state.
--
-- These paths were added to support Joe's "Apply/Reset belong outside the
-- scroll area, always visible at the bottom in multi-edit" UX rule.

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require("test_env")

-- Track SET_VISIBLE / SET_ENABLED on the three button-related widgets.
local visibility = {}  -- widget → bool
local enabled_state = {}

package.loaded["core.command_manager"] = {
    begin_command_event = function() end,
    end_command_event   = function() end,
}
package.loaded["core.qt_constants"] = {
    DISPLAY    = {
        SET_VISIBLE = function(w, v) visibility[w] = v end,
    },
    PROPERTIES = { SET_TEXT = function() end },
    CONTROL    = {
        SET_ENABLED = function(w, v) enabled_state[w] = v end,
    },
}
package.loaded["inspectable"] = {
    clip     = function() return nil end,
    sequence = function() return nil end,
}

package.loaded["ui.inspector.selection_binding"] = nil
local sb = require("ui.inspector.selection_binding")

local pass, fail = 0, 0
local function check(label, ok) if ok then pass = pass + 1 else fail = fail + 1; print("FAIL: " .. label) end end

print("=== Inspector: bottom bar visibility + reset_pending ===\n")

local function make_entry(dirty, error, last_value)
    local e = {
        field_key = "mark_in_frame",
        dirty = dirty,
        error = error or false,
        pending_value = dirty and 1000 or nil,
        _last_model_value = last_value,
    }
    e.blur_revert_calls = 0
    function e:blur_revert() self.blur_revert_calls = self.blur_revert_calls + 1 end
    return e
end

local function make_ui_state(mode, entries)
    local bar, apply, reset, banner = {_kind="bar"}, {_kind="apply"}, {_kind="reset"}, {_kind="banner"}
    local ui_state = {
        mode = mode,
        bottom_bar   = bar,
        apply_button = apply,
        reset_button = reset,
        error_banner = banner,
        _field_errors = {},
        active_schema_view = {
            field_widgets = entries,
        },
    }
    return ui_state, bar, apply, reset, banner
end

--------------------------------------------------------------------------
-- Bottom bar visibility follows ui_state.mode.
--------------------------------------------------------------------------
do
    local ui_state, bar = make_ui_state("single", {})
    visibility = {}
    sb._update_apply_button(ui_state)
    check("mode=single → bottom bar hidden", visibility[bar] == false)
end
do
    local ui_state, bar = make_ui_state("multi_edit", {
        a = make_entry(false), b = make_entry(false),
    })
    visibility = {}
    sb._update_apply_button(ui_state)
    check("mode=multi_edit → bottom bar visible", visibility[bar] == true)
end
do
    local ui_state, bar = make_ui_state("empty", {})
    visibility = {}
    sb._update_apply_button(ui_state)
    check("mode=empty → bottom bar hidden", visibility[bar] == false)
end

--------------------------------------------------------------------------
-- Apply / Reset enabled state reflects dirty + valid.
--------------------------------------------------------------------------
do
    local e1 = make_entry(true, false)   -- dirty, valid
    local e2 = make_entry(false, false)  -- clean
    local ui_state, _, apply, reset = make_ui_state("multi_edit", { e1, e2 })
    enabled_state = {}
    sb._update_apply_button(ui_state)
    check("dirty+valid: Apply enabled",  enabled_state[apply] == true)
    check("dirty+valid: Reset enabled",  enabled_state[reset] == true)
end
do
    local e = make_entry(true, true)  -- dirty + invalid
    local ui_state, _, apply, reset = make_ui_state("multi_edit", { e })
    enabled_state = {}
    sb._update_apply_button(ui_state)
    check("dirty+invalid: Apply disabled", enabled_state[apply] == false)
    check("dirty+invalid: Reset still enabled (always offerable for dirty)",
        enabled_state[reset] == true)
end
do
    local e = make_entry(false)  -- nothing dirty
    local ui_state, _, apply, reset = make_ui_state("multi_edit", { e })
    enabled_state = {}
    sb._update_apply_button(ui_state)
    check("no-dirty: Apply disabled", enabled_state[apply] == false)
    check("no-dirty: Reset disabled", enabled_state[reset] == false)
end

--------------------------------------------------------------------------
-- reset_pending: blur_revert every dirty/errored field; clear banner state.
--------------------------------------------------------------------------
do
    local e1 = make_entry(true,  false, 1000)   -- dirty
    local e2 = make_entry(true,  true,  2000)   -- dirty + error
    local e3 = make_entry(false, false, 3000)   -- clean — must NOT revert
    local ui_state, _, _, _, banner = make_ui_state("multi_edit", { e1, e2, e3 })
    ui_state._field_errors = { some_key = "old error" }
    visibility = {}

    sb.reset_pending(ui_state)

    check("reset_pending: dirty field reverted",        e1.blur_revert_calls == 1)
    check("reset_pending: dirty+error field reverted",  e2.blur_revert_calls == 1)
    check("reset_pending: clean field NOT reverted",    e3.blur_revert_calls == 0)
    check("reset_pending: banner state cleared",
        next(ui_state._field_errors) == nil)
    check("reset_pending: banner widget hidden",
        visibility[banner] == false)
end

-- reset_pending with no active_schema_view is a safe no-op.
do
    local ui_state = { mode = "multi_edit" }  -- no active_schema_view
    local ok = pcall(sb.reset_pending, ui_state)
    check("reset_pending: no active schema → no-op (no error)", ok == true)
end

print(string.format("\n--- %d passed, %d failed ---", pass, fail))
if fail > 0 then error(fail .. " failures") end
print("✅ test_inspector_reset_and_bottom_bar.lua passed")
