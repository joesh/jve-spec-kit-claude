--- Shared fixture for spec-023 LIVE tests.
---
--- LIVE tests (T025, T026, T033, T034, T037, T041, T042, T050, T055)
--- run against a real DaVinci Resolve Studio attached on the local
--- machine. They are NOT part of the default test run because they
--- depend on Resolve's UI being open and a project being loaded.
---
--- This fixture:
---   1. Spawns the helper subprocess and connects via socket (mirrors
---      tests/binding/helper_fixture.lua).
---   2. ping → verifies `resolve_connected == true`; if not, the test
---      EXITS CLEANLY (printing a skip line) rather than asserting.
---      The convention lets the suite run on machines where Resolve
---      isn't attached without false-failing.
---   3. Exposes a helpers table for tests: `request` (raw envelope),
---      `expect_ok` (assert success + return result), `expect_error`
---      (assert structured error with expected code), `skip_unless_live`
---      (the resolve_connected check).
---
--- Tests under tests/live/ are run via:
---     ./build/bin/jve.app/Contents/MacOS/jve --test \
---         tests/live/test_<name>.lua
--- with a Resolve Studio running and a project open.

local protocol = require("core.resolve_bridge.protocol")

local M = {}

local function source_dir()
    return debug.getinfo(1, "S").source:match("^@(.+)/[^/]+$")
end

local function repo_root()
    return source_dir():match("^(.+)/tests/live$")
        or assert(nil, "live_fixture: cannot locate repo root")
end

function M.start(sock_path)
    assert(type(sock_path) == "string" and sock_path ~= "",
        "live_fixture.start: sock_path required")
    os.remove(sock_path)

    local proc = qt_process_create()
    qt_process_set_stderr_cb(proc, function(chunk)
        io.write("[helper stderr] " .. chunk)
    end)
    qt_process_start(proc, "python3", {
        repo_root() .. "/tools/resolve-helper/helper.py",
        "--socket", sock_path,
        "--log-level", "INFO",
    })
    assert(qt_process_wait_for_started(proc, 10000),
        "live_fixture: helper did not start within 10s")

    local bound = false
    for _ = 1, 200 do
        qt_constants.CONTROL.PROCESS_EVENTS()
        if os.execute("test -S " .. sock_path) == 0 then
            bound = true
            break
        end
        os.execute("sleep 0.05")
    end
    assert(bound,
        "live_fixture: helper never bound socket at " .. sock_path)

    local sock = qt_local_socket_create()
    local chunks = {}
    qt_local_socket_set_ready_read_cb(sock, function()
        chunks[#chunks + 1] = qt_local_socket_read_all(sock)
    end)
    qt_local_socket_connect(sock, sock_path)
    assert(qt_local_socket_wait_for_connected(sock, 5000),
        "live_fixture: could not connect to helper socket within 5s")

    return {
        proc      = proc,
        sock      = sock,
        sock_path = sock_path,
        _chunks   = chunks,
    }
end

local NEXT_ID = 0
local function next_corr()
    NEXT_ID = NEXT_ID + 1
    return string.format("live-%d-%d", NEXT_ID,
        math.floor(os.clock() * 1e6))
end

function M.request(fix, verb, args)
    assert(type(fix) == "table" and fix.sock,
        "live_fixture.request: fixture required")
    assert(type(verb) == "string", "live_fixture.request: verb required")
    assert(type(args) == "table",
        "live_fixture.request: args table required (pass {} for "
        .. "no-arg verbs)")

    local corr = next_corr()
    local line = protocol.build_request({
        id = corr, verb = verb, args = args,
    })

    while #fix._chunks > 0 do table.remove(fix._chunks) end
    local written = qt_local_socket_write(fix.sock, line)
    assert(written == #line, string.format(
        "live_fixture.request: partial write %d/%d", written, #line))
    qt_local_socket_flush(fix.sock)

    -- Live verbs can take a while (import / render queries); allow up
    -- to 60s.
    local deadline = 3000  -- ~60s @ 20ms
    while #fix._chunks == 0 and deadline > 0 do
        qt_constants.CONTROL.PROCESS_EVENTS()
        os.execute("sleep 0.02")
        deadline = deadline - 1
    end
    assert(#fix._chunks > 0,
        "live_fixture.request: no response within 60s for verb=" .. verb)

    local response = table.concat(fix._chunks)
    assert(response:sub(-1) == "\n",
        "live_fixture.request: response missing newline terminator")
    local parsed = protocol.parse_response(response:sub(1, -2))
    assert(parsed.id == corr, string.format(
        "live_fixture.request: correlation mismatch (sent %s, got %s)",
        corr, parsed.id))
    return parsed
end

--- Pre-flight: ping the helper and only proceed if Resolve Studio is
--- attached. On non-Studio / no-current-project, prints a skip line
--- and calls os.exit(0) — the harness counts that as "passed" but the
--- printed line makes the skip visible. This avoids false-fails on
--- developer machines without Resolve.
function M.skip_unless_live(fix, test_name)
    local r = M.request(fix, "ping", {})
    assert(r.ok == true, string.format(
        "%s: ping itself failed (%s/%s)",
        test_name, r.error and r.error.code,
        r.error and r.error.message))
    if r.result.resolve_connected ~= true then
        local last = r.result.last_error or {}
        print(string.format(
            "SKIPPED: %s — Resolve Studio not attached (last_error=%s/%s)",
            test_name, last.code or "?", last.message or "?"))
        M.stop(fix)
        os.exit(0)
    end
    return r.result
end

function M.expect_ok(parsed, label)
    assert(parsed.ok == true, string.format(
        "%s: expected ok=true, got %s/%s",
        label, parsed.error and parsed.error.code,
        parsed.error and parsed.error.message))
    return parsed.result
end

function M.expect_error(parsed, expected_code, label)
    assert(parsed.ok == false, label .. ": expected ok=false")
    assert(parsed.error and parsed.error.code == expected_code,
        string.format("%s: expected code %q, got %q (%s)",
            label, expected_code,
            parsed.error and parsed.error.code,
            parsed.error and parsed.error.message))
    return parsed.error
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
end

return M
