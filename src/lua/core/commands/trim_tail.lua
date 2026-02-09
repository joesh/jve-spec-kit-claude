--- TrimTail command — trims clip end(s) to playhead position with ripple.
--
-- Removes content after playhead: reduces duration and adjusts source_out.
-- Ripples downstream clips to close the gap.
--
-- @file trim_tail.lua
local M = {}
local Clip = require("models.clip")
local command_helper = require("core.command_helper")

local SPEC = {
    args = {
        clip_ids = { required = true },  -- array of clip IDs to trim
        project_id = { required = true },
        sequence_id = { required = true },
        trim_frame = { required = true },  -- playhead frame (int)
    },
    persisted = {
        original_states = {},  -- array of {clip_id, timeline_start, duration, source_in, source_out}
        gap_start = {},
        gap_duration = {},
    },
}

function M.register(command_executors, command_undoers, db, set_last_error)
    command_executors["TrimTail"] = function(command)
        local args = command:get_all_parameters()
        local logger = require("core.logger")
        local command_manager = require("core.command_manager")

        local clip_ids = args.clip_ids
        assert(type(clip_ids) == "table" and #clip_ids > 0,
            "TrimTail: clip_ids must be non-empty array")

        local trim_frame = args.trim_frame
        logger.info("trim_tail", string.format("TrimTail clips=%d frame=%d", #clip_ids, trim_frame))

        -- Load all clips ONCE and validate
        local clips_to_trim = {}  -- {clip, clip_start, clip_end}
        local original_states = {}
        local latest_end_frame = nil
        local reference_clip = nil

        for _, clip_id in ipairs(clip_ids) do
            local clip = Clip.load(clip_id)
            if not clip then
                set_last_error(string.format("TrimTail: clip not found: %s", clip_id))
                return false
            end

            reference_clip = reference_clip or clip

            local clip_start = clip.timeline_start
            local clip_end = clip_start + clip.duration

            -- Validate trim point is inside clip
            if trim_frame <= clip_start or trim_frame >= clip_end then
                set_last_error(string.format("TrimTail: playhead (%d) not inside clip %s [%d..%d)",
                    trim_frame, clip_id, clip_start, clip_end))
                return false
            end

            table.insert(clips_to_trim, {
                clip = clip,
                clip_start = clip_start,
                clip_end = clip_end,
            })

            table.insert(original_states, {
                clip_id = clip_id,
                timeline_start = clip.timeline_start,
                duration = clip.duration,
                source_in = clip.source_in,
                source_out = clip.source_out,
            })

            if not latest_end_frame or clip_end > latest_end_frame then
                latest_end_frame = clip_end
            end
        end

        -- Gap: from trim point to latest original end
        local gap_frames = latest_end_frame - trim_frame

        -- Trim all clips (reuse loaded data)
        for _, entry in ipairs(clips_to_trim) do
            local clip = entry.clip
            local clip_end = entry.clip_end
            local trimmed_frames = clip_end - trim_frame

            -- Apply trim: keep start, shrink duration, adjust source_out
            local new_duration_frames = trim_frame - entry.clip_start
            clip.duration = new_duration_frames
            clip.source_out = clip.source_in + new_duration_frames

            if not clip:save() then
                set_last_error(string.format("TrimTail: failed to save clip %s", clip.id))
                return false
            end

            local update = command_helper.clip_update_payload(clip, args.sequence_id)
            if update then
                command_helper.add_update_mutation(command, args.sequence_id, update)
            end

            logger.info("trim_tail", string.format("TrimTail: trimmed %d frames from tail of %s",
                trimmed_frames, clip.id))
        end

        -- Save state for undo
        command:set_parameters({
            original_states = original_states,
            gap_start = trim_frame,
            gap_duration = gap_frames,
        })

        -- Ripple: shift all downstream clips to close the gap
        local ripple_result = command_manager.execute("RippleDelete", {
            track_id = "all",
            gap_start = trim_frame,
            gap_duration = gap_frames,
            sequence_id = args.sequence_id,
            project_id = args.project_id,
        })

        if not ripple_result or not ripple_result.success then
            local msg = ripple_result and ripple_result.error_message or "RippleDelete failed"
            set_last_error("TrimTail ripple: " .. msg)
            return false
        end

        logger.info("trim_tail", string.format("TrimTail: completed with ripple, gap=%d frames", gap_frames))
        return true
    end

    command_undoers["TrimTail"] = function(command)
        local args = command:get_all_parameters()
        local logger = require("core.logger")
        logger.info("trim_tail", "Undoing TrimTail")

        local original_states = args.original_states
        if not original_states or #original_states == 0 then
            return true  -- Nothing to undo
        end

        -- Restore all clips to original state
        for _, state in ipairs(original_states) do
            local clip = Clip.load(state.clip_id)
            if not clip then
                set_last_error(string.format("UndoTrimTail: clip not found: %s", state.clip_id))
                return false
            end

            clip.timeline_start = state.timeline_start
            clip.duration = state.duration
            clip.source_in = state.source_in
            clip.source_out = state.source_out

            if not clip:save() then
                set_last_error(string.format("UndoTrimTail: failed to save clip %s", state.clip_id))
                return false
            end

            local update = command_helper.clip_update_payload(clip, args.sequence_id)
            if update then
                command_helper.add_update_mutation(command, args.sequence_id, update)
            end
        end

        -- Note: RippleDelete undo is handled automatically by command_manager
        -- since it was executed as a nested command

        return true
    end

    return {
        executor = command_executors["TrimTail"],
        undoer = command_undoers["TrimTail"],
        spec = SPEC,
    }
end

return M
