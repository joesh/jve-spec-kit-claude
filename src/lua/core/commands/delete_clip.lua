local M = {}
local Clip = require('models.clip')
local command_helper = require("core.command_helper")

function M.register(command_executors, command_undoers, db, set_last_error)
    command_executors["DeleteClip"] = function(command)
        print("Executing DeleteClip command")

        local clip_id = command:get_parameter("clip_id")
        if not clip_id or clip_id == "" then
            print("WARNING: DeleteClip: Missing required parameter 'clip_id'")
            return false
        end

        local clip = Clip.load_optional(clip_id, db)
        if not clip then
            local previous_state = command:get_parameter("deleted_clip_state")
            if previous_state then
                command_helper.restore_clip_state(previous_state)
                clip = Clip.load_optional(clip_id, db)
            end
        end
        if not clip then
            print(string.format("INFO: DeleteClip: Clip %s already absent during replay; skipping delete", clip_id))
            return true
        end

        local clip_state = command_helper.capture_clip_state(clip)
        command:set_parameter("deleted_clip_state", clip_state)
        command:set_parameter("deleted_clip_properties", command_helper.snapshot_properties_for_clip(clip_id))

        command_helper.delete_properties_for_clip(clip_id)

        if not clip:delete(db) then
            print(string.format("WARNING: DeleteClip: Failed to delete clip %s", clip_id))
            return false
        end

        local sequence_id = command:get_parameter("sequence_id")
            or clip.owner_sequence_id
            or clip.track_sequence_id
            or (clip.track and clip.track.sequence_id)
        if sequence_id then
            command_helper.add_delete_mutation(command, sequence_id, clip.id)
        end

        print(string.format("✅ Deleted clip %s from timeline", clip_id))
        return true
    end

    command_undoers["DeleteClip"] = function(command)
        local clip_state = command:get_parameter("deleted_clip_state")
        if not clip_state then
            print("WARNING: DeleteClip undo: Missing clip state")
            return false
        end

        command_helper.restore_clip_state(clip_state)
        local properties = command:get_parameter("deleted_clip_properties") or {}
        if #properties > 0 then
            command_helper.insert_properties_for_clip(clip_state.id, properties)
        end
        print(string.format("✅ Undo DeleteClip: Restored clip %s", clip_state.id))
        return true
    end

    return {
        executor = command_executors["DeleteClip"],
        undoer = command_undoers["DeleteClip"]
    }
end

return M
