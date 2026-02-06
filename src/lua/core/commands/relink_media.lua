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


local SPEC = {
    args = {
        media_id = { required = true },
        new_file_path = {},
        old_file_path = {},
        old_paths = { required = true },
        project_id = { required = true },
        relink_map = { required = true },
    }
}

function M.register(executors, undoers, db)
    
    local function executor(command)
        local args = command:get_all_parameters()



        if not args.media_id or not args.new_file_path then
            return {success = false, error_message = "RelinkMedia requires args.media_id and args.new_file_path"}
        end

        -- Load media record
        local Media = require("models.media")
        local media = Media.load(args.media_id)

        if not media then
            return {success = false, error_message = "Media not found: " .. args.media_id}
        end

        -- Store old path for undo
        local old_file_path = media.file_path
        command:set_parameter("old_file_path", old_file_path)

        -- Update file path
        media.file_path = args.new_file_path

        -- Save to database
        if not media:save() then
            return {success = false, error_message = "Failed to save relinked media"}
        end

        print(string.format("Relinked media '%s': %s → %s", media.name, old_file_path, args.new_file_path))

        return {
            success = true
        }
    end

    local function undoer(command)
        local args = command:get_all_parameters()



        if not args.media_id or not args.old_file_path then
            print("ERROR: Cannot undo RelinkMedia - missing stored state")
            return false
        end

        -- Load media and restore old path
        local Media = require("models.media")
        local media = Media.load(args.media_id)

        if not media then
            print("ERROR: Cannot undo RelinkMedia - media not found: " .. args.media_id)
            return false
        end

        media.file_path = args.old_file_path

        if not media:save() then
            print("ERROR: Failed to restore old media path")
            return false
        end

        print(string.format("Restored media '%s' to original path: %s", media.name, args.old_file_path))
        return true
    end

    executors["BatchRelinkMedia"] = function(command)
        local args = command:get_all_parameters()


        if not args.relink_map or type(args.relink_map) ~= "table" then
            return {success = false, error_message = "BatchRelinkMedia requires args.relink_map table"}
        end

        local Media = require("models.media")
        local old_paths = {}
        local relinked_count = 0

        -- Relink each media file
        for media_id, new_file_path in pairs(args.relink_map) do
            local media = Media.load(media_id)

            assert(media, string.format("BatchRelinkMedia: media not found: %s", media_id))

            -- Store old path for undo
            old_paths[media_id] = media.file_path

            -- Update path
            media.file_path = new_file_path

            assert(media:save(), string.format("BatchRelinkMedia: failed to save relinked media %s", media_id))
            relinked_count = relinked_count + 1
        end

        command:set_parameters({
            ["old_paths"] = old_paths,
            ["relinked_count"] = relinked_count,
        })
        print(string.format("Batch relinked %d media file(s)", relinked_count))

        return {
            success = true,
            spec = SPEC,
        }
    end

    undoers["BatchRelinkMedia"] = function(command)
        local args = command:get_all_parameters()



        if not args.old_paths then
            print("ERROR: Cannot undo BatchRelinkMedia - missing stored state")
            return false
        end

        local Media = require("models.media")
        local restored_count = 0

        -- Restore each media file to old path
        for media_id, old_file_path in pairs(args.old_paths) do
            local media = Media.load(media_id)

            if media then
                media.file_path = old_file_path

                if media:save() then
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

    return {executor = executor, undoer = undoer}
end

return M
