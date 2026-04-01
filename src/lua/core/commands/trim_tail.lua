--- TrimTail command — trims clip end(s) to playhead position with ripple.
--
-- Delegates to ExtractRange: mark_in = playhead, mark_out = latest clip end.
-- ExtractRange handles clip trimming, gap closing, mutations, and undo.
--
-- @file trim_tail.lua
local M = {}
local Clip = require("models.clip")
local command_helper = require("core.command_helper")

local SPEC = {
    args = {
        clip_ids = {},   -- array of clip IDs (derived from selection/playhead if omitted)
        project_id = { required = true },
        sequence_id = { required = true },
        trim_frame = {},  -- playhead frame (derived from playhead if omitted)
    },
    persisted = {},
}

function M.register(command_executors, command_undoers, db, set_last_error)
    command_executors["TrimTail"] = function(command)
        local args = command:get_all_parameters()
        local log = require("core.logger").for_area("commands")
        local command_manager = require("core.command_manager")

        -- Derive clip_ids and trim_frame from UI state if not provided
        local clip_ids = args.clip_ids
        local trim_frame = args.trim_frame

        if not clip_ids then
            local target_clips, playhead = command_helper.resolve_clips_at_playhead()
            if #target_clips == 0 then
                log.event("TrimTail: no clips under playhead")
                return true
            end
            clip_ids = {}
            for _, clip in ipairs(target_clips) do
                clip_ids[#clip_ids + 1] = clip.id
            end
            trim_frame = trim_frame or playhead
            command:set_parameters({ clip_ids = clip_ids, trim_frame = trim_frame })
        end

        assert(type(clip_ids) == "table" and #clip_ids > 0,
            "TrimTail: clip_ids must be non-empty array")
        assert(type(trim_frame) == "number", "TrimTail: trim_frame required")

        -- Find latest clip end (= mark_out for extract)
        local latest_end = nil
        for _, clip_id in ipairs(clip_ids) do
            local clip = Clip.load(clip_id)
            assert(clip, string.format("TrimTail: clip not found: %s", clip_id))
            local clip_end = clip.timeline_start + clip.duration
            assert(trim_frame > clip.timeline_start and trim_frame < clip_end,
                string.format("TrimTail: playhead (%d) not inside clip %s [%d..%d)",
                    trim_frame, clip_id, clip.timeline_start, clip_end))
            if not latest_end or clip_end > latest_end then
                latest_end = clip_end
            end
        end

        log.event("TrimTail: extract [%d, %d) across %d clip(s)",
            trim_frame, latest_end, #clip_ids)

        local result = command_manager.execute("ExtractRange", {
            mark_in = trim_frame,
            mark_out = latest_end,
            sequence_id = args.sequence_id,
            project_id = args.project_id,
        })

        if not result or not result.success then
            local msg = result and result.error_message or "ExtractRange failed"
            set_last_error("TrimTail: " .. msg)
            return false
        end

        return true
    end

    -- Undo handled entirely by nested ExtractRange
    command_undoers["TrimTail"] = function(_command)
        return true
    end

    return {
        executor = command_executors["TrimTail"],
        undoer = command_undoers["TrimTail"],
        spec = SPEC,
    }
end

return M
