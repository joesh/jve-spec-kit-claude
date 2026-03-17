--- RelinkClips command: clip-level media reconnection with undo
--
-- Responsibilities:
-- - Update clip source_in/source_out and media_id per clip_relink_map
-- - Update media file_path(s) per media_path_changes
-- - Create new media records for segment files
-- - Full undo: restore clip state, media paths, delete new media records
--
-- Non-goals:
-- - Scanning/matching (handled by media_relinker.relink_clips_batch)
-- - UI (handled by ShowRelinkDialog)
--
-- Invariants:
-- - Requires clip_relink_map, project_id
-- - Single atomic operation (one undo reverts all)
--
-- @file relink_clips.lua
local M = {}
local log = require("core.logger").for_area("media")

local SPEC = {
    args = {
        clip_relink_map = { required = true },
        project_id = { required = true },
        media_path_changes = { required = false },
        new_media_records = { required = false },
    }
}

function M.register(executors, undoers, db)

    executors["RelinkClips"] = function(command)
        local args = command:get_all_parameters()
        assert(args.clip_relink_map and type(args.clip_relink_map) == "table",
            "RelinkClips: clip_relink_map table required")
        assert(args.project_id and args.project_id ~= "",
            "RelinkClips: project_id required")

        local Media = require("models.media")

        local old_clip_state = {}
        local old_media_paths = {}
        local media_path_changes = args.media_path_changes or {}
        local new_media_records = args.new_media_records or {}
        local clip_count = 0
        local media_count = 0

        -- Phase 1: Create new media records (for segment files)
        for _, rec in ipairs(new_media_records) do
            assert(rec.id and rec.path and rec.name,
                "RelinkClips: new_media_record requires id, path, name")
            local media = Media.create({
                id = rec.id,
                project_id = args.project_id,
                file_path = rec.path,
                name = rec.name,
                duration_frames = rec.duration_frames or 0,
                fps_numerator = rec.fps_num or 25,
                fps_denominator = rec.fps_den or 1,
                width = rec.width or 0,
                height = rec.height or 0,
                metadata = rec.start_tc_value and
                    require("dkjson").encode({
                        start_tc_value = rec.start_tc_value,
                        start_tc_rate = rec.start_tc_rate,
                    }) or "{}",
            })
            assert(media:save(), string.format("RelinkClips: failed to save new media %s", rec.id))
            log.event("RelinkClips: created media %s → %s", rec.id, rec.path)
        end

        -- Phase 2: Update media paths
        Media.begin_batch()
        for media_id, new_path in pairs(media_path_changes) do
            local media = Media.load(media_id)
            assert(media, string.format("RelinkClips: media not found: %s", media_id))
            old_media_paths[media_id] = media:get_file_path()
            media:set_file_path(new_path)
            assert(media:save(), string.format("RelinkClips: failed to save media %s", media_id))
            media_count = media_count + 1
        end
        Media.end_batch()

        -- Phase 3: Update clips (batch: read old state + write new state via prepared stmts)
        assert(db, "RelinkClips: no database connection")

        -- Read old state in bulk
        local read_stmt = assert(db:prepare(
            "SELECT media_id, source_in_frame, source_out_frame FROM clips WHERE id = ?"),
            "RelinkClips: failed to prepare read query")

        for clip_id, _ in pairs(args.clip_relink_map) do
            read_stmt:bind_value(1, clip_id)
            assert(read_stmt:exec(), "RelinkClips: read exec failed for " .. clip_id)
            assert(read_stmt:next(), "RelinkClips: clip not found: " .. clip_id)
            old_clip_state[clip_id] = {
                old_media_id = read_stmt:value(0),
                old_source_in = read_stmt:value(1),
                old_source_out = read_stmt:value(2),
            }
            read_stmt:reset()
        end
        read_stmt:finalize()

        -- Write new state in bulk
        local write_stmt = assert(db:prepare([[
            UPDATE clips SET media_id = ?, source_in_frame = ?, source_out_frame = ?,
                modified_at = strftime('%s','now') WHERE id = ?
        ]]), "RelinkClips: failed to prepare write query")

        for clip_id, relink in pairs(args.clip_relink_map) do
            local new_media = relink.new_media_id or old_clip_state[clip_id].old_media_id
            write_stmt:bind_value(1, new_media)
            write_stmt:bind_value(2, relink.new_source_in)
            write_stmt:bind_value(3, relink.new_source_out)
            write_stmt:bind_value(4, clip_id)
            assert(write_stmt:exec(), "RelinkClips: write exec failed for " .. clip_id)
            write_stmt:reset()
            clip_count = clip_count + 1
        end
        write_stmt:finalize()

        -- Persist undo state
        command:set_parameter("old_clip_state", old_clip_state)
        command:set_parameter("old_media_paths", old_media_paths)

        -- Emit media_changed for all affected media_ids so viewers refresh
        local changed_media = {}
        for clip_id, relink in pairs(args.clip_relink_map) do
            local mid = relink.new_media_id or old_clip_state[clip_id].old_media_id
            changed_media[mid] = true
        end
        for mid in pairs(old_media_paths) do
            changed_media[mid] = true
        end
        local Signals = require("core.signals")
        Signals.emit("media_changed", changed_media)

        log.event("RelinkClips: relinked %d clip(s), %d media path(s)", clip_count, media_count)
        return { success = true }
    end

    undoers["RelinkClips"] = function(command)
        local args = command:get_all_parameters()
        assert(args.old_clip_state, "RelinkClips undo: old_clip_state missing")

        local Media = require("models.media")

        -- Phase 1: Restore clips (batch via prepared statement)
        local undo_stmt = assert(db:prepare([[
            UPDATE clips SET media_id = ?, source_in_frame = ?, source_out_frame = ?,
                modified_at = strftime('%s','now') WHERE id = ?
        ]]), "RelinkClips undo: failed to prepare query")

        local restored_count = 0
        for clip_id, old_state in pairs(args.old_clip_state) do
            undo_stmt:bind_value(1, old_state.old_media_id)
            undo_stmt:bind_value(2, old_state.old_source_in)
            undo_stmt:bind_value(3, old_state.old_source_out)
            undo_stmt:bind_value(4, clip_id)
            assert(undo_stmt:exec(), "RelinkClips undo: exec failed for " .. clip_id)
            undo_stmt:reset()
            restored_count = restored_count + 1
        end
        undo_stmt:finalize()

        -- Phase 2: Restore media paths
        local old_media_paths = args.old_media_paths or {}
        Media.begin_batch()
        for media_id, old_path in pairs(old_media_paths) do
            local media = Media.load(media_id)
            assert(media, string.format("RelinkClips undo: media not found: %s", media_id))
            media:set_file_path(old_path)
            assert(media:save(), string.format("RelinkClips undo: failed to save media %s", media_id))
        end
        Media.end_batch()

        -- Phase 3: Delete new media records (and their clips)
        local new_media_records = args.new_media_records or {}
        for _, rec in ipairs(new_media_records) do
            local media = Media.load(rec.id)
            if media then
                media:delete()
            end
        end

        -- Emit media_changed so viewers refresh offline status
        local changed_media = {}
        for _, old_state in pairs(args.old_clip_state) do
            changed_media[old_state.old_media_id] = true
        end
        for mid in pairs(old_media_paths) do
            changed_media[mid] = true
        end
        local Signals = require("core.signals")
        Signals.emit("media_changed", changed_media)

        log.event("RelinkClips undo: restored %d clip(s)", restored_count)
        return true
    end

    return {
        ["RelinkClips"] = {
            executor = executors["RelinkClips"],
            undoer = undoers["RelinkClips"],
            spec = SPEC,
        },
    }
end

return M
