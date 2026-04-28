--- Replace clip name/property via find-and-replace (gsub).
--
-- Responsibilities:
-- - ReplaceClipProperty: single-clip find/replace on clip name or properties table
-- - ReplaceAllClipProperties: batch find/replace across multiple clips
--
-- Non-goals:
-- - Does not handle regex patterns (uses plain string match via gsub)
--
-- Invariants:
-- - previous_value(s) captured during execute for undo safety
-- - column must be "name" or a property_name in the properties table
--
-- @file replace_clip_property.lua
local M = {}
local json = require("dkjson")
local log = require("core.logger").for_area("commands")

local SPEC_REPLACE = {
    undoable = true,
    args = {
        project_id = { required = true },
        clip_id = { required = true },
        column = { required = true },
        find_value = { required = true },
        replace_value = { required = true },
    },
    persisted = {
        previous_value = {},
    },
}

local SPEC_REPLACE_ALL = {
    undoable = true,
    args = {
        project_id = { required = true },
        clip_ids = { required = true },
        column = { required = true },
        find_value = { required = true },
        replace_value = { required = true },
    },
    persisted = {
        previous_values = {},
    },
}

--- Read current value for a clip column.
-- @param db database connection
-- @param clip_id string
-- @param column string: "name" or a property_name
-- @return string|nil current value
local function read_value(db, clip_id, column)
    if column == "name" then
        local stmt = db:prepare("SELECT name FROM clips WHERE id = ?")
        assert(stmt, "ReplaceClipProperty: failed to prepare SELECT name")
        stmt:bind_value(1, clip_id)
        local value
        if stmt:exec() and stmt:next() then
            value = stmt:value(0)
        end
        stmt:finalize()
        return value
    else
        local stmt = db:prepare("SELECT property_value FROM properties WHERE clip_id = ? AND property_name = ?")
        assert(stmt, "ReplaceClipProperty: failed to prepare SELECT property")
        stmt:bind_value(1, clip_id)
        stmt:bind_value(2, column)
        local raw
        if stmt:exec() and stmt:next() then
            raw = stmt:value(0)
        end
        stmt:finalize()
        if raw then
            local decoded, _, err = json.decode(raw)
            if err or decoded == nil then
                return raw
            end
            if type(decoded) == "table" and decoded.value ~= nil then
                return tostring(decoded.value)
            end
            return tostring(decoded)
        end
        return nil
    end
end

--- Write a value to a clip column.
-- @param db database connection
-- @param clip_id string
-- @param column string: "name" or a property_name
-- @param value string
local function write_value(db, clip_id, column, value)
    if column == "name" then
        local stmt = db:prepare("UPDATE clips SET name = ? WHERE id = ?")
        assert(stmt, "ReplaceClipProperty: failed to prepare UPDATE name")
        stmt:bind_value(1, value)
        stmt:bind_value(2, clip_id)
        assert(stmt:exec(), "ReplaceClipProperty: failed to UPDATE clip name")
        stmt:finalize()
    else
        local encoded = json.encode({ value = value })
        assert(encoded, "ReplaceClipProperty: failed to encode property value")
        local stmt = db:prepare("UPDATE properties SET property_value = ? WHERE clip_id = ? AND property_name = ?")
        assert(stmt, "ReplaceClipProperty: failed to prepare UPDATE property")
        stmt:bind_value(1, encoded)
        stmt:bind_value(2, clip_id)
        stmt:bind_value(3, column)
        assert(stmt:exec(), "ReplaceClipProperty: failed to UPDATE property")
        stmt:finalize()
    end
end

function M.register(command_executors, command_undoers, db, _set_last_error)
    local executors = command_executors
    local undoers = command_undoers

    ---------------------------------------------------------------------------
    -- ReplaceClipProperty (single clip)
    ---------------------------------------------------------------------------
    executors["ReplaceClipProperty"] = function(command)
        local args = command:get_all_parameters()
        log.event("ReplaceClipProperty: clip=%s column=%s find=%s replace=%s",
            tostring(args.clip_id), tostring(args.column),
            tostring(args.find_value), tostring(args.replace_value))

        local current = read_value(db, args.clip_id, args.column)
        command:set_parameter("previous_value", current)

        if current then
            local new_value = current:gsub(args.find_value, args.replace_value)
            write_value(db, args.clip_id, args.column, new_value)
        end

        return true
    end

    undoers["ReplaceClipProperty"] = function(command)
        local args = command:get_all_parameters()
        log.event("Undo ReplaceClipProperty: clip=%s column=%s", tostring(args.clip_id), tostring(args.column))

        if args.previous_value ~= nil then
            write_value(db, args.clip_id, args.column, args.previous_value)
        end
        return true
    end

    ---------------------------------------------------------------------------
    -- ReplaceAllClipProperties (batch)
    ---------------------------------------------------------------------------
    executors["ReplaceAllClipProperties"] = function(command)
        local args = command:get_all_parameters()
        log.event("ReplaceAllClipProperties: %d clips column=%s find=%s replace=%s",
            #args.clip_ids, tostring(args.column),
            tostring(args.find_value), tostring(args.replace_value))

        local previous_values = {}
        for _, clip_id in ipairs(args.clip_ids) do
            local current = read_value(db, clip_id, args.column)
            previous_values[#previous_values + 1] = { clip_id = clip_id, old_value = current }

            if current then
                local new_value = current:gsub(args.find_value, args.replace_value)
                write_value(db, clip_id, args.column, new_value)
            end
        end

        command:set_parameter("previous_values", previous_values)
        return true
    end

    undoers["ReplaceAllClipProperties"] = function(command)
        local args = command:get_all_parameters()
        log.event("Undo ReplaceAllClipProperties: %d entries", #args.previous_values)

        for _, entry in ipairs(args.previous_values) do
            if entry.old_value ~= nil then
                write_value(db, entry.clip_id, args.column, entry.old_value)
            end
        end
        return true
    end

    ---------------------------------------------------------------------------
    -- Return registrations (multi-command style B)
    ---------------------------------------------------------------------------
    return {
        ["ReplaceClipProperty"] = {
            executor = executors["ReplaceClipProperty"],
            undoer = undoers["ReplaceClipProperty"],
            spec = SPEC_REPLACE,
        },
        ["ReplaceAllClipProperties"] = {
            executor = executors["ReplaceAllClipProperties"],
            undoer = undoers["ReplaceAllClipProperties"],
            spec = SPEC_REPLACE_ALL,
        },
    }
end

return M
