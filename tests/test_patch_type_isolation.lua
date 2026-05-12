#!/usr/bin/env luajit

-- Regression: VIDEO and AUDIO patches at the same index must be independent.
--
-- Root cause that prompted this test: patches table had no track_type column.
-- find_by_record(seq, 1) returned the same patch for both V1 and A1 rows
-- (both have track_index=1), causing blue src-id buttons to appear on every
-- row that shared an index with any stale patch.
--
-- Domain rules:
--   1. SetPatch(VIDEO, src=1, rec=1) and SetPatch(AUDIO, src=1, rec=1) must
--      coexist as distinct patches — they are different track types.
--   2. find_by_record(seq, "VIDEO", 1) returns the VIDEO patch's source.
--   3. find_by_record(seq, "AUDIO", 1) returns the AUDIO patch's source.
--   4. find_by_record(seq, "VIDEO", 2) returns nil (no VIDEO patch at rec=2).
--   5. After disabling the VIDEO patch, AUDIO patch is unaffected.

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require("test_env")

local database    = require("core.database")
local Patch       = require("models.patch")
local command_manager = require("core.command_manager")

_G.qt_create_single_shot_timer = function(_d, cb) cb(); return nil end

print("=== test_patch_type_isolation.lua ===")

local DB = "/tmp/jve/test_patch_type_isolation.db"
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
           ('a1','seq','A1','AUDIO',1,1),
           ('a2','seq','A2','AUDIO',2,1)
]])

command_manager.init("seq", "proj")

-- ── Test 1: VIDEO and AUDIO patches at same index coexist ─────────────────
print("-- 1: VIDEO src=1,rec=1 and AUDIO src=1,rec=1 coexist --")
local rv = command_manager.execute("SetPatch", {
    sequence_id        = "seq",
    source_track_index = 1,
    record_track_index = 1,
    track_type         = "VIDEO",
    project_id         = "proj",
})
assert(rv and rv.success,
    "SetPatch VIDEO src=1,rec=1 failed: " .. tostring(rv and rv.error_message))

local ra = command_manager.execute("SetPatch", {
    sequence_id        = "seq",
    source_track_index = 1,
    record_track_index = 1,
    track_type         = "AUDIO",
    project_id         = "proj",
})
assert(ra and ra.success,
    "SetPatch AUDIO src=1,rec=1 failed: " .. tostring(ra and ra.error_message))

-- Verify both exist as separate rows
local s = db:prepare("SELECT COUNT(*) FROM patches WHERE sequence_id='seq'")
assert(s); s:exec(); assert(s:next())
local count = s:value(0); s:finalize()
assert(count == 2, "expected 2 patch rows (one VIDEO, one AUDIO); got " .. tostring(count))
print("  two distinct patch rows exist — OK")

-- ── Test 2: find_by_record returns VIDEO patch for VIDEO row ──────────────
print("-- 2: find_by_record returns correct type --")
local pv = Patch.find_by_record("seq", "VIDEO", 1)
assert(pv, "find_by_record(seq, VIDEO, 1) must return a patch")
assert(pv.source_track_index == 1,
    "VIDEO patch must have source_track_index=1; got " .. tostring(pv.source_track_index))
assert(pv.track_type == "VIDEO",
    "patch.track_type must be VIDEO; got " .. tostring(pv.track_type))

local pa = Patch.find_by_record("seq", "AUDIO", 1)
assert(pa, "find_by_record(seq, AUDIO, 1) must return a patch")
assert(pa.source_track_index == 1,
    "AUDIO patch must have source_track_index=1; got " .. tostring(pa.source_track_index))
assert(pa.track_type == "AUDIO",
    "patch.track_type must be AUDIO; got " .. tostring(pa.track_type))
print("  VIDEO and AUDIO patches returned correctly — OK")

-- ── Test 3: find_by_record returns nil for unpatched row ──────────────────
print("-- 3: find_by_record nil for unpatched row --")
local pnil = Patch.find_by_record("seq", "VIDEO", 2)
assert(pnil == nil,
    "find_by_record(seq, VIDEO, 2) must be nil (no VIDEO patch at rec=2)")
print("  nil for unpatched VIDEO row — OK")

-- ── Test 4: disabling VIDEO patch does not affect AUDIO patch ─────────────
print("-- 4: disabling VIDEO patch leaves AUDIO patch untouched --")
local rd = command_manager.execute("SetPatch", {
    sequence_id        = "seq",
    source_track_index = 1,
    enabled            = 0,
    track_type         = "VIDEO",
    project_id         = "proj",
})
assert(rd and rd.success, "disable VIDEO patch failed")

local pv2 = Patch.find_by_record("seq", "VIDEO", 1)
assert(pv2 and (pv2.enabled == 0),
    "VIDEO patch must be disabled; got enabled=" .. tostring(pv2 and pv2.enabled))

local pa2 = Patch.find_by_record("seq", "AUDIO", 1)
assert(pa2 and (pa2.enabled == 1 or pa2.enabled == true),
    "AUDIO patch must still be enabled after VIDEO patch disabled; got enabled="
    .. tostring(pa2 and pa2.enabled))
print("  VIDEO disabled, AUDIO unaffected — OK")

print("\n✅ test_patch_type_isolation.lua passed")
