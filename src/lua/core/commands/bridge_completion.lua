--- bridge_completion: shared async-terminal surface for spec 023's
--- four bridge commands (SendToResolve, ConnectToResolveProject,
--- SyncGradesFromResolve, SyncEditsFromResolve).
---
--- Why this exists. Every bridge command is async-with-callback (helper
--- round-trip happens off the calling thread). The root failure that
--- prompted this module was a TEST-COVERAGE gap: not a single test ever
--- drove these commands through `command_manager.execute_interactive`
--- (the menu / shortcut path), so the SPEC-required `on_complete` arg
--- went undetected for the entire feature. SPEC asserted REQUIRED;
--- `execute_interactive` had nowhere to inject a callback; menu picks
--- hard-failed at the schema validator. The regression gate now lives
--- at `tests/smoke/cases/test_bridge_menu_dispatch.py`.
---
--- The fix flips `on_complete` to OPTIONAL on every bridge command and
--- routes every terminal path through `notify()`. "Every terminal path"
--- has a subtlety: each command's `M.register` wraps `M.execute` in a
--- pcall and routes the caught error through `notify()` — that catches
--- SYNC-phase asserts (input validation, payload_builder, Sequence.load,
--- round-trip validator, anything inside `M.execute` BEFORE
--- `client:request(...)` returns). ASYNC-phase asserts (failures inside
--- the response callback — e.g. `M.apply` invariant violations, ledger
--- upsert, response-shape checks) are deliberately NOT pcall-wrapped:
--- those are internal-invariant violations that must crash hard per
--- rule 1.14, not be downgraded to a toast. The four command files
--- each carry a brief in-callback comment pointing at this docstring.
--- If a future debugger sees a frozen UI + no counter advance, the
--- async response handler is the thing to check — not a regression in
--- this contract.
---
--- `notify()` is one place that:
---   1. emits the OP-SPECIFIC completion signal
---      (`<op_snake>_completed`), mirroring the rest of
---      `core/signals.lua` (per-op, never a tagged generic). Subscribers
---      pick exactly the op they care about.
---   2. logs the outcome (event on success, error on failure) — the
---      user-visible feedback path today, before a toast layer lands.
---   3. calls `args.on_complete(result, code, message)` when the
---      caller supplied one. Programmatic callers (scripted tests,
---      future automations) keep working unchanged.
---   4. bumps a monotonic per-op counter. Smokes assert the counter
---      advanced — the actual completion contract is "the async tail
---      reached `notify`", not just "no Lua error on the click."
---      Without the counter, a future regression that pcall-swallows
---      the async tail false-greens the menu-dispatch smoke.
---
--- Signal asymmetry — important to keep straight (do NOT merge these):
---   * `grades_changed(sequence_id)` (already exists; fires from
---     SyncGradesFromResolve.apply / .restore) is a MODEL-MUTATION
---     signal. Cache subscribers (SequenceMonitor's clip-grade cache)
---     want this — "the grade rows changed, drop stale cache."
---   * `sync_grades_from_resolve_completed(result, code, message)`
---     (new, fires from the async tail via this module) is an
---     OPERATION-FINISHED signal. Toast / dialog / smoke counter want
---     this — "the user-initiated sync op finished, possibly with
---     error."
---   On success both fire (apply emits the model signal, the tail
---   emits the completion signal). On error only `*_completed` fires
---   — no model state was changed.
---
--- Wire shape (same for all four signals, mirrors on_complete signature
--- so signal observers and callback observers see identical payloads):
---   Signals.emit("<op_snake>_completed", result, code, message)
---     result  : op-specific success table, or nil on failure
---     code    : structured error code (string) on failure, nil on ok
---     message : human-readable message on failure, nil on ok
---
--- Per-op registration: every bridge command MUST call
--- `register_op(op_name, signal_name)` at module load. This binds the
--- (op → signal) map and zero-initializes the completion counter —
--- so `notify` and `completion_count` never need fallback `or 0` reads
--- (rule 2.13). Unregistered ops fail loudly (rule 1.14), catching the
--- typo "SendToResolv" before the wire.

local M = {}

local Signals = require("core.signals")
local log     = require("core.logger").for_area("media")

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
--- directly from inside M.execute and bypass this wrapper. Those are
--- uncatchable on the response thread by design (rule 1.14):
--- invariant violations in the async tail are real internal bugs that
--- must crash, not be downgraded.
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
--- bridge commands (SendToResolve, ConnectToResolveProject) ignore the
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
