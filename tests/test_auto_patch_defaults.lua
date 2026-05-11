#!/usr/bin/env luajit

-- Test: auto_patch_defaults.apply_if_empty (Feature 015, FR-029).
--
-- Domain behavior:
-- When a source clip is loaded and the record sequence has no patches, identity
-- patches (source Vn→rec Vn, An→rec An) appear for every SOURCE track.
-- When patches already exist, they are never touched.

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require("test_env")

local database    = require("core.database")
local command_manager = require("core.command_manager")
local Patch       = require("models.patch")
local apd         = require("ui.timeline.auto_patch_defaults")

_G.qt_create_single_shot_timer = function(_d, cb) cb(); return nil end

print("=== test_auto_patch_defaults.lua ===")

local DB = "/tmp/jve/test_auto_patch_defaults.db"
os.remove(DB); os.execute("mkdir -p /tmp/jve")
database.init(DB)
local db = database.get_connection()
db:exec(require("import_schema"))

local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at)
    VALUES ('proj', 'P', 'resample', %d, %d)
]], now, now))

-- Record sequence: V1, V2, A1, A2, A3
db:exec(string.format([[
    INSERT INTO sequences (id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_sample_rate,
        width, height, created_at, modified_at)
    VALUES ('rec_seq', 'proj', 'Seq', 'nested', 24, 1, 48000, 1920, 1080, %d, %d)
]], now, now))
db:exec([[
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
    VALUES ('rv1','rec_seq','V1','VIDEO',1,1),
           ('rv2','rec_seq','V2','VIDEO',2,1),
           ('ra1','rec_seq','A1','AUDIO',1,1),
           ('ra2','rec_seq','A2','AUDIO',2,1),
           ('ra3','rec_seq','A3','AUDIO',3,1)
]])

-- Source sequence: V1, A1, A2  (fewer than record — only these should be patched)
db:exec(string.format([[
    INSERT INTO sequences (id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_sample_rate,
        width, height, created_at, modified_at)
    VALUES ('src_seq', 'proj', 'Src', 'nested', 24, 1, 48000, 1920, 1080, %d, %d)
]], now, now))
db:exec([[
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
    VALUES ('sv1','src_seq','V1','VIDEO',1,1),
           ('sa1','src_seq','A1','AUDIO',1,1),
           ('sa2','src_seq','A2','AUDIO',2,1)
]])

command_manager.init("rec_seq", "proj")

-- ── helpers ──────────────────────────────────────────────────────────────────
local function patch_count()
    local s = db:prepare("SELECT COUNT(*) FROM patches WHERE sequence_id='rec_seq'")
    s:exec(); s:next(); local n = s:value(0); s:finalize(); return n
end

local function patch_for(track_type, src_idx)
    return Patch.find_by_source("rec_seq", track_type, src_idx)
end

-- ── Test 1: empty record sequence → identity patches created for source tracks ──
print("\n-- T1: first source load creates identity patches")
assert(patch_count() == 0, "precondition: no patches yet")

apd.apply_if_empty("rec_seq", "src_seq", "proj")

assert(patch_count() == 3, string.format(
    "T1: expected 3 patches (V1+A1+A2 from source), got %d", patch_count()))

local pV1 = patch_for("VIDEO", 1)
assert(pV1,                               "T1: VIDEO patch for source V1 missing")
assert(pV1.record_track_index == 1,       "T1: VIDEO V1 must map to record V1")
assert(pV1.enabled == 1 or pV1.enabled == true,
                                          "T1: VIDEO V1 patch must be enabled")

local pA1 = patch_for("AUDIO", 1)
assert(pA1 and pA1.record_track_index == 1, "T1: AUDIO A1 identity mapping")
local pA2 = patch_for("AUDIO", 2)
assert(pA2 and pA2.record_track_index == 2, "T1: AUDIO A2 identity mapping")

-- Source V2 does NOT exist → no VIDEO patch for src index 2
local pV2 = patch_for("VIDEO", 2)
assert(not pV2, "T1: no VIDEO patch for source index 2 (source has no V2)")

-- Record-only A3 also unpached (source has no A3)
local pA3 = patch_for("AUDIO", 3)
assert(not pA3, "T1: no AUDIO patch for source index 3 (source has no A3)")

-- ── Test 2: calling again is idempotent (patches already exist → no-op) ──
print("\n-- T2: idempotent when patches exist")
apd.apply_if_empty("rec_seq", "src_seq", "proj")
assert(patch_count() == 3, "T2: count unchanged on second call")

-- ── Test 3: existing custom patch is not overwritten ──
print("\n-- T3: existing custom mapping preserved")
-- Simulate user having patched src A2 → rec A3 instead of A2
command_manager.execute("SetPatch", {
    sequence_id        = "rec_seq",
    source_track_index = 2,
    record_track_index = 3,   -- non-identity
    track_type         = "AUDIO",
    project_id         = "proj",
    enabled            = true,
})
-- apply_if_empty is now a no-op (patches exist)
apd.apply_if_empty("rec_seq", "src_seq", "proj")
local pA2_after = patch_for("AUDIO", 2)
assert(pA2_after and pA2_after.record_track_index == 3,
    "T3: custom A2→A3 mapping must not be overwritten by apply_if_empty")

-- ── Test 4: assert guard — empty record_seq_id must error ──
print("\n-- T4: assert fires on empty record_seq_id")
local ok = pcall(apd.apply_if_empty, "", "src_seq", "proj")
assert(not ok, "T4: must assert on empty record_seq_id")

print("\n✅ test_auto_patch_defaults.lua passed")
