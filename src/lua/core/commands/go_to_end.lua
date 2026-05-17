--- GoToEnd: park the playhead at the first frame past content (exclusive
--- out-point of the sequence). Movement-class (FR-020): sequence_id is
--- auto-injected from the displayed-side engine.
---
--- @file go_to_end.lua
local M = {}

local SPEC = {
    undoable = false,
    mutates_clips = false,
    args = {
        dry_run = { kind = "boolean" },
        project_id = { required = true },
        sequence_id = {},
    }
}

function M.register(command_executors, command_undoers, db, set_last_error)
    command_executors["GoToEnd"] = function(command)
        local args = command:get_all_parameters()
        assert(args.sequence_id and args.sequence_id ~= "",
            "GoToEnd: sequence_id is required (auto-injected)")

        local Sequence = require("models.sequence")
        local sequence = Sequence.load(args.sequence_id)
        assert(sequence, "GoToEnd: sequence not found: " .. tostring(args.sequence_id))

        -- End = first frame past content (exclusive out-point). Compute from
        -- the sequence's own content_duration so we don't depend on a view's
        -- in-memory total_frames mirror.
        local duration = sequence:content_duration()
        assert(duration > 0, "GoToEnd: sequence content_duration must be > 0")
        local end_frame = sequence.start_timecode_frame + duration

        if args.dry_run then
            return true, { end_frame = end_frame }
        end

        sequence.playhead_position = end_frame
        sequence:save()
        local Signals = require("core.signals")
        Signals.emit("playhead_changed", args.sequence_id, end_frame)

        require("core.playback.transport").seek_target_if_loaded(
            args.sequence_id, end_frame)

        local timeline_state = require("ui.timeline.timeline_state")
        timeline_state.surface_playhead()
        return true
    end

    return {
        executor = command_executors["GoToEnd"],
        spec = SPEC,
    }
end

return M
