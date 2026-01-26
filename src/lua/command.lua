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
-- Size: ~333 LOC
-- Volatility: unknown
--
-- @file command.lua
-- Original intent (unreviewed):
-- Command module: Lua representation of commands for the command system
-- Provides command creation, parameter management, and serialization
local uuid = require("uuid")
local json = require("dkjson") -- Added
local logger = require("core.logger")
local command_labels = require("core.command_labels")

local M = {}

local function is_ephemeral_parameter_key(key)
    return type(key) == "string" and key:sub(1, 2) == "__"
end

-- Create a new Command
function M.create(command_type, project_id, params)
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
    if params then
        command:set_parameters(params)
    end

    return command
end

-- Parse command from database query result
function M.parse_from_query(query, project_id)
    if not query then
        return nil
    end

    local column_count = 0
    if query.record then
        local rec = query:record()
        if rec and rec.count then
            column_count = rec:count()
        end
    end
    local command = nil

    -- Two supported layouts:
    -- 1) SELECT * FROM commands (schema order)
    -- 2) Explicit column list from command_manager.get_command_at_sequence
    if column_count >= 17 then
        local args_json = query:value(4)
        local args_table = {}
        if args_json and args_json ~= "" then
            local ok, decoded = pcall(json.decode, args_json)
            if ok and type(decoded) == "table" then
                args_table = decoded
            end
        end

        command = {
            id = query:value(0),
            parent_id = query:value(1),
            sequence_number = query:value(2) or 0,
            type = query:value(3),
            parameters = args_table,
            parent_sequence_number = query:value(5),
            pre_hash = query:value(6) or "",
            post_hash = query:value(7) or "",
            created_at = query:value(8) or os.time(),
            executed_at = query:value(8),
            playhead_value = query:value(9),
            playhead_rate = query:value(10),
            selected_clip_ids = query:value(11),
            selected_edge_infos = query:value(12),
            selected_gap_infos = query:value(13),
            selected_clip_ids_pre = query:value(14),
            selected_edge_infos_pre = query:value(15),
            selected_gap_infos_pre = query:value(16),
            status = query:value(17) or "Created"
        }
        command.project_id = project_id or args_table.project_id
    else
        local args_json = query:value(2)
        local args_table = {}
        if args_json and args_json ~= "" then
            local ok, decoded = pcall(json.decode, args_json)
            if ok and type(decoded) == "table" then
                args_table = decoded
            end
        end

        command = {
            id = query:value(0),
            type = query:value(1),
            parameters = args_table,
            sequence_number = query:value(3) or 0,
            parent_sequence_number = query:value(4),
            pre_hash = query:value(5) or "",
            post_hash = query:value(6) or "",
            created_at = query:value(7) or os.time(),
            executed_at = query:value(7),
            playhead_value = query:value(8),
            playhead_rate = query:value(9),
            selected_clip_ids = query:value(10),
            selected_edge_infos = query:value(11),
            selected_gap_infos = query:value(12),
            selected_clip_ids_pre = query:value(13),
            selected_edge_infos_pre = query:value(14),
            selected_gap_infos_pre = query:value(15),
            status = query:value(16) or "Created"
        }
        command.project_id = project_id or args_table.project_id
    end

    setmetatable(command, {__index = M})
    return command
end

-- Load command history for edit history display.
-- Returns list of Command objects that can compute their own labels.
function M.load_history()
    local database = require("core.database")
    local db = database.get_connection()
    if not db then
        return {}
    end

    local query = db:prepare([[
        SELECT * FROM commands
        WHERE command_type NOT LIKE 'Undo%'
        ORDER BY sequence_number ASC
    ]])
    if not query then
        return {}
    end

    local commands = {}
    if query:exec() then
        while query:next() do
            local cmd = M.parse_from_query(query, nil)
            if cmd then
                table.insert(commands, cmd)
            end
        end
    end
    query:finalize()

    return commands
