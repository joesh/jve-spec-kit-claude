local M = {}
local Clip = require('models.clip')
local command_helper = require("core.command_helper")
local timeline_state = require('ui.timeline.timeline_state')

function M.register(command_executors, command_undoers, db, set_last_error)
    local function record_clip_enabled_mutation(command, clip)
        if not clip then
            return
        end
        local mutation_sequence = command:get_parameter("sequence_id") or clip.owner_sequence_id or clip.track_sequence_id
        local update_payload = command_helper.clip_update_payload(clip, mutation_sequence)
        if update_payload then
            command_helper.add_update_mutation(command, update_payload.track_sequence_id or mutation_sequence, update_payload)
        end
    end

    command_executors["ToggleClipEnabled"] = function(command)
        local dry_run = command:get_parameter("dry_run")
        if not dry_run then
            print("Executing ToggleClipEnabled command")
        end

        local active_sequence_id = command:get_parameter("sequence_id")
        if (not active_sequence_id or active_sequence_id == "") and timeline_state and timeline_state.get_sequence_id then
            active_sequence_id = timeline_state.get_sequence_id()
            if active_sequence_id and active_sequence_id ~= "" then
                command:set_parameter("sequence_id", active_sequence_id)
            end
        end

        local toggles = command:get_parameter("clip_toggles")
        if not toggles or #toggles == 0 then
            local clip_ids = command:get_parameter("clip_ids")

            if not clip_ids or #clip_ids == 0 then
                local selected_clips = timeline_state.get_selected_clips() or {}
                clip_ids = {}
                for _, clip in ipairs(selected_clips) do
                    if clip and clip.id then
                        table.insert(clip_ids, clip.id)
                    end
                end
            end

            if not clip_ids or #clip_ids == 0 then
                print("ToggleClipEnabled: No clips selected")
                return false
            end

            toggles = {}
            for _, clip_id in ipairs(clip_ids) do
                local clip = Clip.load_optional(clip_id, db)
                if clip then
                    local enabled_before = clip.enabled ~= false
                    table.insert(toggles, {
                        clip_id = clip_id,
                        enabled_before = enabled_before,
                        enabled_after = not enabled_before,
                    })
                else
                    print(string.format("WARNING: ToggleClipEnabled: Clip %s not found", tostring(clip_id)))
                end
            end

            if #toggles == 0 then
                print("ToggleClipEnabled: No valid clips to toggle")
                return false
            end

            command:set_parameter("clip_toggles", toggles)
        end

        if dry_run then
            return true, {clip_toggles = toggles}
        end

        command:set_parameter("__skip_sequence_replay", true)

        local toggled = 0
        for _, toggle in ipairs(toggles) do
            local clip = Clip.load_optional(toggle.clip_id, db)
            if clip then
                clip.enabled = toggle.enabled_after and true or false
                if clip:save(db, {skip_occlusion = true}) then
                    record_clip_enabled_mutation(command, clip)
                    toggled = toggled + 1
                else
                    print(string.format("ERROR: ToggleClipEnabled: Failed to save clip %s", tostring(toggle.clip_id)))
                    return false
                end
            else
                print(string.format("WARNING: ToggleClipEnabled: Clip %s missing during execution", tostring(toggle.clip_id)))
            end
        end

        print(string.format("✅ Toggled enabled state for %d clip(s)", toggled))
        return toggled > 0
    end

    command_undoers["ToggleClipEnabled"] = function(command)
        local toggles = command:get_parameter("clip_toggles")
        if not toggles or #toggles == 0 then
            return true
        end

        local restored = 0
        for _, toggle in ipairs(toggles) do
            local clip = Clip.load_optional(toggle.clip_id, db)
            if clip then
                clip.enabled = toggle.enabled_before and true or false
                if clip:save(db, {skip_occlusion = true}) then
                    record_clip_enabled_mutation(command, clip)
                    restored = restored + 1
                else
                    print(string.format("WARNING: ToggleClipEnabled undo: Failed to restore clip %s", tostring(toggle.clip_id)))
                end
            end
        end

        -- Flush logic is typically in command_manager, but some undoers called it explicitly.
        -- We assume mutations are picked up from command by manager.

        print(string.format("✅ Undo ToggleClipEnabled: Restored %d clip(s)", restored))
        return true
    end

    return {
        executor = command_executors["ToggleClipEnabled"],
        undoer = command_undoers["ToggleClipEnabled"]
    }
end

return M
