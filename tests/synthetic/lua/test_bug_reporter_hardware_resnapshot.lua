-- Feature 027 T029a: hardware re-snapshot on JVE version bump (FR-018).
--
-- Heartbeat body carries the `hardware` field iff the stored
-- jve_sha_at_register differs from build_info.git_sha. On match, the
-- body MUST NOT carry hardware (bandwidth thrift).

require("test_env")

local function require_or_red(modname, task)
    local ok, mod = pcall(require, modname)
    if not ok then
        error("RED — " .. modname .. " unloadable (" .. task .. " not landed): " .. tostring(mod))
    end
    return mod
end

local telemetry = require_or_red("bug_reporter.telemetry", "T037")
local install   = require_or_red("bug_reporter.install", "T033")

local TMP = "/tmp/jve_resnapshot_test_" .. tostring(math.random(1, 1e9))
os.execute("/bin/mkdir -p " .. TMP)
install.set_home_for_tests(TMP)

local last_heartbeat_body
_G.qt_http_post_json = function(url, headers, body, callback_name)
    if url:find("/heartbeat", 1, true) then
        last_heartbeat_body = body
    end
    if callback_name and _G[callback_name] then
        _G[callback_name](200, '{"server_ts":1719279600,"status":"ok"}', nil)
    end
end

-- Seed install file with jve_sha_at_register != current git_sha.
local function seed_install(jve_sha_at_register)
    install.write({
        install_id = "550e8400-e29b-41d4-a716-446655440000",
        nonce = string.rep("a", 64),
        consent_accepted_ts = 1719279600,
        consent_version = 1,
        jve_sha_at_register = jve_sha_at_register,
        hardware_snapshot = { platform = "Darwin", arch = "arm64" },
        country = "US",
        timezone = "UTC",
    })
end

if type(telemetry.set_pref_for_tests) ~= "function" then
    error("RED — telemetry.set_pref_for_tests missing")
end
telemetry.set_pref_for_tests(true)

-- (1) Mismatch → heartbeat carries hardware.
do
    seed_install("AAAAAAA")  -- definitely != stub's "0000000"
    last_heartbeat_body = nil
    telemetry.heartbeat_for_tests()
    assert(last_heartbeat_body, "heartbeat must fire when pref is on + install exists")
    assert(last_heartbeat_body:find('"hardware"', 1, true),
        "mismatched jve_sha_at_register → body MUST contain hardware field; got: " ..
        last_heartbeat_body:sub(1, 200))
end

-- (2) Match → heartbeat does NOT carry hardware.
do
    seed_install("0000000")  -- matches the test_harness stub for qt_get_build_info
    last_heartbeat_body = nil
    telemetry.heartbeat_for_tests()
    assert(last_heartbeat_body, "heartbeat must still fire")
    assert(not last_heartbeat_body:find('"hardware"', 1, true),
        "matched jve_sha_at_register → body MUST NOT contain hardware field; got: " ..
        last_heartbeat_body:sub(1, 200))
end

os.execute("/bin/rm -rf " .. TMP)
print("✅ test_bug_reporter_hardware_resnapshot.lua passed")
