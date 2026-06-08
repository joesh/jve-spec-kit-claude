--- Shared transport layer for spec-023 helper test fixtures.
---
--- helper_fixture (contract tests, tests/binding/) and live_fixture
--- (LIVE tests, tests/live/) both: spawn the same helper.py via
--- qt_process_*, wait for socket bind, connect via qt_local_socket,
--- write one request line, pump Qt events while awaiting one response,
--- parse through `protocol`, and tear the helper down. The 80% of
--- transport code was duplicated; review item #6 lifted it here.
---
--- The two fixtures still diverge in policy:
---   • helper_fixture: 10s deadline (contract tests are fast),
---     correlation prefix "corr-", helper log-level WARNING, also owns
---     `assert_structured_error` / `skip_unless_resolve`.
---   • live_fixture: 60s deadline (live verbs do real Resolve work),
---     correlation prefix "live-", helper log-level INFO, owns
---     `expect_ok` / `expect_error` / `skip_unless_live`.
--- Those layers stay in their respective fixture modules. Only the
--- transport mechanics live here.
---
--- Both fixtures still go through `protocol.build_request` /
--- `protocol.parse_response` — wire-format coupling is enforced one
--- place upstream of this module.

local protocol = require("core.resolve_bridge.protocol")

local M = {}

--- Resolve repo root from any path under it; both fixtures live two
--- levels deep (`tests/binding/`, `tests/live/`). Callers pass their
--- own __FILE-equivalent so this module stays directory-agnostic.
function M.repo_root_from(source_path, expected_subdir)
    local prefix = source_path:match("^@?(.+)/[^/]+$")
    assert(prefix, "_helper_transport: cannot extract dir from source path")
    local root = prefix:match("^(.+)/" .. expected_subdir .. "$")
    assert(root, string.format(
        "_helper_transport: %q is not under %q",
        prefix, expected_subdir))
    return root
end

--- Start helper.py and connect a socket. Returns a fixture table that
--- carries the spawn state plus the per-fixture config the request
--- loop needs.
---
--- opts:
---   sock_path             (required, string)  Unix socket path
---   repo_root             (required, string)  for helper.py absolute path
---   log_level             (required, string)  "WARNING" | "INFO" | "DEBUG"
---   started_timeout_ms    (required, integer) qt_process_wait_for_started
---   bind_poll_count       (required, integer) 50ms ticks waiting for socket
---   corr_prefix           (required, string)  "corr" or "live"
---   request_timeout_ticks (required, integer) 20ms ticks per request
function M.start(opts)
    assert(type(opts) == "table", "_helper_transport.start: opts required")
    for _, k in ipairs({
        "sock_path", "repo_root", "log_level",
        "started_timeout_ms", "bind_poll_count",
        "corr_prefix", "request_timeout_ticks",
    }) do
        assert(opts[k] ~= nil,
            "_helper_transport.start: opts." .. k .. " required")
    end
    os.remove(opts.sock_path)

    local proc = qt_process_create()
    qt_process_set_stderr_cb(proc, function(chunk)
        io.write("[helper stderr] " .. chunk)
    end)
    qt_process_set_finished_cb(proc, function(code, status)
        io.write(string.format("[helper process] EXITED code=%d status=%s\n", code, tostring(status)))
    end)
    qt_process_start(proc, "python3", {
        opts.repo_root .. "/tools/resolve-helper/helper.py",
        "--socket", opts.sock_path,
        "--log-level", opts.log_level,
    })
    assert(qt_process_wait_for_started(proc, opts.started_timeout_ms),
        string.format(
            "_helper_transport: helper did not start within %dms",
            opts.started_timeout_ms))

    local bound = false
    for _ = 1, opts.bind_poll_count do
        qt_constants.CONTROL.PROCESS_EVENTS()
        if os.execute("test -S " .. opts.sock_path) == 0 then
            bound = true
            break
        end
        os.execute("sleep 0.05")
    end
    assert(bound, "_helper_transport: helper never bound socket at "
        .. opts.sock_path)

    local sock = qt_local_socket_create()
    local chunks = {}
    qt_local_socket_set_ready_read_cb(sock, function()
        chunks[#chunks + 1] = qt_local_socket_read_all(sock)
    end)
    qt_local_socket_connect(sock, opts.sock_path)
    assert(qt_local_socket_wait_for_connected(sock, 5000),
        "_helper_transport: could not connect to helper socket within 5s")

    return {
        proc                  = proc,
        sock                  = sock,
        sock_path             = opts.sock_path,
        _chunks               = chunks,
        _next_id              = 0,
        _corr_prefix          = opts.corr_prefix,
        _request_timeout_ticks = opts.request_timeout_ticks,
    }
end

local function next_corr(fix)
    fix._next_id = fix._next_id + 1
    return string.format("%s-%d-%d",
        fix._corr_prefix, fix._next_id,
        math.floor(os.clock() * 1e6))
end

--- Single-flight write+await. Resets the chunk accumulator before
--- writing (fixtures don't pipeline). Asserts on partial write,
--- timeout, missing newline terminator, and correlation mismatch.
function M.request(fix, verb, args)
    assert(type(fix) == "table" and fix.sock,
        "_helper_transport.request: fixture required")
    assert(type(verb) == "string",
        "_helper_transport.request: verb required")
    assert(type(args) == "table",
        "_helper_transport.request: args table required "
        .. "(pass {} for no-arg verbs)")

    local corr = next_corr(fix)
    local line = protocol.build_request({
        id = corr, verb = verb, args = args,
    })

    while #fix._chunks > 0 do table.remove(fix._chunks) end
    local written = qt_local_socket_write(fix.sock, line)
    assert(written == #line, string.format(
        "_helper_transport.request: partial write %d/%d", written, #line))
    qt_local_socket_flush(fix.sock)

    local deadline = fix._request_timeout_ticks
    local response = ""
    while deadline > 0 do
        if #fix._chunks > 0 then
            response = response .. table.concat(fix._chunks)
            fix._chunks = {}
        end
        if response:sub(-1) == "\n" then
            break
        end
        qt_constants.CONTROL.PROCESS_EVENTS()
        os.execute("sleep 0.02")
        deadline = deadline - 1
    end
    assert(response:sub(-1) == "\n", string.format(
        "_helper_transport.request: response missing newline terminator for verb=%s (got %d bytes)",
        verb, #response))

    local parsed = protocol.parse_response(response:sub(1, -2))
    assert(parsed.id == corr, string.format(
        "_helper_transport.request: correlation mismatch (sent %s, got %s)",
        corr, parsed.id))
    return parsed
end

--- Close socket + terminate helper. Idempotent. Callers that want a
--- post-stop pump (helper_fixture flushes stderr) add it themselves.
function M.stop(fix)
    if not fix then return end
    if fix.sock then
        qt_local_socket_close(fix.sock)
        qt_local_socket_destroy(fix.sock)
    end
    if fix.proc then
        qt_process_terminate(fix.proc)
        qt_process_destroy(fix.proc)
    end
    os.remove(fix.sock_path)
end

return M
