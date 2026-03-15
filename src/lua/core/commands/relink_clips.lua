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

function M.register(executors, undoers, _db)

    executors["RelinkClips"] = function(command)
        local args = command:get_all_parameters()
        assert(args.clip_relink_map and type(args.clip_relink_map) == "table",
            "RelinkClips: clip_relink_map table required")
        assert(args.project_id and args.project_id ~= "",
            "RelinkClips: project_id required")

        local Clip = require("models.clip")
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

        -- Phase 3: Update clips
        for clip_id, relink in pairs(args.clip_relink_map) do
            local clip = Clip.load(clip_id)
            assert(clip, string.format("RelinkClips: clip not found: %s", clip_id))

            -- Save old state for undo
            old_clip_state[clip_id] = {
                old_media_id = clip.media_id,
                old_source_in = clip.source_in,
                old_source_out = clip.source_out,
            }

            -- Apply new state
            if relink.new_media_id then
                clip.media_id = relink.new_media_id
            end
            clip.source_in = relink.new_source_in
            clip.source_out = relink.new_source_out
            assert(clip:save(), string.format("RelinkClips: failed to save clip %s", clip_id))
            clip_count = clip_count + 1
        end

        -- Persist undo state
        command:set_parameter("old_clip_state", old_clip_state)
        command:set_parameter("old_media_paths", old_media_paths)

        log.event("RelinkClips: relinked %d clip(s), %d media path(s)", clip_count, media_count)
        return { success = true }
    end

    undoers["RelinkClips"] = function(command)
        local args = command:get_all_parameters()
        assert(args.old_clip_state, "RelinkClips undo: old_clip_state missing")

        local Clip = require("models.clip")
        local Media = require("models.media")

        -- Phase 1: Restore clips
        for clip_id, old_state in pairs(args.old_clip_state) do
            local clip = Clip.load(clip_id)
            assert(clip, string.format("RelinkClips undo: clip not found: %s", clip_id))

            clip.media_id = old_state.old_media_id
            clip.source_in = old_state.old_source_in
            clip.source_out = old_state.old_source_out
            assert(clip:save(), string.format("RelinkClips undo: failed to save clip %s", clip_id))
        end

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

        log.event("RelinkClips undo: restored %d clip(s)", #(args.old_clip_state or {}))
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
