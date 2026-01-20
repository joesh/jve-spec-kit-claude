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
-- Size: ~30 LOC
-- Volatility: unknown
--
-- @file set_property.lua
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
    command_executors["SetProperty"] = function(command)
        local args = command:get_all_parameters()
        print("Executing SetProperty command")






        local property = Property.create(args.property_name, args.entity_id)

        -- Store previous value for undo
        local previous_value = property.value
        command:set_parameter("previous_value", previous_value)

        -- Set new value
        property:set_value(args.value)

        if property:save(db) then
            print(string.format("Set property %s to %s for %s %s", args.property_name, tostring(args.value), args.entity_type, args.entity_id))
            return true
        else
            set_last_error("Failed to save property change")
            return false
        end
    end

    -- No explicit undo defined in original source, likely relies on generic property restore logic or not fully implemented.
    -- Assuming symmetry if needed later.

    return {
        executor = command_executors["SetProperty"],
        spec = SPEC,
    }
end

return M
