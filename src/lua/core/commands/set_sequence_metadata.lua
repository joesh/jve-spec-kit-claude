local M = {}
local database = require("core.database")

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
            return tonumber(value) or 0
        elseif config.type == "nullable_number" then
            if value == nil or value == "" then
                return nil
            end
            return tonumber(value)
        end
        return value
    end

    command_executors["SetSequenceMetadata"] = function(command)
        local sequence_id = command:get_parameter("sequence_id")
        local field = command:get_parameter("field")
        local new_value = command:get_parameter("value")

        if not sequence_id or sequence_id == "" or not field or field == "" then
            set_last_error("SetSequenceMetadata: Missing required parameters")
            return false
        end

        local column = sequence_metadata_columns[field]
        if not column then
            set_last_error("SetSequenceMetadata: Field not allowed: " .. tostring(field))
            return false
        end

        local select_stmt = db:prepare("SELECT " .. field .. " FROM sequences WHERE id = ?")
        if not select_stmt then
            set_last_error("SetSequenceMetadata: Failed to prepare select statement")
            return false
        end
        select_stmt:bind_value(1, sequence_id)
        local previous_value = nil
        if select_stmt:exec() and select_stmt:next() then
            previous_value = select_stmt:value(0)
        end
        select_stmt:finalize()

        local normalized_value = normalize_sequence_value(field, new_value)
        command:set_parameter("previous_value", previous_value)
        command:set_parameter("normalized_value", normalized_value)

        local update_stmt = db:prepare("UPDATE sequences SET " .. field .. " = ? WHERE id = ?")
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
        update_stmt:bind_value(2, sequence_id)

        local ok = update_stmt:exec()
        update_stmt:finalize()

        if not ok then
            set_last_error("SetSequenceMetadata: Update failed")
            return false
        end

        print(string.format("Set sequence %s field %s to %s", sequence_id, field, tostring(normalized_value)))
        return true
    end

    command_undoers["SetSequenceMetadata"] = function(command)
        local sequence_id = command:get_parameter("sequence_id")
        local field = command:get_parameter("field")
        local previous_value = command:get_parameter("previous_value")

        if not sequence_id or sequence_id == "" or not field or field == "" then
            set_last_error("UndoSetSequenceMetadata: Missing parameters")
            return false
        end

        local column = sequence_metadata_columns[field]
        if not column then
            set_last_error("UndoSetSequenceMetadata: Field not allowed: " .. tostring(field))
            return false
        end

        local normalized = normalize_sequence_value(field, previous_value)
        local stmt = db:prepare("UPDATE sequences SET " .. field .. " = ? WHERE id = ?")
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
        stmt:bind_value(2, sequence_id)

        local ok = stmt:exec()
        stmt:finalize()

        if not ok then
            set_last_error("UndoSetSequenceMetadata: Update failed")
            return false
        end

        print(string.format("Undo sequence %s field %s to %s", sequence_id, field, tostring(normalized)))
        return true
    end

    return {
        executor = command_executors["SetSequenceMetadata"],
        undoer = command_undoers["SetSequenceMetadata"]
    }
end

return M
