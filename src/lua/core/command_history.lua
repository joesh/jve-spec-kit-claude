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
-- Size: ~280 LOC
-- Volatility: unknown
--
-- @file command_history.lua
-- Original intent (unreviewed):
-- CommandHistory: Manages undo/redo stacks, sequence numbers, and position persistence
-- Extracted from command_manager.lua
local M = {}
local log = require("core.logger").for_area("commands")

-- Database connection
local db = nil

-- State tracking
local last_sequence_number = 0
local active_sequence_id = nil
local _active_project_id = nil  -- luacheck: ignore 231

-- Undo group tracking
local undo_group_stack = {}

local GLOBAL_STACK_ID = "global"
local TIMELINE_STACK_PREFIX = "timeline:"

M.GLOBAL_STACK_ID = GLOBAL_STACK_ID

local undo_stack_states = {
    [GLOBAL_STACK_ID] = {
        current_sequence_number = nil,
        current_branch_path = {},
        sequence_id = nil,
        position_initialized = false,
    }
}

local active_stack_id = GLOBAL_STACK_ID
local current_sequence_number = undo_stack_states[GLOBAL_STACK_ID].current_sequence_number
local current_branch_path = undo_stack_states[GLOBAL_STACK_ID].current_branch_path  -- luacheck: ignore 231

-- Registry that callers can use to route commands to specific undo stacks.
local command_stack_resolvers = {}

function M.init(database, sequence_id, project_id)
    db = database
    if not sequence_id or sequence_id == "" then
        error("CommandHistory.init: sequence_id is required", 2)
    end
    if not project_id or project_id == "" then
        error("CommandHistory.init: project_id is required", 2)
    end
    active_sequence_id = sequence_id
    _active_project_id = project_id
    
    M.reset()

    -- Query last sequence number from database.
    -- MUST use MAX of ALL commands (including orphaned branches) to prevent
    -- UNIQUE constraint collisions. Orphaned commands still occupy sequence numbers
    -- and will eventually be accessible via a branch browser.
    M.refresh_last_sequence_number()

    local global_state = M.ensure_stack_state(GLOBAL_STACK_ID)
    global_state.sequence_id = active_sequence_id
    M.set_active_stack(GLOBAL_STACK_ID, {sequence_id = active_sequence_id})
    M.load_global_cursor()
end

function M.reset()
    undo_stack_states = {
        [GLOBAL_STACK_ID] = {
            current_sequence_number = nil,
            current_branch_path = {},
            sequence_id = nil,
            position_initialized = false,
        }
    }
    active_stack_id = GLOBAL_STACK_ID
    current_sequence_number = nil
    current_branch_path = undo_stack_states[GLOBAL_STACK_ID].current_branch_path
    last_sequence_number = 0
end

function M.ensure_stack_state(stack_id)
    stack_id = stack_id or GLOBAL_STACK_ID
    local state = undo_stack_states[stack_id]
    if not state then
        state = {
            current_sequence_number = nil,
            current_branch_path = {},
            sequence_id = nil,
            position_initialized = false,
        }
        undo_stack_states[stack_id] = state
    end
    return state
end

function M.apply_stack_state(stack_id)
    active_stack_id = stack_id or GLOBAL_STACK_ID
    local state = M.ensure_stack_state(active_stack_id)
    current_sequence_number = state.current_sequence_number
    current_branch_path = state.current_branch_path
    return state
end

function M.set_active_stack(stack_id, opts)
    local state = M.apply_stack_state(stack_id)
    if opts and opts.sequence_id then
        state.sequence_id = opts.sequence_id
    end
    if state.sequence_id and not state.position_initialized then
        M.initialize_stack_position_from_db(stack_id, state.sequence_id)
    end
end

function M.set_current_sequence_number(value)
    current_sequence_number = value
    local state = M.ensure_stack_state(active_stack_id)
    state.current_sequence_number = value
    state.position_initialized = true
end

function M.get_current_sequence_number()
    return current_sequence_number
end

function M.get_last_sequence_number()
    return last_sequence_number
end

