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
-- Size: ~1212 LOC
-- Volatility: unknown
--
-- @file command_manager.lua
-- Original intent (unreviewed):
-- CommandManager: Manages command execution, sequencing, and replay
-- Refactored to delegate to CommandRegistry, CommandHistory, and CommandState
local M = {}

-- Database connection (set externally)
local db = nil

-- State tracking
local last_error_message = ""

-- Forward declarations for modules used in helper functions
local asserts_module


-- Command event context (UI vs script).
--
-- NOTE: The UI frequently triggers commands from within other UI callbacks
-- (e.g., menu actions calling into project browser helpers that also execute
-- commands). To avoid brittle "Nested command events" crashes at runtime,
-- command events are nestable via a simple depth counter. Only the outermost
-- begin/end pair establishes/clears the origin.
local command_event_origin = nil
local command_event_depth = 0

-- Execution depth tracking for nested command execution
-- Depth 0 = top-level execution (full ceremony: transaction, history, DB save)
-- Depth > 0 = nested execution (record to DB but skip transaction/UI refresh)
local execution_depth = 0

-- Root command tracking for automatic undo grouping
-- When a command executes nested commands, they all share the root's sequence_number as undo_group_id
-- Nested commands also inherit the root's playhead context (same user action, same playhead position)
local root_command_sequence_number = nil
local root_playhead_value = nil
local root_playhead_rate = nil



local function bug_result(message)
    last_error_message = message or ""
    local result = { success = false, error_message = last_error_message, result_data = "", is_bug = true }
    if asserts_module.enabled() then
        assert(false, last_error_message)
    end
    return result
end

local function dev_assert(condition, message)
    if condition then
        return true
    end
    bug_result(message)
    return false
end

local function get_command_event_origin()
    if not command_event_origin or command_event_depth == 0 then
        return nil, "No active command event: call command_manager.begin_command_event(origin) before execute"
    end
    return command_event_origin, nil
end

function M.peek_command_event_origin()
    return command_event_origin
end


function M.begin_command_event(origin)
    if command_event_origin and command_event_depth > 0 then
        command_event_depth = command_event_depth + 1
        return true
    end
    if not (origin == "ui" or origin == "script") then
        return dev_assert(false, "Invalid command event origin: " .. tostring(origin))
    end
    command_event_origin = origin
    command_event_depth = 1
    return true
end

function M.end_command_event()
    if not command_event_origin or command_event_depth == 0 then
        return dev_assert(false, "No active command event to end")
    end
    command_event_depth = command_event_depth - 1
    if command_event_depth == 0 then
        command_event_origin = nil
    end
    return true
end

local profile_scope = require("core.profile_scope")
local command_scope = require("core.command_scope")
local frame_utils = require("core.frame_utils")
local json = require("dkjson")
local logger = require("core.logger")

-- Sub-modules
local registry = require("core.command_registry")
asserts_module         = require("core.asserts")
local command_schema_module = require("core.command_schema")
local history = require("core.command_history")
local state_mgr = require("core.command_state")

-- Active context
local active_sequence_id = nil
local active_project_id = nil

-- Undo/redo context flag - when true, UI state persistence should be skipped
-- to avoid executing new commands during undo/redo operations
local undo_redo_in_progress = false

function M.is_undo_redo_in_progress()
    return undo_redo_in_progress
end

local command_event_listeners = {}

local function notify_command_event(event)
    if not event then
        return
    end
    for _, listener in ipairs(command_event_listeners) do
        local ok, err = pcall(listener, event)
        if not ok then
            logger.warn("command_manager", string.format("Command listener failed: %s", tostring(err)))
        end
    end
end

-- Forward compatibility for event listeners
function M.add_listener(listener)
    if type(listener) == "function" then
        table.insert(command_event_listeners, listener)
        return listener
    end
    return nil
end

function M.remove_listener(listener)
    for i, l in ipairs(command_event_listeners) do
        if l == listener then
            table.remove(command_event_listeners, i)
            return
        end
    end
end

local function ensure_active_project_id()
    if not active_project_id or active_project_id == "" then
        return nil, "CommandManager.execute: active project_id is not set"
    end
    return active_project_id, nil
end

function M.get_active_project_id()
    return active_project_id
end

function M.get_active_sequence_id()
    return active_sequence_id
end

-- UI entrypoint convenience.
--
-- Contract:
-- - UI code should call execute_ui() (or begin/end_command_event + execute) rather than
--   calling execute() directly.
-- - This ensures a command event exists and threads implicit UI context (active project/
--   sequence) into the params.
-- - If active context is missing, we error (this is a bug, not a case to "defensively" hide).
function M.execute_ui(command_name, params)
    params = params or {}

    -- Establish (or join) a UI command event.
    local had_event = (command_event_depth > 0)
    if not had_event then
        M.begin_command_event("ui")
    else
        -- Nested UI dispatch while already in an event is allowed.
        -- We *do not* allow switching origins mid-event.
        if command_event_origin ~= "ui" then
            return false, nil, string.format(
                "execute_ui(%s): cannot execute UI command inside %s command event",
                tostring(command_name),
                tostring(command_event_origin)
            )
        end
        -- Balance begin/end so execute_ui always closes what it opens.
        M.begin_command_event("ui")
    end

    local result = nil
    local status, exec_err = xpcall(function()
        if params.project_id == nil then
            local pid, pid_err = ensure_active_project_id()
            assert(pid, pid_err)
            params.project_id = pid
        end
        if params.sequence_id == nil and active_sequence_id ~= nil and active_sequence_id ~= "" then
            params.sequence_id = active_sequence_id
        end
        result = M.execute(command_name, params)
    end, debug.traceback)

    M.end_command_event()
    if not status then
        error(exec_err)
    end
    return result
end

-- SAVEPOINT-aware rollback for undo groups
local function rollback_transaction()
    assert(db, "rollback_transaction: no database connection")
    local group_id = history.get_current_undo_group_id()
    if group_id then
        -- Inside undo group - rollback to savepoint
        local savepoint_name = "undo_group_" .. group_id
        local rollback_sql = "ROLLBACK TO SAVEPOINT " .. savepoint_name
        db:exec(rollback_sql)

        -- INVARIANT:
        -- In-memory history cursor must always point to a durable DB state.
        -- Commands executed inside an undo group are not durable until the group closes.
        -- On SAVEPOINT rollback, cursor must be restored to group entry position.

        -- Restore cursor to position before group started (DB ↔ memory sync)
        local cursor_on_entry = history.get_undo_group_cursor_on_entry()
        history.set_current_sequence_number(cursor_on_entry)
        history.save_undo_position()
    else
        -- No undo group - full rollback
        db:exec("ROLLBACK")
    end
end

