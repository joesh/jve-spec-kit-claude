--- CycleFocus command: Tab-key logic ported to the command system.
--- Ensures focus never escapes the current panel.
---
--- @module cycle_focus.lua
local M = {}

local log = require("core.logger").for_area("commands")

-- Active iff there is a focused panel AND a widget the toolkit can cycle
-- within. When false, Tab falls through to Qt's native focus cycling so the
-- toolkit's default behavior applies — JVE has no opinion in this state.
local function has_cycleable_panel()
    local focus_manager = require("ui.focus_manager")
    local focused_panel = focus_manager.get_focused_panel()
    if not focused_panel then return false end
    return focus_manager.focus_panel_widget(focused_panel) ~= nil
end

local SPEC = {
    name = "CycleFocus",
    description = "Cycle focus within the current panel",
    undoable = false,
    args = {
        direction = { required = false, default = "forward" },
        project_id = { required = false }
    },
    when = has_cycleable_panel,
}

function M.execute(args)
    local focus_manager = require("ui.focus_manager")
    local focused_panel = focus_manager.get_focused_panel()
    local panel_widget = focus_manager.focus_panel_widget(focused_panel)
    -- when() guaranteed both at match time; if either vanished mid-tick,
    -- consume + warn rather than silently no-op (the binding was claimed).
    if not (focused_panel and panel_widget) then
        log.warn("CycleFocus: when() said active but panel/widget missing at execute")
        return true
    end

    -- luacheck: globals qt_cycle_panel_focus
    assert(qt_cycle_panel_focus,
        "CycleFocus: qt_cycle_panel_focus binding missing — required by the command")
    local forward = (args.direction ~= "backward")
    log.detail("CycleFocus: %s in panel %s", args.direction, focused_panel)
    qt_cycle_panel_focus(panel_widget, forward)
    return true
end

function M.register(command_executors, _command_undoers, _db, _set_last_error)
    command_executors.CycleFocus = function(command)
        return M.execute(command:get_all_parameters())
    end

    return {
        CycleFocus = {
            executor = command_executors.CycleFocus,
            spec = SPEC,
        }
    }
end

return M