end

-- Load command at specific sequence number
function M.load_at_sequence(seq_num, project_id)
    local database = require("core.database")
    local db = database.get_connection()
    if not db or not seq_num then
        return nil
    end

    local query = db:prepare([[
        SELECT id, command_type, command_args, sequence_number, parent_sequence_number,
               pre_hash, post_hash, timestamp, playhead_value, playhead_rate,
               selected_clip_ids, selected_edge_infos, selected_gap_infos,
               selected_clip_ids_pre, selected_edge_infos_pre, selected_gap_infos_pre,
               undo_group_id, playhead_value_post, playhead_rate_post
        FROM commands
        WHERE sequence_number = ? AND command_type NOT LIKE 'Undo%'
    ]])
    if not query then
        return nil
    end

    query:bind_value(1, seq_num)
    if not query:exec() or not query:next() then
        query:finalize()
        return nil
    end

    -- Build command directly (explicit column order, not parse_from_query)
    local command_args_json = query:value(2)
    local params = {}
    if command_args_json and command_args_json ~= "" and command_args_json ~= "{}" then
        local success, decoded = pcall(json.decode, command_args_json)
        if success and decoded then
            params = decoded
        end
    end

    local command = {
        id = query:value(0),
        type = query:value(1),
        project_id = project_id,
        sequence_number = query:value(3) or 0,
        parent_sequence_number = query:value(4),
        status = "Executed",
        parameters = params,
        pre_hash = query:value(5) or "",
        post_hash = query:value(6) or "",
        created_at = query:value(7) or os.time(),
        executed_at = query:value(7),
        playhead_value = query:value(8),
        playhead_rate = query:value(9),
        selected_clip_ids = query:value(10) or "[]",
        selected_edge_infos = query:value(11) or "[]",
        selected_gap_infos = query:value(12) or "[]",
        selected_clip_ids_pre = query:value(13) or "[]",
        selected_edge_infos_pre = query:value(14) or "[]",
        selected_gap_infos_pre = query:value(15) or "[]",
        undo_group_id = query:value(16),
        playhead_value_post = query:value(17),
        playhead_rate_post = query:value(18)
    }

    setmetatable(command, {__index = M})
    query:finalize()
    return command
end

-- Load commands from sequence number onwards (for replay)
function M.load_from_sequence(start_seq, project_id)
    local database = require("core.database")
    local db = database.get_connection()
    if not db then
        return {}
    end

    local query = db:prepare("SELECT * FROM commands WHERE sequence_number >= ? ORDER BY sequence_number")
    if not query then
        return {}
    end

    query:bind_value(1, start_seq)
    local commands = {}
    if query:exec() then
        while query:next() do
            local cmd = M.parse_from_query(query, project_id)
            if cmd then
                table.insert(commands, cmd)
            end
        end
    end
    query:finalize()
    return commands
end

-- Mark commands after sequence number as undone
function M.mark_undone_after(seq_num)
    local database = require("core.database")
    local db = database.get_connection()
    if not db then
        return false
    end

    local query = db:prepare("UPDATE commands SET status = 'Undone' WHERE sequence_number > ?")
    if not query then
        return false
    end

    query:bind_value(1, seq_num)
    local ok = query:exec()
    query:finalize()
    return ok
end

-- Load parent tree structure (for history branching)
-- Returns table mapping sequence_number -> parent_sequence_number
function M.load_parent_tree()
    local database = require("core.database")
    local db = database.get_connection()
    if not db then
        return {}, {}
    end

    local query = db:prepare([[
        SELECT sequence_number, parent_sequence_number
        FROM commands
        WHERE command_type NOT LIKE 'Undo%'
    ]])
    if not query then
        return {}, {}
    end

    local parent_of = {}
    local exists = {}
    if query:exec() then
        while query:next() do
            local seq = query:value(0) or 0
            local parent = query:value(1) or 0
            parent_of[seq] = parent
            exists[seq] = true
        end
    end
    query:finalize()
    return parent_of, exists
