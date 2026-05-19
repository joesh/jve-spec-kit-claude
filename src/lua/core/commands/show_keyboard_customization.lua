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
        -- Force-load every per-command module so commands declaring
        -- SPEC.keyboard metadata appear in the dialog. Lazy command-load
        -- only fires on first execute, so a user opening the dialog
        -- before pressing any track-header button would otherwise see
        -- an incomplete list.
        require("core.command_registry").load_all_command_modules()

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
