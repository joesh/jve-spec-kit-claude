local M = {}
local command_helper = require("core.command_helper")

function M.register(command_executors, command_undoers, db, set_last_error)
    local function perform_item_rename(target_type, target_id, new_name, project_id)
        if not target_type or target_type == "" then
            return false, "RenameItem: Missing target_type"
        end
        if not target_id or target_id == "" then
            return false, "RenameItem: Missing target_id"
        end

        new_name = command_helper.trim_string(new_name)
        if new_name == "" then
            return false, "RenameItem: New name cannot be empty"
        end

        project_id = project_id or "default_project"

        if target_type == "master_clip" then
            local Clip = require("models.clip")
            local clip = Clip.load_optional(target_id, db)
            if not clip then
                return false, "RenameItem: Master clip not found"
            end
            local previous_name = clip.name or ""
            if previous_name == new_name then
                return true, previous_name
            end
            clip.name = new_name
            if not clip:save(db, {skip_occlusion = true}) then
                return false, "RenameItem: Failed to save master clip"
            end
            local update_stmt = db:prepare([[
                UPDATE clips
                SET name = ?
                WHERE parent_clip_id = ? AND clip_kind = 'timeline'
            ]])
            if not update_stmt then
                return false, "RenameItem: Failed to prepare timeline rename"
            end
            update_stmt:bind_value(1, new_name)
            update_stmt:bind_value(2, clip.id)
            if not update_stmt:exec() then
                update_stmt:finalize()
                return false, "RenameItem: Failed to update timeline clips"
            end
            update_stmt:finalize()
            command_helper.reload_timeline(clip.owner_sequence_id or clip.source_sequence_id)
            return true, previous_name
        elseif target_type == "sequence" then
            local Sequence = require("models.sequence")
            local sequence = Sequence.load(target_id, db)
            if not sequence then
                return false, "RenameItem: Sequence not found"
            end
            local previous_name = sequence.name or ""
            if previous_name == new_name then
                return true, previous_name
            end
            sequence.name = new_name
            if not sequence:save(db) then
                return false, "RenameItem: Failed to save sequence"
            end
            command_helper.reload_timeline(sequence.id)
            return true, previous_name
        elseif target_type == "bin" then
            local tag_service = require("core.tag_service")
            local ok, result = tag_service.rename_bin(project_id, target_id, new_name)
            if not ok then
                return false, result
            end
            return true, result.previous_name or new_name
        else
            return false, "RenameItem: Unsupported target type"
        end

        return true, new_name
    end

    command_executors["RenameItem"] = function(command)
        local target_type = command:get_parameter("target_type")
        local target_id = command:get_parameter("target_id")
        local project_id = command:get_parameter("project_id") or command.project_id or "default_project"
        local new_name = command_helper.trim_string(command:get_parameter("new_name"))

        if not target_type or target_type == "" then
            set_last_error("RenameItem: Missing target_type")
            return false
        end
        if not target_id or target_id == "" then
            set_last_error("RenameItem: Missing target_id")
            return false
        end
        if new_name == "" then
            set_last_error("RenameItem: New name cannot be empty")
            return false
        end

        local success, previous_or_err = perform_item_rename(target_type, target_id, new_name, project_id)
        if not success then
            set_last_error(previous_or_err or "RenameItem failed")
            return false
        end

        command:set_parameter("target_type", target_type)
        command:set_parameter("target_id", target_id)
        command:set_parameter("project_id", project_id)
        command:set_parameter("previous_name", previous_or_err or "")
        command:set_parameter("final_name", new_name)
        return true
    end

    command_undoers["RenameItem"] = function(command)
        local previous_name = command:get_parameter("previous_name")
        if not previous_name or previous_name == "" then
            return true
        end
        local target_type = command:get_parameter("target_type")
        local target_id = command:get_parameter("target_id")
        local project_id = command:get_parameter("project_id") or command.project_id or "default_project"

        local success, err = perform_item_rename(target_type, target_id, previous_name, project_id)
        if not success then
            set_last_error(err or "UndoRenameItem failed")
            return false
        end
        return true
    end

    return {
        executor = command_executors["RenameItem"],
        undoer = command_undoers["RenameItem"]
    }
end

return M
