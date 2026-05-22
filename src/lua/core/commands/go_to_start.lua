--- GoToStart: park the playhead at the sequence's start TC. Movement-class
--- (FR-020): sequence_id is auto-injected from the displayed-side engine.
---
--- @file go_to_start.lua
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
    command_executors["GoToStart"] = function(command)
        local args = command:get_all_parameters()
        assert(args.sequence_id and args.sequence_id ~= "",
            "GoToStart: sequence_id is required (auto-injected)")

        local Sequence = require("models.sequence")
        local sequence = Sequence.load(args.sequence_id)
        assert(sequence, "GoToStart: sequence not found: " .. tostring(args.sequence_id))

        -- Each sequence knows its own start TC (0 for master clips, DRP value for timelines).
        local start_frame = sequence.start_timecode_frame
        assert(type(start_frame) == "number",
            "GoToStart: sequence missing start_timecode_frame")

        if args.dry_run then
            return true, { start_frame = start_frame }
        end

        require("core.playhead").set(args.sequence_id, start_frame)
        require("ui.timeline.timeline_state").surface_playhead()
        return true
    end

    return {
        executor = command_executors["GoToStart"],
        spec = SPEC,
    }
end

return M
