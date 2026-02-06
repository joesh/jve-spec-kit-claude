--- TrimTail command — trims clip end to playhead position.
--
-- Removes content after playhead: reduces duration and adjusts source_out.
--
-- @file trim_tail.lua
local M = {}
local Clip = require("models.clip")
local command_helper = require("core.command_helper")
local Rational = require("core.rational")

local SPEC = {
    args = {
        clip_id = { required = true },
        project_id = { required = true },
        sequence_id = { required = true },
        trim_frame = { required = true },  -- playhead frame (int)
    },
    persisted = {
        original_timeline_start = {},
        original_duration = {},
        original_source_in = {},
        original_source_out = {},
    },
}

function M.register(command_executors, command_undoers, db, set_last_error)
    command_executors["TrimTail"] = function(command)
        local args = command:get_all_parameters()
        local logger = require("core.logger")
        logger.info("trim_tail", string.format("TrimTail clip=%s frame=%s", args.clip_id, tostring(args.trim_frame)))

        local clip = Clip.load(args.clip_id)
        if not clip then
            set_last_error(string.format("TrimTail: clip not found: %s", args.clip_id))
            return false
        end

        local rate = clip.fps_numerator and {fps_numerator = clip.fps_numerator, fps_denominator = clip.fps_denominator}
        assert(rate and rate.fps_numerator and rate.fps_denominator,
            "TrimTail: clip missing fps metadata")

        local trim_rt = Rational.new(args.trim_frame, rate.fps_numerator, rate.fps_denominator)
        local clip_start = Rational.hydrate(clip.timeline_start, rate.fps_numerator, rate.fps_denominator)
        local clip_duration = Rational.hydrate(clip.duration, rate.fps_numerator, rate.fps_denominator)
        local clip_end = clip_start + clip_duration

        -- Trim frame must be within clip (exclusive of boundaries)
        if trim_rt.frames <= clip_start.frames or trim_rt.frames >= clip_end.frames then
            set_last_error(string.format("TrimTail: playhead (%d) not inside clip [%d..%d)",
                trim_rt.frames, clip_start.frames, clip_end.frames))
            return false
        end

        -- Save original state for undo
        command:set_parameters({
            original_timeline_start = clip.timeline_start,
            original_duration = clip.duration,
            original_source_in = clip.source_in,
            original_source_out = clip.source_out,
        })

        -- Apply trim: keep start, shrink duration, adjust source_out
        local new_duration = trim_rt - clip_start
        local source_in_rt = Rational.hydrate(clip.source_in, rate.fps_numerator, rate.fps_denominator)
        clip.duration = new_duration
        clip.source_out = source_in_rt + new_duration

        if not clip:save() then
            set_last_error("TrimTail: failed to save clip")
            return false
        end

        local update = command_helper.clip_update_payload(clip, args.sequence_id)
        if update then
            command_helper.add_update_mutation(command, args.sequence_id, update)
        end

        logger.info("trim_tail", string.format("TrimTail: trimmed %d frames from tail of %s",
            (clip_end - trim_rt).frames, args.clip_id))
        return true
    end

    command_undoers["TrimTail"] = function(command)
        local args = command:get_all_parameters()
        local logger = require("core.logger")
        logger.info("trim_tail", "Undoing TrimTail")

        local clip = Clip.load(args.clip_id)
        if not clip then
            set_last_error(string.format("UndoTrimTail: clip not found: %s", args.clip_id))
            return false
        end

        local function restore_rat(val)
            if type(val) == "table" and val.frames then
                return Rational.new(val.frames, val.fps_numerator, val.fps_denominator)
            end
            return val
        end

        clip.timeline_start = restore_rat(args.original_timeline_start)
        clip.duration = restore_rat(args.original_duration)
        clip.source_in = restore_rat(args.original_source_in)
        clip.source_out = restore_rat(args.original_source_out)

        if not clip:save() then
            set_last_error("UndoTrimTail: failed to save clip")
            return false
        end

        local update = command_helper.clip_update_payload(clip, args.sequence_id)
        if update then
            command_helper.add_update_mutation(command, args.sequence_id, update)
        end

        return true
    end

    return {
        executor = command_executors["TrimTail"],
        undoer = command_undoers["TrimTail"],
        spec = SPEC,
    }
end

return M
