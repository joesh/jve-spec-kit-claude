#!/usr/bin/env luajit

-- T020 (015) — FR-029d: view-toggle modifier flips effective display mode.
--
-- Domain behaviors:
--   1. effective_mode() = pref when modifier NOT held.
--   2. effective_mode() = opposite(pref) when modifier IS held.
--   3. set_modifier_held(false) restores effective_mode to pref value.
--   4. Toggling modifier state never touches the patches table.
--   5. pref.get() is unaffected by modifier state changes.
--
-- Expected FAIL today: source_routing_view_state module does not exist (T041 not applied).

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require("test_env")

local database        = require("core.database")

print("=== test_view_toggle_modifier.lua ===")

-- Use tmp path so pref persists independently of real user pref.
local TEST_PREF_PATH = "/tmp/jve/test_source_routing_view_toggle.json"
os.remove(TEST_PREF_PATH)
os.execute("mkdir -p /tmp/jve")

-- FAIL here if module does not exist (T041 not yet applied).
local state = require("ui.source_routing_view_state")

local pref = require("ui.source_routing_view_pref")
pref.init(TEST_PREF_PATH)
pref.set("per_channel")

-- Set up a minimal DB for patches-unchanged assertions.
local DB = "/tmp/jve/test_view_toggle_modifier.db"
os.remove(DB); os.execute("mkdir -p /tmp/jve")
database.init(DB)
local db = database.get_connection()
db:exec(require("import_schema"))

local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at)
    VALUES ('proj', 'P', 'resample', %d, %d)
]], now, now))
db:exec(string.format([[
    INSERT INTO sequences (id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_sample_rate,
        width, height, created_at, modified_at)
    VALUES ('seq', 'proj', 'S', 'sequence', 24, 1, 48000, 1920, 1080, %d, %d)
]], now, now))
db:exec([[
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
    VALUES ('a1','seq','A1','AUDIO',0,1),('a2','seq','A2','AUDIO',1,1)
]])
-- Seed one patch: A1→A1
db:exec([[
    INSERT INTO patches (sequence_id, source_track_index, record_track_index, enabled)
    VALUES ('seq', 0, 0, 1)
]])

local function patch_count()
    local s = db:prepare("SELECT COUNT(*) FROM patches WHERE sequence_id='seq'")
    assert(s); s:exec(); assert(s:next())
    local n = s:value(0); s:finalize(); return n
end

-- ── 1. Default: no modifier held → effective = pref ──────────────────────────
print("-- 1. no modifier → effective = pref --")
state.init(pref)
state.set_modifier_held(false)
assert(state.effective_mode() == "per_channel",
    "FAIL: expected effective_mode='per_channel' with no modifier; got " .. tostring(state.effective_mode()))
print("  effective_mode = 'per_channel' — OK")

-- ── 2. Modifier held → effective flips ───────────────────────────────────────
print("-- 2. modifier held → effective flips --")
state.set_modifier_held(true)
assert(state.effective_mode() == "per_clip",
    "FAIL: expected effective_mode='per_clip' with modifier held; got " .. tostring(state.effective_mode()))
print("  effective_mode = 'per_clip' with modifier — OK")

-- ── 3. Release modifier → restores to pref ───────────────────────────────────
print("-- 3. release modifier → restores --")
state.set_modifier_held(false)
assert(state.effective_mode() == "per_channel",
    "FAIL: expected effective_mode='per_channel' after release; got " .. tostring(state.effective_mode()))
print("  effective_mode = 'per_channel' after release — OK")

-- ── 4. Works symmetrically with per_clip pref ────────────────────────────────
print("-- 4. symmetric with per_clip pref --")
pref.set("per_clip")
state.init(pref)
state.set_modifier_held(false)
assert(state.effective_mode() == "per_clip",
    "FAIL: expected effective_mode='per_clip' (no modifier); got " .. tostring(state.effective_mode()))
state.set_modifier_held(true)
assert(state.effective_mode() == "per_channel",
    "FAIL: expected effective_mode='per_channel' (modifier + per_clip pref); got " .. tostring(state.effective_mode()))
state.set_modifier_held(false)
print("  per_clip + modifier → per_channel and back — OK")

-- ── 5. pref.get() unaffected by modifier state ───────────────────────────────
print("-- 5. pref.get() unaffected by modifier --")
state.set_modifier_held(true)
assert(pref.get() == "per_clip",
    "FAIL: pref.get() must not change when modifier is held; got " .. tostring(pref.get()))
state.set_modifier_held(false)
print("  pref.get() stable across modifier toggle — OK")

-- ── 6. patches table unchanged by all modifier operations ────────────────────
print("-- 6. patches unchanged --")
local count_before = patch_count()
state.set_modifier_held(true)
state.set_modifier_held(false)
state.set_modifier_held(true)
local count_after = patch_count()
assert(count_after == count_before,
    "FAIL: patches table changed during modifier toggle: before=" .. count_before
    .. " after=" .. count_after)
print("  patches row count unchanged — OK")

os.remove(TEST_PREF_PATH)
print("\n✅ test_view_toggle_modifier.lua passed")
