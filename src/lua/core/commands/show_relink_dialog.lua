--- ShowRelinkDialog command: find offline media and show reconnect dialog
--
-- Responsibilities:
-- - Scan project media for offline files via media_relinker.find_offline_media
-- - Show reconnect dialog with offline list and search directory picker
-- - On user confirm, dispatch RelinkMedia with relink_map
--
-- Non-goals:
-- - Undo support (dialog-only command, actual relink is undoable via RelinkMedia)
--
-- Invariants:
-- - Requires an open project with media
-- - Asserts if no project is open
--
-- @file show_relink_dialog.lua
local M = {}
local log = require("core.logger").for_area("media")

local SPEC = {
    args = {},
    undoable = false,
}

function M.register(executors, _undoers, db)

    executors["ShowRelinkDialog"] = function(_command)
        local media_relinker = require("core.media_relinker")
        local timeline_state = require("ui.timeline.timeline_state")

        local project_id = timeline_state.get_project_id()
        assert(project_id, "ShowRelinkDialog: no project open")

        local offline = media_relinker.find_offline_media(db, project_id)

        if #offline == 0 then
            log.event("ShowRelinkDialog: no offline media found")
            return { success = true, message = "All media is online" }
        end

        log.event("ShowRelinkDialog: found %d offline media file(s)", #offline)

        -- Get parent window for dialog
        local parent_window = nil
        local ui_state_ok, ui_state = pcall(require, "ui.ui_state")
        if ui_state_ok and ui_state.get_main_window then
            parent_window = ui_state.get_main_window()
        end

        -- Show reconnect dialog (blocking modal)
        local media_relink_dialog = require("ui.media_relink_dialog")
        local relink_map = media_relink_dialog.show(offline, parent_window)

        if not relink_map then
            log.event("ShowRelinkDialog: user cancelled")
            return { success = true, cancelled = true }
        end

        -- Dispatch RelinkMedia to apply (undoable)
        local command_manager = require("core.command_manager")
        local result = command_manager.execute("RelinkMedia", {
            relink_map = relink_map,
            project_id = project_id,
        })

        return result
    end

    return {
        ["ShowRelinkDialog"] = {
            executor = executors["ShowRelinkDialog"],
            spec = SPEC,
        },
    }
end

return M
