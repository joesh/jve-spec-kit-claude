--- ToggleTimecodeFocus command — move keyboard focus into or out of the
-- timeline's timecode entry field. Bound to Tab @timeline by default; the
-- binding is editable in the keyboard customization UI.
--
-- The command checks Qt's current focus widget. If the timecode QLineEdit
-- has focus, focus moves to the timeline view; otherwise it moves to the
-- timecode field. This is the only thing Tab does inside the timeline panel
-- — every other widget there is ClickFocus, so Qt's focusNextPrevChild has
-- nowhere to cycle.
--
-- @file toggle_timecode_focus.lua
local M = {}

local SPEC = {
    undoable = false,
    args = {},
}

function M.register(executors, _undoers, _db)
    local function executor(_command)
        local timeline_panel = require("ui.timeline.timeline_panel")
        return timeline_panel.toggle_timecode_focus()
    end

    executors.ToggleTimecodeFocus = executor

    return {
        executor = executor,
        spec = SPEC,
    }
end

return M
