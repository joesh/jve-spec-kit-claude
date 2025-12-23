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
local Rational = require('core.rational')

function M.register(command_executors, command_undoers, db, set_last_error)
    command_executors["GoToEnd"] = function(command)
        local dry_run = command:get_parameter("dry_run")
        if not dry_run then
            print("Executing GoToEnd command")
        end

        local clips = timeline_state.get_clips() or {}
        
        local fps_num = 30
        local fps_den = 1
        if timeline_state.get_sequence_frame_rate then
            local rate = timeline_state.get_sequence_frame_rate()
            if type(rate) == "table" and rate.fps_numerator then
                fps_num = rate.fps_numerator
                fps_den = rate.fps_denominator
            end
        end
        
        local max_end = Rational.new(0, fps_num, fps_den)
        
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

        if dry_run then
            return true, { timeline_end = max_end }
        end

        timeline_state.set_playhead_position(max_end)
        print(string.format("✅ Moved playhead to timeline end (%s)", tostring(max_end)))
        return true
    end

    return {
        executor = command_executors["GoToEnd"]
    }
end

return M
