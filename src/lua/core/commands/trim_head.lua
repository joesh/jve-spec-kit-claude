--- TrimHead command — trims clip start(s) to playhead position with ripple.
--
-- Delegates to ExtractRange: mark_in = earliest clip start, mark_out = playhead.
-- ExtractRange handles clip trimming, gap closing, mutations, and undo.
--
-- @file trim_head.lua
local M = {}
local Clip = require("models.clip")
local Sequence = require("models.sequence")
local Signals = require("core.signals")
local command_helper = require("core.command_helper")

local SPEC = {
    args = {
        clip_ids   = {},   -- array of clip IDs (derived from selection/playhead if omitted)
        project_id = { required = true },
        sequence_id = { required = true },
        trim_frame = {},  -- playhead frame in owner timebase (derived from playhead if omitted)
    },
    persisted = { "prior_playhead" },
}

local function set_playhead(sequence_id, frame)
    local sequence = Sequence.load(sequence_id)
    assert(sequence, "TrimHead: sequence not found: " .. tostring(sequence_id))
    sequence.playhead_position = frame
    assert(sequence:save(), "TrimHead: failed to save sequence playhead")
    Signals.emit("playhead_changed", sequence_id, frame)
end

function M.register(command_executors, command_undoers, _db, set_last_error)
    command_executors["TrimHead"] = function(command)
        local args = command:get_all_parameters()
        local log = require("core.logger").for_area("commands")
        local command_manager = require("core.command_manager")

        local clip_ids = args.clip_ids
        local trim_frame = args.trim_frame

        if not clip_ids then
            local target_clips, playhead = command_helper.resolve_clips_at_playhead()
            if #target_clips == 0 then
                log.event("TrimHead: no clips under playhead")
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
            "TrimHead: clip_ids must be non-empty array")
        assert(type(trim_frame) == "number", "TrimHead: trim_frame required")

        local earliest_start = nil
        for _, clip_id in ipairs(clip_ids) do
            local clip = Clip.load(clip_id)
            assert(clip, string.format("TrimHead: clip not found: %s", clip_id))
            local clip_end = clip.sequence_start + clip.duration
            assert(trim_frame > clip.sequence_start and trim_frame < clip_end,
                string.format("TrimHead: playhead (%d) not inside clip %s [%d..%d)",
                    trim_frame, clip_id, clip.sequence_start, clip_end))
            if not earliest_start or clip.sequence_start < earliest_start then
                earliest_start = clip.sequence_start
            end
        end

        log.event("TrimHead: extract [%d, %d) across %d clip(s)",
            earliest_start, trim_frame, #clip_ids)

        -- Capture pre-trim playhead so undo restores the user's position,
        -- not the trim target. trim_frame is the trim edge (== playhead
        -- when derived from selection), but if it was passed explicitly it
        -- can differ from where the user actually had the playhead.
        do
            local seq = Sequence.load(args.sequence_id)
            assert(seq, "TrimHead: sequence not found: " .. tostring(args.sequence_id))
            command:set_parameter("prior_playhead", seq.playhead_position)
        end

        local result = command_manager.execute("ExtractRange", {
            mark_in = earliest_start,
            mark_out = trim_frame,
            sequence_id = args.sequence_id,
            project_id = args.project_id,
        })

        if not result or not result.success then
            local msg = result and result.error_message or "ExtractRange failed"
            set_last_error("TrimHead: " .. msg)
            return false
        end

        set_playhead(args.sequence_id, earliest_start)
        return true
    end

    -- ExtractRange undo is automatic (nested command).
    -- Restore playhead to pre-trim position.
    command_undoers["TrimHead"] = function(command)
        local args = command:get_all_parameters()
        assert(args.prior_playhead, "TrimHead undo: prior_playhead missing — was capture performed?")
        set_playhead(args.sequence_id, args.prior_playhead)
        return true
    end

    return {
        executor = command_executors["TrimHead"],
        undoer = command_undoers["TrimHead"],
        spec = SPEC,
    }
end

return M
