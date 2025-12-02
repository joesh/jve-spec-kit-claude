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
        
        -- Store points as Rationals in a list, sort manually
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

        -- Deduplicate and sort
        table.sort(points)
        -- Simple dedupe
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

    command_executors["GoToNextEdit"] = function(command)
        local dry_run = command:get_parameter("dry_run")
        if not dry_run then
            print("Executing GoToNextEdit command")
        end

        local points = collect_edit_points()
        local playhead = timeline_state.get_playhead_position()
        
        -- Ensure playhead is Rational
        if type(playhead) == "number" then
             -- Should not happen in V5 usually
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
        for _, point in ipairs(points) do
            if point > playhead then
                target = point
                break
            end
        end

        if dry_run then
            return true, { target = target }
        end

        if target ~= playhead then
            timeline_state.set_playhead_position(target)
            print(string.format("✅ Moved playhead to next edit (%s)", tostring(target)))
        end
        return true
    end

    return {
        executor = command_executors["GoToNextEdit"]
    }
end

return M
