local M = {}
local json = require("dkjson")
local uuid = require("uuid")
local Clip = require("models.clip")
local command_helper = require("core.command_helper")

function M.register(command_executors, command_undoers, db, set_last_error)
    command_executors["SetClipProperty"] = function(command)
        print("Executing SetClipProperty command")

        local clip_id = command:get_parameter("clip_id")
        local property_name = command:get_parameter("property_name")
        local new_value = command:get_parameter("value")
        local property_type = command:get_parameter("property_type")
        local default_value_param = command:get_parameter("default_value")

        if not clip_id or clip_id == "" or not property_name or property_name == "" then
            local message = "SetClipProperty: Missing required parameters"
            set_last_error(message)
            print("WARNING: " .. message)
            return false
        end

        if not property_type or property_type == "" then
            local message = "SetClipProperty: Missing property_type parameter"
            set_last_error(message)
            print("WARNING: " .. message)
            return false
        end

        local clip = Clip.load_optional(clip_id, db)
        if not clip or clip.id == "" then
            local executed_with_clip = command:get_parameter("executed_with_clip")
            if executed_with_clip then
                print(string.format("INFO: SetClipProperty: Clip %s missing during replay; property update skipped", clip_id))
                return true
            end

            if command:get_parameter("previous_value") ~= nil then
                print(string.format("INFO: SetClipProperty: Clip %s missing but previous_value present; assuming clip deleted and skipping", clip_id))
                return true
            end

            print(string.format("WARNING: SetClipProperty: Clip not found during replay: %s; skipping property update", clip_id))
            return true
        end

        local select_stmt = db:prepare("SELECT id, property_value, property_type, default_value FROM properties WHERE clip_id = ? AND property_name = ?")
        if not select_stmt then
            local message = "SetClipProperty: Failed to prepare property lookup query"
            set_last_error(message)
            print("WARNING: " .. message)
            return false
        end
        select_stmt:bind_value(1, clip_id)
        select_stmt:bind_value(2, property_name)

        local property_id = nil
        local previous_value = nil
        local previous_type = nil
        local previous_default = nil
        local existing_property = false

        local function decode_property(raw)
            if not raw or raw == "" then
                return nil
            end
            local decoded, _, err = json.decode(raw)
            if err or decoded == nil then
                return raw
            end
            if type(decoded) == "table" and decoded.value ~= nil then
                return decoded.value
            end
            return decoded
        end

        if select_stmt:exec() and select_stmt:next() then
            existing_property = true
            property_id = select_stmt:value(0)
            previous_value = decode_property(select_stmt:value(1))
            previous_type = select_stmt:value(2)
            previous_default = select_stmt:value(3)
        else
            property_id = uuid.generate()
        end
        select_stmt:finalize()

        local encoded_value, encode_err = json.encode({ value = new_value })
        if not encoded_value then
            local message = "SetClipProperty: Failed to encode property value: " .. tostring(encode_err)
            set_last_error(message)
            print("WARNING: " .. message)
            return false
        end

        local default_json = nil
        do
            local encoded_default, default_err = json.encode({ value = default_value_param })
            if not encoded_default then
                local message = "SetClipProperty: Failed to encode default value: " .. tostring(default_err)
                set_last_error(message)
                print("WARNING: " .. message)
                return false
            end
            default_json = encoded_default
        end

        command:set_parameter("previous_value", previous_value)
        command:set_parameter("previous_type", previous_type)
        command:set_parameter("previous_default", previous_default)
        command:set_parameter("property_id", property_id)
        command:set_parameter("created_new", not existing_property)
        command:set_parameter("executed_with_clip", true)

        if existing_property then
            local update_sql
            if default_json ~= nil then
                update_sql = "UPDATE properties SET property_value = ?, property_type = ?, default_value = ? WHERE id = ?"
            else
                update_sql = "UPDATE properties SET property_value = ?, property_type = ? WHERE id = ?"
            end
            local update_stmt = db:prepare(update_sql)
            if not update_stmt then
                local message = "SetClipProperty: Failed to prepare property update"
                set_last_error(message)
                print("WARNING: " .. message)
                return false
            end
            update_stmt:bind_value(1, encoded_value)
            update_stmt:bind_value(2, property_type)
            if default_json ~= nil then
                update_stmt:bind_value(3, default_json)
                update_stmt:bind_value(4, property_id)
            else
                update_stmt:bind_value(3, property_id)
            end
            if not update_stmt:exec() then
                local err = "unknown"
                if update_stmt.last_error then
                    local ok, msg = pcall(update_stmt.last_error, update_stmt)
                    if ok and msg and msg ~= "" then
                        err = msg
                    end
                end
                local message = "SetClipProperty: Failed to update property row: " .. tostring(err)
                set_last_error(message)
                print("WARNING: " .. message)
                return false
            end
            update_stmt:finalize()
        else
            local insert_stmt = db:prepare("INSERT INTO properties (id, clip_id, property_name, property_value, property_type, default_value) VALUES (?, ?, ?, ?, ?, ?)")
            if not insert_stmt then
                local message = "SetClipProperty: Failed to prepare property insert"
                set_last_error(message)
                print("WARNING: " .. message)
                return false
            end
            insert_stmt:bind_value(1, property_id)
            insert_stmt:bind_value(2, clip_id)
            insert_stmt:bind_value(3, property_name)
            insert_stmt:bind_value(4, encoded_value)
            insert_stmt:bind_value(5, property_type)
            insert_stmt:bind_value(6, default_json or json.encode({ value = nil }))
            if not insert_stmt:exec() then
                local err = "unknown"
                if insert_stmt.last_error then
                    local ok, msg = pcall(insert_stmt.last_error, insert_stmt)
                    if ok and msg and msg ~= "" then
                        err = msg
                    end
                end
                local message = "SetClipProperty: Failed to insert property row: " .. tostring(err)
                set_last_error(message)
                print("WARNING: " .. message)
                return false
            end
            insert_stmt:finalize()
        end

        clip:set_property(property_name, new_value)

        if clip:save(db) then
            print(string.format("Set clip property %s to %s for clip %s", property_name, tostring(new_value), clip_id))
            return true
        else
            local message = "Failed to save clip property change"
            set_last_error(message)
            print("WARNING: " .. message)
            return false
        end
    end

    command_undoers["SetClipProperty"] = function(command)
        print("Undoing SetClipProperty command")

        local clip_id = command:get_parameter("clip_id")
        local property_name = command:get_parameter("property_name")
        local property_id = command:get_parameter("property_id")
        local previous_value = command:get_parameter("previous_value")
        local previous_type = command:get_parameter("previous_type")
        local previous_default = command:get_parameter("previous_default")
        local created_new = command:get_parameter("created_new") and true or false

        if not property_id or property_id == "" then
            local message = "Undo SetClipProperty: Missing property_id parameter"
            set_last_error(message)
            print("WARNING: " .. message)
            return false
        end

        if created_new then
            local delete_stmt = db:prepare("DELETE FROM properties WHERE id = ?")
            if not delete_stmt then
                local message = "Undo SetClipProperty: Failed to prepare delete statement"
                set_last_error(message)
                print("WARNING: " .. message)
                return false
            end
            delete_stmt:bind_value(1, property_id)
            if not delete_stmt:exec() then
                local message = "Undo SetClipProperty: Failed to delete newly created property row"
                set_last_error(message)
                print("WARNING: " .. message)
                return false
            end
            delete_stmt:finalize()
        else
            if not previous_type or previous_type == "" then
                local message = "Undo SetClipProperty: Missing previous_type for existing property restore"
                set_last_error(message)
                print("WARNING: " .. message)
                return false
            end
            local encoded_prev, encode_err = json.encode({ value = previous_value })
            if not encoded_prev then
                local message = "Undo SetClipProperty: Failed to encode previous property value: " .. tostring(encode_err)
                set_last_error(message)
                print("WARNING: " .. message)
                return false
            end
            local update_sql
            if previous_default ~= nil then
                update_sql = "UPDATE properties SET property_value = ?, property_type = ?, default_value = ? WHERE id = ?"
            else
                update_sql = "UPDATE properties SET property_value = ?, property_type = ? WHERE id = ?"
            end
            local update_stmt = db:prepare(update_sql)
            if not update_stmt then
                local message = "Undo SetClipProperty: Failed to prepare update statement"
                set_last_error(message)
                print("WARNING: " .. message)
                return false
            end
            update_stmt:bind_value(1, encoded_prev)
            update_stmt:bind_value(2, previous_type)
            if previous_default ~= nil then
                update_stmt:bind_value(3, previous_default)
                update_stmt:bind_value(4, property_id)
            else
                update_stmt:bind_value(3, property_id)
            end
            if not update_stmt:exec() then
                local message = "Undo SetClipProperty: Failed to restore property row"
                set_last_error(message)
                print("WARNING: " .. message)
                return false
            end
            update_stmt:finalize()
        end

        local clip = Clip.load_optional(clip_id, db)
        if clip then
            clip:set_property(property_name, previous_value)
            clip:save(db)
        end

        return true
    end

    return {
        executor = command_executors["SetClipProperty"],
        undoer = command_undoers["SetClipProperty"]
    }
end

return M
