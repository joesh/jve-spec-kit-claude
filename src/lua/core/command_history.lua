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
local logger = require("core.logger")

-- Database connection
local db = nil

-- State tracking
local last_sequence_number = 0
local active_sequence_id = nil
local active_project_id = nil

-- Undo group tracking (Emacs-style)
local undo_group_stack = {}
local last_undo_group_id = 0

local GLOBAL_STACK_ID = "global"
local TIMELINE_STACK_PREFIX = "timeline:"

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
local current_branch_path = undo_stack_states[GLOBAL_STACK_ID].current_branch_path

local multi_stack_enabled = false
if os and os.getenv then
    multi_stack_enabled = os.getenv("JVE_ENABLE_MULTI_STACK_UNDO") == "1"
end

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
    active_project_id = project_id
    
    M.reset()

    -- Query last sequence number from database
    local query = db:prepare("SELECT MAX(sequence_number) FROM commands")
    assert(query, "CommandHistory.init: failed to prepare sequence_number query")
    local ok = query:exec()
    assert(ok, "CommandHistory.init: failed to execute sequence_number query")
    if query:next() then
        last_sequence_number = query:value(0) or 0
    end
    query:finalize()

    local global_state = M.ensure_stack_state(GLOBAL_STACK_ID)
    global_state.sequence_id = active_sequence_id
    M.set_active_stack(GLOBAL_STACK_ID, {sequence_id = active_sequence_id})
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

function M.increment_sequence_number()
    last_sequence_number = last_sequence_number + 1
    logger.debug("command_history", string.format("Assigned sequence number %d (current=%s)",
        last_sequence_number, tostring(current_sequence_number)))
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
    if not multi_stack_enabled then
        return GLOBAL_STACK_ID
    end
    if not sequence_id or sequence_id == "" then
        return GLOBAL_STACK_ID
    end
    return TIMELINE_STACK_PREFIX .. sequence_id
end

function M.resolve_stack_for_command(command)
    if not multi_stack_enabled then
        return GLOBAL_STACK_ID, nil
    end

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
            logger.warn("command_history", string.format("Stack resolver for %s threw error: %s",
                tostring(command.type), tostring(stack_info)))
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
            logger.warn("command_history", string.format(
                "Orphaned undo cursor: sequence %s has current_sequence_number=%d but command doesn't exist. Resetting to %s.",
                sequence_id, saved_value, last_sequence_number > 0 and tostring(last_sequence_number) or "nil"))
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
                logger.warn("command_history", string.format("Failed to decode command args JSON: %s", tostring(decoded)))
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

-- Undo group management (Emacs-style)
-- group_id is optional - if not provided, a unique ID is generated
-- When called from within a command executor, pass the parent command's sequence_number
function M.begin_undo_group(label, group_id)
    if not group_id then
        -- Generate a unique group ID when not provided
        last_undo_group_id = last_undo_group_id + 1
        group_id = "explicit_group_" .. last_undo_group_id
    end
    table.insert(undo_group_stack, {
        id = group_id,
        label = label or ("group_" .. tostring(group_id)),
        cursor_on_entry = current_sequence_number  -- Save cursor for rollback
    })
    logger.debug("command_history", string.format("Begin undo group %s: %s", tostring(group_id), label or ""))
    return group_id
end

function M.end_undo_group()
    if #undo_group_stack == 0 then
        -- NSF-OK: mismatch can happen if error unwinds during group; callers handle nil return
        logger.warn("command_history", "end_undo_group called with no active group")
        return nil
    end
    local group = table.remove(undo_group_stack)
    logger.debug("command_history", string.format("End undo group %s: %s", tostring(group.id), group.label))
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

return M
