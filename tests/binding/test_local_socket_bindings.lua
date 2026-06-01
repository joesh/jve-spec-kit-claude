-- T020 — qt_local_socket_* binding smoke (run via `jve --test`).
--
-- Spawn the Python resolve-helper as a real subprocess (T021 ping verb is
-- the simplest server-side smoke we have), connect via qt_local_socket,
-- send a ping envelope, assert the round-trip parses.
--
-- This black-boxes the socket bindings against an actual server speaking
-- the line-delimited JSON protocol — same wire as production.

assert(type(qt_local_socket_create) == "function",
    "qt_local_socket_create binding not registered")
assert(type(qt_process_create) == "function",
    "qt_process_create binding not registered (needed to spawn helper)")

local SOCK = "/tmp/jve-binding-test-socket.sock"
os.remove(SOCK)

local helper_proc = qt_process_create()
qt_process_set_stderr_cb(helper_proc, function(chunk)
    io.write("[helper stderr] " .. chunk)
end)
qt_process_start(helper_proc, "python3", {
    "/Users/joe/Local/jve-spec-kit-claude/tools/resolve-helper/helper.py",
    "--socket", SOCK,
    "--log-level", "WARNING",
})
assert(qt_process_wait_for_started(helper_proc, 5000),
    "helper did not start within 5s")

-- Wait for the helper to bind the socket file. Pump Qt events so the
-- helper's stderr cb fires if it crashed during import.
local bind_ok = false
for _ = 1, 100 do
    qt_constants.CONTROL.PROCESS_EVENTS()
    if os.execute("test -S " .. SOCK) == 0 then
        bind_ok = true; break
    end
    os.execute("sleep 0.05")
end
assert(bind_ok, "helper never bound socket at " .. SOCK
    .. " (check stderr above for helper import errors)")

-- ─── connect ────────────────────────────────────────────────────────────
local sock_id = qt_local_socket_create()
local received_chunks = {}
qt_local_socket_set_ready_read_cb(sock_id, function()
    received_chunks[#received_chunks + 1] = qt_local_socket_read_all(sock_id)
end)
qt_local_socket_connect(sock_id, SOCK)
assert(qt_local_socket_wait_for_connected(sock_id, 5000),
    "could not connect to helper socket within 5s")
assert(qt_local_socket_state(sock_id) == "connected",
    "socket state should be 'connected' after wait_for_connected")
print("  ✓ connected to helper")

-- ─── ping round-trip ────────────────────────────────────────────────────
local request_json = '{"v":1,"id":"corr-1","verb":"ping","args":{}}\n'
local written = qt_local_socket_write(sock_id, request_json)
assert(written == #request_json,
    string.format("partial write: %d / %d bytes", written, #request_json))
qt_local_socket_flush(sock_id)

local deadline = 250  -- ~5s @ 20ms
while #received_chunks == 0 and deadline > 0 do
    qt_constants.CONTROL.PROCESS_EVENTS()
    os.execute("sleep 0.02")
    deadline = deadline - 1
end
assert(#received_chunks > 0, "no response received within 5s")

local response = table.concat(received_chunks)
assert(response:sub(-1) == "\n", "response missing newline terminator")
assert(response:find('"v":1', 1, true), "response missing v=1")
assert(response:find('"id":"corr-1"', 1, true),
    "response missing correlation id")
assert(response:find('"ok":true', 1, true),
    "response not ok=true: " .. response)
print("  ✓ ping round-trip parsed cleanly")

-- ─── unknown-handle error ───────────────────────────────────────────────
do
    local ok, err = pcall(qt_local_socket_state, 999999)
    assert(not ok, "unknown handle should error")
    assert(tostring(err):find("unknown handle"),
        "error missing 'unknown handle': " .. tostring(err))
    print("  ✓ unknown handle → luaL_error")
end

-- ─── teardown ───────────────────────────────────────────────────────────
qt_local_socket_close(sock_id)
qt_local_socket_destroy(sock_id)
qt_process_terminate(helper_proc)
qt_process_destroy(helper_proc)
os.remove(SOCK)

print("✅ test_local_socket_bindings.lua passed")
