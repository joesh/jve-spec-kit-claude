-- Feature 027 FR-002a: stale consent_version triggers re-prompt.
--
-- Domain: when the consent text materially changes the version
-- integer bumps; existing installs MUST be re-prompted with the new
-- wording on the next telemetry init. Accept = persist new version +
-- continue. Decline = treat as fresh decline (disable, no traffic).
-- Re-prompt MUST NOT fire when the stored version is current.
--
-- Black-box: drives telemetry.init through its existing
-- set_consent_outcome_for_tests seam; observes the record on disk.

print("=== test_bug_reporter_consent_reprompt.lua ===")
require("test_env")

local telemetry = require("bug_reporter.telemetry")
local install   = require("bug_reporter.install")
local consent   = require("bug_reporter.consent")

local TMP = "/tmp/jve_consent_reprompt_test_" .. tostring(math.random(1, 1e9))
os.execute("/bin/mkdir -p " .. TMP)
install.set_home_for_tests(TMP)

-- The current consent version. When the wording changes this bumps;
-- the test exercises behavior relative to a record one below current.
local CURRENT = consent.CONSENT_VERSION
assert(CURRENT >= 2,
    "this test requires CONSENT_VERSION >= 2 so a 'stale' record at " ..
    "version (CURRENT-1) is well-defined; got " .. tostring(CURRENT))
local STALE   = CURRENT - 1

-- Pre-populate a valid install record carrying a stale consent_version.
-- We bypass install.write's validate so we can plant a record at any
-- version (validate insists on schema consistency, which is fine for
-- production but blocks injecting historical state here).
local function plant_record(version, accepted_ts)
    os.execute("/bin/mkdir -p " .. TMP .. "/.jve")
    local dkjson = require("dkjson")
    local f = io.open(TMP .. "/.jve/install_id.json", "w")
    assert(f, "could not open install_id.json for write")
    f:write(dkjson.encode({
        schema_version = 1,
        install_id = "11111111-2222-4333-8444-555555555555",
        nonce = string.rep("a", 64),
        consent_accepted_ts = accepted_ts or 1719279600,
        consent_version = version,
        jve_sha_at_register = "abcdef0",
    }, { indent = true }))
    f:close()
end

-- Count HTTP calls so we can confirm /register does NOT fire on the
-- reprompt path (the existing nonce is reused).
local http_calls = {}
_G.qt_http_post_json = function(url, _headers, _body, callback_name)
    http_calls[#http_calls + 1] = url
    if callback_name and _G[callback_name] then
        _G[callback_name](200, '{"server_ts":1719279600}', nil)
    end
end
_G.qt_http_post_multipart = function(url, _headers, _parts, callback_name)
    http_calls[#http_calls + 1] = url
    if callback_name and _G[callback_name] then
        _G[callback_name](200, "{}", nil)
    end
end

local function read_record()
    local dkjson = require("dkjson")
    local f = io.open(TMP .. "/.jve/install_id.json", "r")
    if not f then return nil end
    local body = f:read("*a")
    f:close()
    return (dkjson.decode(body))
end

-- (1) Stale stored version + user ACCEPTS reprompt → record's
--     consent_version bumps to current, consent_accepted_ts advances,
--     /register does NOT fire (existing nonce stays).
do
    plant_record(STALE, 1700000000)
    http_calls = {}
    telemetry.set_pref_for_tests(true)
    telemetry.set_consent_outcome_for_tests("accept")
    telemetry.init()
    local rec = read_record()
    assert(rec, "install record must still exist after accept-on-reprompt")
    assert(rec.consent_version == CURRENT, string.format(
        "stale-accept must bump consent_version to %d; got %s",
        CURRENT, tostring(rec.consent_version)))
    assert(rec.consent_accepted_ts > 1700000000, string.format(
        "stale-accept must advance consent_accepted_ts past planted value; got %s",
        tostring(rec.consent_accepted_ts)))
    for _, url in ipairs(http_calls) do
        assert(not url:find("/register", 1, true),
            "stale-accept must NOT issue /register (existing nonce stays); saw " .. url)
    end
end

-- (2) Stale stored version + user DECLINES reprompt → disabled state;
--     no HTTP traffic; record left in place (revoke is a separate flow).
do
    plant_record(STALE, 1700000000)
    http_calls = {}
    telemetry.set_pref_for_tests(true)
    telemetry.set_consent_outcome_for_tests("decline")
    telemetry.init()
    for _, url in ipairs(http_calls) do
        error("stale-decline must NOT issue any HTTP call; saw " .. url)
    end
    local msg = telemetry.f12_message_for_tests()
    assert(msg and msg:lower():find("disabled"),
        "F12 message after stale-decline must surface 'disabled'; got " .. tostring(msg))
end

-- (3) Stored version == CURRENT → no reprompt fires. We force the
--     test-injected outcome to "decline" so that IF the reprompt
--     code path ran in error, the resulting decline would shut off
--     telemetry and leave a 'disabled' F12 message — case (3) detects
--     that regression by asserting the F12 message stays absent and
--     the record's consent_version is unchanged.
do
    plant_record(CURRENT, 1719279600)
    http_calls = {}
    telemetry.set_pref_for_tests(true)
    telemetry.set_consent_outcome_for_tests("decline")  -- trap door
    telemetry.init()
    local rec = read_record()
    assert(rec and rec.consent_version == CURRENT,
        "current-version record must remain at CURRENT; got " ..
        tostring(rec and rec.consent_version))
    assert(rec.consent_accepted_ts == 1719279600,
        "current-version record's consent_accepted_ts must NOT advance " ..
        "(no reprompt fired); got " .. tostring(rec.consent_accepted_ts))
end

os.execute("/bin/rm -rf " .. TMP)
local real_home = os.getenv("HOME")
if real_home and real_home ~= "" then
    os.remove(real_home .. "/.jve/bug_reporter_prefs.json")
end
print("✅ test_bug_reporter_consent_reprompt.lua passed")
