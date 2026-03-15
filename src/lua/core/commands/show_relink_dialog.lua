--- ShowRelinkDialog command: find offline media and show reconnect dialog
--
-- Responsibilities:
-- - Scan project media for offline files via media_relinker.find_offline_media
-- - Show reconnect dialog with clip list, matching rules, search directory
-- - On user confirm, dispatch RelinkClips with clip_relink_map + media changes
--
-- Non-goals:
-- - Undo support (dialog-only command, actual relink is undoable via RelinkClips)
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

        -- Show reconnect dialog (blocking modal, clip-level)
        local media_relink_dialog = require("ui.media_relink_dialog")
        local results = media_relink_dialog.show(offline, parent_window, project_id)

        if not results then
            log.event("ShowRelinkDialog: user cancelled")
            return { success = true, cancelled = true }
        end

        -- Build RelinkClips command args from relink_clips_batch results
        local clip_relink_map = {}
        local media_path_changes = {}
        local seen_media_paths = {}

        for _, entry in ipairs(results.relinked) do
            clip_relink_map[entry.clip_id] = {
                new_media_id = entry.new_media_id,
                new_source_in = entry.new_source_in,
                new_source_out = entry.new_source_out,
            }

            -- Track media path changes (deduplicate — one path change per media_id)
            if entry.new_path and not entry.new_media_id then
                -- Reusing existing media with new path
                -- Find original media_id from clip_infos
                local original_media_id = nil
                for _, info in ipairs(results.relinked) do
                    if info.clip_id == entry.clip_id then
                        original_media_id = entry.original_media_id or info.clip_id
                        break
                    end
                end
                if original_media_id and not seen_media_paths[original_media_id] then
                    media_path_changes[original_media_id] = entry.new_path
                    seen_media_paths[original_media_id] = true
                end
            end
        end

        -- Dispatch RelinkClips (undoable)
        local command_manager = require("core.command_manager")
        local result = command_manager.execute("RelinkClips", {
            clip_relink_map = clip_relink_map,
            media_path_changes = media_path_changes,
            new_media_records = results.new_media or {},
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
