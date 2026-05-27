--- CommandManager: single entry point for command execution, undo/redo,
--- sequencing, and replay. Delegates storage + cursor arithmetic to
--- CommandRegistry, CommandHistory, and CommandState; this module owns
--- the transaction envelope (begin/end_command_event), the per-sequence
--- / GLOBAL undo-stack routing derived from SPEC.args, and the
--- `__timeline_mutations` dispatch that keeps the timeline cache in
--- sync with DB writes without a full reload.
--
-- @file command_manager.lua
local M = {}

-- Database module for connection checks and transaction management
-- Note: command_manager does NOT execute raw SQL - all queries go through model methods.
-- The db variable is only used to pass to sub-modules (registry, history, state) during init.
local db_module = require("core.database")
local db = nil
local Signals = require("core.signals")

-- State tracking
local last_error_message = ""

-- Forward declarations for modules used in helper functions


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

-- Post-commit signal-emit queue.
--
-- Some signals (notably `sequence_list_changed`) drive UI consumers that
-- re-pull from the DB. Emitting from inside a command executor would let
-- those consumers see in-progress transaction state — and worse, would
-- leave them with a stale view if the command later rolls back. The queue
-- defers emits until the transaction (or undo group) commits; rollback
-- discards them.
--
-- Use M.queue_post_commit_emit(signal, ...) from within an executor. The
-- flush points are wired to the per-command commit (no undo group) and to
-- end_undo_group's outermost commit; discard points are the rollback paths.
local _post_commit_emits = {}

local function flush_post_commit_emits()
    if #_post_commit_emits == 0 then return end
    local pending = _post_commit_emits
    _post_commit_emits = {}
    for _, entry in ipairs(pending) do
        Signals.emit(unpack(entry))
    end
end

local function discard_post_commit_emits()
    _post_commit_emits = {}
end

