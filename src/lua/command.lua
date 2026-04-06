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
local log = require("core.logger").for_area("commands")
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
    local command

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

        -- Schema column order: id(0), parent_id(1), sequence_number(2),
        -- command_type(3), command_args(4), parent_sequence_number(5),
        -- undo_group_id(6), pre_hash(7), post_hash(8), timestamp(9),
        -- playhead_value(10), playhead_rate(11), playhead_value_post(12),
        -- playhead_rate_post(13), selected_clip_ids(14), selected_edge_infos(15),
        -- selected_gap_infos(16), selected_clip_ids_pre(17),
        -- selected_edge_infos_pre(18), selected_gap_infos_pre(19),
        -- sequence_id(20)
        command = {
            id = query:value(0),
            parent_id = query:value(1),
            sequence_number = query:value(2) or 0,
            type = query:value(3),
            parameters = args_table,
            parent_sequence_number = query:value(5),
            undo_group_id = query:value(6),
            pre_hash = query:value(7) or "",
            post_hash = query:value(8) or "",
            created_at = query:value(9) or os.time(),
            executed_at = query:value(9),
            playhead_value = query:value(10),
            playhead_rate = query:value(11),
            playhead_value_post = query:value(12),
            playhead_rate_post = query:value(13),
            selected_clip_ids = query:value(14),
            selected_edge_infos = query:value(15),
            selected_gap_infos = query:value(16),
            selected_clip_ids_pre = query:value(17),
            selected_edge_infos_pre = query:value(18),
            selected_gap_infos_pre = query:value(19),
            sequence_id = query:value(20),
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
    assert(db, "Command.load_history: no database connection")

    local query = db:prepare([[
        SELECT * FROM commands
        WHERE command_type NOT LIKE 'Undo%'
        ORDER BY sequence_number ASC
    ]])
    assert(query, "Command.load_history: failed to prepare query (schema mismatch?)")

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

--- Load only commands on the main branch for history display.
-- The main branch is: ancestors of cursor + redo chain (following latest child
-- at each step) + undo group members of any command on the branch.
-- Uses a recursive CTE so cost scales with branch depth, not total command count.
-- @param cursor_seq number: current undo cursor (sequence_number), 0 or nil for empty
-- @return table: list of Command objects sorted by sequence_number ASC
function M.load_history_branch(cursor_seq)
    local database = require("core.database")
    local db = database.get_connection()
    assert(db, "Command.load_history_branch: no database connection")

    cursor_seq = cursor_seq or 0

    -- Step 1: Find the tip of the main branch by walking forward from cursor
    -- following the latest child (highest sequence_number) at each step.
    -- cursor_seq=0 means "before any command" — children are those with NULL parent.
    local tip = cursor_seq
    while true do
        local child_q
        if tip == 0 then
            child_q = db:prepare([[
                SELECT MAX(sequence_number) FROM commands
                WHERE parent_sequence_number IS NULL
                  AND command_type NOT LIKE 'Undo%'
            ]])
        else
            child_q = db:prepare([[
                SELECT MAX(sequence_number) FROM commands
                WHERE parent_sequence_number = ?
                  AND command_type NOT LIKE 'Undo%'
            ]])
        end
        assert(child_q, "load_history_branch: failed to prepare child query (schema mismatch?)")
        if tip ~= 0 then
            child_q:bind_value(1, tip)
        end
        local next_seq = nil
        if child_q:exec() and child_q:next() then
            next_seq = child_q:value(0)
        end
        child_q:finalize()
        if not next_seq then break end
        tip = next_seq
    end

    -- Always include provenance record (seq=0, parent=-1) if it exists.
    -- Provenance is a history marker, not in the undo tree (parent=-1 is unreachable).
    local provenance = nil
    local prov_q = db:prepare([[
        SELECT * FROM commands
        WHERE sequence_number = 0 AND parent_sequence_number = -1 LIMIT 1
    ]])
    assert(prov_q, "load_history_branch: failed to prepare provenance query (schema mismatch?)")
    if prov_q:exec() and prov_q:next() then
        provenance = M.parse_from_query(prov_q, nil)
    end
    prov_q:finalize()

    if tip == 0 then
        if provenance then return { provenance } end
        return {}
    end

    -- Step 2: Walk from tip back to root via parent_sequence_number (the branch spine),
    -- then include all undo group members of any command on that spine.
    local query = db:prepare([[
        WITH RECURSIVE spine(seq) AS (
            SELECT ?
            UNION ALL
            SELECT c.parent_sequence_number
            FROM commands c
            JOIN spine s ON c.sequence_number = s.seq
            WHERE c.parent_sequence_number IS NOT NULL
        )
        SELECT * FROM commands
        WHERE sequence_number IN (SELECT seq FROM spine)
           OR undo_group_id IN (
                SELECT c2.undo_group_id FROM commands c2
                WHERE c2.sequence_number IN (SELECT seq FROM spine)
                  AND c2.undo_group_id IS NOT NULL
              )
        ORDER BY sequence_number ASC
    ]])
    assert(query, "load_history_branch: failed to prepare spine query (schema mismatch?)")
    query:bind_value(1, tip)

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

    -- Prepend provenance if present (always first entry in history)
    if provenance then
        table.insert(commands, 1, provenance)
    end

    return commands
end

--- Load history filtered by sequence_id for per-sequence undo display.
-- Returns commands where sequence_id matches or is NULL (project-level),
-- walking the branch from each cursor.
-- @param seq_cursor number: sequence cursor position
-- @param global_cursor number: global cursor position
-- @param sequence_id string: active sequence ID to filter by
-- @return table: list of Command objects sorted by sequence_number ASC
function M.load_filtered_history_branch(seq_cursor, global_cursor, sequence_id)
    local database = require("core.database")
    local db = database.get_connection()
    assert(db, "Command.load_filtered_history_branch: no database connection")

    seq_cursor = seq_cursor or 0
    global_cursor = global_cursor or 0

    -- Walk forward from each cursor to find the tips, then walk back to build branches.
    -- For simplicity, query all matching commands on the current branches.
    -- Use a union of two branch walks: one for the sequence, one for global.
    local commands = {}
    local seen = {}

    -- Helper: walk a branch (ancestors + forward) for commands matching a filter
    local function walk_branch(cursor, filter_sql, bind_values)
        if cursor == 0 and #bind_values == 0 then return end

        -- Find tip by walking forward from cursor
        local tip = cursor
        while true do
            local child_q
            if tip == 0 then
                child_q = db:prepare(string.format([[
                    SELECT MAX(sequence_number) FROM commands
                    WHERE parent_sequence_number IS NULL
                      AND command_type NOT LIKE 'Undo%%'
                      AND %s
                ]], filter_sql))
            else
                child_q = db:prepare(string.format([[
                    SELECT MAX(sequence_number) FROM commands
                    WHERE parent_sequence_number = ?
                      AND command_type NOT LIKE 'Undo%%'
                      AND %s
                ]], filter_sql))
            end
            assert(child_q, "load_filtered_history_branch: failed to prepare child query (schema mismatch?)")
            local bind_idx = 1
            if tip ~= 0 then
                child_q:bind_value(bind_idx, tip)
                bind_idx = bind_idx + 1
            end
            for _, v in ipairs(bind_values) do
                child_q:bind_value(bind_idx, v)
                bind_idx = bind_idx + 1
            end
            local next_seq = nil
            if child_q:exec() and child_q:next() then
                next_seq = child_q:value(0)
            end
            child_q:finalize()
            if not next_seq then break end
            tip = next_seq
        end

        if tip == 0 then return end

        -- Walk back from tip through parent chain, collecting matching commands
        local query = db:prepare(string.format([[
            WITH RECURSIVE spine(seq) AS (
                SELECT ?
                UNION ALL
                SELECT c.parent_sequence_number
                FROM commands c
                JOIN spine s ON c.sequence_number = s.seq
                WHERE c.parent_sequence_number IS NOT NULL
            )
            SELECT * FROM commands
            WHERE sequence_number IN (SELECT seq FROM spine)
              AND %s
              AND command_type NOT LIKE 'Undo%%'
            ORDER BY sequence_number ASC
        ]], filter_sql))
        assert(query, "load_filtered_history_branch: failed to prepare spine query (schema mismatch?)")
        local bind_idx = 1
        query:bind_value(bind_idx, tip)
        bind_idx = bind_idx + 1
        for _, v in ipairs(bind_values) do
            query:bind_value(bind_idx, v)
            bind_idx = bind_idx + 1
        end

        if query:exec() then
            while query:next() do
                local cmd = M.parse_from_query(query, nil)
                if cmd and not seen[cmd.sequence_number] then
                    seen[cmd.sequence_number] = true
                    commands[#commands + 1] = cmd
                end
            end
        end
        query:finalize()
    end

    -- Walk sequence-scoped branch
    if sequence_id then
        walk_branch(seq_cursor, "sequence_id = ?", {sequence_id})
    end

    -- Walk global branch
    walk_branch(global_cursor, "sequence_id IS NULL", {})

    -- Sort by sequence_number ASC
    table.sort(commands, function(a, b)
        return (a.sequence_number or 0) < (b.sequence_number or 0)
    end)

    -- Prepend provenance if present
    local prov_q = db:prepare([[
        SELECT * FROM commands
        WHERE sequence_number = 0 AND parent_sequence_number = -1 LIMIT 1
    ]])
    assert(prov_q, "load_filtered_history_branch: failed to prepare provenance query (schema mismatch?)")
    if prov_q:exec() and prov_q:next() then
        local provenance = M.parse_from_query(prov_q, nil)
        if provenance and not seen[0] then
            table.insert(commands, 1, provenance)
        end
    end
    prov_q:finalize()

    return commands
end

-- Load command at specific sequence number
function M.load_at_sequence(seq_num, project_id)
    local database = require("core.database")
    local db = database.get_connection()
    assert(db, "Command.load_at_sequence: no database connection")
    assert(seq_num, "Command.load_at_sequence: seq_num is required")

    local query = db:prepare([[
        SELECT id, command_type, command_args, sequence_number, parent_sequence_number,
               pre_hash, post_hash, timestamp, playhead_value, playhead_rate,
               selected_clip_ids, selected_edge_infos, selected_gap_infos,
               selected_clip_ids_pre, selected_edge_infos_pre, selected_gap_infos_pre,
               undo_group_id, playhead_value_post, playhead_rate_post, sequence_id
        FROM commands
        WHERE sequence_number = ? AND command_type NOT LIKE 'Undo%'
    ]])
    assert(query, string.format(
        "Command.load_at_sequence: failed to prepare query for seq=%s (schema mismatch?)",
        tostring(seq_num)))

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
        playhead_rate_post = query:value(18),
        sequence_id = query:value(19),
    }

    setmetatable(command, {__index = M})
    query:finalize()
    return command
end

-- Load commands from sequence number onwards (for replay)
function M.load_from_sequence(start_seq, project_id)
    local database = require("core.database")
    local db = database.get_connection()
    assert(db, "Command.load_from_sequence: no database connection")

    local query = db:prepare("SELECT * FROM commands WHERE sequence_number >= ? ORDER BY sequence_number")
    assert(query, "Command.load_from_sequence: failed to prepare query (schema mismatch?)")

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
    assert(db, "Command.mark_undone_after: no database connection")

    local query = db:prepare("UPDATE commands SET status = 'Undone' WHERE sequence_number > ?")
    assert(query, "Command.mark_undone_after: failed to prepare query (schema mismatch?)")

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
    assert(db, "Command.load_parent_tree: no database connection")

    local query = db:prepare([[
        SELECT sequence_number, parent_sequence_number
        FROM commands
        WHERE command_type NOT LIKE 'Undo%'
    ]])
    assert(query, "Command.load_parent_tree: failed to prepare query (schema mismatch?)")

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
    local data, decode_err = json.decode(json_string)
    if not data then
        return nil, "Failed to decode JSON: " .. tostring(decode_err)
    end

    if type(data) ~= "table" then
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
-- Includes parameter detail when available (visible when history window is wide).
function M:label()
    local custom = self.parameters and self.parameters.display_label
    if custom and custom ~= "" then
        return custom
    end
    return command_labels.label_for_command(self)
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

    -- playhead_value must be integer frames
    local db_playhead_value = self.playhead_value
    if db_playhead_value ~= nil then
        assert(type(db_playhead_value) == "number", "Command:serialize: playhead_value must be integer")
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
    assert(db, "Command.save: no database connection")
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
        log.warn("Command.save: Failed to prepare exists query: %s", err)
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
        if not self.playhead_rate.fps_denominator or self.playhead_rate.fps_denominator == 0 then
            error("Command.save: playhead_rate missing fps_denominator", 2)
        end
        playhead_rate_val = self.playhead_rate.fps_numerator / self.playhead_rate.fps_denominator
    end

    -- playhead_value must be integer frames
    local db_playhead_value = self.playhead_value
    assert(type(db_playhead_value) == "number", string.format(
        "FATAL: Command.save: missing playhead_value (command_type=%s, playhead_value=%s)",
        tostring(self.type), tostring(self.playhead_value)))
    assert(playhead_rate_val > 0, string.format(
        "FATAL: Command.save: invalid playhead_rate (command_type=%s, playhead_rate=%s)",
        tostring(self.type), tostring(playhead_rate_val)))

    -- Post-execution playhead (optional - only captured for commands that advance playhead)
    local db_playhead_value_post = self.playhead_value_post
    if db_playhead_value_post ~= nil then
        assert(type(db_playhead_value_post) == "number", "Command.save: playhead_value_post must be integer")
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
                playhead_value_post = ?, playhead_rate_post = ?, sequence_id = ?
            WHERE id = ?
        ]])
        if not query then
            local err = "unknown error"
            if db.last_error then
                err = db:last_error()
            end
            log.warn("Command.save: Failed to prepare UPDATE query: %s", err)
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
        query:bind_value(18, self.sequence_id)  -- NULL for project-level
        query:bind_value(19, self.id)
    else
        -- INSERT
        query = db:prepare([[
            INSERT INTO commands (id, parent_sequence_number, sequence_number, command_type, command_args, pre_hash, post_hash, timestamp, playhead_value, playhead_rate, selected_clip_ids, selected_edge_infos, selected_gap_infos, selected_clip_ids_pre, selected_edge_infos_pre, selected_gap_infos_pre, undo_group_id, playhead_value_post, playhead_rate_post, sequence_id)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ]])
        if not query then
            local err = "unknown error"
            if db.last_error then
                err = db:last_error()
            end
            log.warn("Command.save: Failed to prepare INSERT query: %s", err)
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
        query:bind_value(20, self.sequence_id)  -- NULL for project-level
    end

    if not query:exec() then
        log.warn("Command.save: Failed to save command: %s", query:last_error())
        query:finalize()
        return false
    end
    
    query:finalize()

    return true
