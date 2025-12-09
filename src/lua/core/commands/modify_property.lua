local M = {}
local Property = require('models.property')

function M.register(command_executors, command_undoers, db, set_last_error)
    command_executors["ModifyProperty"] = function(command)
        print("Executing ModifyProperty command")

        local entity_id = command:get_parameter("entity_id")
        local entity_type = command:get_parameter("entity_type")
        local property_name = command:get_parameter("property_name")
        local new_value = command:get_parameter("value")

        if not entity_id or entity_id == "" or not entity_type or entity_type == "" or not property_name or property_name == "" then
            print("WARNING: ModifyProperty: Missing required parameters")
            return false
        end

        local property = Property.load(entity_id, db)
        if not property or property.id == "" then
            print("WARNING: ModifyProperty: Property not found")
            return false
        end

        -- Store previous value for undo
        local previous_value = property.value
        command:set_parameter("previous_value", previous_value)

        -- Set new value
        property:set_value(new_value)

        if property:save(db) then
            print(string.format("Modified property %s to %s for %s %s", property_name, tostring(new_value), entity_type, entity_id))
            return true
        else
            print("WARNING: Failed to save property modification")
            return false
        end
    end

    return {
        executor = command_executors["ModifyProperty"]
    }
end

return M
