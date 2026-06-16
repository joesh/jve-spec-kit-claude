--- Shared fixture for spec-023 LIVE tests.
---
--- LIVE tests (T025, T026, T033, T034, T037, T041, T042, T050, T055)
--- run against a real DaVinci Resolve Studio attached on the local
--- machine. They are NOT part of the default test run because they
--- depend on Resolve's UI being open and a project being loaded.
---
--- Transport mechanics (start/request/stop loop) live in
--- `binding._helper_transport` — review item #6 lifted the common
--- code shared with helper_fixture. This file owns the LIVE-side
--- policy: 60s request deadline (live verbs do real Resolve work),
--- "live-" correlation prefix, helper at INFO log level, the LIVE-side
--- helpers `expect_ok` / `expect_error` / `skip_unless_live` (the
--- resolve_connected check), plus `unzip_drt_xml` — the shared read util
--- live tests use to inspect a Resolve- or JVE-authored .drt's inner XML.
---
--- Tests under tests/live/ are run via:
---     ./build/bin/jve.app/Contents/MacOS/jve --test \
---         tests/live/test_<name>.lua
--- with a Resolve Studio running and a project open.

local transport = require("synthetic.binding._helper_transport")

local M = {}

local function repo_root()
    return transport.repo_root_from(
        debug.getinfo(1, "S").source, "tests/synthetic/integration/live_resolve")
end

--- `opts` (optional): { allow_test_verbs = true } when the test drives
--- a TEST_VERB_TABLE verb (apply_test_grade, author_reference_timeline).
--- Production live tests omit it and reach only the production verbs.
function M.start(sock_path, opts)
    opts = opts or {}
    return transport.start({
        sock_path             = sock_path,
        repo_root             = repo_root(),
        log_level             = "INFO",
        started_timeout_ms    = 10000,
        bind_poll_count       = 200,        -- 200 * 50ms = 10s
        corr_prefix           = "live",
        request_timeout_ticks = 3000,       -- 3000 * 20ms = 60s
        allow_test_verbs      = opts.allow_test_verbs or false,
    })
end

M.request = transport.request
M.stop    = transport.stop

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

--- A .drt (like a .drp) is a ZIP archive; stream every member's bytes to
--- stdout and return the concatenated inner XML. Used by tests that scan
--- a Resolve- or JVE-authored .drt for element bytes (MediaTimemapBA, In…).
function M.unzip_drt_xml(path)
    local p = assert(io.popen(string.format("unzip -p %q 2>/dev/null", path)),
        "unzip_drt_xml: could not run unzip on " .. tostring(path))
    local xml = p:read("*a"); p:close()
    assert(xml and #xml > 0,
        "unzip_drt_xml: no content from " .. tostring(path))
    return xml
end

-- The import_timeline verb wants the distinct media files behind a payload's
-- clips (one entry per file, original order). Every live source-range test
-- derives this the same way right before the import request.
function M.unique_media_paths(payload)
    local paths, seen = {}, {}
    for _, ref in ipairs(payload.media_refs) do
        if not seen[ref.file_path] then
            seen[ref.file_path] = true
            paths[#paths + 1] = ref.file_path
        end
    end
    return paths
end

return M
