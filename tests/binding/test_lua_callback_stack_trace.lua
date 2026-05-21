-- Contract test (014, T008): Lua-callback bridge logs a stack trace.
--
-- Spec ref: contracts/lua_callback_bridge.md, FR-008, FR-009.
--
-- Domain: when Lua code called from a Qt slot / single-shot timer /
-- signal-handler bridge raises an error (assertion or otherwise), the
-- C++ helper jve_handle_lua_callback_error MUST log a JVE_ASSERT-style
-- stack trace before continuing. The trace identifies the failing
-- module + line + assertion message, matching JVE_ASSERT semantics in
-- C++. The editor stays running (non-fatal).
--
-- Today: the helper logs only the bare error message via lua_tostring,
-- with no traceback. That silence is the meta-bug that hid the
-- project_id failures driving feature 014.
--
-- Red today: captured log lacks a "stack traceback:" block. Turns
-- green after T015 lands luaL_tolstring + luaL_traceback.
--
-- Runs via JVEEditor --test (binding test) so the C++ bridge is real.
-- Uses qt_create_single_shot_timer as the trigger because its error
-- path explicitly routes through jve_handle_lua_callback_error.
--
-- C-level stderr capture (FFI freopen on __stderrp) is required: the
-- bridge writes via JVE_LOG_ERROR at the C level, which bypasses
-- Lua's io.stderr. freopen redirects the underlying fd; LuaJIT can
-- restore it via the same primitive.
--
-- NSF: validates handler invocation (Half 2 pipeline output);
-- validates editor is still alive (Half 2 postcondition); separate
-- captures + assertions per scenario.

require("test_env")
local ffi = require("ffi")

print("=== test_lua_callback_stack_trace ===")

-- ----------------------------------------------------------------------
-- Preconditions.
-- ----------------------------------------------------------------------

assert(type(qt_create_single_shot_timer) == "function", string.format(
    "PRECONDITION: qt_create_single_shot_timer binding required.\n" ..
    "  Got type: %s. This binding test must run via JVEEditor --test.",
    type(qt_create_single_shot_timer)))
assert(qt_constants and qt_constants.CONTROL and
       type(qt_constants.CONTROL.PROCESS_EVENTS) == "function",
    "PRECONDITION: qt_constants.CONTROL.PROCESS_EVENTS required to pump\n" ..
    "  the Qt event loop in --test mode (no app.exec there).")

-- ----------------------------------------------------------------------
-- C-level stderr capture via FFI freopen on macOS __stderrp.
-- The C++ bridge writes via fprintf-family calls to stderr, which
-- expands to __stderrp on macOS. freopen redirects the underlying
-- file pointer so all subsequent writes (C-level AND Lua-level) hit
-- the capture file. After capture, freopen back to /dev/tty restores
-- visible logging.
-- ----------------------------------------------------------------------

ffi.cdef[[
typedef struct __sFILE FILE;
FILE* __stderrp;
FILE* freopen(const char*, const char*, FILE*);
int fflush(FILE*);
]]

local CAPTURE_FILE = "/tmp/jve/test_014_t008_stderr.txt"
os.execute("mkdir -p /tmp/jve")

local function capture_to_file(fn)
    -- Flush any pending C-level buffer state, then redirect.
    ffi.C.fflush(ffi.C.__stderrp)
    local r = ffi.C.freopen(CAPTURE_FILE, "w", ffi.C.__stderrp)
    assert(r ~= nil,
        "capture_to_file: freopen to capture file failed")

    local ok, err = pcall(fn)

    -- Flush captured output, then restore stderr to the terminal so
    -- subsequent diagnostics from this test remain visible.
    ffi.C.fflush(ffi.C.__stderrp)
    ffi.C.freopen("/dev/tty", "w", ffi.C.__stderrp)

    if not ok then error(err) end

    local f = io.open(CAPTURE_FILE, "r")
    assert(f, "capture_to_file: failed to open " .. CAPTURE_FILE .. " for read")
    local content = f:read("*a") or ""
    f:close()
    return content
end

local function pump_until(predicate, timeout_ms)
    local deadline_ms = (os.clock() * 1000) + timeout_ms
    while os.clock() * 1000 < deadline_ms do
        qt_constants.CONTROL.PROCESS_EVENTS()
        if predicate() then return true end
    end
    return false
end

-- ----------------------------------------------------------------------
-- Scenario 1: string error.
-- ----------------------------------------------------------------------

local handler_fired = false

local string_log = capture_to_file(function()
    handler_fired = false
    qt_create_single_shot_timer(0, function()
        handler_fired = true
        error("synthetic test error")
    end)
    pump_until(function() return handler_fired end, 1000)
end)

assert(handler_fired, string.format(
    "SCENARIO 1 INPUT INVARIANT: timer callback must have been invoked\n" ..
    "  during PROCESS_EVENTS. Captured: %q", string_log))
assert(string_log:find("LUA CALLBACK ERROR", 1, true)
       and string_log:find("Location: signal.single_shot_timer", 1, true),
    string.format(
    "SCENARIO 1 LOG FORMAT: expected the canonical bridge banner +\n" ..
    "  'Location: <where>' (jve_lua_callback.cpp stderr format).\n" ..
    "  Captured: %q", string_log))
assert(string_log:find("synthetic test error", 1, true), string.format(
    "SCENARIO 1 LOG CONTENT: must include the original error message.\n" ..
    "  Captured: %q", string_log))
assert(string_log:find("stack traceback", 1, true), string.format(
    "SCENARIO 1 STACK TRACE: jve_handle_lua_callback_error must log a\n" ..
    "  Lua stack traceback (T015 lands luaL_traceback). The trace is\n" ..
    "  the load-bearing diagnostic — without it, callback failures are\n" ..
    "  silently log-and-discarded with no fix-pointer.\n" ..
    "  Captured: %q", string_log))
print("  ✓ string error: bridge logged prefix + message + traceback")

-- Editor-still-running postcondition.
qt_constants.CONTROL.PROCESS_EVENTS()
print("  ✓ editor alive after string-error callback")

-- ----------------------------------------------------------------------
-- Scenario 2: non-string error (table). luaL_tolstring must produce a
--   readable representation; the traceback must still appear.
-- ----------------------------------------------------------------------

handler_fired = false
local table_log = capture_to_file(function()
    handler_fired = false
    qt_create_single_shot_timer(0, function()
        handler_fired = true
        error({ reason = "synthetic_table_err" })
    end)
    pump_until(function() return handler_fired end, 1000)
end)

assert(handler_fired,
    "SCENARIO 2 INPUT INVARIANT: timer callback must have been invoked")
assert(table_log:find("LUA CALLBACK ERROR", 1, true)
       and table_log:find("Location: signal.single_shot_timer", 1, true),
    string.format("SCENARIO 2 LOG FORMAT: missing canonical banner +\n" ..
    "  'Location: <where>'. Captured: %q", table_log))
assert(table_log:find("stack traceback", 1, true), string.format(
    "SCENARIO 2 STACK TRACE: non-string errors (tables, userdata) must\n" ..
    "  still produce a traceback. T015's luaL_tolstring + luaL_traceback\n" ..
    "  combo handles this uniformly. Captured: %q", table_log))
print("  ✓ table error: bridge logged prefix + traceback")

qt_constants.CONTROL.PROCESS_EVENTS()
print("  ✓ editor alive after both scenarios")

-- Cleanup.
os.remove(CAPTURE_FILE)

print("✅ test_lua_callback_stack_trace passed")
