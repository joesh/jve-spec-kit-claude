#!/usr/bin/env luajit

-- T021 (015) — FR-029c: source_routing_view preference persists across app restart.
--
-- Domain: the user's preferred source-routing display mode ('per_channel' or 'per_clip')
-- lives at ~/.jve/source_routing_view.json. Setting it, re-initializing the pref
-- subsystem, and re-reading must yield the persisted value. Default is 'per_channel'.
--
-- Expected FAIL today: source_routing_view module does not exist (T040 not applied).

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require("test_env")

print("=== test_source_routing_view_pref.lua ===")

-- Use a tmp path to avoid clobbering the real user pref.
local TEST_PATH = "/tmp/jve/test_source_routing_view.json"
os.remove(TEST_PATH)
os.execute("mkdir -p /tmp/jve")

-- FAIL here if module does not exist.
local pref = require("ui.source_routing_view_pref")

-- ── Default value before any file exists ─────────────────────────────────────
pref.init(TEST_PATH)
local default_val = pref.get()
assert(default_val == 'per_channel', string.format(
    "FAIL: default source_routing_view expected 'per_channel', got '%s'", tostring(default_val)))
print(string.format("  default value = '%s' — OK", default_val))

-- ── Set and persist ──────────────────────────────────────────────────────────
pref.set('per_clip')
local after_set = pref.get()
assert(after_set == 'per_clip', string.format(
    "FAIL: after set expected 'per_clip', got '%s'", tostring(after_set)))
print("  set to 'per_clip' — OK")

-- ── Re-init from disk simulates app restart ──────────────────────────────────
pref.init(TEST_PATH)
local after_restart = pref.get()
assert(after_restart == 'per_clip', string.format(
    "FAIL: after restart expected 'per_clip', got '%s' — preference not persisted",
    tostring(after_restart)))
print("  value survives restart — OK")

-- ── Invalid value must be rejected ───────────────────────────────────────────
local ok = pcall(function() pref.set('invalid_mode') end)
assert(not ok, "FAIL: pref.set('invalid_mode') must error — got success")
local after_bad = pref.get()
assert(after_bad == 'per_clip', string.format(
    "FAIL: invalid set must not change value; still expected 'per_clip', got '%s'",
    tostring(after_bad)))
print("  invalid value rejected — OK")

-- ── Round-trip back to per_channel ───────────────────────────────────────────
pref.set('per_channel')
pref.init(TEST_PATH)
assert(pref.get() == 'per_channel',
    "FAIL: round-trip to 'per_channel' failed after restart")
print("  round-trip to 'per_channel' — OK")

-- ── Storage path is the documented location ──────────────────────────────────
-- T040 decision: single-purpose file matching ~/.jve/find_dialog_settings.json pattern.
assert(pref.storage_path() == TEST_PATH, string.format(
    "FAIL: pref.storage_path() = '%s', expected '%s'",
    tostring(pref.storage_path()), TEST_PATH))
print(string.format("  storage_path = '%s' — OK", pref.storage_path()))

os.remove(TEST_PATH)

print("\n✅ test_source_routing_view_pref.lua passed")
