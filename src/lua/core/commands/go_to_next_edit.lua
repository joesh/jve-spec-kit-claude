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
-- Size: ~83 LOC
-- Volatility: unknown
--
-- @file go_to_next_edit.lua
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
    local function collect_edit_points()
        local clips = timeline_state.get_clips() or {}

        -- Collect edit points as integers
        local points = {0}

        for _, clip in ipairs(clips) do
            local start = clip.timeline_start or clip.start_value
            local duration = clip.duration or clip.duration_value

            if type(start) == "number" then
                table.insert(points, start)
                if type(duration) == "number" then
                    table.insert(points, start + duration)
                end
            end
        end

        -- Sort and deduplicate
        table.sort(points)
        local unique = {}
        local last = nil
        for _, p in ipairs(points) do
            if p ~= last then
                table.insert(unique, p)
                last = p
            end
        end

        return unique
    end

    command_executors["GoToNextEdit"] = function(command)
        local args = command:get_all_parameters()

        if not args.dry_run then
            print("Executing GoToNextEdit command")
        end

        local points = collect_edit_points()
        local playhead = timeline_state.get_playhead_position()
        assert(type(playhead) == "number", "GoToNextEdit: playhead must be integer frames")

        local target = playhead
        for _, point in ipairs(points) do
            if point > playhead then
                target = point
                break
            end
        end

        if args.dry_run then
            return true, { target = target }
        end

        -- Stop playback before navigating (NLE convention)
        local ok, pc = pcall(require, 'core.playback.playback_controller')
        if ok and pc and pc.state == "playing" then
            pc.stop()
        end

        if target ~= playhead then
            timeline_state.set_playhead_position(target)
            print(string.format("✅ Moved playhead to next edit (frame %d)", target))
        end
        return true
    end

    return {
        executor = command_executors["GoToNextEdit"],
        spec = SPEC,
    }
end

return M