end

-- Deserialize a command from a JSON string
function M.deserialize(json_string)
    if not json_string or json_string == "" then
        return nil, "JSON string is empty"
    end
    local success, data = pcall(json.decode, json_string)
    if not success then
        return nil, "Failed to decode JSON: " .. tostring(data)
    end

    if not data or type(data) ~= "table" then
        return nil, "Decoded JSON is not a table"
    end

    local command = M.create(data.type, data.project_id)
    command.id = data.id or command.id
    command.sequence_number = data.sequence_number or 0
    command.status = data.status or "Created"
    command.parameters = data.parameters or {}
    command.pre_hash = data.pre_hash or ""
    command.post_hash = data.post_hash or ""
    command.created_at = data.created_at or os.time()
    command.executed_at = data.executed_at
    command.playhead_value = data.playhead_value
    command.playhead_rate = data.playhead_rate
    command.selected_clip_ids = data.selected_clip_ids
    command.selected_edge_infos = data.selected_edge_infos
    command.selected_gap_infos = data.selected_gap_infos
    command.selected_clip_ids_pre = data.selected_clip_ids_pre
    command.selected_edge_infos_pre = data.selected_edge_infos_pre
    command.selected_gap_infos_pre = data.selected_gap_infos_pre

    setmetatable(command, {__index = M})
    return command
end

-- Set a parameter
function M:set_parameter(key, value)
    self.parameters[key] = value
end

-- Set multiple parameters
function M:set_parameters(params)
    if not params then return end
    for key, value in pairs(params) do
        self.parameters[key] = value
    end
end

-- Get a parameter
function M:get_parameter(key)
    return self.parameters[key]
end

function M:clear_parameter(key)
    self.parameters[key] = nil
end

-- Get all parameters
function M:get_all_parameters()
    return self.parameters
end

-- Parameters intended for persistence/logging.
-- Convention: keys beginning with "__" are ephemeral execution context only.
function M:get_persistable_parameters()
    local persistable = {}
    for key, value in pairs(self.parameters or {}) do
        if not is_ephemeral_parameter_key(key) then
            persistable[key] = value
        end
    end
    return persistable
end

-- Return human-readable label for this command.
-- Commands can override by setting display_label parameter.
function M:label()
    local custom = self.parameters and self.parameters.display_label
    if custom and custom ~= "" then
        return custom
    end
    return command_labels.label_for_type(self.type)
end

-- Serialize command to JSON string
function M:serialize()
    local playhead_rate_val = 0
    if type(self.playhead_rate) == "number" then
        playhead_rate_val = self.playhead_rate
    elseif type(self.playhead_rate) == "table" and self.playhead_rate.fps_numerator then
        if not self.playhead_rate.fps_denominator or self.playhead_rate.fps_denominator == 0 then
            error("Command:serialize: playhead_rate missing fps_denominator", 2)
        end
        playhead_rate_val = self.playhead_rate.fps_numerator / self.playhead_rate.fps_denominator
    end

    local db_playhead_value = nil
    if type(self.playhead_value) == "number" then
        db_playhead_value = self.playhead_value
    elseif type(self.playhead_value) == "table" and self.playhead_value.frames ~= nil then
        db_playhead_value = self.playhead_value.frames
    end

    local command_data_for_json = {
        id = self.id,
        type = self.type,
        project_id = self.project_id,
        sequence_number = self.sequence_number,
        status = self.status,
        parameters = self:get_persistable_parameters(),
        pre_hash = self.pre_hash,
        post_hash = self.post_hash,
        created_at = self.created_at,
        executed_at = self.executed_at,
        playhead_value = db_playhead_value,
        playhead_rate = playhead_rate_val,
        selected_clip_ids = self.selected_clip_ids,
        selected_edge_infos = self.selected_edge_infos,
        selected_gap_infos = self.selected_gap_infos,
        selected_clip_ids_pre = self.selected_clip_ids_pre,
        selected_edge_infos_pre = self.selected_edge_infos_pre,
        selected_gap_infos_pre = self.selected_gap_infos_pre,
    }

    local success, json_str = pcall(json.encode, command_data_for_json)
    if not success then
        error(string.format("Command:serialize: Failed to encode command to JSON: %s", tostring(json_str)), 2)
    end
    return json_str
