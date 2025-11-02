-- Command module: Lua representation of commands for the command system
-- Provides command creation, parameter management, and serialization

local uuid = require("uuid")

local M = {}

-- Create a new Command
function M.create(command_type, project_id)
    local command = {
        id = uuid.generate(),
        type = command_type,
        project_id = project_id,
        sequence_number = 0,
        status = "Created",
        created_at = os.time(),
        executed_at = nil,
        parameters = {},
        pre_hash = "",
        post_hash = "",
    }

    setmetatable(command, {__index = M})
    return command
end

-- Parse command from database query result
function M.parse_from_query(query, project_id)
    if not query then
        return nil
    end

    -- Assuming query result has these columns:
    -- id, type, project_id, sequence_number, status, parameters, pre_hash, post_hash, created_at, executed_at
    local command = {
        id = query:value(0),
        type = query:value(1),
        project_id = query:value(2) or project_id,
        sequence_number = query:value(3) or 0,
        status = query:value(4) or "Created",
        parameters = {},  -- TODO: Parse JSON parameters from query:value(5)
        pre_hash = query:value(6) or "",
        post_hash = query:value(7) or "",
        created_at = query:value(8) or os.time(),
        executed_at = query:value(9),
    }

    setmetatable(command, {__index = M})
    return command
end

-- Set a parameter
function M:set_parameter(key, value)
    self.parameters[key] = value
end

-- Get a parameter
function M:get_parameter(key)
    return self.parameters[key]
end

-- Get all parameters
function M:get_all_parameters()
    return self.parameters
end

-- Serialize command to JSON string
function M:serialize()
    -- Simple serialization (would use proper JSON library in production)
    local parts = {
        string.format('"id":"%s"', self.id),
        string.format('"type":"%s"', self.type),
        string.format('"project_id":"%s"', self.project_id),
        string.format('"sequence_number":%d', self.sequence_number),
        string.format('"status":"%s"', self.status),
    }

    return "{" .. table.concat(parts, ",") .. "}"
end

-- Create undo command
function M:create_undo()
    local undo_command = M.create("Undo" .. self.type, self.project_id)

    -- Copy relevant parameters for undo
    for k, v in pairs(self.parameters) do
        undo_command:set_parameter(k, v)
    end

    return undo_command
end

-- Save command to database
function M:save(db)
    if not db then
        print("WARNING: Command.save: No database provided")
        return false
    end

    -- Serialize parameters to JSON
    local params_json = "{}"
    if self.parameters and next(self.parameters) ~= nil then
        local success, json_str = pcall(qt_json_encode, self.parameters)
        if success then
            params_json = json_str
        else
            print("WARNING: Command.save: Failed to encode parameters: " .. tostring(json_str))
        end
    end

    -- Check if command exists
    local exists_query = db:prepare("SELECT COUNT(*) FROM commands WHERE id = ?")
    if not exists_query then
        local err = "unknown error"
        if db.last_error then
            err = db:last_error()
        end
        print("WARNING: Command.save: Failed to prepare exists query: " .. err)
        return false
    end

    exists_query:bind_value(1, self.id)

    local exists = false
    if exists_query:exec() and exists_query:next() then
        exists = exists_query:value(0) > 0
    end

    local selected_clip_ids_json = self.selected_clip_ids or "[]"
    local selected_edge_infos_json = self.selected_edge_infos or "[]"
    local selected_gap_infos_json = self.selected_gap_infos or "[]"
    local selected_clip_ids_pre_json = self.selected_clip_ids_pre or "[]"
    local selected_edge_infos_pre_json = self.selected_edge_infos_pre or "[]"
    local selected_gap_infos_pre_json = self.selected_gap_infos_pre or "[]"

    local query
    if exists then
        -- UPDATE
        query = db:prepare([[
            UPDATE commands
            SET command_type = ?, sequence_number = ?, command_args = ?,
                pre_hash = ?, post_hash = ?, timestamp = ?, playhead_time = ?,
                selected_clip_ids = ?, selected_edge_infos = ?, selected_gap_infos = ?,
                selected_clip_ids_pre = ?, selected_edge_infos_pre = ?, selected_gap_infos_pre = ?
            WHERE id = ?
        ]])
        if not query then
            local err = "unknown error"
            if db.last_error then
                err = db:last_error()
            end
            print("WARNING: Command.save: Failed to prepare UPDATE query: " .. err)
            return false
        end

        query:bind_value(1, self.type)
        query:bind_value(2, self.sequence_number)
        query:bind_value(3, params_json)
        query:bind_value(4, self.pre_hash)
        query:bind_value(5, self.post_hash)
        query:bind_value(6, self.executed_at or os.time())
        query:bind_value(7, self.playhead_time or 0)
        query:bind_value(8, selected_clip_ids_json)
        query:bind_value(9, selected_edge_infos_json)
        query:bind_value(10, selected_gap_infos_json)
        query:bind_value(11, selected_clip_ids_pre_json)
        query:bind_value(12, selected_edge_infos_pre_json)
        query:bind_value(13, selected_gap_infos_pre_json)
        query:bind_value(14, self.id)
    else
        -- INSERT
        query = db:prepare([[
            INSERT INTO commands (id, parent_id, parent_sequence_number, sequence_number, command_type, command_args, pre_hash, post_hash, timestamp, playhead_time, selected_clip_ids, selected_edge_infos, selected_gap_infos, selected_clip_ids_pre, selected_edge_infos_pre, selected_gap_infos_pre)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ]])
        if not query then
            local err = "unknown error"
            if db.last_error then
                err = db:last_error()
            end
            print("WARNING: Command.save: Failed to prepare INSERT query: " .. err)
            return false
        end

        query:bind_value(1, self.id)
        query:bind_value(2, nil)  -- parent_id (for batching, not used yet)
        query:bind_value(3, self.parent_sequence_number)  -- For undo tree
        query:bind_value(4, self.sequence_number)
        query:bind_value(5, self.type)
        query:bind_value(6, params_json)
        query:bind_value(7, self.pre_hash)
        query:bind_value(8, self.post_hash)
        query:bind_value(9, self.executed_at or os.time())
        query:bind_value(10, self.playhead_time or 0)
        query:bind_value(11, selected_clip_ids_json)
        query:bind_value(12, selected_edge_infos_json)
        query:bind_value(13, selected_gap_infos_json)
        query:bind_value(14, selected_clip_ids_pre_json)
        query:bind_value(15, selected_edge_infos_pre_json)
        query:bind_value(16, selected_gap_infos_pre_json)
    end

    if not query:exec() then
        print(string.format("WARNING: Command.save: Failed to save command: %s", query:last_error()))
        return false
    end

    return true
end

return M