end

function M:get_display_label()
    return command_labels.label_for_command(self)
end

--- Insert a minimal provenance record into the commands table.
-- Used by importers to mark project origin. Not a real undoable command.
-- parent_sequence_number = -1 (unreachable sentinel) keeps it visible in
-- edit history but invisible to undo/redo traversal.
function M.insert_provenance(command_type, project_id, params)
    assert(command_type and command_type ~= "", "Command.insert_provenance: command_type required")
    assert(project_id and project_id ~= "", "Command.insert_provenance: project_id required")
    local database = require("core.database")
    local db = database.get_connection()
    assert(db, "Command.insert_provenance: no database connection")
    local args_json = json.encode(params or {})
    local stmt = assert(db:prepare([[
        INSERT INTO commands (id, parent_sequence_number, sequence_number, command_type,
            command_args, timestamp, playhead_value, playhead_rate)
        VALUES (?, -1, 0, ?, ?, ?, 0, 25.0)
    ]]), "Command.insert_provenance: failed to prepare INSERT")
    stmt:bind_value(1, uuid.generate())
    stmt:bind_value(2, command_type)
    stmt:bind_value(3, args_json)
    stmt:bind_value(4, os.time())
    assert(stmt:exec(), "Command.insert_provenance: INSERT failed")
    stmt:finalize()
end

return M
