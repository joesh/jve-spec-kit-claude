-- Feature 027 FR-002 Privacy panel — toggle persistence + revoke.
--
-- Domain:
--   (1) Clicking the panel's toggle MUST persist the new boolean to
--       bug_reporter_prefs.json AND drive telemetry.apply_pref_toggle
--       so the runtime state and on-disk pref stay in lockstep.
--   (2) Clicking Revoke MUST delete ~/.jve/install_id.json so the next
--       launch re-prompts. When the file is absent already, Revoke
--       MUST report 'absent' without raising.
--   (3) Toggle MUST refuse non-boolean values (fail-fast vs the
--       "any truthy value" pitfall that silently flips state).
--
-- Black-box: drives privacy_panel.apply_toggle + privacy_panel.revoke
-- directly. No widget stubs needed — the UI shell wires these into
-- click handlers; the persistence semantics live in the module
-- functions.

print("=== test_bug_reporter_privacy_panel.lua ===")
require("test_env")

local panel        = require("bug_reporter.ui.privacy_panel")
local dialog_prefs = require("core.dialog_prefs")

local TMP = "/tmp/jve_privacy_panel_test_" .. tostring(math.random(1, 1e9))
os.execute("/bin/mkdir -p " .. TMP .. "/.jve")

-- Redirect HOME so the panel writes into TMP/.jve, not the real ~/.jve.
local real_home = os.getenv("HOME")
os.execute("HOME=" .. TMP .. " /usr/bin/env true")  -- no-op; HOME is per-process
-- Lua's os.setenv doesn't exist; use posix-ish workaround via
-- monkey-patching os.getenv for dialog_prefs' jve_dir lookup. The
-- panel module already cached its require, so we patch the global
-- os.getenv that dialog_prefs.jve_dir reads on every call.
local original_getenv = os.getenv
os.getenv = function(k)
    if k == "HOME" then return TMP end
    return original_getenv(k)
end

-- Make telemetry.apply_pref_toggle observable but inert (it touches
-- capture_manager + screenshot timer which neither exist in this test).
local telemetry = require("bug_reporter.telemetry")
local apply_toggle_calls = {}
local saved_apply = telemetry.apply_pref_toggle
telemetry.apply_pref_toggle = function(value)
    apply_toggle_calls[#apply_toggle_calls + 1] = value
end

local function read_pref()
    local prefs_path = TMP .. "/.jve/bug_reporter_prefs.json"
    local f = io.open(prefs_path, "r")
    if not f then return nil end
    local body = f:read("*a")
    f:close()
    return (require("dkjson").decode(body))
end

-- (1) Toggle ON persists true to disk AND fires apply_pref_toggle(true).
do
    apply_toggle_calls = {}
    os.remove(TMP .. "/.jve/bug_reporter_prefs.json")
    local rv = panel.apply_toggle(true)
    assert(rv == true, "apply_toggle(true) must return true; got " .. tostring(rv))
    local prefs = read_pref()
    assert(prefs and prefs.bug_reporter_enabled == true,
        "toggle ON must persist bug_reporter_enabled=true; got " ..
        tostring(prefs and prefs.bug_reporter_enabled))
    assert(#apply_toggle_calls == 1 and apply_toggle_calls[1] == true,
        "toggle ON must drive telemetry.apply_pref_toggle(true) exactly once; got " ..
        tostring(#apply_toggle_calls) .. " calls, first=" ..
        tostring(apply_toggle_calls[1]))
end

-- (2) Toggle OFF persists false AND fires apply_pref_toggle(false).
do
    apply_toggle_calls = {}
    panel.apply_toggle(false)
    local prefs = read_pref()
    assert(prefs and prefs.bug_reporter_enabled == false,
        "toggle OFF must persist bug_reporter_enabled=false; got " ..
        tostring(prefs and prefs.bug_reporter_enabled))
    assert(#apply_toggle_calls == 1 and apply_toggle_calls[1] == false,
        "toggle OFF must drive telemetry.apply_pref_toggle(false) exactly once")
end

-- (3) Non-boolean refuses (fail-fast).
do
    local ok, err = pcall(panel.apply_toggle, "yes")
    assert(not ok, "apply_toggle('yes') must raise — truthy-string pitfall")
    assert(tostring(err):find("boolean", 1, true),
        "non-boolean error must mention 'boolean'; got " .. tostring(err))
    local ok2 = pcall(panel.apply_toggle, nil)
    assert(not ok2, "apply_toggle(nil) must raise")
    local ok3 = pcall(panel.apply_toggle, 1)
    assert(not ok3, "apply_toggle(1) must raise")
end

-- (4) Revoke with a planted install file deletes it + returns 'revoked'.
do
    local install_path = TMP .. "/.jve/install_id.json"
    local f = assert(io.open(install_path, "w"))
    f:write('{"schema_version":1}')
    f:close()
    local outcome = panel.revoke()
    assert(outcome == "revoked",
        "revoke() with file present must return 'revoked'; got " .. tostring(outcome))
    local g = io.open(install_path, "r")
    assert(g == nil, "revoke() must delete install_id.json; file still present")
end

-- (5) Revoke with no install file present returns 'absent' (no raise).
do
    os.remove(TMP .. "/.jve/install_id.json")
    local outcome = panel.revoke()
    assert(outcome == "absent",
        "revoke() with no file must return 'absent'; got " .. tostring(outcome))
end

-- Restore globals + clean up.
os.getenv = original_getenv
telemetry.apply_pref_toggle = saved_apply
os.execute("/bin/rm -rf " .. TMP)
print("✅ test_bug_reporter_privacy_panel.lua passed")
