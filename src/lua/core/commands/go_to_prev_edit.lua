local M = {}
local timeline_state = require('ui.timeline.timeline_state')

function M.register(command_executors, command_undoers, db, set_last_error)
    local function collect_edit_points()
        local clips = timeline_state.get_clips() or {}
        local point_map = {[0] = true}

        local function add_point(value)
            if type(value) == "number" then
                point_map[value] = true
            end
        end

        for _, clip in ipairs(clips) do
            local start_value = clip.start_value or clip.start or clip.startTime
            local duration = clip.duration_value or clip.duration or clip.length or clip.duration_ms

            add_point(start_value)
            if type(start_value) == "number" and type(duration) == "number" then
                add_point(start_value + duration)
            end
        end

        local points = {}
        for value in pairs(point_map) do
            table.insert(points, value)
        end
        table.sort(points)
        return points
    end

    command_executors["GoToPrevEdit"] = function(command)
        local dry_run = command:get_parameter("dry_run")
        if not dry_run then
            print("Executing GoToPrevEdit command")
        end

        local points = collect_edit_points()
        local playhead = timeline_state.get_playhead_value() or 0

        local target = 0
        for _, point in ipairs(points) do
            if point < playhead then
                target = point
            else
                break
            end
        end

        if dry_run then
            return true, { target = target }
        end

        timeline_state.set_playhead_value(target)
        print(string.format("✅ Moved playhead to previous edit (%dms)", target))
        return true
    end

    return {
        executor = command_executors["GoToPrevEdit"]
    }
end

return M
