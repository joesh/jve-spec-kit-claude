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
        local path_to_media_id = {}  -- new_path → first media_id that claims it

        -- Build a lookup from media_id → original path for logging
        local Media = require("models.media")
        local media_orig_paths = {}

        for _, entry in ipairs(results.relinked) do
            local orig_media_id = entry.original_media_id

            if entry.new_path and not entry.new_media_id and orig_media_id then
                -- Cache original path for logging
                if not media_orig_paths[orig_media_id] then
                    local m = Media.load(orig_media_id)
                    media_orig_paths[orig_media_id] = m and m:get_file_path() or "?"
                end

                local owner = path_to_media_id[entry.new_path]
                if not owner then
                    path_to_media_id[entry.new_path] = orig_media_id
                    media_path_changes[orig_media_id] = entry.new_path
                elseif owner ~= orig_media_id then
                    log.warn("path collision: media %s (%s) and media %s (%s) both → %s — reassigning clips to %s",
                        orig_media_id:sub(1, 8), media_orig_paths[orig_media_id] or "?",
                        owner:sub(1, 8), media_orig_paths[owner] or "?",
                        entry.new_path, owner:sub(1, 8))
                    entry.new_media_id = owner
                end
            end

            clip_relink_map[entry.clip_id] = {
                new_media_id = entry.new_media_id,
                new_source_in = entry.new_source_in,
                new_source_out = entry.new_source_out,
            }
        end

        -- Count path changes and collisions
        local path_change_count = 0
        for _ in pairs(media_path_changes) do path_change_count = path_change_count + 1 end
        local clip_change_count = 0
        for _ in pairs(clip_relink_map) do clip_change_count = clip_change_count + 1 end
        log.event("ShowRelinkDialog: dispatching RelinkClips — %d clip changes, %d media path changes, %d new media",
            clip_change_count, path_change_count, #(results.new_media or {}))

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
