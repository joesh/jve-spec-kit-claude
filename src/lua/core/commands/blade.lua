--- Blade command: split clips at playhead (Cmd+B).
--
-- If clips are selected, only splits selected clips intersecting the playhead.
-- Otherwise splits all clips at the playhead.
-- Executes SplitClip sub-commands via nested command_manager.execute().
--
-- @file blade.lua
local M = {}
local log = require("core.logger").for_area("commands")
local command_helper = require("core.command_helper")

local SPEC = {
    undoable = false,
    args = {
        project_id = { required = true },
        sequence_id = {},
    }
}

function M.register(executors)
    local function executor(command)
        local command_manager = require("core.command_manager")

        local target_clips, playhead_value = command_helper.resolve_clips_at_playhead()
        if #target_clips == 0 then
            log.event("Blade: no clips under playhead")
            return true
        end

        local args = command:get_all_parameters()
        local project_id = args.project_id
        assert(project_id and project_id ~= "", "Blade: missing active project_id")

        -- Group all SplitClip children into one undo atom
        command_manager.begin_undo_group("Blade")

        local split_count = 0
        local fail_count = 0
        for _, clip in ipairs(target_clips) do
            local start_value = clip.timeline_start
            local duration_value = clip.duration
            assert(type(start_value) == "number", "Blade: clip timeline_start must be integer")
            assert(type(duration_value) == "number", "Blade: clip duration must be integer")

            if duration_value > 0 then
                local end_time = start_value + duration_value
                if playhead_value > start_value and playhead_value < end_time then
                    local result = command_manager.execute("SplitClip", {
                        clip_id = clip.id,
                        split_value = playhead_value,
                        project_id = project_id,
                        sequence_id = args.sequence_id,
                    })
                    if result.success then
                        split_count = split_count + 1
                    else
                        fail_count = fail_count + 1
                        log.error("Blade: SplitClip failed for %s: %s",
                            clip.id, result.error_message or "unknown")
                    end
                end
            end
        end

        command_manager.end_undo_group()

        if split_count > 0 then
            log.event("Blade: split %d clip(s) at %s", split_count, tostring(playhead_value))
        end
        if fail_count > 0 then
            log.warn("Blade: %d of %d split(s) failed", fail_count, split_count + fail_count)
        end

        return fail_count == 0
    end

    return {
        executor = executor,
        spec = SPEC,
    }
end

return M