--- Re-read MAX(sequence_number) from DB. Called on init and after UNIQUE collisions.
function M.refresh_last_sequence_number()
    if not db then return end
    local query = db:prepare("SELECT MAX(sequence_number) FROM commands")
    if not query then return end
    if query:exec() and query:next() then
        local db_max = query:value(0) or 0
        if db_max > last_sequence_number then
            log.warn("refresh_last_sequence_number: DB MAX=%d > cached=%d (stale WAL or concurrent session)",
                db_max, last_sequence_number)
            last_sequence_number = db_max
        end
    end
    query:finalize()
end

function M.increment_sequence_number()
    last_sequence_number = last_sequence_number + 1
    log.event("Assigned sequence number %d (current=%s)",
        last_sequence_number, tostring(current_sequence_number))
    return last_sequence_number
end

function M.decrement_sequence_number()
    last_sequence_number = last_sequence_number - 1
end

function M.get_current_stack_id()
    return active_stack_id
end

function M.get_current_stack_sequence_id(fallback_to_active_sequence)
    local state = M.ensure_stack_state(active_stack_id)
    if state.sequence_id and state.sequence_id ~= "" then
        return state.sequence_id
    end
    if fallback_to_active_sequence then
        return active_sequence_id
    end
    return nil
end

function M.stack_id_for_sequence(sequence_id)
    if not sequence_id or sequence_id == "" then
        return GLOBAL_STACK_ID
    end
    return TIMELINE_STACK_PREFIX .. sequence_id
end

function M.resolve_stack_for_command(command)
    if command.stack_id then
        if type(command.stack_id) == "string" then
            return command.stack_id, nil
        elseif type(command.stack_id) == "table" then
            return command.stack_id.stack_id or GLOBAL_STACK_ID, command.stack_id
        end
    end

    local resolver = command_stack_resolvers[command.type]
    if resolver then
        local ok, stack_info = pcall(resolver, command)
        if ok and stack_info then
            if type(stack_info) == "string" then
                return stack_info, nil
            elseif type(stack_info) == "table" then
                return stack_info.stack_id or GLOBAL_STACK_ID, stack_info
            end
        elseif not ok then
            log.warn("Stack resolver for %s threw error: %s",
                tostring(command.type), tostring(stack_info))
        end
    end

    if command.get_parameter then
        local sequence_param = command:get_parameter("sequence_id")
        if sequence_param and sequence_param ~= "" then
            return M.stack_id_for_sequence(sequence_param), {sequence_id = sequence_param}
        end
    end

    return GLOBAL_STACK_ID, nil
end

function M.load_sequence_undo_position(sequence_id)
    if not db or not sequence_id or sequence_id == "" then
        return nil, false
    end

    local query = db:prepare([[ 
        SELECT current_sequence_number
        FROM sequences
        WHERE id = ?
    ]])

    if not query then
        return nil, false
    end

    query:bind_value(1, sequence_id)
    local has_row = false
    local value = nil
    if query:exec() and query:next() then
        has_row = true
        value = query:value(0)
    end
    query:finalize()
    return value, has_row
end

function M.initialize_stack_position_from_db(stack_id, sequence_id)
    if not sequence_id or sequence_id == "" then
        return
    end

    local saved_value, has_row = M.load_sequence_undo_position(sequence_id)
    local state = M.ensure_stack_state(stack_id)

    -- NSF: Validate that saved cursor points to an existing command
    -- If orphaned (e.g., commands table was cleared), reset to actual last command
    if saved_value and saved_value > 0 then
        local check = db:prepare("SELECT 1 FROM commands WHERE sequence_number = ?")
        assert(check, "initialize_stack_position_from_db: failed to prepare orphan check query")
        check:bind_value(1, saved_value)
        local exists = check:exec() and check:next()
        check:finalize()
        if not exists then
            log.warn("Orphaned undo cursor: sequence %s has current_sequence_number=%d but command doesn't exist. Resetting to %s.",
                sequence_id, saved_value, last_sequence_number > 0 and tostring(last_sequence_number) or "nil")
            saved_value = last_sequence_number > 0 and last_sequence_number or nil
            -- Persist the fix
            local fix = db:prepare("UPDATE sequences SET current_sequence_number = ? WHERE id = ?")
            assert(fix, "initialize_stack_position_from_db: failed to prepare orphan fix query")
            fix:bind_value(1, saved_value or 0)
            fix:bind_value(2, sequence_id)
            local ok = fix:exec()
            fix:finalize()
            assert(ok, string.format("initialize_stack_position_from_db: failed to persist orphan fix for sequence %s", sequence_id))
        end
        M.set_current_sequence_number(saved_value)
    elseif saved_value == 0 then
        M.set_current_sequence_number(nil)
    elseif has_row then
        if last_sequence_number > 0 then
            M.set_current_sequence_number(last_sequence_number)
        else
            M.set_current_sequence_number(nil)
        end
    else
        M.set_current_sequence_number(nil)
    end

    state.position_initialized = true
