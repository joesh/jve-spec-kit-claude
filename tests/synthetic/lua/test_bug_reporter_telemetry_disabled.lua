-- Feature 027 T029: telemetry preference OFF → zero HTTP calls.
--
-- Drives a full simulated session including a Submit attempt; asserts
-- that no qt_http_post_* of any kind fires (FR-020).

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

local TMP = "/tmp/jve_telemdis_test_" .. tostring(math.random(1, 1e9))
os.execute("/bin/mkdir -p " .. TMP)
install.set_home_for_tests(TMP)

local http_call_count = 0
_G.qt_http_post_json = function() http_call_count = http_call_count + 1 end
_G.qt_http_post_multipart = function() http_call_count = http_call_count + 1 end

-- Pref OFF: prerequisites — no install file, pref disabled.
os.remove(TMP .. "/.jve/install_id.json")
if type(telemetry.set_pref_for_tests) ~= "function" then
    error("RED — telemetry.set_pref_for_tests missing (T037/T039)")
end
telemetry.set_pref_for_tests(false)

-- Drive a full session: init + simulated F12 submit attempt.
telemetry.init()
if type(telemetry.attempt_submit_for_tests) ~= "function" then
    error("RED — telemetry.attempt_submit_for_tests missing")
end
telemetry.attempt_submit_for_tests({ title = "test", description = "test" })

assert(http_call_count == 0,
    "preference OFF must produce ZERO HTTP calls; got " .. tostring(http_call_count))

os.execute("/bin/rm -rf " .. TMP)
print("✅ test_bug_reporter_telemetry_disabled.lua passed")
