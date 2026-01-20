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
-- Size: ~34 LOC
-- Volatility: unknown
--
-- @file modify_property.lua
local M = {}
local Property = require('models.property')


local SPEC = {
    args = {
        entity_id = { required = true },
        entity_type = {required = true},
        project_id = { required = true },
        property_name = {required = true},
        value = {},
    },
    persisted = {
        previous_value = {},
    },
}


function M.register(command_executors, command_undoers, db, set_last_error)
    command_executors["ModifyProperty"] = function(command)
        local args = command:get_all_parameters()
        print("Executing ModifyProperty command")






        local property = Property.load(args.entity_id, db)
        if not property or property.id == "" then
            set_last_error("ModifyProperty: Property not found")
            return false
        end

        -- Store previous value for undo
        local previous_value = property.value
        command:set_parameter("previous_value", previous_value)

        -- Set new value
        property:set_value(args.value)

        if property:save(db) then
            print(string.format("Modified property %s to %s for %s %s", args.property_name, tostring(args.value), args.entity_type, args.entity_id))
            return true
        else
            set_last_error("Failed to save property modification")
            return false
        end
    end

    return {
        executor = command_executors["ModifyProperty"],
        spec = SPEC,
    }
end

return M
