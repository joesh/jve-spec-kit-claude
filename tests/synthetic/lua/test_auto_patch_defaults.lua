#!/usr/bin/env luajit

-- Test: Patch.ensure_identity_for_source (015 F2).
--
-- Domain behavior:
--   Patches are the sole edit-time routing mechanism. To preserve pre-
--   patch identity behavior (source N → record N) without forcing users
--   to set up patches, identity rows are seeded automatically when a
--   source becomes relevant to a record sequence.
--
--   Seeding is PER-CHANNEL idempotent:
--     - For each source track index that has no patch row on the rec
--       sequence, create one (identity rec_idx, enabled=1).
--     - Existing rows (identity OR user-customised OR disabled) are
--       NEVER touched.
--
--   Called from Insert.execute and Overwrite.execute (API path) and from
--   the source_loaded_changed UI handler (so patch buttons render
--   before any edit happens).

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require("test_env")

local database = require("core.database")
local Patch    = require("models.patch")

_G.qt_create_single_shot_timer = function(_d, cb) cb(); return nil end

print("=== test_auto_patch_defaults.lua ===")

local DB = "/tmp/jve/test_auto_patch_defaults.db"
os.remove(DB); os.execute("mkdir -p /tmp/jve")
database.init(DB)
local db = database.get_connection()
db:exec(require("import_schema"))

local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
    VALUES ('proj', 'P', 'resample', '{"master_clock_hz":192000,"default_fps":{"num":24,"den":1}}', %d, %d)
]], now, now))

-- Record sequence: V1, V2, A1, A2, A3
db:exec(string.format([[
    INSERT INTO sequences (id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_sample_rate,
        width, height, created_at, modified_at)
    VALUES ('rec_seq', 'proj', 'Seq', 'sequence', 24, 1, 48000, 1920, 1080, %d, %d)
]], now, now))
db:exec([[
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
    VALUES ('rv1','rec_seq','V1','VIDEO',1,1),
           ('rv2','rec_seq','V2','VIDEO',2,1),
           ('ra1','rec_seq','A1','AUDIO',1,1),
           ('ra2','rec_seq','A2','AUDIO',2,1),
           ('ra3','rec_seq','A3','AUDIO',3,1)
]])

-- Source sequence: V1, A1, A2  (fewer than record — only these should be seeded)
db:exec(string.format([[
    INSERT INTO sequences (id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_sample_rate,
        width, height, created_at, modified_at)
    VALUES ('src_seq', 'proj', 'Src', 'sequence', 24, 1, 48000, 1920, 1080, %d, %d)
]], now, now))
db:exec([[
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
    VALUES ('sv1','src_seq','V1','VIDEO',1,1),
           ('sa1','src_seq','A1','AUDIO',1,1),
           ('sa2','src_seq','A2','AUDIO',2,1)
]])

local function patch_count()
    local s = db:prepare("SELECT COUNT(*) FROM patches WHERE sequence_id='rec_seq'")
    s:exec(); s:next(); local n = s:value(0); s:finalize(); return n
end

local function patch_for(track_type, shape, src_idx)
    return Patch.find_by_source("rec_seq", track_type, shape, src_idx)
end

-- src_seq: VIDEO=1 track, AUDIO=2 tracks → shapes (1, 2).
-- src2:    VIDEO=1 track, AUDIO=4 tracks → shapes (1, 4).
local V_SHAPE_1 = 1   -- both sources have 1 video track
local A_SHAPE_2 = 2   -- src_seq audio shape
local A_SHAPE_4 = 4   -- src2 audio shape

-- ── T1: first call seeds identity for every source track ────────────────────
print("\n-- T1: empty rec → identity patches for source tracks")
assert(patch_count() == 0, "precondition: no patches yet")

Patch.ensure_identity_for_source("rec_seq", "src_seq")

assert(patch_count() == 3, string.format(
    "T1: expected 3 patches (V1+A1+A2 from source), got %d", patch_count()))

local pV1 = patch_for("VIDEO", V_SHAPE_1, 1)
assert(pV1 and pV1.record_track_index == 1,
    "T1: VIDEO V1 → record V1 identity")
assert(pV1.enabled == 1 or pV1.enabled == true,
    "T1: seeded patch must be enabled")

