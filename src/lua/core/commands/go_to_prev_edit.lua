local M = {}
local timeline_state = require('ui.timeline.timeline_state')
local Rational = require('core.rational')

function M.register(command_executors, command_undoers, db, set_last_error)
    local function collect_edit_points()
        local clips = timeline_state.get_clips() or {}
        
        -- Determine rate
        local fps_num = 30
        local fps_den = 1
        if timeline_state.get_sequence_frame_rate then
            local rate = timeline_state.get_sequence_frame_rate()
            if type(rate) == "table" and rate.fps_numerator then
                fps_num = rate.fps_numerator
                fps_den = rate.fps_denominator
            end
        end
        local zero = Rational.new(0, fps_num, fps_den)
        
        local points = {zero}

        local function add_point(value)
            if type(value) == "table" and value.frames then
                table.insert(points, value)
            elseif type(value) == "number" then
                table.insert(points, Rational.new(value, fps_num, fps_den))
            end
        end

        for _, clip in ipairs(clips) do
            local start = clip.timeline_start or clip.start_value
            local duration = clip.duration or clip.duration_value

            if start then add_point(start) end
            if start and duration then
                add_point(start + duration)
            end
        end

        table.sort(points)
        -- Dedupe
        local unique = {}
        local last = nil
        for _, p in ipairs(points) do
            if not last or p ~= last then
                table.insert(unique, p)
                last = p
            end
        end
        return unique
    end

    command_executors["GoToPrevEdit"] = function(command)
        local dry_run = command:get_parameter("dry_run")
        if not dry_run then
            print("Executing GoToPrevEdit command")
        end

        local points = collect_edit_points()
        local playhead = timeline_state.get_playhead_position()
        
        if type(playhead) == "number" then
             local fps_num = 30
             local fps_den = 1
             if timeline_state.get_sequence_frame_rate then
                 local rate = timeline_state.get_sequence_frame_rate()
                 if type(rate) == "table" and rate.fps_numerator then
                     fps_num = rate.fps_numerator
                     fps_den = rate.fps_denominator
                 end
             end
             playhead = Rational.new(playhead, fps_num, fps_den)
        end

        local target = playhead
        -- Iterate backwards
        for i = #points, 1, -1 do
            local point = points[i]
            if point < playhead then
                target = point
                break
            end
        end

        if dry_run then
            return true, { target = target }
        end

        if target ~= playhead then
            timeline_state.set_playhead_position(target)
            print(string.format("✅ Moved playhead to previous edit (%s)", tostring(target)))
        end
        return true
    end

    return {
        executor = command_executors["GoToPrevEdit"]
    }
end

return M