end

-- Save current undo position to database (persists across sessions)
function M.save_undo_position()
    assert(db, "CommandHistory.save_undo_position: no database connection")

    local sequence_id = M.get_current_stack_sequence_id(true)
    assert(sequence_id and sequence_id ~= "",
        "CommandHistory.save_undo_position: no active sequence_id")

    local update = db:prepare([[
        UPDATE sequences
        SET current_sequence_number = ?
        WHERE id = ?
    ]])
    assert(update, "CommandHistory.save_undo_position: failed to prepare update")

    local stored_position = current_sequence_number
    if stored_position == nil then
        stored_position = 0
    end
    update:bind_value(1, stored_position)
    update:bind_value(2, sequence_id)
    local success = update:exec()
    update:finalize()

    assert(success, string.format(
        "CommandHistory.save_undo_position: UPDATE failed for sequence %s", tostring(sequence_id)))

    return true
end

function M.find_latest_child_command(parent_sequence)
    if not db then
        return nil
    end

    local query = db:prepare([[ 
        SELECT sequence_number, command_type, command_args
        FROM commands
        WHERE parent_sequence_number IS ? OR (parent_sequence_number IS NULL AND ? = 0)
        ORDER BY sequence_number DESC
        LIMIT 1
    ]])

    if not query then
        return nil
    end

    query:bind_value(1, parent_sequence)
    query:bind_value(2, parent_sequence)

    local command = nil
    local json = require("dkjson")  -- Use dkjson (already used elsewhere in codebase)

    local ok = query:exec()
    if ok and query:next() then
        local args_json = query:value(2)
        local args = nil

        -- Decode JSON if present
        if args_json and args_json ~= "" then
            local decode_ok, decoded = pcall(json.decode, args_json)
            if decode_ok then
                args = decoded
            else
                log.warn("Failed to decode command args JSON: %s", tostring(decoded))
            end
        end

        command = {
            sequence_number = query:value(0),
            command_type = query:value(1),
            command_args = args
        }
    end
    query:finalize()
    return command
end

