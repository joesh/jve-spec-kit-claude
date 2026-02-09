--- TODO: one-line summary (human review required)
--
-- Responsibilities:
-- - TODO
--
-- Non-goals:
-- - TODO
--
-- Invariants:
-- - TODO
--
-- Size: ~42 LOC
-- Volatility: unknown
--
-- @file go_to_end.lua
local M = {}
local timeline_state = require('ui.timeline.timeline_state')


local SPEC = {
    undoable = false,
    args = {
        dry_run = { kind = "boolean" },
        project_id = { required = true },
        sequence_id = {},
    }
}

function M.register(command_executors, command_undoers, db, set_last_error)
    command_executors["GoToEnd"] = function(command)
        local args = command:get_all_parameters()

        if not args.dry_run then
            print("Executing GoToEnd command")
        end

        local clips = timeline_state.get_clips() or {}
        local max_end = 0
        
        for _, clip in ipairs(clips) do
            local start = clip.timeline_start
            local duration = clip.duration
            if start and duration then
                local clip_end = start + duration
                if clip_end > max_end then
                    max_end = clip_end
                end
            end
        end

        if args.dry_run then
            return true, { timeline_end = max_end }
        end

        timeline_state.set_playhead_position(max_end)
        print(string.format("✅ Moved playhead to timeline end (%s)", tostring(max_end)))
        return true
    end

    return {
        executor = command_executors["GoToEnd"],
        spec = SPEC,
    }
end

return M
