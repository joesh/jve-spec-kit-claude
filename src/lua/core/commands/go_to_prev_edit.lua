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
-- Size: ~84 LOC
-- Volatility: unknown
--
-- @file go_to_prev_edit.lua
local M = {}
local timeline_state = require('ui.timeline.timeline_state')
local sequence_frame_rate = require('core.utils.sequence_frame_rate')
local Rational = require('core.rational')


local SPEC = {
    args = {
        dry_run = { kind = "boolean" },
        project_id = { required = true },
    }
}

function M.register(command_executors, command_undoers, db, set_last_error)
    local function collect_edit_points()
        local clips = timeline_state.get_clips() or {}
        
        -- Determine rate
        local fps_num, fps_den = sequence_frame_rate.require_sequence_frame_rate(timeline_state, "GoToPrevEdit")
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
        local args = command:get_all_parameters()

        if not args.dry_run then
            print("Executing GoToPrevEdit command")
        end

        local points = collect_edit_points()
        local playhead = timeline_state.get_playhead_position()
        
        if type(playhead) == "number" then
             local fps_num, fps_den = sequence_frame_rate.require_sequence_frame_rate(timeline_state, "GoToPrevEdit")
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

        if args.dry_run then
            return true, { target = target }
        end

        if target ~= playhead then
            timeline_state.set_playhead_position(target)
            print(string.format("✅ Moved playhead to previous edit (%s)", tostring(target)))
        end
        return true
    end

    return {
        executor = command_executors["GoToPrevEdit"],
        spec = SPEC,
    }
end

return M
