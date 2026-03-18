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

        local Clip = require("models.clip")
        local Media = require("models.media")

        local old_clip_state  -- set in Phase 3
        local old_media_paths = {}
        local media_path_changes = args.media_path_changes or {} -- NSF-OK: optional param, empty = no path changes
        local new_media_records = args.new_media_records or {} -- NSF-OK: optional param, empty = no new media
        local media_count = 0

        -- Wrap all DB changes in a transaction — partial failures roll back
        local txn_started = db:begin_transaction()

        local ok, err = pcall(function()

        -- Phase 1: Create new media records (for segment files)
        for _, rec in ipairs(new_media_records) do
            assert(rec.id and rec.path and rec.name,
                "RelinkClips: new_media_record requires id, path, name")
            assert(rec.duration_frames, "RelinkClips: new_media_record requires duration_frames")
            assert(rec.fps_num, "RelinkClips: new_media_record requires fps_num")
            assert(rec.fps_den, "RelinkClips: new_media_record requires fps_den")
            local media = Media.create({
                id = rec.id,
                project_id = args.project_id,
                file_path = rec.path,
                name = rec.name,
                duration_frames = rec.duration_frames,
                fps_numerator = rec.fps_num,
                fps_denominator = rec.fps_den,
                width = rec.width,     -- nil OK for audio-only (Media.create handles)
                height = rec.height,   -- nil OK for audio-only
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

        -- Phase 3: Read old clip state, write new state (via model batch methods)
        old_clip_state = Clip.batch_read_source(args.clip_relink_map)

        local updates = {}
        for clip_id, relink in pairs(args.clip_relink_map) do
            updates[clip_id] = {
                media_id = relink.new_media_id or old_clip_state[clip_id].media_id,
                source_in = relink.new_source_in,
                source_out = relink.new_source_out,
            }
        end
        Clip.batch_update_source(updates)

        -- Persist undo state
        command:set_parameter("old_clip_state", old_clip_state)
        command:set_parameter("old_media_paths", old_media_paths)

        end) -- end pcall

        if not ok then
            if txn_started then db:rollback_transaction(txn_started) end
            error(err)
        end
        if txn_started then db:commit_transaction(txn_started) end

        -- Emit media_changed for all affected media_ids so viewers refresh
        local changed_media = {}
        for clip_id, relink in pairs(args.clip_relink_map) do
            local mid = relink.new_media_id or old_clip_state[clip_id].media_id
            changed_media[mid] = true
        end
        for mid in pairs(old_media_paths) do
            changed_media[mid] = true
        end
        local Signals = require("core.signals")
        Signals.emit("media_changed", changed_media)

        log.event("RelinkClips: relinked %d clip(s), %d media path(s)",
            (function() local n=0; for _ in pairs(args.clip_relink_map) do n=n+1 end; return n end)(),
            media_count)
        return { success = true }
    end

    undoers["RelinkClips"] = function(command)
        local args = command:get_all_parameters()
        assert(args.old_clip_state, "RelinkClips undo: old_clip_state missing")
        assert(type(args.old_media_paths) == "table", "RelinkClips undo: old_media_paths missing")

        local Clip = require("models.clip")
        local Media = require("models.media")

        local old_media_paths = args.old_media_paths

        -- Wrap all DB changes in a transaction — partial failures roll back
        local txn_started = db:begin_transaction()

        local ok, err = pcall(function()

        -- Phase 1: Restore clips via model batch method
        Clip.batch_update_source(args.old_clip_state)

        -- Phase 2: Restore media paths
        Media.begin_batch()
        for media_id, old_path in pairs(old_media_paths) do
            local media = Media.load(media_id)
            assert(media, string.format("RelinkClips undo: media not found: %s", media_id))
            media:set_file_path(old_path)
            assert(media:save(), string.format("RelinkClips undo: failed to save media %s", media_id))
        end
        Media.end_batch()

        -- Phase 3: Delete new media records (and their clips)
        local new_media_records = args.new_media_records or {} -- NSF-OK: optional, empty = none
        for _, rec in ipairs(new_media_records) do
            local media = Media.load(rec.id)
            assert(media, string.format("RelinkClips undo: new media %s not found for deletion", rec.id))
            media:delete()
        end

        end) -- end pcall

        if not ok then
            if txn_started then db:rollback_transaction(txn_started) end
            error(err)
        end
        if txn_started then db:commit_transaction(txn_started) end

        -- Emit media_changed so viewers refresh offline status
        local changed_media = {}
        for _, old_state in pairs(args.old_clip_state) do
            changed_media[old_state.media_id] = true
        end
        for mid in pairs(old_media_paths) do
            changed_media[mid] = true
        end
        local Signals = require("core.signals")
        Signals.emit("media_changed", changed_media)

        local n = 0; for _ in pairs(args.old_clip_state) do n = n + 1 end
        log.event("RelinkClips undo: restored %d clip(s)", n)
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
