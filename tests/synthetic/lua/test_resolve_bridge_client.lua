-- test_resolve_bridge_client.lua — `core.resolve_bridge.client` request
-- envelope + connect-error surfacing.
--
-- Covers HIGH findings from spec-023 skeptical review:
--   • F2: client:request must build the wire envelope via
--     protocol.build_request's table API ({id,verb,args}). The earlier
--     positional call form (corr_id, verb, args) silently passed a
--     string where a table was expected and would assert-fail on the
--     first real request — no existing test exercised that path because
--     binding fixtures construct envelopes directly.
--   • F11: the correlation id must embed the JVE process PID (not 0).
--     This makes helper-side logs traceable to the JVE that issued the
--     request when multiple JVEs run in parallel.
--   • F13: a connect failure must surface the actual QLocalSocket error
--     name (e.g. ServerNotFoundError) — not a generic "timed out". The
--     error_cb captures it; this test verifies the connect-failure
--     message carries it through.
--
-- Stubs the qt_local_socket_* surface so the client runs in pure Lua.

require("test_env")

-- ─── Qt-socket stub layer ─────────────────────────────────────────────
-- The stub captures every byte written by the client and replays callbacks
-- under test control. Keeps state on a module-local `last_write` so test
-- bodies can inspect the envelope produced by client:request without
-- mocking protocol.* (we want to verify the REAL wire bytes).
local stub = {
    last_write   = nil,
    write_ok     = true,
    connected_ok = true,
    timers       = {},
    ready_cb     = nil,
    disc_cb      = nil,
    err_cb       = nil,
    destroyed    = false,
}
function _G.qt_local_socket_create() return "h1" end
function _G.qt_local_socket_set_ready_read_cb(_, cb)    stub.ready_cb = cb end
function _G.qt_local_socket_set_disconnected_cb(_, cb)  stub.disc_cb  = cb end
function _G.qt_local_socket_set_error_cb(_, cb)         stub.err_cb   = cb end
function _G.qt_local_socket_connect(_, _) end
function _G.qt_local_socket_wait_for_connected(_, _)    return stub.connected_ok end
function _G.qt_local_socket_write(_, bytes)
    stub.last_write = bytes
    return stub.write_ok
end
function _G.qt_local_socket_flush(_) end
function _G.qt_local_socket_destroy(_)                  stub.destroyed = true end
function _G.qt_local_socket_read_all(_)                 return "" end
function _G.qt_create_single_shot_timer(_, cb)
    table.insert(stub.timers, cb)
end
-- F11: pretend the C++ binding returned a real PID so we can verify the
-- correlation id format. The real binding lands in this same change.
function _G.qt_get_pid() return 4242 end

local client = require("core.resolve_bridge.client")
local protocol = require("core.resolve_bridge.protocol")

local pass, fail = 0, 0
local function check(label, cond)
    if cond then pass = pass + 1
    else fail = fail + 1; print("FAIL: " .. label) end
end
local function check_eq(label, got, want)
    if got == want then pass = pass + 1
    else fail = fail + 1
        print(string.format("FAIL: %s\n  got:  %s\n  want: %s",
            label, tostring(got), tostring(want)))
    end
end

print("\n=== Resolve Bridge Client Tests ===")

-- ─── F2: request envelope shape ─────────────────────────────────────────
local c = assert(client.connect("/tmp/jve-test.sock", {
    connect_timeout_ms = 100, request_timeout_ms = 1000,
}))
check("connect returned a client table", type(c) == "table")
c:request("ping", { foo = "bar" }, function() end)
check("a write happened on request", stub.last_write ~= nil)
-- The wire bytes must round-trip through parse_request. If client.lua
-- passed positional args to build_request, the assert there would fire
-- BEFORE qt_local_socket_write — last_write would still be nil and we'd
-- have caught the bug here. If build_request's table API silently
-- accepted a string, parse would fail.
local ok_parse, parsed = pcall(protocol.parse_request, stub.last_write)
check("envelope parses as valid request", ok_parse)
if ok_parse then
    check_eq("envelope verb", parsed.verb, "ping")
    check_eq("envelope args.foo", parsed.args.foo, "bar")
    -- F11: correlation id must embed real PID (4242 from our stub).
    check("correlation id embeds PID 4242",
        parsed.id:find("jve%-4242%-") ~= nil)
end
c:close()

-- ─── F13: connect failure surfaces the actual QLocalSocket error ───────
-- Error names are the snake_case strings produced by socket_error_name()
-- in local_socket_bindings.cpp — NOT the Qt enum names. The client must
-- pass them through verbatim so log readers can distinguish "no helper
-- listening" from "kernel refused" from "we waited too long".
stub.connected_ok = false
function _G.qt_local_socket_connect(_, _)
    if stub.err_cb then stub.err_cb("server_not_found") end
end
local nil_client, err = client.connect("/tmp/missing.sock", {
    connect_timeout_ms = 50, request_timeout_ms = 1000,
})
check("connect to missing socket returned nil", nil_client == nil)
check("err names server_not_found",
    err and err:find("server_not_found", 1, true) ~= nil)

-- Real timeout: wait_for_connected returns false but error_cb never fired.
function _G.qt_local_socket_connect(_, _) end
local nil_t, err_t = client.connect("/tmp/slow.sock", {
    connect_timeout_ms = 50, request_timeout_ms = 1000,
})
check("timeout returns nil", nil_t == nil)
check("timeout error names 'timeout'",
    err_t and err_t:find("timeout", 1, true) ~= nil)
stub.connected_ok = true

print(string.format("\n=== %d passed / %d failed ===", pass, fail))
assert(fail == 0, "test_resolve_bridge_client.lua failed")
print("✅ test_resolve_bridge_client.lua passed")
