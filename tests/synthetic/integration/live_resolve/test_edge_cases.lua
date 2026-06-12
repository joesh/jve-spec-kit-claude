-- T042 — LIVE edge cases (spec 023, FR-009/FR-010/FR-020; quickstart
--          edge checks).
--
-- Live leg (this file): FR-009 handle revalidation across a Resolve
-- project switch. The helper holds no cached project handle a UI
-- switch can invalidate — every verb reacquires (resolve_handle
-- .acquire per @_stateful_verb). Proven against the real thing:
--   1. read_timeline succeeds on the VM's current project.
--   2. A probe switches Resolve to a freshly-created EMPTY project
--      (the scripted twin of the user switching projects in the UI —
--      ProjectManager state changes identically).
--   3. read_timeline now returns the STRUCTURED closed-set error
--      `handle_stale` ("no current timeline") — not a crash, not a
--      stale answer from the previous project.
--   4. The probe switches back; read_timeline succeeds again —
--      revalidation is per-verb, nothing sticky survived the bounce.
--
-- Unit legs (not runnable live, covered in tools/resolve-helper):
--   • FR-010 free-Resolve ⇒ `not_studio` terminal acquire state:
--     test_resolve_handle_gates.py (no free Resolve exists on the VM;
--     the product-name gate is exercised at the fusionscript boundary
--     with the real product strings).
--   • FR-020 locale fractional-rate truncation ⇒
--     `locale_rate_corruption` + conform refused:
--     test_cdl_edl.py (parser: 23/29/47/59 are unambiguous truncation
--     signatures) and test_verbs.py (wire-code mapping). Resolve
--     rejects rates outside its fixed set, so the corrupted read
--     cannot be manufactured on a healthy live instance.
--
-- ⚠ State-changing on the VM Resolve's ProjectManager (creates and
-- deletes a scratch project): run against the VM test environment
-- only (memory: project_vm_test_environment).
--
-- Run via (absolute path, on the VM):
--   ./build/bin/jve.app/Contents/MacOS/jve --test \
--       $PWD/tests/synthetic/integration/live_resolve/test_edge_cases.lua

require("test_env")
local supervisor = require("core.resolve_bridge.helper_supervisor")
local driver = require(
    "synthetic.integration.live_resolve.command_driver")

local PROBE_PROJECT = "jve-t042-stale-probe"
local ORIG_NAME_FILE = "/tmp/jve/t042_orig_project.txt"

supervisor.configure(
    driver.repo_root() .. "/tools/resolve-helper/helper.py")
driver.skip_unless_live("test_edge_cases")

-- ─── Probe plumbing ────────────────────────────────────────────────
-- The scripted twin of a user switching projects in Resolve's UI.
-- Runs OUTSIDE the helper (separate fusionscript session) so the
-- helper can't be coddled by its own connection state.

local PROBE_PRELUDE = [[
import os, sys
api_dir = ("/Library/Application Support/Blackmagic Design/"
           "DaVinci Resolve/Developer/Scripting")
sys.path.insert(0, os.path.join(api_dir, "Modules"))
os.environ["RESOLVE_SCRIPT_API"] = api_dir
os.environ["RESOLVE_SCRIPT_LIB"] = (
    "/Applications/DaVinci Resolve/DaVinci Resolve.app/"
    "Contents/Libraries/Fusion/fusionscript.so")
import DaVinciResolveScript as dvr
resolve = dvr.scriptapp("Resolve")
assert resolve is not None, "probe: scriptapp returned None"
pm = resolve.GetProjectManager()
]]

local function run_probe(name, body)
    os.execute("mkdir -p /tmp/jve")
    local path = "/tmp/jve/t042_probe_" .. name .. ".py"
    local f = assert(io.open(path, "w"))
    f:write(PROBE_PRELUDE, body)
    f:close()
    local rc = os.execute("/usr/bin/python3 '" .. path .. "'")
    assert(rc == 0, string.format(
        "T042 probe %s failed (rc=%s) — see %s", name, tostring(rc),
        path))
end

-- ─── 1. Baseline: current project answers ──────────────────────────
local base = driver.helper_request("read_timeline", {})
assert(type(base.items) == "table",
    "T042 baseline: read_timeline must return items on the VM's "
    .. "current project")
print(string.format("  ✓ baseline read_timeline ok (%d items)",
    #base.items))

-- ─── 2. Switch Resolve to a fresh empty project ────────────────────
run_probe("switch", string.format([[
orig = pm.GetCurrentProject().GetName()
assert orig and orig != %q, (
    "probe leftover is current — prior failed run; restore manually")
open(%q, "w").write(orig)
# Leftover scratch project from a failed prior run would make
# CreateProject return None; clear it first.
pm.DeleteProject(%q)
created = pm.CreateProject(%q)
assert created, "CreateProject %s failed"
print("probe: switched", orig, "->", %q)
]], PROBE_PROJECT, ORIG_NAME_FILE, PROBE_PROJECT, PROBE_PROJECT,
    PROBE_PROJECT, PROBE_PROJECT))

-- ─── 3. Verb against the switched-away state → handle_stale ────────
local stale = driver.helper_request_envelope("read_timeline", {})
assert(stale.ok == false, "T042: read_timeline must FAIL after the "
    .. "project switch (empty project has no current timeline)")
assert(stale.error and stale.error.code == "handle_stale",
    string.format("T042: FR-009 demands the closed-set code "
        .. "handle_stale, got %s (%s)",
        tostring(stale.error and stale.error.code),
        tostring(stale.error and stale.error.message)))
print("  ✓ post-switch read_timeline → handle_stale ("
    .. stale.error.message .. ")")

-- ─── 4. Switch back; the next verb just works ──────────────────────
run_probe("restore", string.format([[
orig = open(%q).read().strip()
assert pm.LoadProject(orig), "LoadProject back to " + orig + " failed"
ok = pm.DeleteProject(%q)
print("probe: restored", orig, "| deleted scratch:", ok)
]], ORIG_NAME_FILE, PROBE_PROJECT))

local back = driver.helper_request("read_timeline", {})
assert(type(back.items) == "table" and #back.items == #base.items,
    string.format("T042 recovery: expected the original project's %d "
        .. "items again, got %s", #base.items,
        tostring(back.items and #back.items)))
print(string.format(
    "  ✓ post-restore read_timeline ok again (%d items) — "
    .. "per-verb reacquire, nothing sticky", #back.items))

os.remove(ORIG_NAME_FILE)
supervisor.shutdown()
print("✅ test_edge_cases.lua passed")
