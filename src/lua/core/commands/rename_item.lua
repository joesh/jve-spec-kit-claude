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
    local function perform_item_rename(command, target_type, target_id, new_name, project_id)
        assert(command, "perform_item_rename: command required for mutation tracking")

        new_name = command_helper.trim_string(new_name)

        if target_type == "master_clip" then
            -- Master clips ARE sequences (IS-a refactor). Load from sequences table.
            local Sequence = require("models.sequence")
            local mc = Sequence.load(target_id)
            if not mc then
                return false, "RenameItem: Master clip not found (id=" .. tostring(target_id) .. ")"
            end
            local previous_name = mc.name or ""
            if previous_name == new_name then
                return true, previous_name
            end
            mc.name = new_name
            if not mc:save() then
                return false, "RenameItem: Failed to save master clip"
            end
            -- Find affected timeline clips and their sequences
            local affected_clips = {}
            local find_stmt = db:prepare([[
                SELECT c.id, t.sequence_id
                FROM clips c
                JOIN tracks t ON c.track_id = t.id
                WHERE c.master_clip_id = ? AND c.clip_kind = 'timeline'
            ]])
            assert(find_stmt, "RenameItem: Failed to prepare affected clips query")
            find_stmt:bind_value(1, mc.id)
            assert(find_stmt:exec(), "RenameItem: Failed to execute affected clips query")
            while find_stmt:next() do
                table.insert(affected_clips, {
                    clip_id = find_stmt:value(0),
                    sequence_id = find_stmt:value(1),
                })
            end
            find_stmt:finalize()
            -- Update DB
            local update_stmt = db:prepare([[
                UPDATE clips
                SET name = ?
                WHERE master_clip_id = ? AND clip_kind = 'timeline'
            ]])
            assert(update_stmt, "RenameItem: Failed to prepare timeline rename")
            update_stmt:bind_value(1, new_name)
            update_stmt:bind_value(2, mc.id)
            assert(update_stmt:exec(), "RenameItem: Failed to update timeline clips")
            update_stmt:finalize()
            -- Produce update mutations for each affected clip
            for _, affected in ipairs(affected_clips) do
                command_helper.add_update_mutation(command, affected.sequence_id, {
                    clip_id = affected.clip_id,
                    name = new_name,
                })
            end
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
            -- Sequence rename doesn't affect clip data — no cache invalidation needed
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
    end

    command_executors["RenameItem"] = function(command)
        local args = command:get_all_parameters()


        local project_id = args.project_id or command.project_id
        local new_name = command_helper.trim_string(args.new_name)

        local success, previous_or_err = perform_item_rename(command, args.target_type, args.target_id, new_name, project_id)
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

        local success, err = perform_item_rename(command, args.target_type, args.target_id, args.previous_name, project_id)
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
