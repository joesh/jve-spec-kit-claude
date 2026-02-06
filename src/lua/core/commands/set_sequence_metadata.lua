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
-- Size: ~127 LOC
-- Volatility: unknown
--
-- @file set_sequence_metadata.lua
local M = {}
local database = require("core.database")


local SPEC = {
    args = {
        field = { required = true },
        previous_value = {},
        project_id = { required = true },
        sequence_id = { required = true },
        value = {},
    }
}

function M.register(command_executors, command_undoers, db, set_last_error)
    local sequence_metadata_columns = {
        name = {type = "string"},
        frame_rate = {type = "number"},
        width = {type = "number"},
        height = {type = "number"},
        timecode_start_frame = {type = "number"},
        playhead_value = {type = "number"},
        viewport_start_value = {type = "number"},
        viewport_duration_frames_value = {type = "number"},
        mark_in_value = {type = "nullable_number"},
        mark_out_value = {type = "nullable_number"}
    }

    local function normalize_sequence_value(field, value)
        local config = sequence_metadata_columns[field]
        if not config then
            return value
        end

        if config.type == "string" then
            return value ~= nil and tostring(value) or ""
        elseif config.type == "number" then
            return assert(tonumber(value), string.format("SetSequenceMetadata: field %s requires numeric value, got %s", tostring(field), tostring(value)))
        elseif config.type == "nullable_number" then
            if value == nil or value == "" then
                return nil
            end
            return tonumber(value)
        end
        return value
    end

    command_executors["SetSequenceMetadata"] = function(command)
        local args = command:get_all_parameters()




        local column = sequence_metadata_columns[args.field]
        if not column then
            set_last_error("SetSequenceMetadata: Field not allowed: " .. tostring(args.field))
            return false
        end

        local select_stmt = db:prepare("SELECT " .. args.field .. " FROM sequences WHERE id = ?")
        if not select_stmt then
            set_last_error("SetSequenceMetadata: Failed to prepare select statement")
            return false
        end
        select_stmt:bind_value(1, args.sequence_id)
        local previous_value = nil
        if select_stmt:exec() and select_stmt:next() then
            previous_value = select_stmt:value(0)
        end
        select_stmt:finalize()

        local normalized_value = normalize_sequence_value(args.field, args.value)
        command:set_parameters({
            ["previous_value"] = previous_value,
            ["normalized_value"] = normalized_value,
        })
        local update_stmt = db:prepare("UPDATE sequences SET " .. args.field .. " = ? WHERE id = ?")
        if not update_stmt then
            set_last_error("SetSequenceMetadata: Failed to prepare update statement")
            return false
        end

        if normalized_value == nil then
            if update_stmt.bind_null then
                update_stmt:bind_null(1)
            else
                update_stmt:bind_value(1, nil)
            end
        else
            update_stmt:bind_value(1, normalized_value)
        end
        update_stmt:bind_value(2, args.sequence_id)

        local ok = update_stmt:exec()
        update_stmt:finalize()

        if not ok then
            set_last_error("SetSequenceMetadata: Update failed")
            return false
        end

        print(string.format("Set sequence %s args.field %s to %s", args.sequence_id, args.field, tostring(normalized_value)))
        return true
    end

    command_undoers["SetSequenceMetadata"] = function(command)
        local args = command:get_all_parameters()




        local column = sequence_metadata_columns[args.field]
        if not column then
            set_last_error("UndoSetSequenceMetadata: Field not allowed: " .. tostring(args.field))
            return false
        end

        local normalized = normalize_sequence_value(args.field, args.previous_value)
        local stmt = db:prepare("UPDATE sequences SET " .. args.field .. " = ? WHERE id = ?")
        if not stmt then
            set_last_error("UndoSetSequenceMetadata: Failed to prepare update statement")
            return false
        end

        if normalized == nil then
            if stmt.bind_null then
                stmt:bind_null(1)
            else
                stmt:bind_value(1, nil)
            end
        else
            stmt:bind_value(1, normalized)
        end
        stmt:bind_value(2, args.sequence_id)

        local ok = stmt:exec()
        stmt:finalize()

        if not ok then
            set_last_error("UndoSetSequenceMetadata: Update failed")
            return false
        end

        print(string.format("Undo sequence %s args.field %s to %s", args.sequence_id, args.field, tostring(normalized)))
        return true
    end

    return {
        executor = command_executors["SetSequenceMetadata"],
        undoer = command_undoers["SetSequenceMetadata"],
        spec = SPEC,
    }
end

return M
