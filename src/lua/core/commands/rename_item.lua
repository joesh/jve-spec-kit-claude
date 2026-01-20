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
-- Size: ~126 LOC
-- Volatility: unknown
--
-- @file rename_item.lua
local M = {}
local command_helper = require("core.command_helper")


local SPEC = {
    args = {
        new_name = { required = true, kind = "string" },
        previous_name = { required = true, kind = "string" },
        project_id = { required = true, kind = "string" },
        target_id = { required = true, kind = "string" },
        target_type = { required = true, kind = "string" },
    }
}
function M.register(command_executors, command_undoers, db, set_last_error)
    local function perform_item_rename(target_type, target_id, new_name, project_id)

        new_name = command_helper.trim_string(new_name)

        if target_type == "master_clip" then
            local Clip = require("models.clip")
            local clip = Clip.load_optional(target_id)
            if not clip then
                return false, "RenameItem: Master clip not found"
            end
            local previous_name = clip.name or ""
            if previous_name == new_name then
                return true, previous_name
            end
            clip.name = new_name
            if not clip:save({skip_occlusion = true}) then
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
            local sequence = Sequence.load(target_id)
            if not sequence then
                return false, "RenameItem: Sequence not found"
            end
            local previous_name = sequence.name or ""
            if previous_name == new_name then
                return true, previous_name
            end
            sequence.name = new_name
            if not sequence:save() then
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
        local args = command:get_all_parameters()


        local project_id = args.project_id or command.project_id
        local new_name = command_helper.trim_string(args.new_name)

        local success, previous_or_err = perform_item_rename(args.target_type, args.target_id, new_name, project_id)
        if not success then
            set_last_error(previous_or_err or "RenameItem failed")
            return false
        end

        command:set_parameters({
            ["args.target_type"] = args.target_type,
            ["args.target_id"] = args.target_id,
            ["project_id"] = project_id,
            ["previous_name"] = previous_or_err or "",
            ["final_name"] = new_name,
        })
        return true
    end

    command_undoers["RenameItem"] = function(command)
        local args = command:get_all_parameters()


        local project_id = args.project_id or command.project_id

        local success, err = perform_item_rename(args.target_type, args.target_id, args.previous_name, project_id)
        if not success then
            set_last_error(err or "UndoRenameItem failed")
            return false
        end
        return true
    end

    return {
        executor = command_executors["RenameItem"],
        undoer = command_undoers["RenameItem"],
        spec = SPEC,
    }
end

return M
