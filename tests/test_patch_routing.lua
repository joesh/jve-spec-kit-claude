#!/usr/bin/env luajit

-- Regression tests for patch routing domain behavior (Feature 015).
--
-- Domain rules under test:
--   1. Patch.find_by_record returns nil when no patch routes to a record row.
--   2. After SetPatch(src=2, rec=3), find_by_record(seq, 3) returns source_track_index=2.
--   3. After SetPatch(src=2, rec=3), find_by_record(seq, 2) returns nil (rec 2 unpatched).
--   4. Re-routing: patching src=2 to a new rec causes old rec row to become nil.
--   5. Cross-type SetPatch (source_track_type VIDEO, record_track_type AUDIO) must fail.
--   6. Same-type SetPatch (both VIDEO) must succeed.

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require("test_env")

local database    = require("core.database")
local Patch       = require("models.patch")
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
    VALUES ('seq', 'proj', 'S', 'nested', 24, 1, 48000, 1920, 1080, %d, %d)
]], now, now))
-- V1, V2, V3 video tracks and A1, A2, A3 audio tracks sharing indices 1-3
db:exec([[
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
    VALUES ('v1', 'seq', 'V1', 'VIDEO', 1, 1),
           ('v2', 'seq', 'V2', 'VIDEO', 2, 1),
           ('v3', 'seq', 'V3', 'VIDEO', 3, 1),
           ('a1', 'seq', 'A1', 'AUDIO', 1, 1),
           ('a2', 'seq', 'A2', 'AUDIO', 2, 1),
           ('a3', 'seq', 'A3', 'AUDIO', 3, 1)
]])

command_manager.init("seq", "proj")

-- ── Test 1: find_by_record returns nil when no patch exists ───────────────
print("-- 1: find_by_record nil when no patch --")
local result = Patch.find_by_record("seq", 1)
assert(result == nil,
    "find_by_record must return nil for an unpatched record row; got: " .. tostring(result))
print("  nil for unpatched row — OK")

-- ── Test 2: find_by_record returns correct source after SetPatch ──────────
print("-- 2: find_by_record after SetPatch(src=2, rec=3) --")
local r2 = command_manager.execute("SetPatch", {
    sequence_id        = "seq",
    source_track_index = 2,
    record_track_index = 3,
    project_id         = "proj",
})
assert(r2 and r2.success,
    "SetPatch(src=2, rec=3) failed: " .. tostring(r2 and r2.error_message))
local p2 = Patch.find_by_record("seq", 3)
assert(p2, "find_by_record(seq, 3) must return a patch after routing src=2 to rec=3")
assert(p2.source_track_index == 2,
    "expected source_track_index=2, got " .. tostring(p2.source_track_index))
print("  find_by_record(seq, 3).source_track_index = 2 — OK")

-- ── Test 3: find_by_record(seq, 2) is nil — rec row 2 is unpatched ────────
print("-- 3: find_by_record nil for unrelated record row --")
local p3 = Patch.find_by_record("seq", 2)
assert(p3 == nil,
    "find_by_record(seq, 2) must be nil — only rec=3 was patched; got source="
    .. tostring(p3 and p3.source_track_index))
print("  find_by_record(seq, 2) is nil — OK")

-- ── Test 4: re-routing — after updating src=2 to rec=1, rec=3 becomes nil ─
print("-- 4: re-routing clears old record row --")
local r4 = command_manager.execute("SetPatch", {
    sequence_id        = "seq",
    source_track_index = 2,
    record_track_index = 1,
    project_id         = "proj",
})
assert(r4 and r4.success,
    "SetPatch re-route (src=2, rec=1) failed: " .. tostring(r4 and r4.error_message))
-- rec=1 must now show src=2
local p4a = Patch.find_by_record("seq", 1)
assert(p4a and p4a.source_track_index == 2,
    "after re-route, find_by_record(seq, 1) must return source=2; got "
    .. tostring(p4a and p4a.source_track_index))
-- rec=3 must now return nil — src=2 no longer routes here
local p4b = Patch.find_by_record("seq", 3)
assert(p4b == nil,
    "after re-route, find_by_record(seq, 3) must return nil; got source="
    .. tostring(p4b and p4b.source_track_index))
print("  old rec row cleared, new rec row patched — OK")

-- ── Test 5: cross-type SetPatch (VIDEO source → AUDIO record) must fail ───
print("-- 5: cross-type VIDEO→AUDIO must fail --")
local r5 = command_manager.execute("SetPatch", {
    sequence_id        = "seq",
    source_track_index = 1,
    record_track_index = 1,
    source_track_type  = "VIDEO",
    record_track_type  = "AUDIO",   -- explicit: destination is an AUDIO track
    project_id         = "proj",
})
assert(not (r5 and r5.success),
    "SetPatch VIDEO→AUDIO cross-type must be refused; it was accepted")
print("  cross-type VIDEO→AUDIO refused — OK")

-- ── Test 6: same-type SetPatch (VIDEO → VIDEO) must succeed ───────────────
print("-- 6: same-type VIDEO→VIDEO must succeed --")
local r6 = command_manager.execute("SetPatch", {
    sequence_id        = "seq",
    source_track_index = 3,
    record_track_index = 3,
    source_track_type  = "VIDEO",
    record_track_type  = "VIDEO",
    project_id         = "proj",
})
assert(r6 and r6.success,
    "SetPatch VIDEO→VIDEO must succeed: " .. tostring(r6 and r6.error_message))
local p6 = Patch.find_by_record("seq", 3)
assert(p6 and p6.source_track_index == 3, "VIDEO→VIDEO patch not found after creation")
print("  same-type VIDEO→VIDEO accepted — OK")

print("\n✅ test_patch_routing.lua passed")
