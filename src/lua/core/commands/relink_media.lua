--- TODO: one-line summary (human review required)
--
-- Responsibilities:
-- - TODO
--
-- Non-goals:
-- - TODO
--
-- Invariants:
-- - TODO
--
-- Size: ~102 LOC
-- Volatility: unknown
--
-- @file relink_media.lua
-- Original intent (unreviewed):
-- RelinkMedia and BatchRelinkMedia commands
local M = {}

function M.register(executors, undoers, db)
    
    executors["RelinkMedia"] = function(command)
        local media_id = command:get_parameter("media_id")
        local new_file_path = command:get_parameter("new_file_path")

        if not media_id or not new_file_path then
            return {success = false, error_message = "RelinkMedia requires media_id and new_file_path"}
        end

        -- Load media record
        local Media = require("models.media")
        local media = Media.load(media_id, db)

        if not media then
            return {success = false, error_message = "Media not found: " .. media_id}
        end

        -- Store old path for undo
        local old_file_path = media.file_path
        command:set_parameter("old_file_path", old_file_path)

        -- Update file path
        media.file_path = new_file_path

        -- Save to database
        if not media:save(db) then
            return {success = false, error_message = "Failed to save relinked media"}
        end

        print(string.format("Relinked media '%s': %s → %s", media.name, old_file_path, new_file_path))

        return {
            success = true
        }
    end

    undoers["RelinkMedia"] = function(command)
        local media_id = command:get_parameter("media_id")
        local old_file_path = command:get_parameter("old_file_path")

        if not media_id or not old_file_path then
            print("ERROR: Cannot undo RelinkMedia - missing stored state")
            return false
        end

        -- Load media and restore old path
        local Media = require("models.media")
        local media = Media.load(media_id, db)

        if not media then
            print("ERROR: Cannot undo RelinkMedia - media not found: " .. media_id)
            return false
        end

        media.file_path = old_file_path

        if not media:save(db) then
            print("ERROR: Failed to restore old media path")
            return false
        end

        print(string.format("Restored media '%s' to original path: %s", media.name, old_file_path))
        return true
    end

    executors["BatchRelinkMedia"] = function(command)
        local relink_map = command:get_parameter("relink_map")

        if not relink_map or type(relink_map) ~= "table" then
            return {success = false, error_message = "BatchRelinkMedia requires relink_map table"}
        end

        local Media = require("models.media")
        local old_paths = {}
        local relinked_count = 0

        -- Relink each media file
        for media_id, new_file_path in pairs(relink_map) do
            local media = Media.load(media_id, db)

            if media then
                -- Store old path for undo
                old_paths[media_id] = media.file_path

                -- Update path
                media.file_path = new_file_path

                if media:save(db) then
                    relinked_count = relinked_count + 1
                else
                    print(string.format("WARNING: Failed to relink media %s", media_id))
                end
            else
                print(string.format("WARNING: Media not found: %s", media_id))
            end
        end

        command:set_parameter("old_paths", old_paths)
        command:set_parameter("relinked_count", relinked_count)

        print(string.format("Batch relinked %d media file(s)", relinked_count))

        return {
            success = true
        }
    end

    undoers["BatchRelinkMedia"] = function(command)
        local relink_map = command:get_parameter("relink_map")
        local old_paths = command:get_parameter("old_paths")

        if not old_paths then
            print("ERROR: Cannot undo BatchRelinkMedia - missing stored state")
            return false
        end

        local Media = require("models.media")
        local restored_count = 0

        -- Restore each media file to old path
        for media_id, old_file_path in pairs(old_paths) do
            local media = Media.load(media_id, db)

            if media then
                media.file_path = old_file_path

                if media:save(db) then
                    restored_count = restored_count + 1
                else
                    print(string.format("WARNING: Failed to restore media %s", media_id))
                end
            else
                print(string.format("WARNING: Media not found during undo: %s", media_id))
            end
        end

        print(string.format("Batch undo: restored %d media file path(s)", restored_count))
        return true
    end

    return {executor = executors["RelinkMedia"], undoer = undoers["RelinkMedia"]}
end

return M