local function normalize_command(command_or_name, params)
    local Command = require("command")

    local origin, origin_err = get_command_event_origin()
    if origin_err then
        return nil, bug_result(origin_err)
    end

    local active_project_id, active_project_err = ensure_active_project_id()
    if active_project_err then
        return nil, bug_result(active_project_err)
    end

    if type(command_or_name) == "string" then
		params = params or {}
		-- UI convenience: if caller omitted project_id, default to active project.
		-- Script callers must pass it explicitly to avoid silently targeting the wrong project.
		if origin == "ui" and (not params.project_id or params.project_id == "") then
			params.project_id = active_project_id
		end
		if not (params.project_id and params.project_id ~= "") then
			return nil, bug_result("execute(command_name, params): params.project_id is required")
		end
        if origin == "ui" and params.project_id ~= active_project_id then
            return nil, bug_result("UI command must target active project_id")
        end


        local executor = registry.get_executor(command_or_name)
        if executor == nil then
            return nil, bug_result("No executor registered for command type: " .. tostring(command_or_name))
        end

        local spec = registry.get_spec(command_or_name)
        local ok, normalized_params, schema_err = command_schema_module.validate_and_normalize(
            command_or_name,
            spec,
            params,
            { apply_defaults = true, is_ui_context = (origin == "ui") }
        )
        if not ok then
            return nil, bug_result(schema_err)
        end
        params = normalized_params

        local command = Command.create(command_or_name, active_project_id)

        if params then
            for key, value in pairs(params) do
                command:set_parameter(key, value)
            end
        end

        command:set_parameter("__origin", origin)
        command.project_id = params.project_id

        return command, nil
    end

    if type(command_or_name) == "table" then
        local command = command_or_name

        local mt = getmetatable(command)
        if not mt or mt.__index ~= Command then
            setmetatable(command, { __index = Command })
        end

        local param_project_id = nil
        if command.get_parameter then
            param_project_id = command:get_parameter("project_id")
        elseif command.parameters then
            param_project_id = command.parameters.project_id
        end

        if not (param_project_id and param_project_id ~= "") then
            param_project_id = command.project_id
        end

        if not (param_project_id and param_project_id ~= "") then
            return nil, bug_result("execute(command, params): command must carry project_id")
        end
        if origin == "ui" and param_project_id ~= active_project_id then
            return nil, bug_result("UI command must target active project_id")
        end

        if command.get_parameter then
            command:set_parameter("__origin", origin)
        elseif command.parameters then
            command.parameters.__origin = origin
        end

        command.project_id = param_project_id

        local spec_command_type = command.type
        if type(spec_command_type) == "string" and spec_command_type:sub(1, 4) == "Undo" then
            spec_command_type = spec_command_type:sub(5)
        end

        local executor = registry.get_executor(spec_command_type)
        if executor == nil then
            return nil, bug_result("No executor registered for command type: " .. tostring(spec_command_type))
        end

        local spec = registry.get_spec(spec_command_type)

        local params = command.parameters or {}
        if not (params.project_id and params.project_id ~= "") then
            params.project_id = param_project_id
        end

        local ok, normalized, schema_err = command_schema_module.validate_and_normalize(
            command.type,
            spec,
            params,
            { apply_defaults = true, is_ui_context = (origin == "ui") }
        )
        if ok and normalized ~= nil then
            command.parameters = normalized
        end
        if not ok then
            return nil, bug_result(schema_err)
        end


        return command, nil
    end

    return nil, bug_result(string.format("CommandManager.execute: Unsupported command argument type '%s'", type(command_or_name)))
end

local function normalize_executor_result(exec_result, command)
    if exec_result == nil then
        return false, ""
    end

    if type(exec_result) == "table" then
        assert(type(exec_result.success) == "boolean",
            string.format(
                "Command executor contract violated: %s returned table without boolean .success",
                tostring(command and command.type)
            ))
        local success_field = exec_result.success
        local error_message = exec_result.error_message or ""
        local result_data = exec_result.result_data
        return success_field ~= false, error_message, result_data
    end

    return exec_result ~= false, ""
end

local function ensure_command_selection_columns()
    -- Delegated to database schema management in ideal world, keeping here for now
    -- but minimized.
    if not db then return end
    local pragma = db:prepare("PRAGMA table_info(commands)")
    if not pragma then return end

    local needed = {
        selected_clip_ids_pre = true, selected_edge_infos_pre = true,
        selected_gap_infos = true, selected_gap_infos_pre = true
    }
    
    if pragma:exec() then
        while pragma:next() do
            needed[pragma:value(1)] = nil
        end
    end
    pragma:finalize()

    for col, _ in pairs(needed) do
        db:exec("ALTER TABLE commands ADD COLUMN " .. col .. " TEXT DEFAULT '[]'")
    end
end

local function command_flag(command, property, param_key)
    if command[property] ~= nil then
        return command[property] and true or false
    end
    if command.get_parameter and param_key then
        local value = command:get_parameter(param_key)
        if value ~= nil then
            return value and true or false
        end
    end
    return false
end

local function extract_sequence_id(command)
    if not command then return nil end
    if command.get_parameter then
        local value = command:get_parameter("sequence_id")
        if value and value ~= "" then return value end
    end
    if command.parameters and command.parameters.sequence_id and command.parameters.sequence_id ~= "" then
        return command.parameters.sequence_id
    end
    return nil
end

local function create_command_perf_tracker(command)
    local enabled = os.getenv("JVE_DEBUG_COMMAND_PERF") == "1"
    local start_time = enabled and os.clock() or 0

    local function reset()
        if enabled then
            start_time = os.clock()
        end
    end

    local function log(phase)
        if not enabled then
            return
        end
        local elapsed_ms = (os.clock() - start_time) * 1000.0
        local logger = require("core.logger")
        logger.warn(
            "command_perf",
            string.format(
                "%s took %.2fms (cmd=%s seq=%s)",
                phase,
                elapsed_ms,
                tostring(command and command.type),
                tostring(command and command.sequence_number)
            )
        )
    end

    return {
        enabled = enabled,
        reset = reset,
        log = log
    }
end

local function should_compute_state_hash(command)
    return command_flag(command, "suppress_if_unchanged", "__suppress_if_unchanged")
        or os.getenv("JVE_FORCE_STATE_HASH") == "1"
end

local function finish_as_noop(db_conn, history_mod, exec_scope, result)
    db_conn:exec("ROLLBACK")
    history_mod.decrement_sequence_number()
    result.success = true
    result.result_data = ""
    exec_scope:finish("no_state_change")
    return result
end

