#!/usr/bin/env luajit

-- Regression tests for patch routing domain behavior (Feature 015).
--
-- Domain rules under test, all at a fixed source shape (3 V + 3 A) so
-- the test exercises the shape-keyed (sequence_id, track_type,
-- source_shape, source_track_index) → record_track_index contract.
--   1. Patch.find_by_record returns nil when no patch routes to a record row.
--   2. After SetPatch(VIDEO, shape=3, src=2, rec=3), find_by_record(seq,
--      VIDEO, shape=3, rec=3) returns source_track_index=2.
--   3. After the above, find_by_record(seq, VIDEO, shape=3, rec=2) returns nil.
--   4. Re-routing: patching src=2 to a new rec causes old rec row to become nil.
--   5. VIDEO src and AUDIO src at same index are independent slots (no cross-
--      type confusion) even at the same shape.

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require("test_env")

local database        = require("core.database")
local Patch           = require("models.patch")
local command_manager = require("core.command_manager")

_G.qt_create_single_shot_timer = function(_d, cb) cb(); return nil end

print("=== test_patch_routing.lua ===")

local DB = "/tmp/jve/test_patch_routing.db"
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
    VALUES ('v1','seq','V1','VIDEO',1,1),
           ('v2','seq','V2','VIDEO',2,1),
           ('v3','seq','V3','VIDEO',3,1),
           ('a1','seq','A1','AUDIO',1,1),
           ('a2','seq','A2','AUDIO',2,1),
           ('a3','seq','A3','AUDIO',3,1)
]])

command_manager.init("seq", "proj")

local SHAPE = 3  -- fixed shape used throughout this test

-- ── Test 1: find_by_record returns nil when no patch exists ───────────────
print("-- 1: find_by_record nil when no patch --")
local result = Patch.find_by_record("seq", "VIDEO", SHAPE, 1)
assert(result == nil,
    "find_by_record must return nil for an unpatched record row; got: " .. tostring(result))
print("  nil for unpatched row — OK")

-- ── Test 2: find_by_record returns correct source after SetPatch ──────────
print("-- 2: find_by_record after SetPatch(VIDEO, src=2, rec=3) --")
local r2 = command_manager.execute("SetPatch", {
    sequence_id        = "seq",
    source_shape       = SHAPE,
    source_track_index = 2,
    record_track_index = 3,
    enabled            = 1,
    track_type         = "VIDEO",
    project_id         = "proj",
})
assert(r2 and r2.success,
    "SetPatch(VIDEO, src=2, rec=3) failed: " .. tostring(r2 and r2.error_message))
local p2 = Patch.find_by_record("seq", "VIDEO", SHAPE, 3)
assert(p2, "find_by_record(seq, VIDEO, shape=3, rec=3) must return a patch")
assert(p2.source_track_index == 2,
    "expected source_track_index=2, got " .. tostring(p2.source_track_index))
print("  find_by_record(seq, VIDEO, shape=3, rec=3).source_track_index = 2 — OK")

-- ── Test 3: find_by_record(seq, VIDEO, shape=3, rec=2) is nil ─────────────
print("-- 3: find_by_record nil for unrelated record row --")
local p3 = Patch.find_by_record("seq", "VIDEO", SHAPE, 2)
assert(p3 == nil,
    "find_by_record(seq, VIDEO, shape=3, rec=2) must be nil — only rec=3 was patched")
print("  find_by_record(seq, VIDEO, shape=3, rec=2) is nil — OK")

-- ── Test 4: re-routing clears old record row ──────────────────────────────
print("-- 4: re-routing clears old record row --")
local r4 = command_manager.execute("SetPatch", {
    sequence_id        = "seq",
    source_shape       = SHAPE,
    source_track_index = 2,
    record_track_index = 1,
    track_type         = "VIDEO",
    project_id         = "proj",
})
assert(r4 and r4.success,
    "SetPatch re-route (VIDEO, src=2, rec=1) failed: " .. tostring(r4 and r4.error_message))
local p4a = Patch.find_by_record("seq", "VIDEO", SHAPE, 1)
assert(p4a and p4a.source_track_index == 2,
    "after re-route, find_by_record(seq, VIDEO, shape=3, rec=1) must return source=2")
local p4b = Patch.find_by_record("seq", "VIDEO", SHAPE, 3)
assert(p4b == nil,
    "after re-route, find_by_record(seq, VIDEO, shape=3, rec=3) must return nil")
print("  old rec row cleared, new rec row patched — OK")

-- ── Test 5: VIDEO and AUDIO patches at same indices are independent ───────
print("-- 5: VIDEO and AUDIO patches at same index are independent --")
local r5a = command_manager.execute("SetPatch", {
    sequence_id        = "seq",
    source_shape       = SHAPE,
    source_track_index = 2,
    record_track_index = 2,
    enabled            = 1,
    track_type         = "AUDIO",
    project_id         = "proj",
})
assert(r5a and r5a.success, "SetPatch AUDIO src=2,rec=2 failed")
-- VIDEO patch for src=2 still targets rec=1 (set in test 4)
local pv = Patch.find_by_record("seq", "VIDEO", SHAPE, 1)
assert(pv and pv.source_track_index == 2,
    "VIDEO patch must still have src=2,rec=1 after AUDIO patch created")
local pa = Patch.find_by_record("seq", "AUDIO", SHAPE, 2)
assert(pa and pa.source_track_index == 2,
    "AUDIO patch src=2,rec=2 must exist independently")
print("  VIDEO and AUDIO patches independent — OK")

print("\n✅ test_patch_routing.lua passed")