--- Queue a signal emit to fire after the surrounding command's
--- transaction commits. Argument list mirrors Signals.emit.
---
--- Safe to call from any context: when no command is executing
--- (execution_depth == 0, e.g. initial project open's importer pass),
--- there's no commit to defer to, so the emit fires immediately.
function M.queue_post_commit_emit(signal_name, ...)
    assert(type(signal_name) == "string" and signal_name ~= "",
        "queue_post_commit_emit: signal_name required")
    if execution_depth == 0 then
        Signals.emit(signal_name, ...)
        return
    end
    _post_commit_emits[#_post_commit_emits + 1] = { signal_name, ... }
end

-- Root command tracking for automatic undo grouping
-- When a command executes nested commands, they all share the root's sequence_number as undo_group_id
-- Nested commands also inherit the root's playhead and pre-selection context (same user action)
local root_command_sequence_number = nil
local root_playhead_value = nil
local root_playhead_rate = nil
-- True while an undoable=false / no_persist command is executing. Read by
-- should_auto_promote to decide whether persisting children should be
-- auto-promoted to top-level. See that function for the full rationale.
local parent_is_non_persisting = false
-- Selection captured at root command start (inherited by nested commands for undo)
local root_selected_clips_pre = nil
local root_selected_edges_pre = nil
local root_selected_gaps_pre = nil


-------------------------------------------------------------------------------
-- ARCHITECTURAL NOTE: Implicit vs Explicit Command Parameters
-------------------------------------------------------------------------------
-- Many selection-based commands (Cut, Delete, ToggleClipEnabled, etc.) derive
-- their target clip_ids from timeline_state.get_selected_clips() if not
-- explicitly provided. This is the "implicit derivation" pattern.
--
-- How it works:
--   1. UI calls execute("Cut", {project_id, sequence_id})  -- no clip_ids
--   2. Executor calls timeline_state.get_selected_clips() to get targets
--   3. Executor PERSISTS the derived values to the command for undo/redo
--   4. Undo/redo uses persisted values, NOT current selection
--
-- This pattern is SAFE for undo/redo because step 3 captures the state.
--
-- FUTURE CONSIDERATION: Macro Recording / Command Sourcing
-- If we implement macro recording or command sourcing (replaying commands from
-- logs), this implicit pattern will need attention:
--   - Option A: Macros capture the RESULT of execution (with persisted values)
--   - Option B: Refactor all commands to require explicit parameters
--   - Option C: Macro system resolves selection at record time, stores explicit IDs
--
-- See: toggle_clip_enabled.lua for an example with detailed comments.
-- See also: cut.lua, delete_clip.lua, ripple_delete_selection.lua
-------------------------------------------------------------------------------


local function bug_result(message)
    assert(message, "command_manager.bug_result: message is required")
    last_error_message = message
    local result = { success = false, error_message = last_error_message, result_data = "", is_bug = true }
    -- Log with traceback but DON'T assert — let the error result flow through
    -- the return-value chain. Asserting here converts a returned error into a
    -- thrown exception that bounces through 3 xpcall/error re-raise layers,
    -- stacking tracebacks and producing ~8 lines of output for 1 error.
    local _log = require("core.logger").for_area("commands")
    _log.error("BUG: %s\n%s", last_error_message, debug.traceback("", 2))
    return result
end

local function dev_assert(condition, message)
    if condition then
        return true
    end
    -- Invariant violation — must throw (not return) so pcall callers see failure.
    -- bug_result logs+returns which is correct for command execution results,
    -- but dev_assert guards structural invariants that must halt the caller.
    local _log = require("core.logger").for_area("commands")
    _log.error("BUG: %s\n%s", message, debug.traceback("", 2))
    error(message, 2)
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
local log = require("core.logger").for_area("commands")

-- Sub-modules
local registry = require("core.command_registry")
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

-- Forward declarations
local extract_sequence_id
local get_effective_sequence_id

local function notify_command_event(event)
    if not event then
        return
    end
    for _, listener in ipairs(command_event_listeners) do
        -- NSF-OK: pcall isolates broadcast listeners; one failing listener must not block others
        local ok, err = pcall(listener, event)
        if not ok then
            log.error("Command listener failed: %s", tostring(err))
        end
    end

    -- Notify listeners that this sequence's content may have changed.
    -- Fires for every UNDOABLE command's execute/undo/redo. Non-undoable
    -- commands (SetPlayhead, MovePlayhead, etc.) skip this path via the
    -- `execute_as_non_persisting_parent` shortcut earlier in _execute_body —
    -- those commands don't mutate clips, so the source viewer + inspectors
    -- don't need to refresh on them. Centralizing here means individual
    -- commands don't have to remember to emit:
    --   * "content_changed" — playback layer; handler is a no-op when
    --     total_frames unchanged.
    --   * "sequence_content_changed" — source viewer, inspectors, and
    --     any module that watches a sequence's content. Handlers must
    --     be idempotent on no-op (re-pull from model + republish).
    -- Cross-sequence commands (nest/unnest/grow_master_medium) still
    -- emit explicitly for their SECONDARY seq_ids — the central emit
    -- only knows the command's primary seq_id.
    --
    -- TODO(perf): some undoable commands (SetMarkIn/Out, SetClipProperty
    -- on metadata, etc.) don't actually change clip layout; firing the
    -- signal still triggers listeners to do their idempotent-no-op work.
    -- If profiling shows hot path, gate this emit on a "mutated content"
    -- marker — `__timeline_mutations` presence or a command-level
    -- `mutates_clips` flag in SPEC.
    local seq_id = event.command and extract_sequence_id(event.command)
    if seq_id and seq_id ~= "" then
        Signals.emit("content_changed", seq_id)
        Signals.emit("sequence_content_changed", seq_id)
    end
end

--- Apply __timeline_mutations from a command to the UI cache.
-- Returns true if mutations were applied, false if not (caller should reload).
local function apply_command_mutations(cmd)
    local mutations = cmd:get_parameter("__timeline_mutations")
    if not mutations then return false end
    -- Wrapper commands (Insert, Overwrite) forward their nested command's
    -- mutations onto themselves so downstream inspectors see them; the
    -- nested command has already applied those mutations to timeline_state,
    -- so the outer MUST NOT re-apply or it duplicates every inserted clip.
    -- The flag treats the outer as "applied" without touching state.
    if cmd:get_parameter("__timeline_mutations_already_applied") then
        return true
    end
    local ts = require('ui.timeline.timeline_state')
    if not ts.apply_mutations then return false end
    local fallback_seq = extract_sequence_id(cmd)
    local active_seq = ts.get_tab_strip():active_sequence_id() or nil

    -- timeline_state holds exactly one active sequence's clip cache.
    -- Mutations addressed to a DIFFERENT sequence are valid — two cases:
    --   1. Cross-sequence commands (per 006-per-sequence-undo FR-012:
    --      "a command that touches two sequences is one atomic command.
    --      Undoing from either sequence undoes both sides"). A drag
    --      from seqA to seqB produces mutations for both; only one
    --      matches the active cache.
    --   2. Legacy project-level SetClipProperty rows persisted before
    --      the sequence_id scoping fix (2026-04-21). They live on the
    --      GLOBAL cursor and can fire from any tab.
    -- In both cases the DB write has already been done by the
    -- executor/undoer. The ACTIVE cache just shouldn't try to hydrate
    -- an out-of-scope clip (that blows up clip_state's sanity check).
    -- Return true (treat as "applied") so the safety-net reload doesn't
    -- fire either; when the user switches to the target sequence,
    -- timeline_state.init reloads its clips fresh from DB.
    local function applies_to_active(target_seq)
        return active_seq ~= nil and active_seq ~= ""
            and target_seq == active_seq
    end

    if mutations.sequence_id or mutations.inserts or mutations.updates or mutations.deletes then
        -- Single-bucket format
        local target_seq = mutations.sequence_id or fallback_seq
        assert(target_seq and target_seq ~= "",
            string.format("apply_command_mutations: no sequence_id for %s mutations", cmd.type or "unknown"))
        if not applies_to_active(target_seq) then
            return true
        end
        return ts.apply_mutations(target_seq, mutations)
    end

    -- Multi-bucket format (keyed by sequence_id)
    local applied = false
    local any_bucket_seen = false
    for _, bucket in pairs(mutations) do
        if type(bucket) == "table" then
            any_bucket_seen = true
            local target_seq = bucket.sequence_id or fallback_seq
            assert(target_seq and target_seq ~= "",
                string.format("apply_command_mutations: no sequence_id in bucket for %s", cmd.type or "unknown"))
            if applies_to_active(target_seq) then
                if ts.apply_mutations(target_seq, bucket) then
                    applied = true
                end
            end
        end
    end
    -- Any buckets at all → treat as applied, even if none matched the
    -- active sequence. Cross-sequence buckets' DB writes already
    -- happened; no need for the safety-net reload here.
    if any_bucket_seen and not applied then
        return true
    end
    return applied
end

--- Bump mutation_generation for every sequence touched by this action.
--
-- Semantics: one bump per user-visible action, not per command. Wrapper
-- commands (Insert, Overwrite) form an undo group with their nested
-- AddClipsToSequence children; the group is a single user action, so
-- undoing it unwinds every member but the sequence's "generation"
-- advances by exactly one. Callers pass the set of commands participating
-- in the action (one-element list for non-grouped paths, full group for
-- grouped undo/redo). Sequence IDs are de-duped so a group spanning the
-- same sequence twice still advances that sequence by one.
--
-- The counter is monotonic: undo and redo still increment because a
-- rollback is itself a state transition that invalidates any cached
-- reference to a prior generation. Commands without a sequence_id
-- (project-level: CreateSequence, DeleteSequence, etc.) are skipped —
-- they don't target any sequence's mutation_generation.
local function increment_sequence_generations_for_commands(cmds)
    assert(type(cmds) == "table" and #cmds > 0,
        "increment_sequence_generations_for_commands: cmds must be a non-empty list")
    local Sequence = require("models.sequence")
    local bumped = {}
    for _, cmd in ipairs(cmds) do
        assert(cmd, "increment_sequence_generations_for_commands: nil command in list")
        local seq_id = cmd.sequence_id
        if seq_id and seq_id ~= "" and not bumped[seq_id] then
            bumped[seq_id] = true
            Sequence.increment_generation(seq_id)
        end
    end
end

local function increment_sequence_generation_if_scoped(cmd)
    assert(cmd, "increment_sequence_generation_if_scoped: cmd is required")
    increment_sequence_generations_for_commands({ cmd })
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

-- Interactive (user-initiated) entry point for dispatching commands.
--
-- Contract:
-- - UI code (keyboard, menu, mouse gestures, TC entry, inspectors, drag/drop)
--   calls execute_interactive. Nested dispatches from inside a command's
--   executor call plain execute, which stays a pure model path.
-- - execute_interactive establishes a "ui" command event and threads implicit
--   UI context (active project/sequence/playhead) into params.
-- - Pass 2 will add a viewport-surfacing policy here so interactive user
--   actions surface the playhead (or undo/redo change region) without every
--   UI caller having to do it themselves.
-- - If active context is missing, we error (this is a bug, not a case to
--   "defensively" hide).
-- - Return value: the executor's result table on a successful dispatch, or
--   `nil` when the dispatch was aborted because `effective_source` produced
--   a user-facing problem (no source loaded, non-insertable selection,
--   cycle). The popup is shown before this function returns; callers may
--   treat `nil` as "user has been told what went wrong, no further action
--   needed".
function M.execute_interactive(command_name, params)
    params = params or {}

    -- Establish (or join) a UI command event.
    -- When already inside a non-"ui" event (e.g. the test harness establishes
    -- a "script" event to mark scripted dispatch), delegate straight to
    -- M.execute — UI-context injection is meaningless in scripted flow, and
    -- refusing the call here would silently break every UI-exercising test.
    -- Pass 2 viewport policy likewise runs only when we actually opened our
    -- own "ui" event (wrapped_ui=true below).
    local wrapped_ui = false
    if command_event_depth == 0 then
        M.begin_command_event("ui")
        wrapped_ui = true
    elseif command_event_origin == "ui" then
        -- Nested UI dispatch inside a UI event. Balance begin/end so we
        -- always close what we open.
        M.begin_command_event("ui")
        wrapped_ui = true
    end

    -- Capture playhead before execute so the post-execute policy can
    -- tell whether the command actually moved it. A gesture that leaves
    -- the playhead put (clip selection, property toggle, non-advancing
    -- insert) must not trigger surface_playhead — otherwise clicking
    -- a clip off-screen would scroll the viewport back to the playhead,
    -- away from what the user just clicked on.
    local ts = require("ui.timeline.timeline_state")
    local playhead_pre = ts.get_playhead_position()

    -- 015 F2: resolve source_sequence_id for commands that declare it
    -- (Insert, Overwrite). The resolver is destination-aware — passing
    -- active_sequence_id lets it detect self/transitive cycles upfront
    -- and surface a user-facing popup instead of bubbling a Lua
    -- stacktrace warning out of _place_shared.pick_endpoints.
    -- Commands that don't declare source_sequence_id in their arg spec
    -- skip this entirely — the field is irrelevant to them.
    --
    -- Object-form dispatch (Command object instead of a name string) is
    -- used by callers that build their own param table (e.g. inspectable
    -- setters); those carry source_sequence_id themselves when needed and
    -- don't benefit from auto-injection.
    if type(command_name) == "string" and params.source_sequence_id == nil then
        local spec = registry.get_spec(command_name)
        if spec and spec.args and spec.args.source_sequence_id then
            assert(active_sequence_id and active_sequence_id ~= "", string.format(
                "execute_interactive: command %s requires source_sequence_id "
                .. "resolution but no active sequence is set", command_name))
            local effective_source = require("core.effective_source")
            local seq, problem = effective_source.pick_for_edit(
                active_sequence_id, command_name)
            if problem ~= nil then
                require("ui.edit_source_popup").show(problem)
                if wrapped_ui then M.end_command_event() end
                return nil
            end
            params.source_sequence_id = seq
        end
    end

    local result = nil
    local executed_command = nil
    local status, exec_err = xpcall(function()
        if params.project_id == nil then
            local pid, pid_err = ensure_active_project_id()
            assert(pid, pid_err)
            params.project_id = pid
        end
        result, executed_command = M.execute(command_name, params)
    end, debug.traceback)

    if wrapped_ui then
        M.end_command_event()
    end
    if not status then
        error(exec_err)
    end

    -- Viewport surfacing policy. Fires only when this call owned the "ui"
    -- event boundary (wrapped_ui = outermost user action). Nested
    -- execute_interactive dispatched inside a UI-event-owning caller
    -- never fires the policy separately; the outer caller owns it.
    -- Scripted contexts (wrapped_ui=false because the event was already
    -- open with a non-"ui" origin) also skip — tests opt out of UI
    -- repainting by design.
    if wrapped_ui and executed_command and type(result) == "table" and result.success then
        local spec = executed_command.type and registry.get_spec(executed_command.type) or nil
        local skip = spec and spec.skip_execute_viewport_policy
        local playhead_post = ts.get_playhead_position()
        -- Only surface on execute when the playhead actually moved.
        -- Gestures that leave the playhead put (selection, property
        -- toggles, non-advancing inserts) are the user interacting
        -- with visible content; repainting the viewport to "wherever
        -- the playhead is" would yank it away from their click.
        if not skip and playhead_pre ~= playhead_post then
            require("ui.timeline.viewport_policy").apply_post_command("execute", executed_command)
        end
    end

    return result
end

-- Rollback in-memory clip state to pre-transaction snapshot.
-- No-op when no snapshot was taken (command opted out via
-- spec.skip_clip_snapshot because it doesn't modify clips).
local function rollback_mutations()
    local clip_state = require("ui.timeline.state.clip_state")
    if clip_state.has_active_mutation_snapshot() then
        clip_state.rollback_mutation_transaction()
    end
end

-- Rollback an undo group: DB savepoint, cursor, in-memory mutations, abort flag.
-- The savepoint rollback unwinds any cursor write performed during the failed
-- command, so `history.invalidate_cas_baseline()` must run before save_undo_position
-- — otherwise the next CAS compares against a baseline reflecting a write that
-- no longer exists in the DB and the assertion fires spuriously.
local function rollback_undo_group(group_id)
    db_module.rollback_to_savepoint("undo_group_" .. group_id)
    history.invalidate_cas_baseline()
    local cursor_on_entry = history.get_undo_group_cursor_on_entry()
    history.set_current_sequence_number(cursor_on_entry)
    history.save_undo_position()
    rollback_mutations()
    history.mark_undo_group_aborted()
end

-- SAVEPOINT-aware rollback: undo group → rollback to savepoint; standalone → full rollback.
-- Both paths restore in-memory clip state from the mutation transaction snapshot.
-- Also drops any queued post-commit signal emits: a command that rolled back
-- must not notify listeners about state that's no longer in the DB.
local function rollback_transaction()
    assert(db_module.has_connection(), "rollback_transaction: no database connection")
    local group_id = history.get_current_undo_group_id()
    if group_id then
        rollback_undo_group(group_id)
    else
        db_module.rollback()
        -- Standalone rollback also unwinds any in-progress cursor write; the
        -- CAS baseline must be re-seeded from DB on the next save.
        history.invalidate_cas_baseline()
        rollback_mutations()
    end
    discard_post_commit_emits()
end

local function normalize_command(command_or_name, params)
    local Command = require("command")

    local origin, origin_err = get_command_event_origin()
    if origin_err then
        return nil, bug_result(origin_err)
    end

    -- Check spec early for commands that don't require project context (e.g., OpenProject)
    local spec_for_check = type(command_or_name) == "string" and registry.get_spec(command_or_name) or nil
    local no_project_context = spec_for_check and spec_for_check.no_project_context

    local active_project_id, active_project_err = ensure_active_project_id()
    if active_project_err and not no_project_context then
        return nil, bug_result(active_project_err)
    end

    if type(command_or_name) == "string" then
		params = params or {}
		-- UI convenience: if caller omitted project_id, default to active project.
		-- Script callers must pass it explicitly to avoid silently targeting the wrong project.
		-- Commands with no_project_context can run without a project_id.
		if origin == "ui" and (not params.project_id or params.project_id == "") then
			params.project_id = active_project_id or ""
		end
		if not no_project_context and not (params.project_id and params.project_id ~= "") then
			return nil, bug_result("execute(command_name, params): params.project_id is required")
		end
        if not no_project_context and origin == "ui" and params.project_id ~= active_project_id then
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

        local cmd_params = command.parameters or {}
        if not (cmd_params.project_id and cmd_params.project_id ~= "") then
            cmd_params.project_id = param_project_id
        end

        local ok, normalized, schema_err = command_schema_module.validate_and_normalize(
            command.type,
            spec,
            cmd_params,
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
    local db_module = require("core.database")
    db_module.ensure_commands_table_columns()
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

extract_sequence_id = function(command)
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

-- Per-Sequence Undo: classify a command as sequence-scoped or project-level.
-- Returns the sequence_id to store on the command record, or nil for project-level.
-- CreateSequence/DeleteSequence are project-level despite having sequence_id in args.
local PROJECT_LEVEL_COMMAND_TYPES = {
    CreateSequence = true,
    DeleteSequence = true,
}

-- Commands classified as "non-clip-mutating" in their own spec
-- (mutates_clips = false). They write to sequence/project-level state and
-- drive UI refresh through their own signals (marks_changed,
-- project_changed, …) rather than __timeline_mutations. Consulted by the
-- hash-based mutation assertion and the clip-level recovery reload.
--
-- Keeping classification on each command's spec (rule 2.21: statically
-- verifiable) means adding a new non-clip command can't silently re-break
-- the diagnostic — the flag lives with the command it describes, not in a
-- disconnected allowlist here.
local function is_non_clip_mutating_command(cmd_type)
    local spec = registry.get_spec(cmd_type)
    return spec ~= nil and spec.mutates_clips == false
end

-- Recovery reload after a command's executor/undoer produced no
-- __timeline_mutations (delegation, test env, or genuine bug). Skipped for
-- non-clip-mutating commands, which drive UI refresh via their own signals
-- — the clip-level reload would be wasted work and would mask the fact
-- that these commands have a different refresh contract.
local function reload_clips_after_no_mutations(cmd_type, seq_id)
    if is_non_clip_mutating_command(cmd_type) then return end
    local ts = require('ui.timeline.timeline_state')
    if ts.reload_clips then ts.reload_clips(seq_id) end
end

local function classify_command_sequence_id(command)
    if PROJECT_LEVEL_COMMAND_TYPES[command.type] then
        return nil
    end
    return extract_sequence_id(command)
end

local function create_command_perf_tracker(command)
    local start_time = os.clock()

    local function reset()
        start_time = os.clock()
    end

    local function log_phase(phase)
        local elapsed_ms = (os.clock() - start_time) * 1000.0
        log.detail("%s took %.2fms (cmd=%s seq=%s)",
            phase, elapsed_ms,
            tostring(command and command.type),
            tostring(command and command.sequence_number))
    end

    return {
        reset = reset,
        log = log_phase
    }
end

local function should_compute_state_hash(command)
    return command_flag(command, "suppress_if_unchanged", "__suppress_if_unchanged")
        or os.getenv("JVE_FORCE_STATE_HASH") == "1"
end

-- Finish command execution without persisting (no-op or cancelled)
-- @param db_conn: Database connection (unused, kept for signature compatibility)
-- @param history_mod: History module
-- @param exec_scope: Execution scope for logging
-- @param result: Result table to update
-- @param opts: Optional { skip_rollback = true } for nested commands, { cancelled = true } for cancelled
local function finish_as_noop(db_conn, history_mod, exec_scope, result, opts)
    opts = opts or {}
    if not opts.skip_rollback then
        local db_module = require("core.database")
        db_module.rollback()
    end
    history_mod.decrement_sequence_number()
    result.success = true
    result.result_data = ""
    if opts.cancelled then
        result.cancelled = true
    end
    local scope_reason = opts.cancelled and "cancelled" or "no_state_change"
    if opts.skip_rollback then
        scope_reason = scope_reason .. "_nested"
    end
    exec_scope:finish(scope_reason)
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

-- Save a command with collision recovery. When another writer (external
-- process, prior session's uncommitted WAL, test harness) has inserted
-- command rows at sequence_numbers our cached allocator doesn't know about,
-- the SQLite UNIQUE constraint on commands.sequence_number fires. The
-- recovery is: refresh the allocator from the DB's real MAX, reallocate
-- a fresh sequence_number, re-chain parent_sequence_number from the
-- current cursor, and retry the save.
--
-- Bounded retries prevent an infinite loop in the pathological case where
-- the DB is growing faster than we can catch up. Three attempts matches
-- SQLite's own default retry depth for busy handlers and is more than
-- enough for realistic concurrent writers.
local UNIQUE_COLLISION_MAX_ATTEMPTS = 3

local function save_command_with_collision_retry(command, db_conn)
    local ok, err = command:save(db_conn)
    if ok then return true, nil end

    -- Only UNIQUE collisions on sequence_number are recoverable by
    -- reallocation. Any other error (NOT NULL, FK violation, disk full)
    -- is a real failure — surface it unchanged.
    local function is_unique_collision(e)
        return type(e) == "string"
            and e:match("UNIQUE constraint failed: commands%.sequence_number") ~= nil
    end

    if not is_unique_collision(err) then
        return false, err
    end

    for attempt = 2, UNIQUE_COLLISION_MAX_ATTEMPTS do
        -- Walk back the allocator (undo this attempt's increment), refresh
        -- from DB MAX, re-increment, and re-chain parent. The cursor is
        -- per-session and not affected by external writers, so it stays put.
        history.decrement_sequence_number()
        history.refresh_last_sequence_number()
        local new_seq = history.increment_sequence_number()
        command.sequence_number = new_seq
        command.parent_sequence_number = history.get_current_sequence_number()
            or history.get_global_cursor()

        log.warn("Command.save: UNIQUE collision, retrying at seq=%d (attempt %d/%d)",
            new_seq, attempt, UNIQUE_COLLISION_MAX_ATTEMPTS)

        ok, err = command:save(db_conn)
        if ok then return true, nil end
        if not is_unique_collision(err) then
            return false, err
        end
    end

    return false, string.format(
        "Command.save: UNIQUE collision unresolved after %d attempts: %s",
        UNIQUE_COLLISION_MAX_ATTEMPTS, tostring(err))
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

    -- Get database connection to pass to sub-modules
    -- Note: command_manager itself does NOT execute SQL - only sub-modules do
    db = db_module.get_connection()
    assert(db, "CommandManager.init: database connection not available")

    registry.init(db, M.set_last_error)
    history.init(db, sequence_id, project_id)
    state_mgr.init(db)

    -- Per-Sequence Undo: activate the initial sequence's timeline stack
    M.activate_timeline_stack(sequence_id)

    -- 017: bootstrap the role-bound playback transport for this project so
    -- TogglePlay / MovePlayhead / shuttle dispatch correctly. Idempotent
    -- (transport.init asserts if already initialized) — guard so tests that
    -- call command_manager.init repeatedly don't trip the assert. Wrapped
    -- in pcall because transport.init → PlaybackEngine.new pulls in
    -- qt_constants which legacy headless tests cannot satisfy; tests
    -- exercising the new transport path bootstrap qt_constants themselves
    -- before calling command_manager.init.
    -- pcall accommodates headless tests where transport.init's deps
    -- (qt_constants, PlaybackEngine internals) aren't fully stubbed.
    -- Log on failure so the runtime path's "transport refused to
    -- bootstrap" mode is visible — the prior bare pcall hid this and
    -- left record_engine.loaded_sequence_id nil with no breadcrumb.
    -- A full no-pcall gate (e.g. on qt_constants presence) broke
    -- legacy tests that relied on the pcall's partial-success state,
    -- so the conservative move is "log + keep tolerating."
    local ok_transport, transport_err = pcall(function()
        local transport = require("core.playback.transport")
        if transport.bound_project_id() ~= project_id then
            if transport.is_bootstrapped() then transport.shutdown() end
            transport.init(project_id)
        end
    end)
    if not ok_transport then
        log.warn("command_manager.init: transport.init pcall failed: %s "
            .. "(project_id=%s) — record_engine won't bind",
            tostring(transport_err), tostring(project_id))
    end

    -- Keep timeline_state IDs initialized so selection persistence doesn't assert during headless tests.
    local Sequence = require("models.sequence")
    local seq = Sequence.load(sequence_id)
    if seq and seq.project_id and seq.project_id ~= "" then
        assert(seq.project_id == project_id,
            "CommandManager.init: provided project_id does not match sequences.project_id (sequence_id="
                .. tostring(sequence_id) .. ", provided=" .. tostring(project_id) .. ", db=" .. tostring(seq.project_id) .. ")")
        -- NSF-OK: timeline_state may not have init() in test/headless environments
        local ok_ts, timeline_state = pcall(require, "ui.timeline.timeline_state")
        if ok_ts and timeline_state and type(timeline_state.init) == "function" then
            timeline_state.init(sequence_id, project_id)
        end
    end
    
    ensure_command_selection_columns()

    log.event("Initialized (last_sequence=%d current_position=%s)",
        history.get_last_sequence_number(),
        tostring(history.get_current_sequence_number()))
end

--- Initialize CommandManager for a project with NO active sequence.
--- Used on startup when the project has no saved tab info (feature 010).
--- The manager is fully operational for project-scoped commands; per-sequence
--- stacks become reachable once the user opens a sequence (which calls
--- M.activate_timeline_stack).
function M.init_project_only(project_id)
    if not project_id or project_id == "" then
        error("CommandManager.init_project_only: project_id is required", 2)
    end
    active_sequence_id = nil
    active_project_id = project_id

    db = db_module.get_connection()
    assert(db, "CommandManager.init_project_only: database connection not available")

    registry.init(db, M.set_last_error)
    history.init(db, nil, project_id)
    state_mgr.init(db)

    ensure_command_selection_columns()

    log.event("Initialized (project-only, no active sequence; last_sequence=%d)",
        history.get_last_sequence_number())
end

--- Drop the currently-active per-sequence stack without discarding its
--- persisted commands. Feature 010, FR-014 — undoing a sequence delete must
--- be able to restore the sequence's undo history intact. Idempotent.
function M.deactivate()
    local was_active = active_sequence_id
    active_sequence_id = nil
    -- Route subsequent undo/redo through the global stack; per-sequence state
    -- remains on disk.
    history.set_active_stack(history.GLOBAL_STACK_ID)
    log.event("Deactivated (no active sequence; global stack active)")

    -- Mirror activate_timeline_stack's "sequence_switched" event with
    -- sequence_id=nil so menus / panels refresh their enabled state for
    -- per-sequence commands (feature 010, FR-008).
    if was_active then
        notify_command_event({
            event = "sequence_switched",
            sequence_id = nil,
            project_id = active_project_id,
        })
    end
end

-- Validate command parameters
local function validate_command_parameters(command)
    if not command.type or command.type == "" then return false end
    -- project_id validation is handled by schema - commands that need it declare it there
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

local command_helper = require("core.command_helper")

-- Drop any clip_ids from a JSON-encoded selection list that appear in
-- the exclude set. Used to prune the post-selection capture so clips
-- the command just deleted don't appear in the stored snapshot.
local function prune_selection_json(clips_json, exclude_set)
    if not clips_json or clips_json == "" or clips_json == "[]" then return clips_json end
    if next(exclude_set) == nil then return clips_json end
    local ok, ids = pcall(json.decode, clips_json)
    if not ok or type(ids) ~= "table" then return clips_json end
    local filtered = {}
    for _, id in ipairs(ids) do
        if not exclude_set[id] then table.insert(filtered, id) end
    end
    return json.encode(filtered)
end

local function capture_post_selection_for_command(command)
    local scope = profile_scope.begin("command_manager.capture_selection_post")
    local clips_json, edges_json, gaps_json = state_mgr.capture_selection_snapshot()
    -- apply_command_mutations runs later (DB commits first, UI updates
    -- second), which means the live selection state still contains any
    -- clips this command is deleting. Prune them from the captured
    -- post-selection so redo-time selection restore doesn't try to load
    -- a clip the redo itself just deleted.
    local deleted = command_helper.collect_deleted_clip_ids(command)
    clips_json = prune_selection_json(clips_json, deleted)
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
            log.error("Executor failed (%s):\n%s", tostring(command and command.type), tostring(result))
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
        log.error("Unknown command type: %s", command.type)
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

-- Run a non-persisting command (undoable=false or no_persist) with the
-- parent_is_non_persisting flag set. Nestable via save/restore so a
-- non-persisting wrapper dispatched from inside another non-persisting
-- wrapper still restores correctly on return.
local function execute_as_non_persisting_parent(command)
    local was_non_persisting = parent_is_non_persisting
    parent_is_non_persisting = true
    local result = execute_non_recording(command)
    parent_is_non_persisting = was_non_persisting
    return result
end

-- Should a dispatch inside a non-persisting parent be promoted to top-level?
--
-- Scenario: a non-persisting parent (ShowRelinkDialog, OpenProject, any
-- modal dialog wrapper) dispatches a persisting child from inside its
-- executor. Without promotion the child would be saved via
-- execute_nested_command under a nil root — skipping notify_command_event
-- and leaving the global cursor stale — so the edit history panel would
-- never see the command and Cmd+Z would skip it.
--
-- Two dispatch shapes reach here with parent_is_non_persisting set:
--   (a) is_nested=true — truly nested under an open undo_group (e.g. the
--       non-persisting parent has already opened a recording group and
--       this child comes in deeper).
--   (b) is_nested=false at execution_depth>1 — dispatched inside a
--       non-persisting wrapper that hasn't opened any shared scope, so
--       _execute_body's is_nested ternary (requires an active undo_group
--       or root_command_sequence_number) evaluates to false even though
--       we're architecturally nested.
-- Both must run top-level AND clear parent_is_non_persisting for the
-- duration, so their own nested children nest normally instead of
-- re-promoting and colliding on the open transaction. parent_is_non_persisting
-- is the correct gate; is_nested alone misses case (b).
--
-- A command persists unless its spec explicitly opts out (undoable=false
-- or no_persist). Commands without a registered spec default to persisting,
-- matching the _execute_body convention where a nil spec falls through to
-- the top-level recording path.
local function should_auto_promote(cmd_type)
    if not parent_is_non_persisting then return false end
    assert(type(cmd_type) == "string" and cmd_type ~= "",
        "should_auto_promote: cmd_type must be a non-empty string")
    local spec = registry.get_spec(cmd_type)
    if spec and (spec.undoable == false or spec.no_persist) then return false end
    return true
end

--- Execute a nested command (one invoked from inside a root command's
-- executor). Shares the root's transaction, inherits its undo group,
-- and writes directly to the existing mutation snapshot. The top-level
-- execute body calls this for every depth > 1 call and returns the
-- result without touching the top-level ceremony (validation, hashing,
-- transaction lifecycle, UI refresh, notify) — all of that is owned
-- by the root command.
--
-- The caller owns `exec_scope` so that the scope spans both nested and
-- top-level paths uniformly; this function calls `:finish` on it
-- exactly once before returning.
local function execute_nested_command(command, exec_scope)
    assert(command and command.type and command.type ~= "",
        "execute_nested_command: command with .type is required")
    assert(exec_scope and type(exec_scope.finish) == "function",
        "execute_nested_command: exec_scope with :finish method is required")
    -- Note: root_command_sequence_number may be nil here. That happens
    -- when a non-recording top-level command (spec.undoable == false,
    -- e.g. DeleteSelection) spawns nested recording children — the
    -- non-recording parent bypasses the top-level ceremony that sets
    -- root_command_sequence_number, but the nested children still run
    -- under the parent's explicit undo group. The `or`-chains below
    -- handle the nil case.

    -- Non-undoable nested commands bypass the recording ceremony entirely.
    -- Example: a wrapper command invoking a utility that mutates nothing
    -- the user would want to undo independently.
    local spec = registry.get_spec(command.type)
    if spec and spec.undoable == false then
        local result = execute_non_recording(command)
        exec_scope:finish("non_recording_nested")
        return result
    end

    -- Assign sequence number and chain to the current cursor position.
    -- After each nested save, set_current_sequence_number advances the
    -- cursor, so siblings chain linearly: child1→pre-root, child2→child1,
    -- etc. This is used only for cursor restore after undo — group
    -- membership is determined by undo_group_id, not parent chain.
    local sequence_number = history.increment_sequence_number()
    command.sequence_number = sequence_number
    command.parent_sequence_number = history.get_current_sequence_number()
        or root_command_sequence_number

    -- Inherit undo group: explicit group (from begin_undo_group) takes
    -- precedence over automatic grouping (from recording root).
    local explicit_group = history.get_current_undo_group_id()
    command.undo_group_id = explicit_group or root_command_sequence_number

    local exec_result = execute_command_implementation(command)
    local execution_success, execution_error_message, execution_result_data =
        normalize_executor_result(exec_result, command)

    local result = {
        success = execution_success,
        error_message = execution_error_message ~= "" and execution_error_message
            or (last_error_message ~= "" and last_error_message or ""),
        result_data = execution_result_data or "",
    }

    -- Preserve custom fields the executor attached to its return table
    -- (anything beyond success/error_message/result_data/cancelled).
    if type(exec_result) == "table" then
        for key, value in pairs(exec_result) do
            if key ~= "success" and key ~= "error_message" and key ~= "result_data" and key ~= "cancelled" then
                result[key] = value
            end
        end
    end

    -- User cancellation: discard without touching history or DB state.
    if type(exec_result) == "table" and exec_result.cancelled then
        return finish_as_noop(db, history, exec_scope, result, { skip_rollback = true, cancelled = true })
    end

    if execution_success then
        command.status = "Executed"
        command.executed_at = os.time()

        -- Inherit playhead/selection context from root — same user
        -- action, same playhead position. Post-selection is NOT
        -- inherited because it's captured AFTER the root executor
        -- completes, but nested commands run DURING the executor.
        -- redo_group handles that by restoring from root after all
        -- nested redos complete.
        command.playhead_value = root_playhead_value
        command.playhead_rate = root_playhead_rate
        command.selected_clip_ids_pre = root_selected_clips_pre
        command.selected_edge_infos_pre = root_selected_edges_pre
        command.selected_gap_infos_pre = root_selected_gaps_pre

        -- Per-Sequence Undo: classify before persisting.
        command.sequence_id = classify_command_sequence_id(command)

        local saved = save_command_with_collision_retry(command, db)
        sequence_number = command.sequence_number  -- retry may have reallocated
        if saved then
            -- Advance, never regress: a parent nested command (e.g. BatchRippleEdit
            -- at seq=N) that spawned its own deeper-nested child (e.g. SplitClip
            -- at seq=N+k) must NOT pull the cursor back to N. The cursor is the
            -- undo head; if it sits below the deepest child, find_group_members
            -- (which clamps with sequence_number <= cursor) silently drops the
            -- deeper child from the undo walk and its undoer never runs.
            local current = history.get_current_sequence_number()
            if not current or current < sequence_number then
                history.set_current_sequence_number(sequence_number)
                -- Advance the tip alongside the cursor on the stack the
                -- nested command lands on (matches column, not active stack
                -- — see the top-level commit comment for why).
                local tip_stack = command.sequence_id
                    and history.stack_id_for_sequence(command.sequence_id)
                    or history.GLOBAL_STACK_ID
                history.set_branch_tip_on_stack(tip_stack, sequence_number)
            end
            log.event("Nested command %s (seq=%d) saved, group=%s",
                command.type, sequence_number, tostring(root_command_sequence_number))
            apply_command_mutations(command)
        else
            result.success = false
            result.error_message = "Failed to save nested command to database"
            execution_success = false
            history.decrement_sequence_number()
            -- Roll back only when an explicit undo group owns the
            -- savepoint. When NOT inside an undo group, the nested
            -- command is a plain sub-call from a parent executor; the
            -- parent's top-level failure path will handle rollback.
            -- Calling rollback_transaction here would double-pop the
            -- parent's single mutation snapshot.
            if history.get_current_undo_group_id() then
                rollback_transaction()
            end
        end
    else
        command.status = "Failed"
        history.decrement_sequence_number()
        -- Same rationale as the save-failed branch: only unwind the
        -- savepoint when an explicit group is active.
        if history.get_current_undo_group_id() then
            rollback_transaction()
        end
    end

    exec_scope:finish(execution_success and "success_nested" or "failure_nested")
    return result
end

-- Main execute function
-- 017 FR-005/020/021a: sequence_id + playhead auto-injection.
--
-- Routing class is derived from the schema arg's `required` flag:
--   args.sequence_id = { required = true }   → ACTIVE-RECORD routing.
--     Edit-class commands (Insert, Overwrite, Blade, Trim, Nudge,
--     ExtendEdit, SelectClips, AddTrack, etc.) always land on the
--     active record regardless of what the user is parked on — you
--     can't edit the master from the source tab.
--   args.sequence_id = {}  (not required)    → DISPLAYED-SIDE routing.
--     Movement-class (MovePlayhead, GoToStart/End, SetMark, etc.) acts
--     on whatever the user is parked on (source tab/viewer or record
--     timeline) per transport.engine_for_target().
--
-- Overrides:
--   SPEC.targets_rec_sequence = true   force ACTIVE-RECORD (rarely needed
--     since the required-flag rule covers most cases; provided for
--     commands that don't declare sequence_id in args).
--   SPEC.caller_supplied_sequence_id = true   no injection at all. Used
--     by sequence-management commands (DeleteSequence, RenameSequence)
--     and metadata setters where the caller (menu, dialog, tree click)
--     always supplies an explicit id.
--
-- Playhead auto-injection (centralized — Insert/Overwrite/ExtendEdit etc.
-- no longer resolve it locally): any command whose SPEC declares
-- `args.playhead` receives it from the routing-appropriate transport
-- engine. Pre-bootstrap (headless tests), the persisted
-- `sequences.playhead_position` is the authoritative source — the same
-- value the transport engine would converge to once bootstrapped.

-- Classify the routing class for a command's SPEC. Returns
-- "active_record", "movement", or "none".
local function classify_routing(spec)
    if spec.caller_supplied_sequence_id == true then return "none" end
    local seq_arg = spec.args and spec.args.sequence_id
    if spec.targets_rec_sequence == true then return "active_record" end
    if seq_arg == nil then return "none" end
    if seq_arg.required == true then return "active_record" end
    return "movement"
end

-- Resolve the transport engine relevant to a routing class. nil when
-- transport hasn't been bootstrapped (headless tests, pre-project boot).
-- Precondition: routing ∈ {"active_record","movement"}. Statically
-- enforced by classify_routing's return type + inject_context's
-- "none" guard, so no runtime assert here (per ENG 2.21
-- statically-verifiable preferred over runtime checks).
local function transport_engine_for_routing(routing)
    local transport = require("core.playback.transport")
    if not transport.is_bootstrapped() then return nil end
    if routing == "active_record" then
        return transport.engine_for_role("record")
    end
    return transport.engine_for_target()
end

-- Resolve sequence_id from transport (live binding) or, pre-bootstrap,
-- from the module-level active_sequence_id. Returns nil when neither is
-- available; the caller surfaces that via schema-required validation.
local function resolve_injected_sequence_id(te)
    if te and te.loaded_sequence_id then
        return te.loaded_sequence_id
    end
    if active_sequence_id and active_sequence_id ~= "" then
        return active_sequence_id
    end
    return nil
end

-- Resolve playhead for MOVEMENT-class commands. Authority is the live
-- transport engine, ONLY when it's currently bound to a sequence —
-- otherwise its position is meaningless. Pre-bootstrap or unbound:
-- no injection; commands fall back to their own "ask the active
-- sequence monitor" surface (SetMark, MovePlayhead's executor).
local function resolve_movement_playhead(te)
    if not (te and te.loaded_sequence_id) then return nil end
    return te:get_position()
end

-- Resolve playhead for ACTIVE-RECORD-class commands. Authority is the
-- record engine when it's bound to our sequence; otherwise the model's
-- persisted playhead_position (authoritative for headless tests and for
-- engines bootstrapped but not yet bound).
local function resolve_active_record_playhead(te, sequence_id)
    if not (sequence_id and sequence_id ~= "") then return nil end
    if te and te.loaded_sequence_id == sequence_id then
        local pos = te:get_position()
        if pos ~= nil then return pos end
    end
    local Sequence = require("models.sequence")
    local seq = Sequence.find(sequence_id)
    if not seq then return nil end
    return seq.playhead_position
end

-- Inject sequence_id and/or playhead into `params` based on the command's
-- SPEC. Single entry point for both string-form and object-form dispatch.
--
-- Per-routing contracts:
--   MOVEMENT (017 FR-005, unchanged): sequence_id and playhead are PAIRED
--     via transport.engine_for_target() — the displayed-side engine owns
--     both. Inject the pair only when sequence_id is absent; if the caller
--     pinned sequence_id, the transport's playhead may belong to a
--     different sequence and is therefore not trustworthy. Executor falls
--     back to timeline_state.get_playhead_position or its own monitor
--     query in that case.
--   ACTIVE-RECORD: sequence_id and playhead are INDEPENDENT. The active
--     record is well-defined regardless of caller-supplied sequence_id;
--     playhead comes from the record engine when bound, else the model's
--     persisted `sequences.playhead_position`.
--
-- opts.inject_sequence_id (default true): when false, sequence_id is
-- never auto-filled. Object-form callers (M.execute(cmd)) set this to
-- false because they own their sequence_id by contract — a Command
-- object built in script context that omits sequence_id did so on
-- purpose (ImportMedia, undo/redo replay, etc.). Playhead injection is
-- governed by SPEC.args.playhead regardless.
local function inject_context(command_type, params, opts)
    if type(command_type) ~= "string" then return end

    local spec = registry.get_spec(command_type)
    if not spec then return end

    local routing = classify_routing(spec)
    if routing == "none" then return end

    opts = opts or {}
    local may_inject_sequence_id = (opts.inject_sequence_id ~= false)

    if routing == "movement" then
        -- Paired: inject only if sequence_id is missing AND allowed.
        if params.sequence_id ~= nil then return end
        if not may_inject_sequence_id then return end
        local te = transport_engine_for_routing(routing)
        params.sequence_id = resolve_injected_sequence_id(te)
        if params.playhead == nil then
            params.playhead = resolve_movement_playhead(te)
        end
        return
    end

    -- routing == "active_record": independent injection.
    local needs_sequence_id = may_inject_sequence_id and (params.sequence_id == nil)
    local needs_playhead = (params.playhead == nil
        and spec.args and spec.args.playhead ~= nil)
    if not (needs_sequence_id or needs_playhead) then return end

    local te = transport_engine_for_routing(routing)
    if needs_sequence_id then
        params.sequence_id = resolve_injected_sequence_id(te)
    end
    if needs_playhead then
        params.playhead = resolve_active_record_playhead(te, params.sequence_id)
    end
end

function M.execute(command_or_name, params)
    params = params or {}
    -- Centralized context injection (sequence_id + playhead) — same
    -- function for both dispatch forms, posture flag selects the
    -- contract. String-form (UI / menus / keyboard shortcuts) gets
    -- full injection. Object-form (callers that built their own
    -- Command) owns its sequence_id by contract; only playhead is
    -- auto-filled, which is the one piece of context that used to be
    -- duplicated inside Insert/Overwrite/ExtendEdit before centralization.
    if type(command_or_name) == "string" then
        inject_context(command_or_name, params)
    elseif type(command_or_name) == "table" and type(command_or_name.type) == "string" then
        local cmd_params = command_or_name.parameters or {}
        inject_context(command_or_name.type, cmd_params, { inject_sequence_id = false })
        command_or_name.parameters = cmd_params
    end
    -- Auto-wrap in command event if none active (avoids requiring every call site to wrap)
    local auto_wrapped = false
    if not command_event_origin or command_event_depth == 0 then
        M.begin_command_event("ui")
        auto_wrapped = true
    end

    -- Track execution depth for nested command support
    execution_depth = execution_depth + 1

    -- Guard: ensure execution_depth is always decremented even if the body throws
    local ok, result_or_err, command_out = xpcall(function()
        return M._execute_body(command_or_name, params)
    end, debug.traceback)

    execution_depth = execution_depth - 1
    -- Clear root tracking when top-level command finishes
    if execution_depth == 0 then
        root_command_sequence_number = nil
        root_playhead_value = nil
        root_playhead_rate = nil
        root_selected_clips_pre = nil
        root_selected_edges_pre = nil
        root_selected_gaps_pre = nil
    end

    if auto_wrapped then
        M.end_command_event()
    end

    if not ok then
        error(result_or_err)
    end
    return result_or_err, command_out
end

function M._execute_body(command_or_name, params)
    -- During redo, wrapper commands may call execute() but nested cmds are replayed by redo_group
    -- Check early to skip normalize_command which requires an active command event
    if undo_redo_in_progress then
        return { success = true }, nil
    end

    -- Reject nested commands inside an aborted undo group. A prior command
    -- failed and rolled back the entire group — continuing would execute
    -- against inconsistent expectations.
    if execution_depth > 1 and history.is_undo_group_aborted() then
        log.error("execute rejected: undo group aborted by prior failure")
        return { success = false, error_message = "Undo group aborted by prior failure" }, nil
    end

    -- A command is truly nested only when there's an active transaction to
    -- share. A recording command inside a non-recording parent (e.g.,
    -- RelinkClips inside ShowRelinkDialog) must be promoted to top-level
    -- so it gets its own transaction and rollback protection.
    local is_nested = execution_depth > 1
        and (history.get_current_undo_group_id() ~= nil
             or root_command_sequence_number ~= nil)

    local command, normalize_failure = normalize_command(command_or_name, params)
    if not command then
        return normalize_failure, nil
    end

    -- Auto-promote runs after normalize so it can trust command.type and
    -- so a normalize failure can return early without leaking the cleared
    -- parent_is_non_persisting flag. When promoting, clear the flag for
    -- the duration of the promoted command's execution — otherwise any
    -- nested children of the promoted command would also promote, opening
    -- a nested DB transaction inside the promoted parent's open
    -- transaction. Restored in the ::cleanup:: label so the outer
    -- non-persisting wrapper's scope is preserved across the promote.
    local promoted_non_persisting_saved
    if should_auto_promote(command.type) then
        log.event("Auto-promoting %s to top-level (parent is non-persisting)", command.type)
        is_nested = false
        promoted_non_persisting_saved = parent_is_non_persisting
        parent_is_non_persisting = false
    end

    -- Declare all locals upfront to avoid goto scope issues
    local exec_scope, result, scope_ok, scope_err, stack_id, stack_info, stack_opts
    local undo_group_active, snapshot_taken, perf, needs_state_hash, pre_hash
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

    -- Nested commands (depth > 1) share the root's transaction and undo
    -- group. The extracted helper owns the whole nested path and the
    -- exec_scope finalization; the outer body just captures the result
    -- and drops through to cleanup.
    if is_nested then
        result = execute_nested_command(command, exec_scope)
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
        -- Capture root playhead/selection for nested recording commands to inherit.
        if root_playhead_value == nil then
            timeline_state = require('ui.timeline.timeline_state')
            root_playhead_value = timeline_state.get_playhead_position()
            assert(root_playhead_value ~= nil,
                "command_manager: get_playhead_position() returned nil — timeline_state not initialized")
            root_playhead_rate = timeline_state.get_sequence_frame_rate()
            if not command_flag(command, "skip_selection_snapshot", "__skip_selection_snapshot") then
                capture_pre_selection_for_command(command)
                root_selected_clips_pre = command.selected_clip_ids_pre
                root_selected_edges_pre = command.selected_edge_infos_pre
                root_selected_gaps_pre = command.selected_gap_infos_pre
            end
        end
        -- No implicit undo group — commands that need grouping use explicit
        -- begin_undo_group/end_undo_group in their executor (e.g., Blade, DeleteSelection).
        -- Mark parent as non-persisting so any persisting child commands
        -- dispatched from this executor get auto-promoted to top-level
        -- (not silently nested).
        result = execute_as_non_persisting_parent(command)

        exec_scope:finish("non_recording")
        goto cleanup
    end

    -- Commands with no_persist skip transaction handling entirely
    -- (e.g. OpenProject which switches databases mid-execution).
    -- Same rationale as the undoable=false branch: any persisting child
    -- dispatched from this executor gets auto-promoted to top-level.
    if spec and spec.no_persist then
        result = execute_as_non_persisting_parent(command)
        exec_scope:finish("no_persist")
        goto cleanup
    end

    -- Stack routing: determine which undo stack this command belongs to.
    -- Project-level commands go to GLOBAL. Sequence-scoped commands go to their sequence's stack.
    -- Commands that derive sequence_id during execution (Paste, Insert, etc.) have
    -- sequence_id in their spec — use that as a signal to route to the timeline stack.
    do
        local pre_seq_id = extract_sequence_id(command)
        if PROJECT_LEVEL_COMMAND_TYPES[command.type] then
            stack_id = history.GLOBAL_STACK_ID
            stack_opts = nil
        elseif pre_seq_id then
            stack_id = history.stack_id_for_sequence(pre_seq_id)
            stack_opts = {sequence_id = pre_seq_id}
        else
            -- Check if this command type has sequence_id in its spec.
            -- If so, it will derive it during execution — route to the active timeline stack.
            local cmd_spec = registry.get_spec(command.type)
            local has_seq_in_spec = cmd_spec and cmd_spec.args and cmd_spec.args.sequence_id
            if has_seq_in_spec and active_sequence_id then
                stack_id = history.stack_id_for_sequence(active_sequence_id)
                stack_opts = {sequence_id = active_sequence_id}
            else
                stack_id = history.GLOBAL_STACK_ID
                stack_opts = nil
            end
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
        local db_module = require("core.database")
        if not db_module.begin_transaction() then
            result.error_message = "Failed to begin transaction"
            exec_scope:finish("begin_tx_failed")
            goto cleanup
        end
        -- Mutation transaction parallels the DB transaction: snapshot in-memory
        -- clip state so rollback_transaction can restore it if the command fails.
        -- (For explicit undo groups, begin_undo_group handles this.)
        -- Commands that only modify sequence/track/project metadata (not
        -- clips) can declare spec.skip_clip_snapshot to avoid cloning every
        -- clip in the active sequence on every execution. For a 3000+ clip
        -- project dragged in a slider, that's the difference between
        -- smooth and stutter. Default is to snapshot (safe).
        if not (spec and spec.skip_clip_snapshot) then
            snapshot_taken = true
            local clip_state = require("ui.timeline.state.clip_state")
            clip_state.begin_mutation_transaction()
        end
    end

    perf = create_command_perf_tracker(command)
    needs_state_hash = should_compute_state_hash(command)
    -- Always compute pre_hash: needed for NSF mutation check (assert if DB
    -- changed but executor produced no __timeline_mutations).
    -- Scoped to active sequence to avoid scanning entire project (127K+ clips).
    perf.reset()
    pre_hash = state_mgr.calculate_state_hash(command.project_id, active_sequence_id)
    perf.log("state_hash_pre")
    perf.reset()

    -- Use history module for sequence tracking
    sequence_number = history.increment_sequence_number()
    command.sequence_number = sequence_number
    -- Parent in the undo tree: the per-sequence cursor if available,
    -- otherwise the global cursor (first command on a newly-activated sequence).
    command.parent_sequence_number = history.get_current_sequence_number()
        or history.get_global_cursor()

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
            log.error("Command %d has NULL parent but is not first!", sequence_number)
            rollback_transaction()
            snapshot_taken = false  -- rollback_mutations already popped it
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
        -- Store for nested commands to inherit (they share the same user action context)
        root_selected_clips_pre = command.selected_clip_ids_pre
        root_selected_edges_pre = command.selected_edge_infos_pre
        root_selected_gaps_pre = command.selected_gap_infos_pre
    end

    -- EXECUTE
    exec_result = execute_command_implementation(command)
    perf.log("execute_command_implementation")
    perf.reset()
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

    -- Handle user cancellation (e.g., file dialog dismissed) - no persistence needed
    if type(exec_result) == "table" and exec_result.cancelled then
        result = finish_as_noop(db, history, exec_scope, result, { cancelled = true })
        goto cleanup
    end

    if execution_success then
        command.status = "Executed"
        command.executed_at = os.time()

        -- Normalize selection after trim edits: stale gap edges become clip edges
        -- when the gap has been closed by the edit
        if not skip_selection_snapshot then
            local ok_sel, selection_state = pcall(require, "ui.timeline.state.selection_state")
            if ok_sel and selection_state and type(selection_state.normalize_edge_selection) == "function" then
                selection_state.normalize_edge_selection()
            end
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
            post_hash = state_mgr.calculate_state_hash(command.project_id, active_sequence_id)
            perf.log("state_hash_post")
            perf.reset()
        else
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

        -- Per-Sequence Undo: classify after execution (executors may set sequence_id)
        command.sequence_id = classify_command_sequence_id(command)

        saved = save_command_with_collision_retry(command, db)
        sequence_number = command.sequence_number  -- retry may have reallocated
        perf.log("command:save")
        perf.reset()
        if saved then
            result.success = true
            result.result_data = command:serialize()

            -- Move HEAD - but only if nested commands haven't already advanced past us
            -- (nested commands chain their parent_sequence_number through the cursor).
            -- New commits advance BOTH cursor and tip: tip = leaf of the user's
            -- current branch, which is exactly the just-committed command. If the
            -- user had undone before committing, the prior subtree is orphaned
            -- (still in the commands table, but unreachable via Cmd+Shift+Z because
            -- the tip no longer points there). Tip MUST be set on the stack where
            -- the command actually lands (command.sequence_id column), NOT the
            -- active stack — SetClipProperty has sequence_id in its spec so active
            -- stack is per-seq, but the column ends up NULL and the command lands
            -- on GLOBAL; tip on per-seq would be a no-op for that command's redo.
            local current_cursor = history.get_current_sequence_number()
            local should_advance = not current_cursor or current_cursor < sequence_number
            if command.sequence_id then
                if should_advance then
                    history.set_current_sequence_number(sequence_number)
                    history.set_branch_tip_on_stack(
                        history.stack_id_for_sequence(command.sequence_id),
                        sequence_number)
                end
                history.save_undo_position()
            else
                if should_advance then
                    history.set_branch_tip_on_stack(
                        history.GLOBAL_STACK_ID, sequence_number)
                end
                history.set_global_cursor(sequence_number)
            end

            -- Snapshotting (only for commands that modify existing sequences)
            local snapshot_mgr = require('core.snapshot_manager')
            local force_snapshot = command_flag(command, "force_snapshot", "__force_snapshot")
            local seq_id = command:get_parameter("sequence_id")
            if seq_id and (force_snapshot or snapshot_mgr.should_snapshot(sequence_number)) then
                 local clips = require('core.database').load_clips(seq_id)
                 snapshot_mgr.create_snapshot(db, seq_id, sequence_number, clips)
                 perf.log("snapshotting")
                 perf.reset()
            end

            -- PRE-COMMIT MUTATION VALIDATION
            -- Catch garbage mutations before they reach the DB. If a command
            -- produced obviously wrong results (e.g., a clip delete from a
            -- constraint calculation bug), rollback instead of committing.
            -- NOTE: Legitimate trim-to-zero deletes ARE allowed — they happen
            -- when |delta| >= clip duration. A garbage delete happens when the
            -- user's requested delta is too small to reach zero but a broken
            -- per-edge constraint amplifies it internally.
            local mutation_order = command:get_parameter("executed_mutation_order")
            if type(mutation_order) == "table" and #mutation_order > 0 then
                local original_states = command:get_parameter("original_states")
                local delta_frames = command:get_parameter("delta_frames")
                for _, mut in ipairs(mutation_order) do
                    if mut.type == "delete" and original_states and original_states[mut.clip_id] then
                        local orig = original_states[mut.clip_id]
                        if orig.duration and type(delta_frames) == "number" then
                            local abs_delta = math.abs(delta_frames)
                            -- A delete is only legitimate when the user's delta
                            -- is large enough to trim the clip to zero duration.
                            -- If |delta| < duration, the clip should NOT be deleted —
                            -- a constraint bug amplified the delta internally.
                            if abs_delta < orig.duration then
                                log.error("PRE-COMMIT REJECTED: %s would delete clip %s "
                                    .. "(duration=%d but |delta|=%d is too small to reach zero). "
                                    .. "Likely a constraint bug. Rolling back.",
                                    command.type, tostring(mut.clip_id),
                                    orig.duration, abs_delta)
                                rollback_transaction()
                                snapshot_taken = false  -- rollback_mutations already popped it
                                history.decrement_sequence_number()
                                result.success = false
                                result.error_message = string.format(
                                    "Safety rollback: %s would delete clip (duration=%d) with delta=%d",
                                    command.type, orig.duration, delta_frames)
                                exec_scope:finish("mutation_validation_failed")
                                goto cleanup
                            end
                        end
                    end
                end
            end

            -- Bump mutation_generation inside the commit transaction so
            -- nested-sequence references observing the counter see the
            -- increment atomically with the mutation itself.
            increment_sequence_generation_if_scoped(command)

            -- COMMIT (skip if undo group is active - savepoint will handle commit)
            if not undo_group_active then
                local db_module = require("core.database")
                assert(db_module.commit(), "command_manager: post-command commit failed")
                -- Discard mutation snapshot (commit: in-memory state is now
                -- authoritative). Guarded on snapshot_taken — a command that
                -- declared skip_clip_snapshot never pushed a snapshot, so
                -- there's nothing to commit.
                if snapshot_taken then
                    local clip_state = require("ui.timeline.state.clip_state")
                    clip_state.commit_mutation_transaction()
                    snapshot_taken = false
                end
                -- Transaction is committed. Any post-commit emits queued by
                -- the executor (e.g. CreateSequence's sequence_list_changed)
                -- can now fire — DB state is authoritative.
                flush_post_commit_emits()
            end
            perf.log("db_commit")
            perf.reset()

            -- UI Refresh / Mutation Handling
            local skip_timeline_reload = command_flag(command, "skip_timeline_reload", "__skip_timeline_reload")
            if not skip_timeline_reload then
                 local reload_sequence_id = extract_sequence_id(command)
                 local applied_mutations = false
                 local timeline_active_seq = timeline_state.get_tab_strip():active_sequence_id()
                 if reload_sequence_id and reload_sequence_id ~= "" and (not timeline_active_seq or timeline_active_seq == "") then
                     -- Tests/headless command execution may run without timeline UI bootstrap; initialize on demand.
                     timeline_state.init(reload_sequence_id, command.project_id)
                 end

                 applied_mutations = apply_command_mutations(command)

                 if not applied_mutations and reload_sequence_id and reload_sequence_id ~= "" then
                     -- NSF: distinguish "executor forgot mutations" from
                     -- "mutations present but UI cache unavailable (test env)".
                     local has_mutations = command:get_parameter("__timeline_mutations") ~= nil
                     if not has_mutations then
                         local is_project_level = is_non_clip_mutating_command(command.type)
                             or not command.sequence_id
                         local has_nested_children = command.undo_group_id
                             and #history.find_group_members(command.undo_group_id, nil, nil) > 1
                         if not is_project_level and not has_nested_children then
                             local mutation_check_hash = state_mgr.calculate_state_hash(command.project_id, active_sequence_id)
                             assert(mutation_check_hash == pre_hash, string.format(
                                 "execute: command %s modified DB but produced no __timeline_mutations "
                                 .. "for sequence %s. Fix the executor to produce mutations.",
                                 command.type, reload_sequence_id))
                         end
                     end
                     reload_clips_after_no_mutations(command.type, reload_sequence_id)
                 end
                 perf.log("ui_refresh")
                 perf.reset()
            end

            notify_command_event({
                event = "execute",
                command = command,
                project_id = command.project_id,
                stack_id = stack_id,
                sequence_number = sequence_number
            })
            perf.log("notify_command_event")

        else
            result.error_message = "Failed to save command to database"
            rollback_transaction()
            snapshot_taken = false  -- rollback_mutations already popped it
            history.decrement_sequence_number()
        end
    else
        command.status = "Failed"
        result.error_message = execution_error_message ~= "" and execution_error_message
            or (last_error_message ~= "" and last_error_message or "Command execution failed")
        last_error_message = ""
        rollback_transaction()
        snapshot_taken = false  -- rollback_mutations already popped it
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
    -- If we own a mutation snapshot that wasn't committed or rolled back
    -- (noop, cancel, early exit), discard it by committing it — the
    -- in-memory clip state is already in the desired post-command shape
    -- either way. Guarded because skip_clip_snapshot commands never push
    -- a snapshot, and the success/rollback branches above set this false
    -- to signal "already handled".
    if snapshot_taken then
        local clip_state = require("ui.timeline.state.clip_state")
        clip_state.commit_mutation_transaction()
        snapshot_taken = false
    end
    -- Restore the parent's non-persisting scope after a promote. See the
    -- promote block at the top of _execute_body for the rationale.
    if promoted_non_persisting_saved ~= nil then
        parent_is_non_persisting = promoted_non_persisting_saved
    end
    return result, command
end

function M.get_last_command(project_id)
    -- In merged view, "last command" is the most recent done across sequence + global cursors
    local target = history.find_merged_undo_target(get_effective_sequence_id())
    if not target then return nil end
    return M.get_command_at_sequence(target.sequence_number, project_id)
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
    -- Load filtered history: active sequence + global (project-level) commands
    local Command = require("command")
    local eff_seq_id = get_effective_sequence_id()
    local seq_cursor = eff_seq_id and (history.get_sequence_cursor(eff_seq_id) or 0) or 0
    local global_cursor = history.get_global_cursor() or 0
    local commands = Command.load_filtered_history_branch(seq_cursor, global_cursor, eff_seq_id)
    local cmd_labels = require("core.command_labels")

    -- Identify undo groups: first/last member, count
    local group_first = {}   -- gid → lowest seq
    local group_last = {}    -- gid → highest seq
    local group_count = {}   -- gid → member count
    for _, cmd in ipairs(commands) do
        local gid = cmd.undo_group_id
        if gid then
            local seq = cmd.sequence_number or 0
            if not group_first[gid] or seq < group_first[gid] then
                group_first[gid] = seq
            end
            if not group_last[gid] or seq > group_last[gid] then
                group_last[gid] = seq
            end
            group_count[gid] = (group_count[gid] or 0) + 1
        end
    end

    -- Build visible entry list: one entry per command or per group
    local out = {}
    local visible_seq_for = {}  -- maps any seq → visible representative seq

    for _, cmd in ipairs(commands) do
        local seq = cmd.sequence_number or 0
        local gid = cmd.undo_group_id
        local count = gid and group_count[gid] or 1

        if gid and count > 1 then
            -- Group member: only emit for first member, skip rest
            visible_seq_for[seq] = group_first[gid]
            if seq == group_first[gid] then
                local base = cmd_labels.label_for_type(cmd.type) or cmd:label()
                out[#out + 1] = {
                    sequence_number = seq,
                    command_type = cmd.type,
                    sequence_id = cmd.sequence_id,
                    timestamp = cmd.created_at,
                    label = base .. " (" .. count .. ")",
                    group_last = group_last[gid],
                }
            end
        else
            -- Single command (no group or group of 1)
            visible_seq_for[seq] = seq
            out[#out + 1] = {
                sequence_number = seq,
                command_type = cmd.type,
                sequence_id = cmd.sequence_id,
                timestamp = cmd.created_at,
                label = cmd:label(),
                group_last = gid and group_last[gid] or nil,
            }
        end
    end

    -- Map current cursor to visible representative.
    -- In merged view, the "current position" is the most recent done command
    -- across both the sequence cursor and global cursor.
    -- NOTE: math.max is a proxy for "most recent" — it works because sequence_numbers
    -- are monotonically assigned and timestamps are monotonically increasing (same thread).
    -- find_merged_undo_target uses timestamp comparison which must agree with this.
    local current_seq = math.max(seq_cursor, global_cursor)
    local visible_current = visible_seq_for[current_seq] or current_seq

    return out, visible_current
end

-- parent_of maps seq→parent_sequence_number (load_parent_tree coerces
-- top-level NULL to 0, so parent_of[existing_seq] is always defined;
-- nil means `seq` isn't in the DB, which is a DB inconsistency bug).
local function next_parent(seq, parent_of)
    local parent = parent_of[seq]
    assert(parent, string.format(
        "jump_to_sequence_number: parent_of[%d] missing — command not in DB", seq))
    return parent
end

local function collect_ancestors_into(set, start_seq, parent_of)
    local seq = start_seq
    while true do
        set[seq] = true
        if seq == 0 then return end
        seq = next_parent(seq, parent_of)
    end
end

local function build_chain_from(start_seq, parent_of)
    local chain = {}
    local seq = start_seq
    while true do
        table.insert(chain, seq)
        if seq == 0 then return chain end
        seq = next_parent(seq, parent_of)
    end
end

local function find_lca(chain, ancestor_set)
    for i, seq in ipairs(chain) do
        if ancestor_set[seq] then return seq, i end
    end
    return nil, nil
end

-- Uses the same scope-filtered cursor as the history panel (active
-- sequence stack + global stack); the loop's termination check must
-- agree with what M.undo() consumes.
function M:jump_to_sequence_number(target_sequence_number)
    if type(target_sequence_number) ~= "number" or target_sequence_number < 0 then
        return false, "Invalid target sequence number"
    end
    if not db then
        return false, "No database connection"
    end

    local function merged_current()
        return history.merged_current_sequence_number(get_effective_sequence_id())
    end

    if target_sequence_number == merged_current() then
        return true
    end

    local Command = require("command")
    local parent_of, exists = Command.load_parent_tree()

    if target_sequence_number ~= 0 and not exists[target_sequence_number] then
        return false, "Unknown sequence number: " .. tostring(target_sequence_number)
    end

    -- Walk from BOTH raw cursors: parent_sequence_number chains can hop
    -- stacks, so walking only one cursor can miss ancestors on the other.
    local seq_id = get_effective_sequence_id()
    local seq_cursor = (seq_id and history.get_sequence_cursor(seq_id)) or 0
    local global_cursor = history.get_global_cursor() or 0
    local ancestor_set = {}
    collect_ancestors_into(ancestor_set, seq_cursor, parent_of)
    collect_ancestors_into(ancestor_set, global_cursor, parent_of)

    local target_chain = build_chain_from(target_sequence_number, parent_of)
    local lca, lca_index = find_lca(target_chain, ancestor_set)
    if not lca_index then
        return false, "Failed to compute history join point"
    end

    while merged_current() ~= lca do
        local result = M.undo()
        if not result.success then
            return false, "Undo failed: " .. result.error_message
        end
    end

    for i = lca_index - 1, 1, -1 do
        local result = M.redo_to_sequence_number(target_chain[i])
        if not result.success then
            return false, "Redo failed: " .. result.error_message
        end
    end

    -- Postcondition: the undo/redo sequence must have landed exactly at
    -- the requested target. Silent drift would leave the UI showing the
    -- wrong history position with no indication a jump went wrong.
    local landed = merged_current()
    assert(landed == target_sequence_number, string.format(
        "jump_to_sequence_number: expected merged cursor at %d after jump, " ..
        "got %d (lca=%d, chain_len=%d)",
        target_sequence_number, landed, lca, #target_chain))

    return true
end

-- Helper to fetch specific command (restored from DB)
function M.get_command_at_sequence(seq_num, project_id)
    if not db or not seq_num then return nil end
    -- Delegate to Command model (no raw SQL in command_manager)
    local Command = require("command")
    return Command.load_at_sequence(seq_num, project_id)
end

--- Get the effective sequence_id for merged undo/redo walk.
-- Uses the active stack's sequence_id, falling back to active_sequence_id.
get_effective_sequence_id = function()
    return history.get_current_stack_sequence_id(false) or active_sequence_id
end

function M.can_undo()
    if not db then return false end
    return history.can_undo_merged(get_effective_sequence_id())
end

function M.can_redo()
    if not db then return false end
    return history.can_redo_merged(get_effective_sequence_id())
end

function M.undo()
    if not M.can_undo() then
        return { success = false, error_message = "Nothing to undo" }
    end

    -- Find the most recent done command in the merged view
    local target = history.find_merged_undo_target(get_effective_sequence_id())
    if not target then
        return { success = false, error_message = "Nothing to undo" }
    end

    local cmd = M.get_command_at_sequence(target.sequence_number, active_project_id)
    if not cmd then
        return { success = false, error_message = "Command not found at sequence " .. tostring(target.sequence_number) }
    end

    -- Undo group or single command
    if cmd.undo_group_id then
        return M.undo_group(cmd.undo_group_id)
    else
        return M.execute_undo(cmd)
    end
end

--- Core undo: run undoer + apply mutations. No cursor/selection/playhead/notify.
-- Mirrors the lean nested forward execution path.
local function run_undoer(cmd)
    local undoer = registry.get_undoer(cmd.type)
    if not undoer then
        registry.load_command_module("Undo" .. tostring(cmd.type))
        undoer = registry.get_undoer(cmd.type)
    end
    if not undoer then
        return false, string.format("No undoer registered for %s", tostring(cmd.type))
    end

    -- Clear forward-execution mutations so the undoer writes clean reverse mutations.
    cmd:set_parameter("__timeline_mutations", nil)

    local ok, exec_result, extra = pcall(undoer, cmd)
    if not ok then
        return false, tostring(exec_result)
    end
    local success, err_msg = normalize_executor_result(exec_result)
    if not success then
        if (not err_msg or err_msg == "") and type(extra) == "string" then
            err_msg = extra
        end
        -- Fall through to last_error_message (set by set_last_error in undoers)
        if not err_msg or err_msg == "" then
            err_msg = last_error_message ~= "" and last_error_message or "Undo executor returned false"
        end
        last_error_message = ""
        return false, err_msg
    end

    if not apply_command_mutations(cmd) then
        local seq_id = extract_sequence_id(cmd)
        if seq_id and seq_id ~= "" then
            -- Wrapper commands (Insert, Overwrite) delegate to nested AddClipsToSequence
            -- which produces the mutations. Only warn for leaf commands.
            local has_nested = cmd.undo_group_id
                and #history.find_group_members(cmd.undo_group_id, nil, nil) > 1
            local no_muts_expected = cmd.parameters
                and cmd.parameters.__no_timeline_mutations_expected
            if not is_non_clip_mutating_command(cmd.type)
                and not has_nested
                and not no_muts_expected then
                log.error("run_undoer: command %s produced no __timeline_mutations for sequence %s\n%s",
                    cmd.type, seq_id, debug.traceback("", 2))
            end
            reload_clips_after_no_mutations(cmd.type, seq_id)
        end
    end
    return true, nil
end

--- Undo ceremony: cursor, selection, playhead, notify. Called once after undoer(s).
local function apply_undo_ceremony(cmd)
    history.move_cursor_for_undo(cmd)
    -- Persist the cursor for sequence-scoped commands
    if cmd.sequence_id then
        history.save_undo_position()
    end
    state_mgr.restore_selection_from_serialized(
        cmd.selected_clip_ids_pre, cmd.selected_edge_infos_pre, cmd.selected_gap_infos_pre,
        command_helper.collect_deleted_clip_ids(cmd))
    if cmd.playhead_value ~= nil then
        local ts = require('ui.timeline.timeline_state')
        if ts.set_playhead_position then
            ts.set_playhead_position(cmd.playhead_value)
        end
    end
    -- Viewport surfacing policy: surface the change region of the undone
    -- command (from __timeline_mutations), falling back to the playhead
    -- when no region is present (e.g. non-clip-mutating commands).
    require("ui.timeline.viewport_policy").apply_post_command("undo", cmd)
    notify_command_event({
        event = "undo",
        command = cmd,
        project_id = cmd.project_id,
    })
end

function M.undo_group(group_id)
    assert(db, "undo_group: no database connection")

    -- Determine the correct cursor for this group's commands.
    -- Peek at the first command in the group to check if it's sequence-scoped or global.
    local peek = history.find_group_members(group_id, nil, nil)
    if #peek == 0 then
        return { success = false, error_message = "No commands found in undo group" }
    end
    local first_cmd = M.get_command_at_sequence(peek[1], active_project_id)
    local current_seq
    if first_cmd and first_cmd.sequence_id then
        current_seq = history.get_sequence_cursor(first_cmd.sequence_id)
    else
        current_seq = history.get_global_cursor()
    end
    if not current_seq then
        return { success = false, error_message = "Nothing to undo" }
    end

    -- Collect all commands in this group up to the current cursor position,
    -- ordered by sequence_number DESC (highest first = undo in reverse order).
    local seq_numbers = history.find_group_members(group_id, current_seq, nil)
    if #seq_numbers == 0 then
        return { success = false, error_message = "No commands found in undo group" }
    end

    undo_redo_in_progress = true

    -- Run undoers + apply mutations per child (lean path, no ceremony)
    local earliest_cmd = nil
    local group_cmds = {}
    for _, seq in ipairs(seq_numbers) do
        local cmd = M.get_command_at_sequence(seq, active_project_id)
        if not cmd then
            undo_redo_in_progress = false
            return { success = false, error_message = "Command not found at sequence " .. tostring(seq) }
        end
        local success, err_msg = run_undoer(cmd)
        if not success then
            undo_redo_in_progress = false
            return { success = false, error_message = err_msg }, cmd
        end
        earliest_cmd = cmd
        table.insert(group_cmds, cmd)
    end

    -- One generation bump per undo (not per member). The group is a
    -- single user action — wrapper + nested children unwind together.
    increment_sequence_generations_for_commands(group_cmds)

    -- Ceremony once: cursor, selection, playhead, notify
    apply_undo_ceremony(earliest_cmd)
    undo_redo_in_progress = false

    return { success = true }
end

--- Core redo: run executor + save + apply mutations. No cursor/selection/playhead/notify.
local function run_redo_executor(cmd)
    local executor = registry.get_executor(cmd.type)
    if not executor then
        return false, "No executor for redo command: " .. tostring(cmd.type)
    end

    local ok, exec_result = pcall(executor, cmd)
    if not ok then
        return false, tostring(exec_result)
    end
    local success, err_msg = normalize_executor_result(exec_result)
    if not success then
        return false, err_msg or "Redo executor returned false"
    end

    -- Persist updated mutations (e.g., new split clip IDs generated during redo)
    assert(cmd:save(db), string.format(
        "run_redo_executor: failed to persist command %s (seq=%s)",
        cmd.type, tostring(cmd.sequence_number)))

    if not apply_command_mutations(cmd) then
        local seq_id = extract_sequence_id(cmd)
        if seq_id and seq_id ~= "" then
            local has_nested = cmd.undo_group_id
                and #history.find_group_members(cmd.undo_group_id, nil, nil) > 1
            local no_muts_expected = cmd.parameters
                and cmd.parameters.__no_timeline_mutations_expected
            if not is_non_clip_mutating_command(cmd.type)
                and not has_nested
                and not no_muts_expected then
                log.error("run_redo_executor: command %s produced no __timeline_mutations for sequence %s\n%s",
                    cmd.type, seq_id, debug.traceback("", 2))
            end
            reload_clips_after_no_mutations(cmd.type, seq_id)
        end
    end
    return true, nil
end

--- Redo ceremony: cursor, selection, playhead, notify. Called once after executor(s).
local function apply_redo_ceremony(cmd)
    history.move_cursor_for_redo(cmd)
    if cmd.sequence_id then
        history.save_undo_position()
    end
    state_mgr.restore_selection_from_serialized(
        cmd.selected_clip_ids, cmd.selected_edge_infos, cmd.selected_gap_infos,
        command_helper.collect_deleted_clip_ids(cmd))
    local skip_playhead = cmd:get_parameter("__skip_sequence_replay_on_undo")
    if cmd.playhead_value_post ~= nil and not skip_playhead then
        local ts = require('ui.timeline.timeline_state')
        if ts.set_playhead_position then
            ts.set_playhead_position(cmd.playhead_value_post)
        end
    end
    -- Viewport surfacing policy: surface the change region of the redone
    -- command, falling back to the playhead when no region is present.
    if not skip_playhead then
        require("ui.timeline.viewport_policy").apply_post_command("redo", cmd)
    end
    notify_command_event({
        event = "redo",
        command = cmd,
        project_id = cmd.project_id,
    })
end

local function execute_redo_command(cmd)
    assert(cmd, "execute_redo_command requires cmd")

    -- Restore pre-execution selection before re-running the executor.
    -- Commands like Cut derive clip_ids from live selection — without this,
    -- redo fails when selection has changed since the original execution
    -- (e.g., history panel jump after user interaction).
    state_mgr.restore_selection_from_serialized(
        cmd.selected_clip_ids_pre, cmd.selected_edge_infos_pre, cmd.selected_gap_infos_pre,
        command_helper.collect_deleted_clip_ids(cmd))

    undo_redo_in_progress = true
    local success, err_msg = run_redo_executor(cmd)
    if not success then
        last_error_message = err_msg
        undo_redo_in_progress = false
        return { success = false, error_message = err_msg }
    end
    -- Single-command redo: one bump for this user action.
    increment_sequence_generation_if_scoped(cmd)
    apply_redo_ceremony(cmd)
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

    -- Use the appropriate cursor for parent validation
    local expected_parent
    if cmd.sequence_id then
        expected_parent = history.get_sequence_cursor(cmd.sequence_id) or 0
    else
        expected_parent = history.get_global_cursor() or 0
    end
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
    if not M.can_redo() then
        return { success = false, error_message = "Nothing to redo" }
    end

    -- Find the earliest undone command in the merged view
    local target = history.find_merged_redo_target(get_effective_sequence_id())
    if not target then
        return { success = false, error_message = "Nothing to redo" }
    end

    local cmd = M.get_command_at_sequence(target.sequence_number, active_project_id)
    if not cmd then
        return { success = false, error_message = "Redo command not found at sequence " .. tostring(target.sequence_number) }
    end

    if cmd.undo_group_id then
        return M.redo_group(cmd.undo_group_id)
    else
        return M.redo_to_sequence_number(target.sequence_number)
    end
end

-- Interactive (user-initiated) undo/redo entry points.
--
-- Contract parallels execute_interactive:
-- - UI code (keyboard Cmd+Z/Cmd+Shift+Z, menu, meta-commands Undo/Redo)
--   calls undo_interactive / redo_interactive.
-- - Internal plumbing inside executors or tests calls plain M.undo() / M.redo()
--   when they want model mutation without UI post-hooks.
-- - Pass 2 will add viewport-surfacing policy here so undo/redo surface the
--   change region of the undone/redone command without every caller having
--   to do it themselves.
function M.undo_interactive()
    return M.undo()
end

function M.redo_interactive()
    return M.redo()
end

function M.redo_group(group_id)
    assert(db, "redo_group: no database connection")

    -- Determine the correct cursor for this group's commands.
    local all_members = history.find_group_members(group_id, nil, nil)
    local current_seq
    if #all_members > 0 then
        local first_cmd = M.get_command_at_sequence(all_members[#all_members], active_project_id)
        if first_cmd and first_cmd.sequence_id then
            current_seq = history.get_sequence_cursor(first_cmd.sequence_id) or 0
        else
            current_seq = history.get_global_cursor() or 0
        end
    else
        current_seq = 0
    end

    -- Collect all commands in this group after the current cursor position,
    -- ordered by sequence_number ASC (lowest first = redo in chronological order).
    local seq_numbers = history.find_group_members(group_id, nil, current_seq)
    if #seq_numbers == 0 then
        return { success = false, error_message = "No commands found to redo in group" }
    end

    undo_redo_in_progress = true

    -- Run executors + apply mutations per child (lean path, no ceremony)
    local last_cmd = nil
    local root_cmd = nil
    local group_cmds = {}
    for _, seq in ipairs(seq_numbers) do
        local cmd = M.get_command_at_sequence(seq, active_project_id)
        if not cmd then
            undo_redo_in_progress = false
            return { success = false, error_message = "Command not found at sequence " .. tostring(seq) }
        end
        if not root_cmd then root_cmd = cmd end
        local success, err_msg = run_redo_executor(cmd)
        if not success then
            undo_redo_in_progress = false
            return { success = false, error_message = err_msg }, cmd
        end
        last_cmd = cmd
        table.insert(group_cmds, cmd)
    end

    -- One generation bump per redo (not per member). Symmetric with
    -- execute (one wrapper command) and undo_group.
    increment_sequence_generations_for_commands(group_cmds)

    -- Ceremony once: cursor from last command, selection from root
    apply_redo_ceremony(last_cmd)
    if root_cmd and root_cmd ~= last_cmd then
        state_mgr.restore_selection_from_serialized(
            root_cmd.selected_clip_ids, root_cmd.selected_edge_infos, root_cmd.selected_gap_infos,
            command_helper.collect_deleted_clip_ids(root_cmd))
    end
    undo_redo_in_progress = false

    return { success = true }
end

--- Core undo: run undoer + apply mutations. No cursor/selection/playhead/notify.
-- Mirrors the lean nested forward execution path.
function M.execute_undo(original_command)
    log.event("Executing undo for command: %s", tostring(original_command.type))

    undo_redo_in_progress = true

    local success, err_msg = run_undoer(original_command)

    local result = { success = false, error_message = "", result_data = "" }
    if success then
        result.success = true
        local undo_command = original_command:create_undo()
        result.result_data = undo_command:serialize()
        -- Single-command undo: one bump for this user action.
        increment_sequence_generation_if_scoped(original_command)
        apply_undo_ceremony(original_command)
        log.event("Undo successful (position=%s)", tostring(history.get_current_sequence_number()))
    else
        last_error_message = err_msg or "Undo execution failed"
        result.error_message = last_error_message
        log.error("Undo failed: %s", tostring(result.error_message))
    end

    undo_redo_in_progress = false

    return result
end

function M.execute_batch(commands)
    log.event("Executing batch of %d commands", #commands)
    local results = {}
    for _, command in ipairs(commands) do
        local result = M.execute(command)
        table.insert(results, result)
        if not result.success then
            log.error("Batch execution failed at command: %s", tostring(command.type))
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
    log.event("Reverting to sequence: %d", sequence_number)
    -- Delegate to Command model (no raw SQL in command_manager)
    local Command = require("command")
    assert(Command.mark_undone_after(sequence_number),
        "command_manager.revert_to_sequence: failed to revert commands at sequence " .. tostring(sequence_number))
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
        log.warn("replay_events: no database connection")
        return false
    end

    local seq_id = sequence_id or active_sequence_id
    if not seq_id or seq_id == "" then
        log.warn("replay_events: missing sequence_id and no active sequence set")
        return false
    end
    local target_seq = target_sequence_number
    if type(target_seq) ~= "number" then
        target_seq = history.get_current_sequence_number() or 0
    end

    -- Gracefully handle missing sequence rows (e.g., after deletes)
    -- Use Sequence model (no raw SQL in command_manager)
    local Sequence = require("models.sequence")
    local seq_record = Sequence.load(seq_id)
    if not seq_record then
        log.warn("replay_events: sequence '%s' missing; skipping replay", tostring(seq_id))
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
        log.warn("replay_events: timeline reload failed: %s", tostring(err))
        return false
    end

    return true
end

-- Replay from sequence
function M.replay_from_sequence(start_sequence_number)
    log.event("Replaying commands from sequence: %d", start_sequence_number)
    local result = {
        success = true,
        commands_replayed = 0,
        error_message = "",
        failed_commands = {}
    }

    -- Load commands via Command model (no raw SQL in command_manager)
    local Command = require("command")
    local commands = Command.load_from_sequence(start_sequence_number, active_project_id)

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
    log.event("Replaying all commands")
    return M.replay_from_sequence(1)
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
    local prev_seq = active_sequence_id
    active_sequence_id = seq
    local stack_id = history.stack_id_for_sequence(seq)
    history.set_active_stack(stack_id, {sequence_id = seq})

    -- Notify listeners that the active sequence changed (history panel, etc.)
    if prev_seq ~= seq then
        notify_command_event({
            event = "sequence_switched",
            sequence_id = seq,
            project_id = active_project_id,
        })
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
    local db_module = require("core.database")
    local savepoint_name = "undo_group_" .. group_id
    assert(db_module.savepoint(savepoint_name),
        "command_manager.begin_undo_group: failed to create savepoint " .. savepoint_name)

    -- Snapshot in-memory clip state (parallels the DB savepoint)
    local clip_state = require("ui.timeline.state.clip_state")
    clip_state.begin_mutation_transaction()

    return group_id
end

--- Stamp playhead_value_post on the last command in a completed group.
-- Nested commands only capture playhead_value (pre). redo_group needs
-- playhead_value_post on the last child for ceremony.
local function stamp_group_playhead_post(last_cmd)
    if not last_cmd or last_cmd.playhead_value_post ~= nil then return end
    local ts = require('ui.timeline.timeline_state')
    last_cmd.playhead_value_post = ts.get_playhead_position()
    last_cmd.playhead_rate_post = ts.get_sequence_frame_rate()
    assert(last_cmd:save(db),
        string.format("end_undo_group: failed to save playhead_value_post on seq %s",
            tostring(last_cmd.sequence_number)))
end

--- Get the command at the current undo cursor, or nil.
local function get_current_cursor_command()
    local current_seq = history.get_current_sequence_number()
    if not current_seq then return nil end
    return M.get_command_at_sequence(current_seq, active_project_id)
end

function M.end_undo_group()
    -- Check aborted flag BEFORE popping (end_undo_group pops the stack)
    local was_aborted = history.is_undo_group_aborted()
    local group_id = history.end_undo_group()
    if not group_id then return end

    local db_module = require("core.database")
    db_module.release_savepoint("undo_group_" .. group_id)

    local last_cmd = get_current_cursor_command()

    if not was_aborted then
        stamp_group_playhead_post(last_cmd)
        local clip_state = require("ui.timeline.state.clip_state")
        clip_state.commit_mutation_transaction()
    end
    -- If aborted: snapshot already restored by rollback_transaction

    -- Commit + notify once the outermost group closes
    if not history.get_current_undo_group_id() then
        db_module.commit()
        -- Outermost group is now committed. Flush queued post-commit emits
        -- accumulated by member commands. Discard happens via rollback paths
        -- when the group was aborted.
        flush_post_commit_emits()
        -- Notify listeners (edit history, etc.). Nested commands don't fire
        -- notify_command_event, and the non-undoable wrapper (e.g. DeleteSelection)
        -- goes through execute_non_recording which doesn't notify either.
        if last_cmd then
            notify_command_event({
                event = "execute",
                command = last_cmd,
                project_id = last_cmd.project_id,
            })
        end
    end
end

return M
