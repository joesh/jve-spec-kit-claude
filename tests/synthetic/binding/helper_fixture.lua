--- Shared fixture for helper contract tests (T013/T014/T051).
---
--- Spawns the real Python helper, connects via qt_local_socket,
--- exposes single request() entrypoint, parses through protocol.
---
--- Transport mechanics (start/request/stop loop) live in
--- `binding._helper_transport` — review item #6 lifted the common
--- code so this file owns only contract-test-side policy: shorter
--- request deadline, "corr-" correlation prefix, helper at WARNING
--- log level, and the contract-side helpers `assert_structured_error`
--- + `skip_unless_resolve`.

local transport = require("synthetic.binding._helper_transport")
local protocol  = require("core.resolve_bridge.protocol")

local M = {}

local function pump(milliseconds)
    local ticks = math.max(1, math.floor(milliseconds / 20))
    for _ = 1, ticks do
        qt_constants.CONTROL.PROCESS_EVENTS()
        os.execute("sleep 0.02")
    end
end

local function repo_root()
    return transport.repo_root_from(
        debug.getinfo(1, "S").source, "tests/synthetic/binding")
end

function M.start(sock_path)
    return transport.start({
        sock_path             = sock_path,
        repo_root             = repo_root(),
        log_level             = "DEBUG",
        started_timeout_ms    = 5000,
        bind_poll_count       = 100,        -- 100 * 50ms = 5s
        corr_prefix           = "corr",
        request_timeout_ticks = 1500,       -- 1500 * 20ms = 30s
        allow_test_verbs      = true,       -- contract tests exercise verb gates
    })
end

M.request = transport.request

--- Skip the rest of the test if the helper's `ping` reports
--- `resolve_connected=false` (Resolve Studio not running OR the
--- DaVinciResolveScript module isn't importable). Tears the fixture
--- down and exits 0 so the batch runner sees a pass; prints
--- `[SKIP <test_name>] reason` so the line is traceable in the build log.
---
--- Use at the top of any helper contract test that exercises live
--- Resolve state (read_identities, read_timeline, read_grades, etc.).
--- bad_request / closed-set discipline assertions don't need Resolve
--- and should NOT skip — call this AFTER they've run, or split the
--- test into a live-section that calls this and a wire-section that
--- doesn't.
function M.skip_unless_resolve(fix, test_name)
    assert(type(test_name) == "string" and test_name ~= "",
        "skip_unless_resolve: test_name required")
    local r = M.request(fix, "ping", {})
    assert(r.ok == true, "skip_unless_resolve: ping failed unexpectedly: "
        .. tostring(r.error and r.error.message))
    if r.result.resolve_connected == true then return end
    io.write(string.format(
        "[SKIP %s] helper reports resolve_connected=%s "
        .. "(Resolve Studio not running here, or DaVinciResolveScript "
        .. "module unavailable)\n",
        test_name, tostring(r.result.resolve_connected)))
    M.stop(fix)
    os.exit(0)
end

--- Assert a wire response is a closed-set structured error.
--- Was copy-pasted into 6 helper contract tests; lifted here so a
--- contract change updates one place (review item #1).
function M.assert_structured_error(parsed, expected_code, label)
    assert(parsed.ok == false, label .. ": expected ok=false")
    assert(type(parsed.error) == "table",
        label .. ": missing error table")
    assert(type(parsed.error.code) == "string"
        and parsed.error.code ~= "",
        label .. ": error.code must be non-empty string")
    assert(type(parsed.error.message) == "string"
        and parsed.error.message ~= "",
        label .. ": error.message must be non-empty string (never bare)")
    assert(protocol.is_known_error_code(parsed.error.code),
        string.format("%s: error code %q is not in the closed set",
            label, parsed.error.code))
    assert(parsed.error.code == expected_code,
        string.format("%s: expected code %q, got %q (%s)",
            label, expected_code, parsed.error.code,
            parsed.error.message))
end

function M.stop(fix)
    transport.stop(fix)
    -- Tiny pump to drain stderr cb so logs flush before teardown.
    if fix then pump(50) end
end

return M
