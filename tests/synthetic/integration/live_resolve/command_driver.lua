--- Shared e2e driver for spec-023 LIVE tests that exercise the REAL
--- bridge commands (SendToResolve / SyncGradesFromResolve /
--- ConnectToResolveProject) inside `jve --test` against the VM's
--- Resolve Studio.
---
--- Lifted from test_reconform.lua when test_connect_imported.lua became
--- its second consumer (DRY at the would-be third copy: T055 is next).
---
--- Channels:
---   • Commands are observed via their `*_completed` SIGNAL — the
---     production channel. Do NOT pass args.on_complete to UNDOABLE
---     bridge commands: function args crash Command.save's JSON
---     encoding (todo_023_on_complete_undoable_json).
---   • Direct helper verbs go through the SAME supervisor client the
---     commands use (one helper process, one Resolve connection).
---
--- `qt_constants` is a global injected by jve --test.

local command_manager = require("core.command_manager")
local supervisor = require("core.resolve_bridge.helper_supervisor")
local Signals = require("core.signals")

local M = {}

function M.repo_root()
    local src = debug.getinfo(1, "S").source:sub(2)
    return src:gsub("/tests/synthetic/integration/live_resolve/[^/]+$", "")
end

--- Pump the Qt event loop until `predicate()` is true; error on timeout.
function M.pump_until(label, ticks, predicate)
    for _ = 1, ticks do
        if predicate() then return end
        qt_constants.CONTROL.PROCESS_EVENTS()
        os.execute("sleep 0.02")
    end
    error(string.format("command_driver: timed out waiting for %s "
        .. "(%d ticks)", label, ticks))
end

--- Dispatch a bridge command, await its completion signal, return the
--- success result (asserts on structured error).
function M.run_bridge_command(name, signal_name, args)
    local done, result, code, message = false, nil, nil, nil
    local conn = Signals.connect(signal_name, function(r, c, m)
        done, result, code, message = true, r, c, m
    end)
    local exec = command_manager.execute(name, args)
    assert(exec and exec.success ~= false, string.format(
        "%s dispatch failed: %s", name,
        tostring(exec and exec.error_message)))
    M.pump_until(name .. " completion signal", 1500,
        function() return done end)
    Signals.disconnect(conn)
    assert(code == nil, string.format(
        "%s completed with error %s/%s", name,
        tostring(code), tostring(message)))
    return result
end

--- Single helper verb round-trip returning a normalized envelope —
--- for edge-case tests that EXPECT structured errors. The client
--- delivers ok responses as the parsed envelope and structured errors
--- as (nil, code, message) (client.lua dispatch_line); normalize both
--- to { ok, result?, error? = {code, message} }.
function M.helper_request_envelope(verb, args)
    local c = assert(supervisor.ensure_client(),
        "command_driver: supervisor.ensure_client failed")
    local done, response, code, message = false, nil, nil, nil
    c:request(verb, args, function(r, cd, m)
        done, response, code, message = true, r, cd, m
    end)
    M.pump_until(verb .. " response", 1500, function() return done end)
    if response ~= nil then
        assert(response.ok == true, string.format(
            "command_driver: client delivered a non-ok envelope as "
            .. "success for %s", verb))
        return response
    end
    assert(code ~= nil, string.format(
        "command_driver: %s produced neither envelope nor error code",
        verb))
    return { ok = false, error = { code = code, message = message } }
end

--- Single helper verb round-trip through the supervisor's client.
--- Asserts ok=true; returns response.result.
function M.helper_request(verb, args)
    local response = M.helper_request_envelope(verb, args)
    assert(response.ok == true, string.format(
        "command_driver: %s failed — %s/%s", verb,
        tostring(response.error and response.error.code),
        tostring(response.error and response.error.message)))
    return response.result
end

--- Monotonic change tokens for direct test-verb calls (each call is a
--- distinct logical mutation; the per-verb extra-key fields keep
--- distinct payloads from conflating regardless).
local token_n = 100
function M.fresh_token(project_id, sequence_id)
    token_n = token_n + 1
    return { project_id = project_id, sequence_id = sequence_id,
             mutation_generation = token_n }
end

--- ping through the production client; skip (exit 0, visibly) when
--- Resolve isn't attached — mirrors live_fixture.skip_unless_live.
function M.skip_unless_live(test_name)
    local ping = M.helper_request("ping", {})
    if ping.resolve_connected ~= true then
        print(string.format(
            "SKIPPED: %s — Resolve Studio not attached", test_name))
        supervisor.shutdown()
        os.exit(0)
    end
end

return M