--- Find all sequence_numbers in an undo group, bounded by a cursor position.
-- @param group_id  The undo_group_id to match
-- @param up_to_seq  Only include sequence_numbers <= this value (for undo)
--                   Pass nil to include all members (for redo, caller filters)
-- @param after_seq  Only include sequence_numbers > this value (for redo)
--                   Pass nil to skip lower bound (for undo)
-- @return array of sequence_numbers (DESC when up_to_seq set, ASC when after_seq set)
function M.find_group_members(group_id, up_to_seq, after_seq)
    if not db or not group_id then
        return {}
    end
    local sql
    local bind_count
    if up_to_seq and after_seq then
        sql = [[SELECT sequence_number FROM commands
                WHERE undo_group_id = ? AND sequence_number <= ? AND sequence_number > ?
                ORDER BY sequence_number DESC]]
        bind_count = 3
    elseif up_to_seq then
        sql = [[SELECT sequence_number FROM commands
                WHERE undo_group_id = ? AND sequence_number <= ?
                ORDER BY sequence_number DESC]]
        bind_count = 2
    elseif after_seq then
        sql = [[SELECT sequence_number FROM commands
                WHERE undo_group_id = ? AND sequence_number > ?
                ORDER BY sequence_number ASC]]
        bind_count = 2
    else
        sql = [[SELECT sequence_number FROM commands
                WHERE undo_group_id = ?
                ORDER BY sequence_number DESC]]
        bind_count = 1
    end
    local query = db:prepare(sql)
    assert(query, "find_group_members: failed to prepare SQL (schema mismatch?)")
    query:bind_value(1, group_id)
    if bind_count == 3 then
        query:bind_value(2, up_to_seq)
        query:bind_value(3, after_seq)
    elseif bind_count == 2 then
        query:bind_value(2, up_to_seq or after_seq)
    end
    local results = {}
    if query:exec() then
        while query:next() do
            results[#results + 1] = query:value(0)
        end
    end
    query:finalize()
    return results
end

-- Undo group management (Emacs-style)
-- group_id is optional - if not provided, a unique ID is generated
-- When called from within a command executor, pass the parent command's sequence_number
function M.begin_undo_group(label, group_id)
    if not group_id then
        -- Allocate from the sequence number counter to guarantee uniqueness
        -- with automatic undo_group_ids (which are also sequence numbers).
        last_sequence_number = last_sequence_number + 1
        group_id = last_sequence_number
    end
    table.insert(undo_group_stack, {
        id = group_id,
        label = label or ("group_" .. tostring(group_id)),
        cursor_on_entry = current_sequence_number  -- Save cursor for rollback
    })
    log.event("Begin undo group %s: %s", tostring(group_id), label or "")
    return group_id
end

function M.end_undo_group()
    if #undo_group_stack == 0 then
        -- NSF-OK: mismatch can happen if error unwinds during group; callers handle nil return
        log.warn("end_undo_group called with no active group")
        return nil
    end
    local group = table.remove(undo_group_stack)
    log.event("End undo group %s: %s", tostring(group.id), group.label)
    return group.id
end

function M.get_current_undo_group_id()
    if #undo_group_stack == 0 then
        return nil
    end
    -- Nested groups collapse into outer group (Emacs semantics)
    return undo_group_stack[1].id
end

function M.get_undo_group_cursor_on_entry()
    if #undo_group_stack == 0 then
        return nil
    end
    -- Return cursor position from outermost group (Emacs semantics)
    return undo_group_stack[1].cursor_on_entry
end

--- Mark the current undo group as aborted. Subsequent execute() calls will be rejected.
function M.mark_undo_group_aborted()
    if #undo_group_stack > 0 then
        undo_group_stack[#undo_group_stack].aborted = true
        log.event("Undo group %s marked aborted", tostring(undo_group_stack[#undo_group_stack].id))
    end
end

--- Check if the current undo group has been aborted by a failed command.
function M.is_undo_group_aborted()
    if #undo_group_stack == 0 then return false end
    return undo_group_stack[#undo_group_stack].aborted == true
end

-- ==========================================================================
-- Per-Sequence Undo: Global cursor management
-- ==========================================================================

--- Get the global cursor from the projects table.
function M.get_global_cursor()
    local global_state = M.ensure_stack_state(GLOBAL_STACK_ID)
    return global_state.current_sequence_number
end

--- Set the global cursor (in-memory + DB persistence).
function M.set_global_cursor(value)
    assert(db, "set_global_cursor: no database connection")
    assert(_active_project_id and _active_project_id ~= "",
        "set_global_cursor: no active project_id")
    local global_state = M.ensure_stack_state(GLOBAL_STACK_ID)
    global_state.current_sequence_number = value
    global_state.position_initialized = true
    local update = db:prepare("UPDATE projects SET global_undo_cursor = ? WHERE id = ?")
    assert(update, "set_global_cursor: failed to prepare UPDATE")
    update:bind_value(1, value or 0)
    update:bind_value(2, _active_project_id)
    assert(update:exec(), string.format(
        "set_global_cursor: UPDATE failed for project %s", _active_project_id))
    update:finalize()
end

--- Load the global cursor from the projects table on init.
function M.load_global_cursor()
    assert(db, "load_global_cursor: no database connection")
    assert(_active_project_id and _active_project_id ~= "",
        "load_global_cursor: no active project_id")
    local query = db:prepare("SELECT global_undo_cursor FROM projects WHERE id = ?")
    assert(query, "load_global_cursor: failed to prepare SELECT")
    query:bind_value(1, _active_project_id)
    assert(query:exec(), "load_global_cursor: SELECT failed")
    local global_state = M.ensure_stack_state(GLOBAL_STACK_ID)
    assert(query:next(), string.format(
        "load_global_cursor: no project row for id=%s", _active_project_id))
    local value = query:value(0)
    if value and value > 0 then
        global_state.current_sequence_number = value
    else
        global_state.current_sequence_number = nil
    end
    global_state.position_initialized = true
    query:finalize()
end

-- ==========================================================================
-- Per-Sequence Undo: Merged view for undo/redo walk
-- ==========================================================================

--- Get the cursor for a specific sequence's stack.
function M.get_sequence_cursor(sequence_id)
    if not sequence_id then return nil end
    local stack_id = M.stack_id_for_sequence(sequence_id)
    local state = undo_stack_states[stack_id]
    if state then
        return state.current_sequence_number
    end
    return nil
end

--- Find the next command to undo in the merged view (active sequence + global).
-- Returns the command row with the highest timestamp among:
--   - Active sequence's command at its cursor
--   - Global command at the global cursor
-- @param active_seq_id string: active sequence ID
-- @return table|nil: {sequence_number, command_type, sequence_id, timestamp, undo_group_id} or nil
function M.find_merged_undo_target(active_seq_id)
    if not db then return nil end

    local seq_cursor = M.get_sequence_cursor(active_seq_id)
    local global_cursor = M.get_global_cursor()

    -- Query the command at each cursor position
    local seq_cmd = nil
    local global_cmd = nil

    -- Helper: fetch command at a cursor position
    local function fetch_command_at(cursor, label)
        local q = db:prepare([[
            SELECT sequence_number, command_type, sequence_id, timestamp, undo_group_id
            FROM commands WHERE sequence_number = ?
              AND command_type NOT LIKE 'Undo%'
        ]])
        assert(q, string.format("find_merged_undo_target: failed to prepare %s query", label))
        q:bind_value(1, cursor)
        local cmd = nil
        if q:exec() and q:next() then
            local ts = q:value(3)
            assert(ts, string.format(
                "find_merged_undo_target: command at seq=%d has NULL timestamp", cursor))
            cmd = {
                sequence_number = q:value(0),
                command_type = q:value(1),
                sequence_id = q:value(2),
                timestamp = ts,
                undo_group_id = q:value(4),
            }
        end
        q:finalize()
        return cmd
    end

    if seq_cursor and seq_cursor > 0 then
        seq_cmd = fetch_command_at(seq_cursor, "sequence")
    end

    if global_cursor and global_cursor > 0 then
        global_cmd = fetch_command_at(global_cursor, "global")
    end

    -- Pick the one with the higher timestamp (most recent)
    if seq_cmd and global_cmd then
        if seq_cmd.timestamp >= global_cmd.timestamp then
            return seq_cmd
        else
            return global_cmd
        end
    end
    return seq_cmd or global_cmd
end

--- Find the next command to redo in the merged view.
-- Returns the command with the lowest timestamp among the children of each cursor.
-- @param active_seq_id string: active sequence ID
-- @return table|nil: {sequence_number, command_type, sequence_id, timestamp, undo_group_id}
function M.find_merged_redo_target(active_seq_id)
    if not db then return nil end

    local seq_cursor = M.get_sequence_cursor(active_seq_id)
    local global_cursor = M.get_global_cursor()

    local seq_child
    local global_child

    -- Helper: parse a redo child from a query result
    local function parse_redo_child(q)
        if not q:exec() or not q:next() then
            q:finalize()
            return nil
        end
        local ts = q:value(3)
        assert(ts, string.format(
            "find_merged_redo_target: redo child at seq=%s has NULL timestamp",
            tostring(q:value(0))))
        local child = {
            sequence_number = q:value(0),
            command_type = q:value(1),
            sequence_id = q:value(2),
            timestamp = ts,
            undo_group_id = q:value(4),
        }
        q:finalize()
        return child
    end

    -- Find redo child for active sequence
    if active_seq_id then
        local parent = seq_cursor or 0
        local q = db:prepare([[
            SELECT sequence_number, command_type, sequence_id, timestamp, undo_group_id
            FROM commands
            WHERE (parent_sequence_number IS ? OR (parent_sequence_number IS NULL AND ? = 0))
              AND sequence_id = ?
              AND command_type NOT LIKE 'Undo%'
            ORDER BY sequence_number DESC LIMIT 1
        ]])
        assert(q, "find_merged_redo_target: failed to prepare seq query")
        q:bind_value(1, parent)
        q:bind_value(2, parent)
        q:bind_value(3, active_seq_id)
        seq_child = parse_redo_child(q)
    end

    -- Find redo child for global
    do
        local parent = global_cursor or 0
        local q = db:prepare([[
            SELECT sequence_number, command_type, sequence_id, timestamp, undo_group_id
            FROM commands
            WHERE (parent_sequence_number IS ? OR (parent_sequence_number IS NULL AND ? = 0))
              AND sequence_id IS NULL
              AND command_type NOT LIKE 'Undo%'
            ORDER BY sequence_number DESC LIMIT 1
        ]])
        assert(q, "find_merged_redo_target: failed to prepare global query")
        q:bind_value(1, parent)
        q:bind_value(2, parent)
        global_child = parse_redo_child(q)
    end

    -- Pick the one with the lower timestamp (earliest undone)
    if seq_child and global_child then
        if seq_child.timestamp <= global_child.timestamp then
            return seq_child
        else
            return global_child
        end
    end
    return seq_child or global_child
end

--- Move the appropriate cursor after an undo.
-- If the command is sequence-scoped, move the sequence cursor.
-- If the command is global (sequence_id IS NULL), move the global cursor.
function M.move_cursor_for_undo(cmd)
    assert(cmd, "move_cursor_for_undo: cmd required")
    assert(cmd.sequence_number, string.format(
        "move_cursor_for_undo: cmd missing sequence_number (type=%s)",
        tostring(cmd.type)))
    -- parent_sequence_number can be nil (undoing the very first command)
    if cmd.sequence_id then
        local stack_id = M.stack_id_for_sequence(cmd.sequence_id)
        local state = M.ensure_stack_state(stack_id)
        state.current_sequence_number = cmd.parent_sequence_number
        state.position_initialized = true
        if stack_id == active_stack_id then
            current_sequence_number = cmd.parent_sequence_number
        end
    else
        M.set_global_cursor(cmd.parent_sequence_number)
    end
end

--- Move the appropriate cursor after a redo.
function M.move_cursor_for_redo(cmd)
    assert(cmd, "move_cursor_for_redo: cmd required")
    assert(cmd.sequence_number, string.format(
        "move_cursor_for_redo: cmd missing sequence_number (type=%s)",
        tostring(cmd.type)))
    if cmd.sequence_id then
        local stack_id = M.stack_id_for_sequence(cmd.sequence_id)
        local state = M.ensure_stack_state(stack_id)
        state.current_sequence_number = cmd.sequence_number
        state.position_initialized = true
        if stack_id == active_stack_id then
            current_sequence_number = cmd.sequence_number
        end
    else
        M.set_global_cursor(cmd.sequence_number)
    end
end

--- Check if undo is possible in the merged view.
function M.can_undo_merged(active_seq_id)
    return M.find_merged_undo_target(active_seq_id) ~= nil
end

--- Check if redo is possible in the merged view.
function M.can_redo_merged(active_seq_id)
    return M.find_merged_redo_target(active_seq_id) ~= nil
end

--- Get the active sequence ID.
function M.get_active_sequence_id()
    return active_sequence_id
end

return M
