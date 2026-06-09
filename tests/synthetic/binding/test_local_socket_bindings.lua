-- T020 — qt_local_socket_* binding smoke (run via `jve --test`).
--
-- Black-box: spawn the real Python resolve-helper, drive a single ping
-- through `helper_fixture`, prove the FFI bindings round-trip cleanly.
-- Shape-level assertions on ping live in test_helper_ping.lua (T013);
-- this file's responsibility is *only* that the socket bindings work.

assert(type(qt_local_socket_create) == "function",
    "qt_local_socket_create binding not registered")
assert(type(qt_local_socket_state) == "function",
    "qt_local_socket_state binding not registered")
assert(type(qt_process_create) == "function",
    "qt_process_create binding not registered (needed to spawn helper)")

local fixture = require("synthetic.binding.helper_fixture")

local fix = fixture.start("/tmp/jve-binding-test-socket.sock")
assert(qt_local_socket_state(fix.sock) == "connected",
    "socket state should be 'connected' after fixture.start")
print("  ✓ connected to helper")

local response = fixture.request(fix, "ping", {})
assert(response.ok == true, "ping must return ok=true (helper alive)")
print("  ✓ ping round-trip parsed cleanly")

-- ─── unknown-handle error (binding contract, not protocol) ──────────────
do
    local ok, err = pcall(qt_local_socket_state, 999999)
    assert(not ok, "unknown handle should error")
    assert(tostring(err):find("unknown handle"),
        "error missing 'unknown handle': " .. tostring(err))
    print("  ✓ unknown handle → luaL_error")
end

fixture.stop(fix)

print("✅ test_local_socket_bindings.lua passed")
