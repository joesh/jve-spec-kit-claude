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
local qt_constants = require("core.qt_constants")
local log = require("core.logger").for_area("commands")

local M = {}

local CONNECT_TIMEOUT_MS = 5000
local REQUEST_TIMEOUT_MS = 30000
local STARTUP_GRACE_MS = 3000
-- qt_process_wait_for_started returns when posix_spawn's fork+exec syscall
-- completes (~1ms). The helper still has to load bash/python, run imports,
-- and call socket.bind — ~70ms cold on a fast machine, longer under load.
-- QLocalSocket::waitForConnected does NOT retry on ServerNotFoundError; its
-- timeout only covers an in-progress connection. So we poll for the
-- socket file ourselves before handing off to client.connect, with a
-- budget separate from the per-connect budget (FR-007: structured error
-- on failure, no silent retry of the underlying request).
local BIND_READY_TIMEOUT_MS = 5000
local BIND_READY_POLL_MS = 25

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
    -- Fail-fast (rule 1.14): existence check happens here so the only
    -- caller path (layout.lua → first Send/Connect) surfaces a useful
    -- error at app-start, not as a runtime qt_process_start "no such
    -- file" on first menu click. Bundle layout: helper.py expected at
    -- jve.app/Contents/Resources/resolve-helper/helper.py in release,
    -- tools/resolve-helper/helper.py in dev.
    local f = io.open(helper_script_path, "r")
    assert(f, string.format(
        "helper_supervisor.configure: helper.py not found at %s — "
        .. "in dev expected at tools/resolve-helper/helper.py; in a "
        .. "packaged build at jve.app/Contents/Resources/resolve-helper"
        .. "/helper.py (check spec 023 packaging)",
        helper_script_path))
    f:close()
    state.helper_script_path = helper_script_path
end

-- Tear down whatever supervisor state may exist. Shared by three
-- callers: spawn_helper's wait_for_started timeout (helper never came
-- up), ensure_client's connect-failed branch (helper came up but
-- socket unreachable / handshake stuck), and public M.shutdown (app
-- teardown). Idempotent — each clause guards its own state slot, so
-- partial state from a half-built spawn cleans up the same way as a
-- fully-running supervisor.
local function _teardown()
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

-- Block until the helper has actually called socket.bind on `socket_path`,
-- OR the process has died, OR we've exceeded the budget. Returns nil on
-- success and an error string on failure (so the caller can pass it
-- through to a structured (code, message) failure per FR-007).
--
-- Why this is necessary: qt_process_wait_for_started's "started"
-- semantic is "fork+exec syscall returned"; the helper still has to
-- load bash/python and run imports before reaching socket.bind. The
-- delta is ~70ms cold. QLocalSocket::waitForConnected fires
-- ServerNotFoundError instantly when the socket file doesn't exist and
-- does NOT retry within its own timeout, so we own the readiness wait
-- here at the supervisor seam — the supervisor's job is to hand the
-- caller a helper that *is* listening (rule 1.14 — fail fast or
-- succeed, never half-state).
--
-- `os.execute("test -S")` is reliable for socket files (which
-- io.open/stat-as-regular-file are not); same probe the binding
-- fixture uses (tests/synthetic/binding/helper_fixture.lua) so prod and test
-- agree on what "ready" means.
local function wait_for_bind(proc, socket_path, timeout_ms)
    local elapsed = 0
    while elapsed < timeout_ms do
        -- QFileInfo::exists() picks up the Unix-domain socket inode the
        -- moment QLocalServer creates it; the shell `test -S` shellout
        -- this replaced forked sh per tick and silently failed under the
        -- Finder-launched .app's stripped PATH.
        if qt_fs_path_exists(socket_path) then
            return nil
        end
        -- If the helper died mid-startup, fail with a distinct message
        -- so log readers don't chase a phantom "slow bind". finished_cb
        -- has already cleared state.process_handle by this point — we
        -- query the QProcess slot directly via the local proc handle.
        if qt_process_state(proc) == "not_running" then
            return "helper exited during startup before binding socket "
                .. socket_path
        end
        qt_constants.CONTROL.PROCESS_EVENTS()
        qt_thread_msleep(BIND_READY_POLL_MS)
        elapsed = elapsed + BIND_READY_POLL_MS
    end
    return string.format(
        "helper did not bind socket %s within %dms",
        socket_path, timeout_ms)
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
        _teardown()
        return nil, "helper_unavailable", string.format(
            "helper process failed to start within %dms", STARTUP_GRACE_MS)
    end

    local ready_err = wait_for_bind(proc, socket_path,
        BIND_READY_TIMEOUT_MS)
    if ready_err then
        _teardown()
        return nil, "helper_unavailable", ready_err
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
        -- Was leaking: prior code only terminated the proc and left
        -- process_handle / socket_path populated, so the next
        -- ensure_client returned a dead state. Full _teardown clears
        -- every slot so the next call respawns clean.
        _teardown()
        return nil, "helper_unavailable", connect_err
    end
    state.client_handle = c
    return c
end

--- Run `body(client)` with a connected helper client, or route the
--- structured (code, message) failure straight to the command's notify.
---
--- Lifted from 4 identical 4-line early-returns at the top of every
--- bridge command. The bridge command's body is invariably async-with-
--- callback (client:request inside `body`), so there is no caller code
--- after the with_client call that needs to run on the failure path.
---
--- Contract:
---   notify : function(args, result, code, message) — the per-command
---            closure from bridge_command.declare(...).notify
---   args   : the command's args table (threaded to notify on failure)
---   body   : function(client) — invoked with the connected client on
---            success; not invoked on failure.
--- The function returns nothing — bridge commands are async, terminal
--- result flows through notify, not through the return value.
function M.with_client(notify, args, body)
    assert(type(notify) == "function",
        "helper_supervisor.with_client: notify (function) required")
    assert(type(args) == "table",
        "helper_supervisor.with_client: args (table) required")
    assert(type(body) == "function",
        "helper_supervisor.with_client: body (function) required")
    local connected, code, msg = M.ensure_client()
    if not connected then
        notify(args, nil, code, msg)
        return
    end
    body(connected)
end

--- Shut down — terminate helper, close client. Idempotent.
function M.shutdown()
    _teardown()
end

return M
