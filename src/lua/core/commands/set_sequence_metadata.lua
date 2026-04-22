--- SetSequenceMetadata: update a single column on the sequences row
--- with undo/redo. Operates on a fixed whitelist of columns — the
--- column name is interpolated into SQL, so only known-safe names
--- reach string.format. Inspector-entered TIMECODE values are integer
--- frames; rate stays on the sequence model and is not duplicated
--- into the payload (012 Inspector rewrite resolution).
---
--- @file set_sequence_metadata.lua
local M = {}
local log = require("core.logger").for_area("commands")


local SPEC = {
    mutates_clips = false,  -- writes a single sequences row field; no clip mutations
    args = {
        field = { required = true },
        previous_value = {},
        project_id = { required = true },
        sequence_id = { required = true },
        value = {},
    }
}

function M.register(command_executors, command_undoers, db, set_last_error)
    -- Keys here MUST match actual columns in the `sequences` table (schema.sql).
    -- field is injected directly into SQL (table-scanned from this whitelist
    -- only), so names must be the real column names. Prior bug: keys like
    -- `timecode_start_frame`, `playhead_value`, `mark_in_value` didn't match
    -- DDL columns (`start_timecode_frame`, `playhead_frame`, `mark_in_frame`)
    -- so every write failed with "Failed to prepare select statement".
    -- See tests/test_set_sequence_metadata_columns.lua for the drift check.
    local sequence_metadata_columns = {
        name                    = {type = "string"},
        width                   = {type = "number"},
        height                  = {type = "number"},
        audio_rate              = {type = "number"},
        start_timecode_frame    = {type = "number"},
        playhead_frame          = {type = "number"},
        view_start_frame        = {type = "number"},
        view_duration_frames    = {type = "number"},
        mark_in_frame           = {type = "nullable_number"},
        mark_out_frame          = {type = "nullable_number"},
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

        log.event("SetSequenceMetadata: %s.%s = %s",
            args.sequence_id, args.field, tostring(normalized_value))
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

        log.event("UndoSetSequenceMetadata: %s.%s = %s",
            args.sequence_id, args.field, tostring(normalized))
        return true
    end

    return {
        executor = command_executors["SetSequenceMetadata"],
        undoer = command_undoers["SetSequenceMetadata"],
        spec = SPEC,
    }
end

return M
