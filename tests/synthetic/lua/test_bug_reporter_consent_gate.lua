-- Feature 027 T028: consent dialog gates all telemetry.
--
-- Decline path: no /register, no /heartbeat, no /report; F12 surfaces
-- "Bug reporting is disabled" (FR-009 / AS #14).
-- Accept path: /register observed; install_id.json exists.
-- Decline then toggle ON: next interaction issues /register first
-- (FR-002 / AS #15).
--
-- Black-box: counts http calls via stubbed qt_http_post_*.

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

local TMP = "/tmp/jve_consent_test_" .. tostring(math.random(1, 1e9))
os.execute("/bin/mkdir -p " .. TMP)
install.set_home_for_tests(TMP)

-- Count every HTTP call.
local http_calls = {}
_G.qt_http_post_json = function(url, headers, body, callback_name)
    http_calls[#http_calls + 1] = { kind = "json", url = url }
    if callback_name and _G[callback_name] then
        -- Pretend register succeeded.
        _G[callback_name](200, '{"nonce":"' .. string.rep("a", 64) ..
            '","server_ts":1719279600,"country":"US","timezone":"UTC"}', nil)
    end
end
_G.qt_http_post_multipart = function(url, headers, parts, callback_name)
    http_calls[#http_calls + 1] = { kind = "multipart", url = url }
    if callback_name and _G[callback_name] then
        _G[callback_name](200, '{"report_id":"abc","ref_short":"abc"}', nil)
    end
end

-- (1) Decline: no /register call observed.
do
    http_calls = {}
    -- The consent dialog is fired by telemetry.init when no install file
    -- exists. T037 must accept a test hook to inject a "decline" outcome.
    if type(telemetry.set_consent_outcome_for_tests) ~= "function" then
        error("RED — telemetry.set_consent_outcome_for_tests missing (T037 must expose for testing)")
    end
    telemetry.set_consent_outcome_for_tests("decline")
    os.remove(TMP .. "/.jve/install_id.json")
    telemetry.init()
    for _, call in ipairs(http_calls) do
        error("declined consent must NOT issue any HTTP call; got " .. call.kind .. " " .. call.url)
    end
    -- F12 should surface the disabled message.
    if type(telemetry.f12_message_for_tests) ~= "function" then
        error("RED — telemetry.f12_message_for_tests missing")
    end
    local msg = telemetry.f12_message_for_tests()
    assert(msg and msg:lower():find("disabled"),
        "F12 must surface 'Bug reporting is disabled' message after decline; got: " .. tostring(msg))
end

-- (2) Accept: /register fires; install_id.json exists.
do
    http_calls = {}
    -- Reset pref to the never-set state — case (1) saved pref=false on
    -- decline; case (2) simulates a fresh user (no prior decline).
    if type(telemetry.set_pref_for_tests) == "function" then
        telemetry.set_pref_for_tests(nil)
    end
    telemetry.set_consent_outcome_for_tests("accept")
    os.remove(TMP .. "/.jve/install_id.json")
    telemetry.init()
    local register_seen = false
    for _, call in ipairs(http_calls) do
        if call.url:find("/register", 1, true) then register_seen = true end
    end
    assert(register_seen,
        "accept consent must issue POST /register; HTTP calls: " ..
        tostring(#http_calls))
    local f = io.open(TMP .. "/.jve/install_id.json", "r")
    assert(f, "install_id.json must exist after accept + register")
    f:close()
end

-- (3) Decline → flip pref ON → next interaction issues /register first.
do
    http_calls = {}
    if type(telemetry.set_pref_for_tests) == "function" then
        telemetry.set_pref_for_tests(nil)  -- fresh-user state
    end
    telemetry.set_consent_outcome_for_tests("decline")
    os.remove(TMP .. "/.jve/install_id.json")
    telemetry.init()  -- decline path; no register
    -- Pref toggle ON.
    if type(telemetry.toggle_pref_for_tests) ~= "function" then
        error("RED — telemetry.toggle_pref_for_tests missing (T039 must wire)")
    end
    telemetry.set_consent_outcome_for_tests("accept")  -- next consent prompt now accepted
    telemetry.toggle_pref_for_tests(true)
    -- After toggle ON, the very next backend interaction should
    -- register first.
    local register_seen = false
    for _, call in ipairs(http_calls) do
        if call.url:find("/register", 1, true) then register_seen = true end
    end
    assert(register_seen,
        "toggle ON after decline must trigger /register before any other backend call (FR-002)")
end

os.execute("/bin/rm -rf " .. TMP)
-- dialog_prefs writes to the real ~/.jve/bug_reporter_prefs.json
-- because dialog_prefs.path_for reads HOME directly; clean up that
-- pollution at exit.
local real_home = os.getenv("HOME")
if real_home and real_home ~= "" then
    os.remove(real_home .. "/.jve/bug_reporter_prefs.json")
end
print("✅ test_bug_reporter_consent_gate.lua passed")
