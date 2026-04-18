--- ShowKeyboardCustomization command: opens the keyboard shortcuts dialog
--
-- Responsibilities:
-- - Lazily loads ui.keyboard_customization_dialog and shows it
--
-- @file show_keyboard_customization.lua
local M = {}

local SPEC = {
    args = {},
    undoable = false,
}

function M.register(executors, _undoers, _db)
    executors["ShowKeyboardCustomization"] = function(_command)
        local dialog = require("ui.keyboard_customization_dialog")
        dialog.show()
        return { success = true }
    end

    return {
        ["ShowKeyboardCustomization"] = {
            executor = executors["ShowKeyboardCustomization"],
            spec = SPEC,
        },
    }
end

return M