local pA1 = patch_for("AUDIO", A_SHAPE_2, 1)
local pA2 = patch_for("AUDIO", A_SHAPE_2, 2)
assert(pA1 and pA1.record_track_index == 1, "T1: AUDIO A1 identity")
assert(pA2 and pA2.record_track_index == 2, "T1: AUDIO A2 identity")

-- Source has no V2 → no patch for it.
assert(not patch_for("VIDEO", V_SHAPE_1, 2), "T1: no VIDEO patch for src V2 (source has none)")
-- Source has no A3 → no patch for it.
assert(not patch_for("AUDIO", A_SHAPE_2, 3), "T1: no AUDIO patch for src A3 (source has none)")

-- ── T2: full idempotence — second call adds nothing ─────────────────────────
print("\n-- T2: second call is a no-op (all rows present)")
Patch.ensure_identity_for_source("rec_seq", "src_seq")
assert(patch_count() == 3, "T2: count unchanged on repeat call")

-- ── T3: per-channel idempotence ─────────────────────────────────────────────
-- User reroutes A2 to A3 and disables A1. New source loaded with same
-- channels triggers another seed call. The seeded rows must be left
-- alone — neither rewritten to identity, nor re-enabled.
print("\n-- T3: per-channel idempotence — existing customisations preserved")
do
    local p = patch_for("AUDIO", A_SHAPE_2, 2)
    p.record_track_index = 3
    p:save()
end
do
    local p = patch_for("AUDIO", A_SHAPE_2, 1)
    p.enabled = 0
    p:save()
end

Patch.ensure_identity_for_source("rec_seq", "src_seq")

local pA1_after = patch_for("AUDIO", A_SHAPE_2, 1)
assert(pA1_after.record_track_index == 1,
    "T3: A1 record index untouched (still identity by row, just disabled)")
assert(pA1_after.enabled == 0,
    "T3: A1 disabled state preserved across seed call")
local pA2_after = patch_for("AUDIO", A_SHAPE_2, 2)
assert(pA2_after.record_track_index == 3,
    "T3: A2 customised routing (→A3) preserved across seed call")

-- ── T4: load a source with MORE channels — only new src_idx values seeded ──
print("\n-- T4: new source channels get seeded; existing patches untouched")
db:exec(string.format([[
    INSERT INTO sequences (id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_sample_rate,
        width, height, created_at, modified_at)
    VALUES ('src2', 'proj', 'Src2', 'sequence', 24, 1, 48000, 1920, 1080, %d, %d)
]], now, now))
db:exec([[
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
    VALUES ('s2v1','src2','V1','VIDEO',1,1),
           ('s2a1','src2','A1','AUDIO',1,1),
           ('s2a2','src2','A2','AUDIO',2,1),
           ('s2a3','src2','A3','AUDIO',3,1),
           ('s2a4','src2','A4','AUDIO',4,1)
]])

Patch.ensure_identity_for_source("rec_seq", "src2")

-- A3 and A4 are new — they get identity-seeded. A1 (disabled), A2 (rerouted),
-- V1 unchanged.
local pA3 = patch_for("AUDIO", A_SHAPE_4, 3)
assert(pA3 and pA3.record_track_index == 3 and pA3.enabled == 1,
    "T4: A3 newly seeded as identity-enabled")
local pA4 = patch_for("AUDIO", A_SHAPE_4, 4)
assert(pA4 and pA4.record_track_index == 4 and pA4.enabled == 1,
    "T4: A4 newly seeded as identity-enabled")
-- A1 disabled / A2 rerouted were customised under src_seq (shape 2). Loading
-- src2 (shape 4) gets an INDEPENDENT remembered map — the shape-2 customisations
-- must survive untouched.
assert(patch_for("AUDIO", A_SHAPE_2, 1).enabled == 0, "T4: A1 disabled flag preserved at shape 2")
assert(patch_for("AUDIO", A_SHAPE_2, 2).record_track_index == 3,
    "T4: A2 custom routing preserved at shape 2")

-- ── T5: assert guards ───────────────────────────────────────────────────────
print("\n-- T5: empty args fail loudly")
assert(not pcall(Patch.ensure_identity_for_source, "", "src_seq"),
    "T5: empty rec_seq_id must assert")
assert(not pcall(Patch.ensure_identity_for_source, "rec_seq", ""),
    "T5: empty src_seq_id must assert")

print("\n✅ test_auto_patch_defaults.lua passed")
