--- Shared fixture for helper contract tests (T013/T014/T051).
---
--- Spawns the real Python helper as a subprocess, connects via
--- qt_local_socket, exposes a single request() entrypoint that builds
--- the envelope through src/lua/core/resolve_bridge/protocol.lua (so
--- tests verify the live wire, not a hand-rolled string), pumps Qt
--- events while waiting, parses the response through the same
--- protocol module, and tears the helper down at the end.
---
--- Requires `jve --test` (needs qt_process_* / qt_local_socket_*).

local protocol = require("core.resolve_bridge.protocol")

local M = {}

local function source_dir()
    -- This file is read by `dofile` from the binding batch runner; use
    -- debug.getinfo to find ourselves regardless of CWD.
    return debug.getinfo(1, "S").source:match("^@(.+)/[^/]+$")
end

local function repo_root()
    return source_dir():match("^(.+)/tests/binding$")
        or assert(nil, "helper_fixture: cannot locate repo root")
end

local function pump(milliseconds)
    local ticks = math.max(1, math.floor(milliseconds / 20))
    for _ = 1, ticks do
        qt_constants.CONTROL.PROCESS_EVENTS()
        os.execute("sleep 0.02")
    end
end

function M.start(sock_path)
    assert(type(sock_path) == "string" and sock_path ~= "",
        "helper_fixture.start: sock_path required")
    os.remove(sock_path)

    local proc = qt_process_create()
    qt_process_set_stderr_cb(proc, function(chunk)
        io.write("[helper stderr] " .. chunk)
    end)
    qt_process_start(proc, "python3", {
        repo_root() .. "/tools/resolve-helper/helper.py",
        "--socket", sock_path,
        "--log-level", "WARNING",
    })
    assert(qt_process_wait_for_started(proc, 5000),
        "helper did not start within 5s")

    local bind_ok = false
    for _ = 1, 100 do
        qt_constants.CONTROL.PROCESS_EVENTS()
        if os.execute("test -S " .. sock_path) == 0 then
            bind_ok = true; break
        end
        os.execute("sleep 0.05")
    end
    assert(bind_ok, "helper never bound socket at " .. sock_path)

    local sock = qt_local_socket_create()
    local chunks = {}
    qt_local_socket_set_ready_read_cb(sock, function()
        chunks[#chunks + 1] = qt_local_socket_read_all(sock)
    end)
    qt_local_socket_connect(sock, sock_path)
    assert(qt_local_socket_wait_for_connected(sock, 5000),
        "could not connect to helper socket within 5s")

    return {
        proc      = proc,
        sock      = sock,
        sock_path = sock_path,
        _chunks   = chunks,
    }
end

local NEXT_ID = 0
local function new_correlation_id()
    NEXT_ID = NEXT_ID + 1
    return string.format("corr-%d-%d", NEXT_ID, math.floor(os.clock() * 1e6))
end

--- Send `{verb, args}` to the helper, await one response, return the
--- parsed envelope (whatever protocol.parse_response returns).
function M.request(fix, verb, args)
    assert(type(fix) == "table" and fix.sock, "request: fixture required")
    assert(type(verb) == "string", "request: verb required")
    assert(type(args) == "table",
        "request: args table required (pass {} for no-arg verbs)")
    local corr = new_correlation_id()
    local line = protocol.build_request({
        id = corr, verb = verb, args = args,
    })
    -- Reset accumulator before write — fixture is single-flight.
    while #fix._chunks > 0 do table.remove(fix._chunks) end

    local written = qt_local_socket_write(fix.sock, line)
    assert(written == #line, string.format(
        "request: partial write %d/%d", written, #line))
    qt_local_socket_flush(fix.sock)

    local deadline = 500  -- ~10s @ 20ms
    while #fix._chunks == 0 and deadline > 0 do
        qt_constants.CONTROL.PROCESS_EVENTS()
        os.execute("sleep 0.02")
        deadline = deadline - 1
    end
    assert(#fix._chunks > 0, "no response within 10s for verb=" .. verb)

    local response = table.concat(fix._chunks)
    assert(response:sub(-1) == "\n",
        "response missing newline terminator")
    local parsed = protocol.parse_response(response:sub(1, -2))
    assert(parsed.id == corr, string.format(
        "correlation mismatch: sent %s, got %s", corr, parsed.id))
    return parsed
end

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
    -- Tiny pump to drain stderr cb so logs flush before teardown.
    pump(50)
end

return M