end

-- Create undo command
function M:create_undo()
    local undo_command = M.create("Undo" .. self.type, self.project_id)

    -- Copy relevant parameters for undo
    for k, v in pairs(self.parameters) do
        if not is_ephemeral_parameter_key(k) then
            undo_command:set_parameter(k, v)
        end
    end

    return undo_command
end

-- Save command to database
-- db parameter is optional - will get connection from database module if not provided
function M:save(db)
    if not db then
        local database = require("core.database")
        db = database.get_connection()
    end
    if not db then
        logger.warn("command", "Command.save: No database connection available")
        return false
    end
    -- Serialize parameters to JSON
    local params_json = "{}"
    local persistable_parameters = self:get_persistable_parameters()
    if next(persistable_parameters) ~= nil then
        local success, json_str = pcall(json.encode, persistable_parameters) -- Changed to json.encode
        if success then
            params_json = json_str
        else
            error("Command.save: Failed to encode parameters: " .. tostring(json_str), 2)
        end
    end

    -- Check if command exists
    local exists_query = db:prepare("SELECT COUNT(*) FROM commands WHERE id = ?")
    if not exists_query then
        local err = "unknown error"
        if db.last_error then
            err = db:last_error()
        end
        logger.warn("command", "Command.save: Failed to prepare exists query: " .. err)
        return false
    end

    exists_query:bind_value(1, self.id)

    local exists = false
    if exists_query:exec() and exists_query:next() then
        exists = exists_query:value(0) > 0
    end
    exists_query:finalize()

    local selected_clip_ids_json = self.selected_clip_ids or "[]"
    local selected_edge_infos_json = self.selected_edge_infos or "[]"
    local selected_gap_infos_json = self.selected_gap_infos or "[]"
    local selected_clip_ids_pre_json = self.selected_clip_ids_pre or "[]"
    local selected_edge_infos_pre_json = self.selected_edge_infos_pre or "[]"
    local selected_gap_infos_pre_json = self.selected_gap_infos_pre or "[]"

    local playhead_rate_val = 0
    if type(self.playhead_rate) == "number" then
        playhead_rate_val = self.playhead_rate
    elseif type(self.playhead_rate) == "table" and self.playhead_rate.fps_numerator then
        playhead_rate_val = self.playhead_rate.fps_numerator / (self.playhead_rate.fps_denominator or 1)
    end

    local db_playhead_value = nil
    if type(self.playhead_value) == "number" then
        db_playhead_value = self.playhead_value
    elseif type(self.playhead_value) == "table" and self.playhead_value.frames ~= nil then
        db_playhead_value = self.playhead_value.frames
    end

    if db_playhead_value == nil or playhead_rate_val <= 0 then
        error("FATAL: Command.save requires playhead_value and valid playhead_rate")
    end

    -- Post-execution playhead (optional - only captured for commands that advance playhead)
    local db_playhead_value_post = nil
    if type(self.playhead_value_post) == "number" then
        db_playhead_value_post = self.playhead_value_post
    elseif type(self.playhead_value_post) == "table" and self.playhead_value_post.frames ~= nil then
        db_playhead_value_post = self.playhead_value_post.frames
    end

    local playhead_rate_post_val = 0
    if type(self.playhead_rate_post) == "number" then
        playhead_rate_post_val = self.playhead_rate_post
    elseif type(self.playhead_rate_post) == "table" and self.playhead_rate_post.fps_numerator then
        playhead_rate_post_val = self.playhead_rate_post.fps_numerator / (self.playhead_rate_post.fps_denominator or 1)
    end
    if not self.executed_at then
        error("FATAL: Command.save requires executed_at")
    end

    local query
    if exists then
        -- UPDATE
        query = db:prepare([[
            UPDATE commands
            SET command_type = ?, sequence_number = ?, command_args = ?,
                pre_hash = ?, post_hash = ?, timestamp = ?, playhead_value = ?, playhead_rate = ?,
                selected_clip_ids = ?, selected_edge_infos = ?, selected_gap_infos = ?,
                selected_clip_ids_pre = ?, selected_edge_infos_pre = ?, selected_gap_infos_pre = ?, undo_group_id = ?,
                playhead_value_post = ?, playhead_rate_post = ?
            WHERE id = ?
        ]])
        if not query then
            local err = "unknown error"
            if db.last_error then
                err = db:last_error()
            end
            logger.warn("command", "Command.save: Failed to prepare UPDATE query: " .. err)
            return false
        end

        query:bind_value(1, self.type)
        query:bind_value(2, self.sequence_number)
        query:bind_value(3, params_json)
        query:bind_value(4, self.pre_hash)
        query:bind_value(5, self.post_hash)
        query:bind_value(6, self.executed_at)
        query:bind_value(7, db_playhead_value)
        query:bind_value(8, playhead_rate_val)
        query:bind_value(9, selected_clip_ids_json)
        query:bind_value(10, selected_edge_infos_json)
        query:bind_value(11, selected_gap_infos_json)
        query:bind_value(12, selected_clip_ids_pre_json)
        query:bind_value(13, selected_edge_infos_pre_json)
        query:bind_value(14, selected_gap_infos_pre_json)
        query:bind_value(15, self.undo_group_id)
        query:bind_value(16, db_playhead_value_post)
        query:bind_value(17, playhead_rate_post_val)
        query:bind_value(18, self.id)
    else
        -- INSERT
        query = db:prepare([[
            INSERT INTO commands (id, parent_sequence_number, sequence_number, command_type, command_args, pre_hash, post_hash, timestamp, playhead_value, playhead_rate, selected_clip_ids, selected_edge_infos, selected_gap_infos, selected_clip_ids_pre, selected_edge_infos_pre, selected_gap_infos_pre, undo_group_id, playhead_value_post, playhead_rate_post)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ]])
        if not query then
            local err = "unknown error"
            if db.last_error then
                err = db:last_error()
            end
            logger.warn("command", "Command.save: Failed to prepare INSERT query: " .. err)
            return false
        end

        query:bind_value(1, self.id)
        -- parent_id removed
        query:bind_value(2, self.parent_sequence_number)
        query:bind_value(3, self.sequence_number)
        query:bind_value(4, self.type)
        query:bind_value(5, params_json)
        query:bind_value(6, self.pre_hash)
        query:bind_value(7, self.post_hash)
        query:bind_value(8, self.executed_at)
        query:bind_value(9, db_playhead_value)
        query:bind_value(10, playhead_rate_val)
        query:bind_value(11, selected_clip_ids_json)
        query:bind_value(12, selected_edge_infos_json)
        query:bind_value(13, selected_gap_infos_json)
        query:bind_value(14, selected_clip_ids_pre_json)
        query:bind_value(15, selected_edge_infos_pre_json)
        query:bind_value(16, selected_gap_infos_pre_json)
        query:bind_value(17, self.undo_group_id)
        query:bind_value(18, db_playhead_value_post)
        query:bind_value(19, playhead_rate_post_val)
    end

    if not query:exec() then
        logger.warn("command", string.format("Command.save: Failed to save command: %s", query:last_error()))
        query:finalize()
        return false
    end
    
    query:finalize()

    return true
end

function M:get_display_label()
    return command_labels.label_for_command(self)
end

return M
