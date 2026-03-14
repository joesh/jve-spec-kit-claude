--- RelinkMedia command: relink one or more offline media files (with undo)
--
-- Responsibilities:
-- - Update media file_path(s) from relink_map {media_id → new_path}
-- - Store old paths for undo
--
-- Non-goals:
-- - UI (handled by ShowRelinkDialog command)
-- - Scanning for offline media (handled by media_relinker)
--
-- Invariants:
-- - Requires relink_map (table {media_id → new_path})
-- - Asserts if any media_id not found or save fails
--
-- @file relink_media.lua
local M = {}
local log = require("core.logger").for_area("media")

local SPEC = {
    args = {
        relink_map = { required = true },
        project_id = { required = true },
    }
}

function M.register(executors, undoers, _db)

    executors["RelinkMedia"] = function(command)
        local args = command:get_all_parameters()
        assert(args.relink_map and type(args.relink_map) == "table",
            "RelinkMedia: relink_map table required")

        local Media = require("models.media")
        local old_paths = {}
        local relinked_count = 0

        for media_id, new_file_path in pairs(args.relink_map) do
            local media = Media.load(media_id)
            assert(media, string.format("RelinkMedia: media not found: %s", media_id))

            old_paths[media_id] = media.file_path
            media.file_path = new_file_path
            assert(media:save(), string.format("RelinkMedia: failed to save media %s", media_id))
            relinked_count = relinked_count + 1
        end

        command:set_parameter("old_paths", old_paths)
        command:set_parameter("relinked_count", relinked_count)
        log.event("Relinked %d media file(s)", relinked_count)

        return { success = true }
    end

    undoers["RelinkMedia"] = function(command)
        local args = command:get_all_parameters()
        assert(args.old_paths, "RelinkMedia undo: old_paths missing (command never executed?)")

        local Media = require("models.media")
        local restored_count = 0

        for media_id, old_file_path in pairs(args.old_paths) do
            local media = Media.load(media_id)
            assert(media, string.format("RelinkMedia undo: media not found: %s", media_id))

            media.file_path = old_file_path
            assert(media:save(),
                string.format("RelinkMedia undo: failed to save media %s", media_id))
            restored_count = restored_count + 1
        end

        log.event("Undo relink: restored %d media file path(s)", restored_count)
        return true
    end

    return {
        ["RelinkMedia"] = {
            executor = executors["RelinkMedia"],
            undoer = undoers["RelinkMedia"],
            spec = SPEC,
        },
    }
end

return M
