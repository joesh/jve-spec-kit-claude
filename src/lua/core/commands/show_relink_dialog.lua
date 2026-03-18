--- ShowRelinkDialog command: find offline media and show reconnect dialog
--
-- Responsibilities:
-- - Scan project media for offline files via media_relinker.find_offline_media
-- - Show reconnect dialog with clip list, matching rules, search directory
-- - Auto-resolve duplicate media using folder priority
-- - On user confirm, dispatch RelinkClips with clip_relink_map + media changes
--
-- @file show_relink_dialog.lua
local M = {}
local log = require("core.logger").for_area("media")

local SPEC = {
    args = {},
    undoable = false,
}

--- Given folder priority order and a media path, return its priority (lower = better).
-- @param path string Media file path
-- @param folder_priority table Ordered array of folder roots (index 1 = highest)
-- @return number Priority (1 = highest, #folder_priority+1 = no match)
local function get_folder_priority(path, folder_priority)
    for i, root in ipairs(folder_priority) do
        if path:sub(1, #root) == root then
            return i
        end
    end
    return #folder_priority + 1  -- unmatched = lowest
end

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

        local ui_state = require("ui.ui_state")
        local parent_window = ui_state.get_main_window and ui_state.get_main_window() or nil

        local media_relink_dialog = require("ui.media_relink_dialog")
        local results = media_relink_dialog.show(offline, parent_window, project_id)

        if not results then
            log.event("ShowRelinkDialog: user cancelled")
            return { success = true, cancelled = true }
        end

        -- Build RelinkClips args with folder-priority collision resolution
        local Media = require("models.media")
        assert(results.folder_priority, "ShowRelinkDialog: results missing folder_priority")
        local folder_priority = results.folder_priority
        local clip_relink_map = {}
        local media_path_changes = {}
        local path_to_media = {}     -- new_path → {media_id, priority}
        local media_orig_paths = {}  -- media_id → original file_path

        -- Helper: check if a path is already owned by an existing media record in the DB
        local db_path_cache = {}  -- path → media_id or false
        local function find_existing_media_by_path(path)
            if db_path_cache[path] ~= nil then
                return db_path_cache[path] ~= false and db_path_cache[path] or nil
            end
            local stmt = db:prepare("SELECT id FROM media WHERE file_path = ? LIMIT 1")
            if not stmt then db_path_cache[path] = false; return nil end
            stmt:bind_value(1, path)
            local found_id = nil
            if stmt:exec() and stmt:next() then
                found_id = stmt:value(0)
            end
            stmt:finalize()
            db_path_cache[path] = found_id or false
            return found_id
        end

        for _, entry in ipairs(results.relinked) do
            local mid = entry.original_media_id

            if entry.new_path and not entry.new_media_id and mid then
                if not media_orig_paths[mid] then
                    local m = Media.load(mid)
                    assert(m, string.format("ShowRelinkDialog: media not found: %s", mid))
                    media_orig_paths[mid] = m:get_file_path()
                end

                -- Check if path already belongs to an existing media record
                local db_owner = find_existing_media_by_path(entry.new_path)
                if db_owner and db_owner ~= mid then
                    -- Path already taken by existing media — reassign clip to it
                    log.event("path exists in DB: media %s already at %s — reassigning clip %s",
                        db_owner:sub(1, 8),
                        entry.new_path:match("([^/]+)$") or entry.new_path,
                        entry.clip_id:sub(1, 8))
                    entry.new_media_id = db_owner
                    clip_relink_map[entry.clip_id] = {
                        new_media_id = db_owner,
                        new_source_in = entry.new_source_in,
                        new_source_out = entry.new_source_out,
                    }
                    goto continue
                end

                local my_priority = get_folder_priority(media_orig_paths[mid], folder_priority)
                local existing = path_to_media[entry.new_path]

                if not existing or existing.media_id == mid then
                    if not existing then
                        path_to_media[entry.new_path] = {
                            media_id = mid, priority = my_priority
                        }
                        media_path_changes[mid] = entry.new_path
                    end
                elseif my_priority < existing.priority then
                    log.event("folder priority: %s (%s, pri=%d) beats %s (%s, pri=%d) for %s",
                        mid:sub(1, 8), media_orig_paths[mid], my_priority,
                        existing.media_id:sub(1, 8), media_orig_paths[existing.media_id], existing.priority,
                        entry.new_path:match("([^/]+)$") or entry.new_path)
                    media_path_changes[existing.media_id] = nil
                    media_path_changes[mid] = entry.new_path
                    path_to_media[entry.new_path] = {
                        media_id = mid, priority = my_priority
                    }
                else
                    log.detail("skip: media %s (%s, pri=%d) lost to %s (pri=%d) for %s",
                        mid:sub(1, 8), media_orig_paths[mid], my_priority,
                        existing.media_id:sub(1, 8), existing.priority,
                        entry.new_path:match("([^/]+)$") or entry.new_path)
                    goto continue
                end
            end

            clip_relink_map[entry.clip_id] = {
                new_media_id = entry.new_media_id,
                new_source_in = entry.new_source_in,
                new_source_out = entry.new_source_out,
            }

            ::continue::
        end

        local path_change_count = 0
        for _ in pairs(media_path_changes) do path_change_count = path_change_count + 1 end
        local clip_change_count = 0
        for _ in pairs(clip_relink_map) do clip_change_count = clip_change_count + 1 end
        log.event("ShowRelinkDialog: dispatching RelinkClips — %d clip changes, %d media path changes, %d new media",
            clip_change_count, path_change_count, #(results.new_media))

        local command_manager = require("core.command_manager")
        local result = command_manager.execute("RelinkClips", {
            clip_relink_map = clip_relink_map,
            media_path_changes = media_path_changes,
            new_media_records = results.new_media,
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
