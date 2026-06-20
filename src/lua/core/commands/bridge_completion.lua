--- bridge_completion: shared async-terminal surface for spec 023's
--- bridge commands (SendToResolve, SyncGradesFromResolve,
--- SyncEditsFromResolve).
---
--- Every bridge command is async-with-callback. `notify(args, result,
--- code, message)` is the one terminal path; it
---   1. emits the op's `<op_snake>_completed` signal,
---   2. logs (event on ok, error on failure),
---   3. invokes optional `args.on_complete(result, code, message)`,
---   4. bumps a per-op counter (smokes assert advancement to catch
---      pcall-swallow regressions in the async tail).
---
--- Each command's `M.register` wraps `M.execute` in a pcall and routes
--- the caught error through `notify()` — that catches SYNC-phase asserts
--- (input validation, payload_builder, Sequence.load, anything BEFORE
--- `client:request` returns). ASYNC-phase asserts (failures inside the
--- response callback) MUST ALSO be pcall-caught and routed through
--- `notify()` as a failure: the C++ socket boundary delivering the
--- response (jve_invoke_lua_callback → jve_handle_lua_callback_error)
--- SWALLOWS any error raised on that callback — it logs+pops+continues
--- and never re-raises — so an un-caught async assert never reaches
--- notify(), the `<op>_completed` signal never fires, and any
--- in-progress UI indicator (e.g. FR-016 "Syncing…") hangs until
--- restart. A swallowed assert is a worse 2.32 silent failure than a
--- surfaced one; route it through the one terminal path instead.
---
--- Signal asymmetry — do NOT merge:
---   * `grades_changed(sequence_id)`: model-mutation signal; cache
---     subscribers (SequenceMonitor's grade cache) listen here.
---   * `<op>_completed(result, code, message)`: operation-finished
---     signal; toast / dialog / smoke counter listen here.
---   On success both fire; on error only `<op>_completed` does.
---
--- Per-op registration: every bridge command MUST call
--- `register_op(op_name, signal_name)` at module load. Unregistered
--- ops fail loudly so the typo "SendToResolv" surfaces before the wire.

local M = {}

local Signals = require("core.signals")
local log     = require("core.logger").for_area("commands")

-- (op_name → signal_name) and (op_name → integer counter). Keys are
-- populated by `register_op` at command-module load. Reads are guarded
-- so a typo / missing register call is fail-fast, not silent zero.
local _signals_by_op = {}
local _counts_by_op  = {}

--- Bind an op to its completion signal and zero its counter. Call once
--- at command-module load (top-level), NOT lazily inside a closure.
--- @param op_name string the command's registry name (e.g. "SendToResolve")
--- @param signal_name string per-op completion signal (e.g. "send_to_resolve_completed")
function M.register_op(op_name, signal_name)
    assert(type(op_name) == "string" and op_name ~= "",
        "bridge_completion.register_op: op_name (string) required")
    assert(type(signal_name) == "string" and signal_name ~= "",
        "bridge_completion.register_op: signal_name (string) required")
    assert(_signals_by_op[op_name] == nil,
        "bridge_completion.register_op: op '" .. op_name
        .. "' already registered to signal '"
        .. tostring(_signals_by_op[op_name]) .. "'")
    _signals_by_op[op_name] = signal_name
    _counts_by_op[op_name]  = 0
end

local function assert_terminal_shape(op_name, result, code, message)
    -- A terminal result is either success (result ~= nil, code == nil,
    -- message == nil) or failure (result == nil, code ~= nil). Mixing
    -- these would let a caller silently lose information; fail loudly
    -- per rule 2.32 (no silent failures).
    if result ~= nil then
        assert(code == nil and message == nil,
            "bridge_completion.notify(" .. op_name .. "): success path must "
            .. "pass nil code/message (got code=" .. tostring(code)
            .. ", message=" .. tostring(message) .. ")")
        return
    end
    assert(type(code) == "string" and code ~= "",
        "bridge_completion.notify(" .. op_name .. "): failure path requires "
        .. "non-empty code string (got " .. tostring(code) .. ")")
end

--- Surface a bridge command's terminal result through every channel.
--- @param op_name string the command's registered op name
--- @param args table the command's args table; checked for on_complete
--- @param result table|nil success payload (nil on failure)
--- @param code string|nil structured error code (nil on success)
--- @param message string|nil human-readable message (nil on success)
function M.notify(op_name, args, result, code, message)
    local signal_name = _signals_by_op[op_name]
    assert(signal_name,
        "bridge_completion.notify: op '" .. tostring(op_name)
        .. "' not registered — call register_op at the command "
        .. "module's top level before any execute() can run")
    assert(type(args) == "table",
        "bridge_completion.notify: args table required")
    assert_terminal_shape(op_name, result, code, message)

    if result ~= nil then
        log.event("%s: completed", op_name)
    else
        log.error("%s: %s — %s", op_name, tostring(code),
            tostring(message or ""))
    end

    _counts_by_op[op_name] = _counts_by_op[op_name] + 1

    Signals.emit(signal_name, result, code, message)

    if type(args.on_complete) == "function" then
        args.on_complete(result, code, message)
    end
end

--- Build + install the standard bridge-command executor.
---
--- Every bridge command needs the same executor shape: invoke
--- `execute_fn(args, db)` under pcall, and on a caught error route
--- through notify() so the *_completed signal + counter fire (rule
--- 2.32 — no silent failures: an assert in payload_builder /
--- Sequence.load / round-trip validator must not escape via pcall
--- without the completion contract being satisfied). set_last_error
--- still runs so command_manager's executor (ok, err) protocol stays
--- intact.
---
--- Async (helper response) terminal paths route through notify()
--- directly from inside M.execute and bypass this wrapper. They must
--- pcall the response-handler body themselves and route a caught error
--- through notify() as a failure: the C++ socket boundary swallows
--- errors raised on the response callback (logs+pops+continues, never
--- re-raises), so an un-caught async assert would vanish silently and
--- strand the *_completed signal (rule 2.32) — worse than surfacing it.
---
--- @param command_executors table  executors registry to install into
--- @param op_name string           the command's registered op name
--- @param execute_fn function      M.execute (receives args, db, command)
--- @param db table|nil             open SQLite connection
--- @param set_last_error function  command_manager error-slot callback
--- @return function the installed executor closure
---
--- Why the closure threads `command` through to execute_fn (not just
--- `args`): undoable bridge commands need to persist async-callback
--- results back onto the command parameters so the undoer can find them
--- (SyncGradesFromResolve persists `captured` via
--- `command:set_parameter("captured", ...)` in its read_grades
--- response handler). command_manager holds the same command-object
--- reference in the undo stack, so a late set_parameter is visible to
--- the undoer when the user eventually presses undo. Non-undoable
--- bridge commands (SendToResolve, SyncEditsFromResolve) ignore the
--- third argument.
function M.register_executor(
        command_executors, op_name, execute_fn, db, set_last_error)
    assert(type(command_executors) == "table",
        "bridge_completion.register_executor: command_executors required")
    assert(type(op_name) == "string" and op_name ~= "",
        "bridge_completion.register_executor: op_name (non-empty) required")
    assert(_signals_by_op[op_name],
        "bridge_completion.register_executor: op '" .. op_name
        .. "' not registered — call register_op first")
    assert(type(execute_fn) == "function",
        "bridge_completion.register_executor: execute_fn required")
    assert(type(set_last_error) == "function",
        "bridge_completion.register_executor: set_last_error required")

    local closure = function(command)
        local args = command:get_all_parameters()
        local ok, err = pcall(execute_fn, args, db, command)
        if not ok then
            M.notify(op_name, args, nil, "internal_error", tostring(err))
            set_last_error(op_name .. ": " .. tostring(err))
            return false, tostring(err)
        end
        return true
    end
    command_executors[op_name] = closure
    return closure
end

--- Monotonic per-op completion counter. Smokes snap before, settle, snap
--- after; the delta is the "the async tail actually reached notify"
--- assertion that "no Lua error in log slice" alone can't provide.
--- @param op_name string a registered op name
--- @return integer count
function M.completion_count(op_name)
    local count = _counts_by_op[op_name]
    assert(count ~= nil,
        "bridge_completion.completion_count: op '" .. tostring(op_name)
        .. "' not registered — register_op must run before any "
        .. "smoke / test asks for its count")
    return count
end

return M
