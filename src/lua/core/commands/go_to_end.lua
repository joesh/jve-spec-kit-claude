local M = {}
local timeline_state = require('ui.timeline.timeline_state')

function M.register(command_executors, command_undoers, db, set_last_error)
    command_executors["GoToEnd"] = function(command)
        local dry_run = command:get_parameter("dry_run")
        if not dry_run then
            print("Executing GoToEnd command")
        end

        local clips = timeline_state.get_clips() or {}
        local max_end = 0
        for _, clip in ipairs(clips) do
            local start_value = clip.start_value
            local duration = clip.duration
            if start_value and duration then
                local clip_end = start_value + duration
                if clip_end > max_end then
                    max_end = clip_end
                end
            end
        end

        if dry_run then
            return true, { timeline_end = max_end }
        end

        timeline_state.set_playhead_value(max_end)
        print(string.format("✅ Moved playhead to timeline end (%dms)", max_end))
        return true
    end

    return {
        executor = command_executors["GoToEnd"]
    }
end

return M
