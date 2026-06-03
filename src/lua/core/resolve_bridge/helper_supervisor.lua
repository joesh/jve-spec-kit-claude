--- Resolve helper supervisor — lifecycle policy in Lua over the thin
--- `qt_process_*` + `qt_local_socket_*` FFI (spec 023, T023, FR-007).
---
--- Responsibilities:
---   • Start the helper Python process on first use.
---   • Re-start it on crash, surfacing a structured error to whoever
---     was mid-request (no silent retry — FR-007).
---   • Hand callers a connected client (via core.resolve_bridge.client).
---   • Tear down cleanly on app shutdown (kill process, unlink socket).
---
--- NOT responsible for: protocol framing (client.lua), idempotency
--- (helper-side ledger), reconcile algorithm (T036).
---
--- Socket path: per-spawn unique path under /tmp produced by
--- `os.tmpname()` (mktemp-style) with a `.sock` suffix. Joe runs
--- parallel JVE sessions; the prior `/tmp/jve-resolve-bridge-<n>.sock`
--- scheme started <n>=1 in every process and collided. mktemp gives
--- per-process per-spawn uniqueness without a getpid binding and
--- without re-using a socket path on the rare re-spawn race.
--- Helper script: bundled at `jve.app/Contents/Resources/resolve-helper/
--- helper.py` (Joe's decision — Python binary discovered via env/PATH).

local client = require("core.resolve_bridge.client")
local log = require("core.logger").for_area("commands")

local M = {}

local CONNECT_TIMEOUT_MS = 5000
local REQUEST_TIMEOUT_MS = 30000
local STARTUP_GRACE_MS = 3000

local state = {
    process_handle = nil,
    socket_path = nil,
    client_handle = nil,
    helper_script_path = nil,
    spawn_sequence = 0,
}

-- DaVinci Resolve's scripting API is loaded into a Python interpreter
-- by the helper process; phase0-findings.md proved system `python3` is
-- the compatible choice. The lookup is a two-step: explicit env
-- override wins, then bare `python3` resolved against PATH. Both modes
-- are explicit (env or shebang-equivalent name); there is no "guess"
-- fallback to `python` or `python2`. qt_process_start surfaces a
-- structured failure when the named binary is not on PATH.
local DEFAULT_PYTHON_BINARY = "python3"
local function detect_python()
    local override = os.getenv("JVE_RESOLVE_HELPER_PYTHON")
    if override ~= nil and override ~= "" then return override end
    return DEFAULT_PYTHON_BINARY
end

--- Configure the supervisor (called once at app start, before first use).
--- helper_script_path: absolute path to tools/resolve-helper/helper.py
---   (in a packaged app: jve.app/Contents/Resources/resolve-helper/helper.py;
---   in dev: repo's tools/resolve-helper/helper.py).
function M.configure(helper_script_path)
    assert(type(helper_script_path) == "string"
        and helper_script_path ~= "",
        "helper_supervisor.configure: helper_script_path required")
    state.helper_script_path = helper_script_path
end

local function spawn_helper()
    assert(state.helper_script_path,
        "helper_supervisor: configure() must be called first")

    state.spawn_sequence = state.spawn_sequence + 1
    -- os.tmpname yields a fresh unique /tmp/lua_XXXXXX path per call;
    -- remove it (we want the path, not the empty placeholder file —
    -- QLocalServer creates its own socket inode), then re-suffix to
    -- something the user can recognize in `lsof -U` while keeping the
    -- mktemp uniqueness guarantee.
    local base = os.tmpname()
    os.remove(base)
    local socket_path = string.format(
        "%s-jve-resolve-bridge-%d.sock", base, state.spawn_sequence)
    state.socket_path = socket_path

    local proc = qt_process_create()
    state.process_handle = proc

    qt_process_set_finished_cb(proc, function(exit_code, exit_status)
        log.event("helper exited code=%d status=%s",
            exit_code, exit_status)
        -- Drop the client; next request will spawn fresh. The client's
        -- own disconnected-cb resolves any in-flight requests with a
        -- structured error.
        if state.client_handle then
            state.client_handle:close()
            state.client_handle = nil
        end
        state.process_handle = nil
    end)

    qt_process_set_stderr_cb(proc, function(chunk)
        log.event("helper stderr: %s", chunk:gsub("%s+$", ""))
    end)

    qt_process_set_error_cb(proc, function(err_name)
        log.error("helper process error: %s", err_name)
    end)

    local python = detect_python()
    qt_process_start(proc, python, {
        state.helper_script_path,
        "--socket", socket_path,
        "--log-level", "INFO",
    })
    local started = qt_process_wait_for_started(proc, STARTUP_GRACE_MS)
    if not started then
        qt_process_destroy(proc)
        state.process_handle = nil
        state.socket_path = nil
        return nil, "helper_unavailable", string.format(
            "helper process failed to start within %dms", STARTUP_GRACE_MS)
    end
    return socket_path
end

--- Get a connected client. Spawns the helper if needed.
---
--- Returns one of:
---   (client_handle)               on success
---   (nil, code, message)          on failure — code is a closed-set code
---                                 (helper-protocol KNOWN_ERROR_CODES); the
---                                 only one this layer emits today is
---                                 "helper_unavailable" (spawn or socket
---                                 unreachable). Callers pass code+message
---                                 through to bridge_completion.notify;
---                                 closure is enforced by the protocol
---                                 module, not invented here.
function M.ensure_client()
    if state.client_handle then return state.client_handle end

    local socket_path, spawn_code, spawn_msg = spawn_helper()
    if not socket_path then return nil, spawn_code, spawn_msg end

    local c, connect_err = client.connect(socket_path, {
        connect_timeout_ms = CONNECT_TIMEOUT_MS,
        request_timeout_ms = REQUEST_TIMEOUT_MS,
    })
    if not c then
        log.error("client.connect failed: %s", connect_err)
        if state.process_handle then
            qt_process_terminate(state.process_handle)
        end
        return nil, "helper_unavailable", connect_err
    end
    state.client_handle = c
    return c
end

--- Shut down — terminate helper, close client. Idempotent.
function M.shutdown()
    if state.client_handle then
        state.client_handle:close()
        state.client_handle = nil
    end
    if state.process_handle then
        qt_process_terminate(state.process_handle)
        qt_process_destroy(state.process_handle)
        state.process_handle = nil
    end
    if state.socket_path then
        os.remove(state.socket_path)
        state.socket_path = nil
    end
end

return M