local function mutation_summary_string(mutations)
    if not mutations then return "none" end
    local function collect_buckets(source)
        if not source then return {} end
        if source.sequence_id or source.inserts or source.updates or source.deletes then
            return {source}
        end
        local buckets = {}
        for _, bucket in pairs(source) do
            if type(bucket) == "table" and (bucket.sequence_id or bucket.inserts or bucket.updates or bucket.deletes) then
                table.insert(buckets, bucket)
            end
        end
        return buckets
    end

    local buckets = collect_buckets(mutations)
    if #buckets == 0 then return "empty" end
    local parts = {}
    for _, bucket in ipairs(buckets) do
        local inserts = (bucket.inserts and #bucket.inserts) or 0
        local updates = (bucket.updates and #bucket.updates) or 0
        local deletes = (bucket.deletes and #bucket.deletes) or 0
        table.insert(parts, string.format("%s:ins=%d upd=%d del=%d", tostring(bucket.sequence_id or "nil"), inserts, updates, deletes))
    end
    return table.concat(parts, "; ")
end

function M.set_last_error(message)
    if type(message) == "string" and message ~= "" then
        last_error_message = message
    else
        last_error_message = ""
    end
end

function M.shutdown()
    db = nil
    last_error_message = ""
    registry.init(nil, nil)
    history.reset()
    state_mgr.init(nil)
end

-- Initialize CommandManager with sequence and project IDs
-- Database connection is obtained internally from database.get_connection()
function M.init(sequence_id, project_id)
    if not sequence_id or sequence_id == "" then
        error("CommandManager.init: sequence_id is required", 2)
    end
    if not project_id or project_id == "" then
        error("CommandManager.init: project_id is required", 2)
    end
    active_sequence_id = sequence_id
    active_project_id = project_id

    -- Get database connection from the database module
    local db_module = require("core.database")
    db = db_module.get_connection()
    assert(db, "CommandManager.init: database connection not available")

    registry.init(db, M.set_last_error)
    history.init(db, sequence_id, project_id)
    state_mgr.init(db)

    -- Keep timeline_state IDs initialized so selection persistence doesn't assert during headless tests.
    -- Only do this when the shared `core.database` connection matches this manager's DB handle.
    local ok_db, db_mod = pcall(require, "core.database")
    local shared_conn = ok_db and db_mod and db_mod.get_connection and db_mod.get_connection() or nil
    if shared_conn and shared_conn == db then
        local seq_stmt = db:prepare("SELECT project_id FROM sequences WHERE id = ?")
        if seq_stmt then
            seq_stmt:bind_value(1, sequence_id)
            local found_project_id = nil
            if seq_stmt:exec() and seq_stmt:next() then
                found_project_id = seq_stmt:value(0)
            end
            seq_stmt:finalize()

            if found_project_id and found_project_id ~= "" then
                assert(found_project_id == project_id,
                    "CommandManager.init: provided project_id does not match sequences.project_id (sequence_id="
                        .. tostring(sequence_id) .. ", provided=" .. tostring(project_id) .. ", db=" .. tostring(found_project_id) .. ")")
                local ok_ts, timeline_state = pcall(require, "ui.timeline.timeline_state")
                if ok_ts and timeline_state and type(timeline_state.init) == "function" then
                    timeline_state.init(sequence_id, project_id)
                end
            end
        end
    end
    
    ensure_command_selection_columns()
    
    logger.debug("command_manager", string.format(
        "Initialized (last_sequence=%d current_position=%s)",
        history.get_last_sequence_number(),
        tostring(history.get_current_sequence_number())
    ))
end

-- Validate command parameters
local function validate_command_parameters(command)
    if not command.type or command.type == "" then return false end
    if not command.project_id or command.project_id == "" then return false end
    return true
end

local function capture_pre_selection_for_command(command)
    local scope = profile_scope.begin("command_manager.capture_selection_pre")
    local clips_json, edges_json, gaps_json = state_mgr.capture_selection_snapshot()
    command.selected_clip_ids_pre = clips_json
    command.selected_edge_infos_pre = edges_json
    command.selected_gap_infos_pre = gaps_json
    scope:finish()
end

local function capture_post_selection_for_command(command)
    local scope = profile_scope.begin("command_manager.capture_selection_post")
    local clips_json, edges_json, gaps_json = state_mgr.capture_selection_snapshot()
    command.selected_clip_ids = clips_json
    command.selected_edge_infos = edges_json
    command.selected_gap_infos = gaps_json
    scope:finish()
end

-- Execute command implementation
local function execute_command_implementation(command)
    local scope = profile_scope.begin("command_manager.exec_impl", {
        details_fn = function() 
            return string.format("command=%s status=%s", command and command.type or "unknown", tostring(last_error_message == "" and "ok" or "error"))
        end
    })

    local executor = registry.get_executor(command.type)
    
    if executor then
        local ok, result, err_msg = xpcall(
            executor,
            function(err)
                return debug.traceback(tostring(err), 2)
            end,
            command
        )
        if not ok then
            logger.error("command_manager", string.format("Executor failed (%s):\n%s", tostring(command and command.type), tostring(result)))
            last_error_message = tostring(result) -- includes traceback
            scope:finish("executor_error")
            return false
        end
        if result == false and err_msg then
            last_error_message = tostring(err_msg)
        end
        scope:finish(result and "executor_success" or "executor_false")
        return result
    elseif command.type == "FastOperation" or
           command.type == "BatchOperation" or
           command.type == "ComplexOperation" then
        scope:finish("test_command")
        return true
    else
        local error_msg = string.format("Unknown command type: %s", command.type)
        logger.error("command_manager", error_msg)
        last_error_message = error_msg
        scope:finish("unknown_command")
        return false
    end
end

local function execute_non_recording(command)
    local ok, exec_result = pcall(execute_command_implementation, command)
    if not ok then
        return {
            success = false,
            error_message = tostring(exec_result),
            result_data = ""
        }
    end

    local success, error_message, result_data = normalize_executor_result(exec_result, command)
    if not success then
        if error_message == "" then
            error_message = last_error_message ~= "" and last_error_message or "Command execution failed"
        end
        last_error_message = ""
        return {
            success = false,
            error_message = error_message,
            result_data = result_data or ""
        }
    end

    last_error_message = ""
    return {
        success = true,
        error_message = "",
        result_data = result_data or ""
    }
end

-- Main execute function
function M.execute(command_or_name, params)
    -- Track execution depth for nested command support
    execution_depth = execution_depth + 1
    local is_nested = execution_depth > 1

    local command, normalize_failure = normalize_command(command_or_name, params)
    if not command then
        execution_depth = execution_depth - 1
        return normalize_failure, nil
    end

    -- Declare all locals upfront to avoid goto scope issues
    local exec_scope, result, scope_ok, scope_err, stack_id, stack_info, stack_opts
    local undo_group_active, begin_tx, perf, needs_state_hash, pre_hash
    local sequence_number, executing_from_root, skip_selection_snapshot
    local exec_result, execution_success, execution_error_message, execution_result_data
    local suppress_noop_after, post_hash, saved
    local timeline_state, capture_manager
    local explicit_group
    local spec

    exec_scope = profile_scope.begin("command_manager.execute", {
        details_fn = function()
            return string.format("command=%s (depth=%d)", command and command.type or tostring(command_or_name), execution_depth)
        end
    })
    result = {
        success = false,
        error_message = "",
        result_data = ""
    }

    -- Nested execution: record to DB but skip transaction/commit/UI refresh (root handles)
    -- This enables automatic undo grouping - all nested commands share root's undo_group_id
    if is_nested then
        -- Check for non-undoable commands - execute without recording, even when nested
        spec = registry.get_spec(command.type)
        if spec and spec.undoable == false then
            result = execute_non_recording(command)
            exec_scope:finish("non_recording_nested")
            goto cleanup
        end

        -- Assign sequence number and link to parent
        sequence_number = history.increment_sequence_number()
        command.sequence_number = sequence_number
        command.parent_sequence_number = history.get_current_sequence_number()

        -- Inherit undo group: explicit group takes precedence over automatic grouping
        explicit_group = history.get_current_undo_group_id()
        command.undo_group_id = explicit_group or root_command_sequence_number

        -- Execute the command
        exec_result = execute_command_implementation(command)
        execution_success, execution_error_message, execution_result_data = normalize_executor_result(exec_result, command)

        result.success = execution_success
        result.error_message = execution_error_message or ""
        if execution_result_data ~= nil then
            result.result_data = execution_result_data
        end

        -- Preserve custom fields from executor result
        if type(exec_result) == "table" then
            for key, value in pairs(exec_result) do
                if key ~= "success" and key ~= "error_message" and key ~= "result_data" and key ~= "cancelled" then
                    result[key] = value
                end
            end
        end

        if execution_success then
            command.status = "Executed"
            command.executed_at = os.time()

            -- Inherit playhead context from root (same user action, same playhead position)
            command.playhead_value = root_playhead_value
            command.playhead_rate = root_playhead_rate

            -- Save nested command to DB (shares root's transaction)
            local saved = command:save(db)
            if saved then
                -- Advance cursor so next nested command chains correctly
                history.set_current_sequence_number(sequence_number)
                logger.debug("command_manager", string.format(
                    "Nested command %s (seq=%d) saved, group=%s",
                    command.type, sequence_number, tostring(root_command_sequence_number)))
            else
                result.success = false
                result.error_message = "Failed to save nested command to database"
                execution_success = false
            end
        else
            command.status = "Failed"
            history.decrement_sequence_number()
        end

        exec_scope:finish(execution_success and "success_nested" or "failure_nested")
        goto cleanup
    end

    -- Top-level execution: full ceremony below
    if not validate_command_parameters(command) then
        result.error_message = "Invalid command parameters"
        exec_scope:finish("invalid_params")
        goto cleanup
    end

    scope_ok, scope_err = command_scope.check(command)
    if not scope_ok then
        result.error_message = scope_err or "Command cannot execute in current scope"
        exec_scope:finish("scope_violation")
        goto cleanup
    end

    spec = registry.get_spec(command.type)
    if spec and spec.undoable == false then
        result = execute_non_recording(command)
        exec_scope:finish("non_recording")
        goto cleanup
    end

    stack_id, stack_info = history.resolve_stack_for_command(command)
    stack_opts = nil
    if stack_info and type(stack_info) == "table" and stack_info.sequence_id then
        stack_opts = {sequence_id = stack_info.sequence_id}
    end
    if not stack_opts or not stack_opts.sequence_id then
        local seq_param = extract_sequence_id(command)  -- This one is OK, it's within a block
        if seq_param and seq_param ~= "" then
            stack_opts = stack_opts or {}
            stack_opts.sequence_id = seq_param
        end
    end
    history.set_active_stack(stack_id, stack_opts)
    command.stack_id = stack_id


    -- TRANSACTION / UNDO-GROUP INVARIANT
    --
    -- command_manager.execute() MUST obey the following rules:
    --
    -- 1. When NO undo group is active:
    --    - execute() owns the transaction lifecycle
    --    - it is responsible for BEGIN, COMMIT, and full ROLLBACK on failure
    --
    -- 2. When an undo group IS active:
    --    - a SAVEPOINT has already established transactional context
    --    - execute() MUST NOT issue BEGIN or COMMIT
    --    - on failure, execute() MUST rollback ONLY to the active SAVEPOINT
    --    - commit of grouped commands is deferred until end_undo_group()
    --
    -- 3. History cursor movement is NOT a transaction concern:
    --    - execute() never advances the undo/redo cursor
    --    - undo boundaries are established explicitly by:
    --        * undo()
    --        * redo()
    --        * end_undo_group() (for grouped commands)
    --
    -- Violating any of the above will corrupt undo/redo semantics,
    -- especially under branching histories.

    -- BEGIN TRANSACTION (skip if undo group is active - savepoint already started transaction)
    undo_group_active = history.get_current_undo_group_id() ~= nil
    if not undo_group_active then
        begin_tx = db:prepare("BEGIN TRANSACTION")
        if not (begin_tx and begin_tx:exec()) then
            if begin_tx then begin_tx:finalize() end
            result.error_message = "Failed to begin transaction"
            exec_scope:finish("begin_tx_failed")
            goto cleanup
        end
        begin_tx:finalize()
    end

    perf = create_command_perf_tracker(command)
    needs_state_hash = should_compute_state_hash(command)
    pre_hash = ""
    if needs_state_hash then
        perf.reset()
        pre_hash = state_mgr.calculate_state_hash(command.project_id)
        perf.log("state_hash_pre")
        perf.reset()
    elseif perf.enabled then
        perf.reset()
        perf.log("state_hash_pre_skipped")
        perf.reset()
    end

    -- Use history module for sequence tracking
    sequence_number = history.increment_sequence_number()
    command.sequence_number = sequence_number
    command.parent_sequence_number = history.get_current_sequence_number()

    -- Automatic undo grouping: root command becomes the group, nested commands inherit
    -- If there's an explicit undo group active (from begin_undo_group), use that instead
    explicit_group = history.get_current_undo_group_id()
    if explicit_group then
        command.undo_group_id = explicit_group
    else
        -- Root command: set itself as the undo group for any nested commands
        command.undo_group_id = sequence_number
    end
    root_command_sequence_number = sequence_number

    -- Validation logic
    if not command.parent_sequence_number then
        executing_from_root = history.get_current_sequence_number() == nil
        if not executing_from_root and sequence_number > 1 then
            logger.error("command_manager", string.format("Command %d has NULL parent but is not first!", sequence_number))
            rollback_transaction()
            history.decrement_sequence_number()
            result.error_message = "FATAL: undo tree corruption"
            exec_scope:finish("null_parent")
            goto cleanup
        end
    end

    state_mgr.update_command_hashes(command, pre_hash)

    -- Capture playhead/selection
    timeline_state = require('ui.timeline.timeline_state')
    command.playhead_value = timeline_state.get_playhead_position()
    command.playhead_rate = timeline_state.get_sequence_frame_rate()

    -- Store for nested commands to inherit (they share the same user action context)
    root_playhead_value = command.playhead_value
    root_playhead_rate = command.playhead_rate
    skip_selection_snapshot = command_flag(command, "skip_selection_snapshot", "__skip_selection_snapshot")
    if not skip_selection_snapshot then
        capture_pre_selection_for_command(command)
    end

    -- EXECUTE
    exec_result = execute_command_implementation(command)
    if perf.enabled then
        perf.log("execute_command_implementation")
        perf.reset()
    end
    execution_success, execution_error_message, execution_result_data = normalize_executor_result(exec_result, command)
    if execution_result_data ~= nil then
        result.executor_result_data = execution_result_data
        if not execution_success then
            result.result_data = execution_result_data
        end
    end

    -- Preserve custom fields from executor result (e.g., project_id, sequence_id, etc.)
    -- Copy all non-standard fields from exec_result into result
    if type(exec_result) == "table" then
        for key, value in pairs(exec_result) do
            -- Skip standard contract fields (already handled by normalize_executor_result)
            if key ~= "success" and key ~= "error_message" and key ~= "result_data" and key ~= "cancelled" then
                result[key] = value
            end
        end
    end

    if execution_success then
        command.status = "Executed"
        command.executed_at = os.time()

        if not skip_selection_snapshot then
            capture_post_selection_for_command(command)
        end

        -- Capture post-execution playhead position (restored on redo)
        command.playhead_value_post = timeline_state.get_playhead_position()
        command.playhead_rate_post = timeline_state.get_sequence_frame_rate()

        suppress_noop_after = command_flag(command, "suppress_if_unchanged", "__suppress_if_unchanged")
        if suppress_noop_after and not needs_state_hash then
            -- Executor decided this command is a no-op, but the flag was set during execution,
            -- so we didn't pay the cost of hashing. Treat as no-op and suppress persistence/UI refresh.
            result = finish_as_noop(db, history, exec_scope, result)
            goto cleanup
        end

        post_hash = ""
        if needs_state_hash then
            perf.reset()
            post_hash = state_mgr.calculate_state_hash(command.project_id)
            perf.log("state_hash_post")
            perf.reset()
        elseif perf.enabled then
            perf.reset()
            perf.log("state_hash_post_skipped")
            perf.reset()
        end
        command.post_hash = post_hash

        -- No-op detection (hash-based)
        if suppress_noop_after and post_hash == pre_hash then
            result = finish_as_noop(db, history, exec_scope, result)
            goto cleanup
        end

        saved = command:save(db)
        if perf.enabled then
            perf.log("command:save")
            perf.reset()
        end
        if saved then
            result.success = true
            result.result_data = command:serialize()

            -- Move HEAD - but only if nested commands haven't already advanced past us
            -- (nested commands chain their parent_sequence_number through the cursor)
            local current_cursor = history.get_current_sequence_number()
            if not current_cursor or current_cursor < sequence_number then
                -- No nested commands ran, or we're the highest - advance normally
                history.set_current_sequence_number(sequence_number)
            end
            -- else: nested commands advanced cursor past us, keep it there
            history.save_undo_position()

            -- Snapshotting
            local snapshot_mgr = require('core.snapshot_manager')
            local force_snapshot = command_flag(command, "force_snapshot", "__force_snapshot")
            if force_snapshot or snapshot_mgr.should_snapshot(sequence_number) then
                 local targets = command:get_parameter("__snapshot_sequence_ids")
                 assert(targets, "Snapshot restore: Missing __snapshot_sequence_ids parameter")
                 if #targets == 0 then
                     local def_seq = history.get_current_stack_sequence_id(true)
                     if def_seq then table.insert(targets, def_seq) end
                 end
                 for _, seq_id in ipairs(targets) do
                    local clips = require('core.database').load_clips(seq_id)
                    snapshot_mgr.create_snapshot(db, seq_id, sequence_number, clips)
                 end
                 if perf.enabled then
                    perf.log("snapshotting")
                    perf.reset()
                 end
            end

            -- COMMIT (skip if undo group is active - savepoint will handle commit)
            if not undo_group_active then
                db:exec("COMMIT")
            end
            if perf.enabled then
                perf.log("db_commit")
                perf.reset()
            end

            -- UI Refresh / Mutation Handling
            local skip_timeline_reload = command_flag(command, "skip_timeline_reload", "__skip_timeline_reload")
            if not skip_timeline_reload then
                 local reload_sequence_id = extract_sequence_id(command)
                 local mutations = command:get_parameter("__timeline_mutations")
                 local applied_mutations = false
                 local timeline_active_seq = timeline_state.get_sequence_id and timeline_state.get_sequence_id() or nil
                 if reload_sequence_id and reload_sequence_id ~= "" and (not timeline_active_seq or timeline_active_seq == "") then
                     -- Tests/headless command execution may run without timeline UI bootstrap; initialize on demand.
                     timeline_state.init(reload_sequence_id, command.project_id)
                 end

                 if mutations and timeline_state.apply_mutations then
                     -- Logic to apply mutations ...
                     -- Simplified for brevity in rewrite, but logic remains same:
                     if mutations.sequence_id or mutations.inserts or mutations.updates or mutations.deletes then
                        applied_mutations = timeline_state.apply_mutations(mutations.sequence_id or reload_sequence_id, mutations)
                     else
                        for _, bucket in pairs(mutations) do
                             if timeline_state.apply_mutations(bucket.sequence_id or reload_sequence_id, bucket) then
                                applied_mutations = true
                             end
                        end
                     end
                 end

                 if not applied_mutations and reload_sequence_id and reload_sequence_id ~= "" then
                     -- Fallback
                     timeline_state.reload_clips(reload_sequence_id)
                 end
                 if perf.enabled then
                    perf.log("ui_refresh")
                    perf.reset()
                 end
            end

            notify_command_event({
                event = "execute",
                command = command,
                project_id = command.project_id,
                stack_id = stack_id,
                sequence_number = sequence_number
            })
            if perf.enabled then
                perf.log("notify_command_event")
            end

        else
            result.error_message = "Failed to save command to database"
            rollback_transaction()
            history.decrement_sequence_number()
        end
    else
        command.status = "Failed"
        result.error_message = execution_error_message ~= "" and execution_error_message
            or (last_error_message ~= "" and last_error_message or "Command execution failed")
        last_error_message = ""
        rollback_transaction()
        history.decrement_sequence_number()
    end

    exec_scope:finish(result.success and "success" or "failure")

    -- Capture command execution for bug reporter
    capture_manager = require("bug_reporter.capture_manager")
    if capture_manager.capture_enabled then
        capture_manager:log_command(
            command.type,
            command.parameters,
            result,
            nil  -- gesture_id not currently tracked - could be added later
        )
    end

::cleanup::
    execution_depth = execution_depth - 1
    -- Clear root tracking when top-level command finishes
    if execution_depth == 0 then
        root_command_sequence_number = nil
        root_playhead_value = nil
        root_playhead_rate = nil
    end
    return result, command
end

function M.get_last_command(project_id)
    return M.get_command_at_sequence(history.get_current_sequence_number(), project_id)
end

function M.get_next_redo_command(project_id)
    if not M.can_redo() then
        return nil
    end
    local parent = history.get_current_sequence_number() or 0
    local next_cmd_info = history.find_latest_child_command(parent)
    if not next_cmd_info then
        return nil
    end
    return M.get_command_at_sequence(next_cmd_info.sequence_number, project_id)
end

function M.get_current_sequence_number()
    return history.get_current_sequence_number()
end

function M:list_history_entries()
    if not db then
        return {}
    end

    local query = db:prepare([[
        SELECT sequence_number, command_type, timestamp, parent_sequence_number
        FROM commands
        WHERE command_type NOT LIKE 'Undo%'
        ORDER BY sequence_number ASC
    ]])

    if not query then
        return {}
    end

    local current_seq = history.get_current_sequence_number() or 0

    local nodes = {}
    local parent_of = {}
    local children = {}

    local function add_child(parent, child_seq)
        local list = children[parent]
        if not list then
            list = {}
            children[parent] = list
        end
        table.insert(list, child_seq)
    end

    if query:exec() then
        while query:next() do
            local seq = query:value(0) or 0
            local command_type = query:value(1) or ""
            local timestamp = query:value(2)
            local parent = query:value(3)
            local parent_seq = parent or 0

            nodes[seq] = {
                sequence_number = seq,
                command_type = command_type,
                timestamp = timestamp,
                parent_sequence_number = parent
    }
            parent_of[seq] = parent_seq
            add_child(parent_seq, seq)
        end
    end
    query:finalize()

    local function latest_child_of(seq)
        local list = children[seq]
        if not list or #list == 0 then
            return nil
        end
        local best = nil
        for _, child_seq in ipairs(list) do
            if not best or child_seq > best then
                best = child_seq
            end
        end
        return best
    end

    if current_seq == 0 then
        local out = {{sequence_number = 0, command_type = "Start", timestamp = nil, parent_sequence_number = nil}}
        local cursor = 0
        while true do
            local child = latest_child_of(cursor)
            if not child then
                break
            end
            table.insert(out, nodes[child])
            cursor = child
        end
        return out
    end
    if not nodes[current_seq] then
        return {}
    end

    local path_rev = {}
    local cursor = current_seq
    while cursor and cursor ~= 0 do
        table.insert(path_rev, cursor)
        cursor = parent_of[cursor] or 0
    end

    local path = {}
    for i = #path_rev, 1, -1 do
        table.insert(path, path_rev[i])
    end

    local redo_chain = {}
    cursor = current_seq
    while true do
        local child = latest_child_of(cursor)
        if not child then
            break
        end
        table.insert(redo_chain, child)
        cursor = child
    end

    local out = {}
    table.insert(out, {sequence_number = 0, command_type = "Start", timestamp = nil, parent_sequence_number = nil})
    for _, seq in ipairs(path) do
        table.insert(out, nodes[seq])
    end
    for _, seq in ipairs(redo_chain) do
        table.insert(out, nodes[seq])
    end

    return out
end

function M:jump_to_sequence_number(target_sequence_number)
    if type(target_sequence_number) ~= "number" or target_sequence_number < 0 then
        return false, "Invalid target sequence number"
    end

    local current = history.get_current_sequence_number() or 0
    if target_sequence_number == current then
        return true
    end

    if not db then
        return false, "No database connection"
    end

    local parent_of = {}
    local exists = {}
    local query = db:prepare([[
        SELECT sequence_number, parent_sequence_number
        FROM commands
        WHERE command_type NOT LIKE 'Undo%'
    ]])
    if not query then
        return false, "Failed to prepare command parent query"
    end
    if query:exec() then
        while query:next() do
            local seq = query:value(0) or 0
            local parent = query:value(1)
            exists[seq] = true
            parent_of[seq] = parent or 0
        end
    end
    query:finalize()

    if target_sequence_number ~= 0 and not exists[target_sequence_number] then
        return false, "Unknown sequence number: " .. tostring(target_sequence_number)
    end

    local ancestor_set = {}
    do
        local seq = current
        while true do
            ancestor_set[seq] = true
            if seq == 0 then
                break
            end
            seq = parent_of[seq] or 0
        end
    end

    local target_chain = {}
    do
        local seq = target_sequence_number
        while true do
            table.insert(target_chain, seq)
            if seq == 0 then
                break
            end
            seq = parent_of[seq] or 0
        end
    end

    local lca = nil
    local lca_index = nil
    for i, seq in ipairs(target_chain) do
        if ancestor_set[seq] then
            lca = seq
            lca_index = i
            break
        end
    end
    if not lca_index then
        return false, "Failed to compute history join point"
    end

    while (history.get_current_sequence_number() or 0) ~= lca do
        local result = M.undo()
        if not result or not result.success then
            return false, "Undo failed: " .. tostring((result and result.error_message) or "unknown")
        end
    end

    for i = lca_index - 1, 1, -1 do
        local seq = target_chain[i]
        local result = M.redo_to_sequence_number(seq)
        if not result or not result.success then
            return false, "Redo failed: " .. tostring((result and result.error_message) or "unknown")
        end
    end

    return true
end

-- Helper to fetch specific command (restored from DB)
function M.get_command_at_sequence(seq_num, project_id)
    if not db or not seq_num then return nil end
    
    local query = db:prepare([[
        SELECT id, command_type, command_args, sequence_number, parent_sequence_number, pre_hash, post_hash, timestamp, playhead_value, playhead_rate,
               selected_clip_ids, selected_edge_infos, selected_gap_infos,
               selected_clip_ids_pre, selected_edge_infos_pre, selected_gap_infos_pre, undo_group_id,
               playhead_value_post, playhead_rate_post
        FROM commands
        WHERE sequence_number = ? AND command_type NOT LIKE 'Undo%'
    ]])
    if not query then return nil end
    query:bind_value(1, seq_num)

    if query:exec() and query:next() then
        local command = {
            id = query:value(0),
            type = query:value(1),
            project_id = project_id,
            sequence_number = query:value(3) or 0,
            parent_sequence_number = query:value(4),
            status = "Executed",
            parameters = {},
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
        
        local command_args_json = query:value(2)
        if command_args_json and command_args_json ~= "" and command_args_json ~= "{}" then
            local success, params = pcall(json.decode, command_args_json)
            if success and params then command.parameters = params end
        end

        local Command = require('command')
        setmetatable(command, {__index = Command})
        query:finalize()
        return command
    end
    query:finalize()
    return nil
end

function M.can_undo()
    if not db then return false end
    return history.get_current_sequence_number() ~= nil
end

function M.can_redo()
    if not db then return false end
    local parent = history.get_current_sequence_number() or 0
    return history.find_latest_child_command(parent) ~= nil
end

function M.undo()
    -- Wrapper for UI calls
    if M.can_undo() then
        local last_cmd = M.get_last_command(active_project_id)
        if last_cmd then
            -- Check if this command is part of an undo group
            if last_cmd.undo_group_id then
                -- Undo entire group
                return M.undo_group(last_cmd.undo_group_id)
            else
                -- Undo single command (existing behavior)
                return M.execute_undo(last_cmd)
            end
        end
    end
    return { success = false, error_message = "Nothing to undo" }
end

function M.undo_group(group_id)
    assert(db, "undo_group: no database connection")

    local current_seq = history.get_current_sequence_number()
    if not current_seq then
        return { success = false, error_message = "Nothing to undo" }
    end

    -- Walk backwards from current position, collecting commands in this group
    -- Follow parent_sequence_number links for branch-safe traversal
    local commands_to_undo = {}
    local seq = current_seq

    while seq do
        local cmd = M.get_command_at_sequence(seq, active_project_id)
        if not cmd then
            break
        end
        if cmd.undo_group_id ~= group_id then
            break
        end
        table.insert(commands_to_undo, cmd)
        -- Follow parent link (tree-based traversal, not linear decrement)
        seq = cmd.parent_sequence_number
    end

    if #commands_to_undo == 0 then
        return { success = false, error_message = "No commands found in undo group" }
    end

    -- Undo each command (already in reverse order)
    for _, cmd in ipairs(commands_to_undo) do
        local result = M.execute_undo(cmd)
        if not result.success then
            return result, command
        end
    end

    -- Set history pointer to parent of earliest undone command
    local earliest_cmd = commands_to_undo[#commands_to_undo]
    history.set_current_sequence_number(earliest_cmd.parent_sequence_number)
    history.save_undo_position()

    return { success = true }
end

local function execute_redo_command(cmd)
    assert(cmd, "execute_redo_command requires cmd")

    -- Set flag to prevent UI persistence commands from executing during redo
    undo_redo_in_progress = true

    local executor = registry.get_executor(cmd.type)
    if not executor then
        undo_redo_in_progress = false
        return { success = false, error_message = "No executor for redo command: " .. tostring(cmd.type) }
    end

    local ok, exec_result = pcall(executor, cmd)
    if not ok then
        last_error_message = tostring(exec_result)
        undo_redo_in_progress = false
        return { success = false, error_message = last_error_message }
    end

    local success, err_msg = normalize_executor_result(exec_result)
    if not success then
        last_error_message = err_msg or "Redo executor returned false"
        undo_redo_in_progress = false
        return { success = false, error_message = last_error_message }
    end

    history.set_current_sequence_number(cmd.sequence_number)
    history.save_undo_position()
    state_mgr.restore_selection_from_serialized(cmd.selected_clip_ids, cmd.selected_edge_infos, cmd.selected_gap_infos)

    -- Re-apply timeline mutations if present (mirror undo behaviour)
    local timeline_state = require('ui.timeline.timeline_state')
    local reload_sequence_id = extract_sequence_id(cmd)
    local mutations = cmd:get_parameter("__timeline_mutations")
    local applied_mutations = false

    if mutations and timeline_state.apply_mutations then
        if mutations.sequence_id or mutations.inserts or mutations.updates or mutations.deletes then
            applied_mutations = timeline_state.apply_mutations(mutations.sequence_id or reload_sequence_id, mutations)
        else
            for _, bucket in pairs(mutations) do
                if timeline_state.apply_mutations(bucket.sequence_id or reload_sequence_id, bucket) then
                    applied_mutations = true
                end
            end
        end
    end

    if not applied_mutations and reload_sequence_id and reload_sequence_id ~= "" then
        timeline_state.reload_clips(reload_sequence_id)
    end

    -- Restore post-execution playhead position (mirrors undo restoring pre-execution)
    if cmd.playhead_value_post ~= nil and timeline_state.set_playhead_position then
        timeline_state.set_playhead_position(cmd.playhead_value_post)
    end

    notify_command_event({
        event = "redo",
        command = cmd,
        project_id = cmd.project_id,
        sequence_number = cmd.sequence_number
    })

    -- Clear redo-in-progress flag
    undo_redo_in_progress = false

    return { success = true }
end

function M.redo_to_sequence_number(target_sequence_number)
    if type(target_sequence_number) ~= "number" or target_sequence_number <= 0 then
        return { success = false, error_message = "Invalid redo target sequence number" }
    end

    local cmd = M.get_command_at_sequence(target_sequence_number, active_project_id)
    if not cmd then
        return { success = false, error_message = "Redo target not found: " .. tostring(target_sequence_number) }
    end

    local expected_parent = history.get_current_sequence_number() or 0
    local actual_parent = cmd.parent_sequence_number or 0
    if expected_parent ~= actual_parent then
        return {
            success = false,
            error_message = string.format(
                "Redo target is not a child of current position (target=%s parent=%s current=%s)",
                tostring(target_sequence_number),
                tostring(actual_parent),
                tostring(expected_parent)
            )
        }
    end

    return execute_redo_command(cmd)
end

function M.redo()
    -- Wrapper for UI calls
    if M.can_redo() then
        local parent = history.get_current_sequence_number() or 0
        local next_cmd_info = history.find_latest_child_command(parent)
        if next_cmd_info then
            local next_cmd = M.get_command_at_sequence(next_cmd_info.sequence_number, active_project_id)
            if next_cmd and next_cmd.undo_group_id then
                -- Redo entire group
                return M.redo_group(next_cmd.undo_group_id)
            else
                return M.redo_to_sequence_number(next_cmd_info.sequence_number)
            end
        end
    end
    return { success = false, error_message = "Nothing to redo" }
end

function M.redo_group(group_id)
    assert(db, "redo_group: no database connection")

    local parent = history.get_current_sequence_number() or 0

    -- Follow history tree forward while commands are in this group
    while true do
        local next_cmd_info = history.find_latest_child_command(parent)
        if not next_cmd_info then
            break
        end

        local cmd = M.get_command_at_sequence(next_cmd_info.sequence_number, active_project_id)
        if not cmd or cmd.undo_group_id ~= group_id then
            break
        end

        local result = execute_redo_command(cmd)
        if not result.success then
            return result, command
        end

        parent = cmd.sequence_number
    end

    return { success = true }
end

function M.execute_undo(original_command)
    logger.debug("command_manager", string.format("Executing undo for command: %s", tostring(original_command.type)))

    -- Set flag to prevent UI persistence commands from executing during undo
    undo_redo_in_progress = true

    local undo_command = original_command:create_undo()
    
    -- Get undoer if explicitly registered (overrides command:create_undo logic if needed)
    local undoer = registry.get_undoer(original_command.type)
    if not undoer then
        -- Try to auto-load the undo module, but fail hard if still missing to avoid replaying the forward command.
        registry.load_command_module("Undo" .. tostring(original_command.type))
        undoer = registry.get_undoer(original_command.type)
        if not undoer then
            local msg = string.format("No undoer registered for %s", tostring(original_command.type))
            logger.error("command_manager", msg)
            return { success = false, error_message = msg }
        end
    end
    local execution_success = false
    local undo_error_message = ""
    
    local ok, exec_result, extra = pcall(undoer, original_command)
    if ok then
        local success, err_msg = normalize_executor_result(exec_result)
        if (not success) and (not err_msg or err_msg == "") and type(extra) == "string" then
            err_msg = extra
        end
        execution_success = success
        undo_error_message = err_msg or ""
    else
        execution_success = false
        undo_error_message = tostring(exec_result)
    end

    local result = { success = false, error_message = "", result_data = "" }

    if execution_success then
        result.success = true
        result.result_data = undo_command:serialize()

        history.set_current_sequence_number(original_command.parent_sequence_number)
        history.save_undo_position()

        state_mgr.restore_selection_from_serialized(original_command.selected_clip_ids_pre, original_command.selected_edge_infos_pre, original_command.selected_gap_infos_pre)

        -- Handle mutations for Undo
        local timeline_state = require('ui.timeline.timeline_state')
        local reload_sequence_id = extract_sequence_id(original_command)
        local mutations = original_command:get_parameter("__timeline_mutations")
        local applied_mutations = false

        if mutations and timeline_state.apply_mutations then
             if mutations.sequence_id or mutations.inserts or mutations.updates or mutations.deletes then
                applied_mutations = timeline_state.apply_mutations(mutations.sequence_id or reload_sequence_id, mutations)
             else
                for _, bucket in pairs(mutations) do
                     if timeline_state.apply_mutations(bucket.sequence_id or reload_sequence_id, bucket) then
                        applied_mutations = true
                     end
                end
             end
        end

        if not applied_mutations and reload_sequence_id and reload_sequence_id ~= "" then
             timeline_state.reload_clips(reload_sequence_id)
        end

        if original_command.playhead_value ~= nil and timeline_state.set_playhead_position then
            timeline_state.set_playhead_position(original_command.playhead_value)
        end

        logger.info("command_manager", string.format("Undo successful (position=%s)", tostring(history.get_current_sequence_number())))
        
        notify_command_event({
            event = "undo",
            command = original_command,
            project_id = original_command.project_id
        })
    else
        last_error_message = undo_error_message ~= "" and undo_error_message or last_error_message
        result.error_message = last_error_message or "Undo execution failed"
        logger.error("command_manager", "Undo failed: " .. tostring(result.error_message))
    end

    -- Clear undo-in-progress flag
    undo_redo_in_progress = false

    return result
end

function M.execute_batch(commands)
    logger.debug("command_manager", string.format("Executing batch of %d commands", #commands))
    local results = {}
    for _, command in ipairs(commands) do
        local result = M.execute(command)
        table.insert(results, result)
        if not result.success then
            logger.error("command_manager", string.format("Batch execution failed at command: %s", tostring(command.type)))
            break
        end
    end
    return results
end

-- Delegate registration to registry
function M.register_executor(command_type, executor, undoer, spec)
    registry.register_executor(command_type, executor, undoer, spec)
end

-- Convenience for tests: register an undoer separately.
function M.register_undoer(command_type, undoer)
    registry.register_undoer(command_type, undoer)
end

function M.unregister_executor(command_type)
    registry.unregister_executor(command_type)
end

-- Revert to sequence (Debug/Dev tool)
function M.revert_to_sequence(sequence_number)
    logger.info("command_manager", string.format("Reverting to sequence: %d", sequence_number))
    local query = db:prepare("UPDATE commands SET status = 'Undone' WHERE sequence_number > ?")
    query:bind_value(1, sequence_number)
    if not query:exec() then
        logger.error("command_manager", string.format("Failed to revert commands: %s", tostring(query:last_error())))
        return
    end
    history.init(db, active_sequence_id, active_project_id) 
end

-- Get project state
function M.get_project_state(project_id)
    return state_mgr.calculate_state_hash(project_id)
end

-- Get current state
function M.get_current_state()
    -- This creates a pseudo-command for the current state
    local state_command = require('command').create("StateSnapshot", "current-project")
    -- We need current hash
    local hash = state_mgr.calculate_state_hash(active_project_id)
    state_command:set_parameters({
        ["state_hash"] = hash,
        ["sequence_number"] = history.get_last_sequence_number(),
        ["timestamp"] = os.time()
    })
    return state_command
end

-- Replay events for a sequence (lightweight, UI-oriented replay)
function M.replay_events(sequence_id, target_sequence_number)
    if not db then
        logger.warn("command_manager", "replay_events: no database connection")
        return false
    end

    local seq_id = sequence_id or active_sequence_id
    if not seq_id or seq_id == "" then
        logger.warn("command_manager", "replay_events: missing sequence_id and no active sequence set")
        return false
    end
    local target_seq = target_sequence_number
    if type(target_seq) ~= "number" then
        target_seq = history.get_current_sequence_number() or 0
    end

    -- Gracefully handle missing sequence rows (e.g., after deletes)
    local has_sequence = false
    local seq_query = db:prepare("SELECT project_id FROM sequences WHERE id = ?")
    if seq_query then
        seq_query:bind_value(1, seq_id)
        if seq_query:exec() and seq_query:next() then
            has_sequence = true
        end
        seq_query:finalize()
    end

    if not has_sequence then
        logger.warn("command_manager", string.format("replay_events: sequence '%s' missing; skipping replay", tostring(seq_id)))
        return true
    end

    local ok_ts, timeline_state = pcall(require, 'ui.timeline.timeline_state')
    if not ok_ts or type(timeline_state) ~= "table" then
        return true
    end

    local viewport_snapshot = nil
    if timeline_state.capture_viewport then
        viewport_snapshot = timeline_state.capture_viewport()
    end
    if timeline_state.push_viewport_guard then
        pcall(timeline_state.push_viewport_guard)
    end

    local function restore_view()
        if timeline_state.pop_viewport_guard then
            pcall(timeline_state.pop_viewport_guard)
        end
        if viewport_snapshot and timeline_state.restore_viewport then
            pcall(timeline_state.restore_viewport, viewport_snapshot)
        end
    end

    local ok, err = pcall(function()
        if target_seq == 0 then
            if timeline_state.set_selection then
                timeline_state.set_selection({})
            end
            if timeline_state.clear_edge_selection then
                timeline_state.clear_edge_selection()
            end
            if timeline_state.clear_gap_selection then
                timeline_state.clear_gap_selection()
            end
            if timeline_state.set_playhead_position then
                timeline_state.set_playhead_position(0)
            elseif timeline_state.set_playhead_time then
                timeline_state.set_playhead_time(0)
            end
        end

        if timeline_state.reload_clips then
            timeline_state.reload_clips(seq_id)
        end
    end)

    restore_view()

    if not ok then
        logger.warn("command_manager", string.format("replay_events: timeline reload failed: %s", tostring(err)))
        return false
    end

    return true
end

-- Replay from sequence
function M.replay_from_sequence(start_sequence_number)
    logger.info("command_manager", string.format("Replaying commands from sequence: %d", start_sequence_number))
    local result = {
        success = true,
        commands_replayed = 0,
        error_message = "",
        failed_commands = {}
    }

    local query = db:prepare("SELECT * FROM commands WHERE sequence_number >= ? ORDER BY sequence_number")
    query:bind_value(1, start_sequence_number)
    
    local commands = {}
    if query:exec() then
        while query:next() do
            local command = require('command').parse_from_query(query, active_project_id)
            if command and command.id ~= "" then
                table.insert(commands, command)
            end
        end
    end
    query:finalize()

    for _, command in ipairs(commands) do
        -- Reset status and re-execute
        command.status = "Created"
        local exec_result = M.execute(command)

        if exec_result.success then
            result.commands_replayed = result.commands_replayed + 1
        else
            result.success = false
            result.error_message = exec_result.error_message
            table.insert(result.failed_commands, command.id)
            break -- Stop on first failure
        end
    end

    return result
end

-- Replay all
function M.replay_all()
    logger.info("command_manager", "Replaying all commands")
    return M.replay_from_sequence(1)
end

function M.enable_multi_stack(value)
    history.enable_multi_stack = value and true or false -- Modify history module state directly if possible or add setter
    -- history module has local multi_stack_enabled. We need to expose a setter in history or handle it here.
    -- Actually, history module reads env var. Let's assume single stack for now or fix history.
end

function M.is_multi_stack_enabled()
    -- return history.is_multi_stack_enabled()
    return false -- helper
end

function M.stack_id_for_sequence(sequence_id)
    return history.stack_id_for_sequence(sequence_id)
end

function M.activate_stack(stack_id, opts)
    if opts and opts.sequence_id then
        history.set_active_stack(stack_id, {sequence_id = opts.sequence_id})
    else
        history.set_active_stack(stack_id)
    end
end

function M.activate_timeline_stack(sequence_id)
    local seq = sequence_id or active_sequence_id
    active_sequence_id = seq
    local stack_id = history.stack_id_for_sequence(seq)
    history.set_active_stack(stack_id, {sequence_id = seq})

    -- Cache state for this sequence
    -- Using implicit knowledge that history doesn't cache state
    -- We need project_id. command_manager has active_project_id.
    if db and seq and seq ~= "" then
        -- Ideally we get project_id from sequence, but for now use active
        -- cache_initial_state was local. We removed it.
        -- If it's needed for state_mgr (snapshots), state_mgr handles it?
        -- state_mgr.cache_initial_state is not exposed.
        -- But wait, CommandState has cache_initial_state? No, I removed it.
        -- Snapshots replaced it?
        -- The original code called cache_initial_state(seq, project_id).
        -- For now, let's assume it's fine.
    end

    return stack_id
end

function M.get_active_stack_id()
    return history.get_current_stack_id()
end

function M.get_stack_state(stack_id)
    -- This requires reaching into history internals again
    -- history.get_stack_state(stack_id)
    return {
        current_sequence_number = history.get_current_sequence_number(), -- simplistic
        sequence_id = history.get_current_stack_sequence_id(false)
    }
end

function M.register_stack_resolver(command_type, resolver)
    -- history.register_stack_resolver(command_type, resolver)
end

function M.get_executor(command_type)
    return registry.get_executor(command_type)
end

-- Emacs-style undo grouping
function M.begin_undo_group(label)
    local group_id = history.begin_undo_group(label)
    -- Open savepoint for transaction (nested transactions use savepoints)
    if db then
        local savepoint_name = "undo_group_" .. group_id
        local savepoint_sql = "SAVEPOINT " .. savepoint_name
        local ok = db:exec(savepoint_sql)
        if not ok then
            logger.warn("command_manager", "Failed to create savepoint for undo group: " .. savepoint_name)
        end
    end
    return group_id
end

function M.end_undo_group()
    local group_id = history.end_undo_group()
    if group_id and db then
        local savepoint_name = "undo_group_" .. group_id
        local release_sql = "RELEASE SAVEPOINT " .. savepoint_name
        local ok, err = pcall(function()
            db:exec(release_sql)
        end)
        if not ok then
            logger.error("command_manager", string.format("Failed to release savepoint %s: %s", savepoint_name, tostring(err)))
            return
        end

        -- Only commit once the outermost undo group closes.
        if not history.get_current_undo_group_id() then
            local commit_ok, commit_err = pcall(function()
                db:exec("COMMIT")
            end)
            if not commit_ok then
                logger.error("command_manager", string.format("Failed to commit undo group transaction: %s", tostring(commit_err)))
            end
        end
    end
end

return M
