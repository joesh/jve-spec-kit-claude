--- Blade command: split clips at playhead (Cmd+B).
--
-- If clips are selected, only splits selected clips intersecting the playhead.
-- Otherwise splits all clips at the playhead.
-- Creates a BatchCommand of SplitClip sub-commands.
--
-- @file blade.lua
local M = {}

local SPEC = {
    undoable = false,  -- delegates to BatchCommand which IS undoable
    args = {
        project_id = { required = true },
        sequence_id = {},
    }
}

function M.register(executors, undoers, db)
    local function executor(command)
        local timeline_state = require('ui.timeline.timeline_state')
        local json = require("dkjson")

        local selected_clips = timeline_state.get_selected_clips()
        local playhead_value = timeline_state.get_playhead_position()

        local target_clips
        if selected_clips and #selected_clips > 0 then
            target_clips = timeline_state.get_clips_at_time(playhead_value, selected_clips)
        else
            target_clips = timeline_state.get_clips_at_time(playhead_value)
        end

        if #target_clips == 0 then
            if selected_clips and #selected_clips > 0 then
                print("Blade: Playhead does not intersect selected clips")
            else
                print("Blade: No clips under playhead")
            end
            return true
        end

        local specs = {}
        for _, clip in ipairs(target_clips) do
            local start_value = clip.timeline_start or clip.start_value
            local duration_value = clip.duration or clip.duration_value
            assert(type(start_value) == "number", "Blade: clip timeline_start must be integer")
            assert(type(duration_value) == "number", "Blade: clip duration must be integer")
            assert(type(playhead_value) == "number", "Blade: playhead must be integer")

            if duration_value > 0 then
                local end_time = start_value + duration_value
                if playhead_value > start_value and playhead_value < end_time then
                    specs[#specs + 1] = {
                        command_type = "SplitClip",
                        parameters = {
                            clip_id = clip.id,
                            split_value = playhead_value,
                        }
                    }
                end
            end
        end

        if #specs == 0 then
            print("Blade: No valid clips to split at current playhead position")
            return true
        end

        local args = command:get_all_parameters()
        local project_id = args.project_id
        assert(project_id and project_id ~= "", "Blade: missing active project_id")

        local batch_params = {
            project_id = project_id,
            commands_json = json.encode(specs),
        }
        local sequence_id = args.sequence_id
        if sequence_id and sequence_id ~= "" then
            batch_params.sequence_id = sequence_id
        end

        local command_manager = require("core.command_manager")
        local result = command_manager.execute("BatchCommand", batch_params)
        if result.success then
            print(string.format("Blade: Split %d clip(s) at %s", #specs, tostring(playhead_value)))
        else
            print(string.format("Blade: Failed to split clips: %s", result.error_message or "unknown error"))
        end

        return true
    end

    return {
        executor = executor,
        spec = SPEC,
    }
end

return M
