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

function M.register(command_executors, command_undoers, db, set_last_error)
    command_executors["SetProperty"] = function(command)
        print("Executing SetProperty command")

        local entity_id = command:get_parameter("entity_id")
        local entity_type = command:get_parameter("entity_type")
        local property_name = command:get_parameter("property_name")
        local new_value = command:get_parameter("value")

        if not entity_id or entity_id == "" or not entity_type or entity_type == "" or not property_name or property_name == "" then
            print("WARNING: SetProperty: Missing required parameters")
            return false
        end

        local property = Property.create(property_name, entity_id)

        -- Store previous value for undo
        local previous_value = property.value
        command:set_parameter("previous_value", previous_value)

        -- Set new value
        property:set_value(new_value)

        if property:save(db) then
            print(string.format("Set property %s to %s for %s %s", property_name, tostring(new_value), entity_type, entity_id))
            return true
        else
            print("WARNING: Failed to save property change")
            return false
        end
    end

    -- No explicit undo defined in original source, likely relies on generic property restore logic or not fully implemented.
    -- Assuming symmetry if needed later.

    return {
        executor = command_executors["SetProperty"]
    }
end

return M
