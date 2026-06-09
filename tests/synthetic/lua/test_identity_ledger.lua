-- test_identity_ledger.lua — `core.resolve_bridge.identity_ledger` contract.
--
-- Per data-model.md "Entity: resolve_bridge_link":
--   • One row per clip; PK jve_clip_uuid; FK clips ON DELETE CASCADE.
--   • For imported clips, `resolve_item_id == clip.id` (FR-011b). For
--     UUID-minted clips, the value is matched positionally at connect
--     time (FR-011c).
--   • grade_fingerprint / edit_fingerprint NULL until first sync.
--   • Cascade-delete (FR-013a). No standalone delete.
--   • Fingerprint changes detect Resolve-side change (grade) and
--     conflict between Resolve-side and JVE-side change (edit, FR-025).
--
-- Reconcile is NOT exercised here — T035 covers blade/split reconcile
-- once T036 lands the algorithm. This test only pins the read/write +
-- cascade + fingerprint-change contract.

require("test_env")

local database = require("core.database")
local ledger = require("core.resolve_bridge.identity_ledger")
local ClipGrade = require("models.clip_grade")

local pass = 0
local fail = 0
local function check(label, cond)
    if cond then pass = pass + 1
    else fail = fail + 1; print("FAIL: " .. label) end
end

print("\n=== Identity Ledger Tests ===")

local db_path = "/tmp/jve/test_identity_ledger.db"
os.remove(db_path)
os.execute("mkdir -p /tmp/jve")
assert(database.init(db_path))
local db = database.get_connection()
db:exec(require("import_schema"))

local now = os.time()
-- Two clips: one imported (clip.id == Sm2Ti DbId, no UUID shape), one
-- JVE-minted (UUIDv4 shape). Both go into the ledger; only the second
-- carries a distinct resolve_item_id.
db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
    VALUES ('p', 'P', 'resample',
        '{"master_clock_hz":705600000,"default_fps":{"num":24,"den":1}}', %d, %d);
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator,
        audio_sample_rate, width, height, view_start_frame, view_duration_frames,
        playhead_frame, selected_clip_ids, selected_edge_infos, created_at, modified_at)
    VALUES ('s', 'p', 'S', 'sequence', 24000, 1001, 48000, 1920, 1080, 0, 240, 0,
        '[]', '[]', %d, %d);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index,
        enabled, locked, muted, soloed, volume, pan)
    VALUES ('t', 's', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
    INSERT INTO clips (id, project_id, name, track_id, owner_sequence_id, sequence_id,
        sequence_start_frame, duration_frames, source_in_frame, source_out_frame,
        source_in_subframe, source_out_subframe, enabled, created_at, modified_at,
        master_layer_track_id, master_audio_track_id, fps_mismatch_policy, volume,
        playhead_frame)
    VALUES ('resolve-dbid-imported', 'p', 'A', 't', 's', 's', 0, 96, 0, 96,
        NULL, NULL, 1, %d, %d, NULL, NULL, 'resample', 1.0, 0);
    INSERT INTO clips (id, project_id, name, track_id, owner_sequence_id, sequence_id,
        sequence_start_frame, duration_frames, source_in_frame, source_out_frame,
        source_in_subframe, source_out_subframe, enabled, created_at, modified_at,
        master_layer_track_id, master_audio_track_id, fps_mismatch_policy, volume,
        playhead_frame)
    VALUES ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'p', 'B', 't', 's', 's',
        96, 96, 0, 96, NULL, NULL, 1, %d, %d, NULL, NULL, 'resample', 1.0, 0);
]], now, now, now, now, now, now, now, now))

-- ─── upsert + load: imported clip (resolve_item_id == clip.id) ───────
ledger.upsert("resolve-dbid-imported", {
    resolve_item_id = "resolve-dbid-imported",
}, db)
local r1 = ledger.load("resolve-dbid-imported", db)
check("imported clip: link loaded",
    r1 ~= nil)
check("imported clip: resolve_item_id == clip.id (FR-011b)",
    r1 and r1.resolve_item_id == "resolve-dbid-imported")
check("imported clip: grade_fingerprint NULL until first sync",
    r1 and r1.grade_fingerprint == nil)
check("imported clip: edit_fingerprint NULL until first sync",
    r1 and r1.edit_fingerprint == nil)

-- ─── upsert + load: UUID clip (positional match → distinct id) ───────
ledger.upsert("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", {
    resolve_item_id = "resolve-side-1234",  -- matched positionally per FR-011c
}, db)
local r2 = ledger.load("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", db)
check("UUID clip: link loaded",
    r2 ~= nil)
check("UUID clip: resolve_item_id is the matched id (not clip.id)",
    r2 and r2.resolve_item_id == "resolve-side-1234")

-- ─── grade_fingerprint changes when the grade changes ────────────────
-- The fingerprint must be stable for the same CDL and different for
-- different CDLs — that's the change-detection contract. Use the
-- public ClipGrade.fingerprint helper so this test pins the contract,
-- not a private hashing implementation.
local CDL_A = {
    slope_r = 1.05, slope_g = 0.98, slope_b = 0.92,
    offset_r = 0.01, offset_g = 0.0, offset_b = -0.02,
    power_r  = 1.1,  power_g  = 1.0, power_b  = 0.95,
    saturation = 0.85,
}
local CDL_B = {}
for k, v in pairs(CDL_A) do CDL_B[k] = v end
CDL_B.saturation = 0.5  -- single channel changed

local fp_a1 = ClipGrade.fingerprint({ cdl = CDL_A, fidelity = "primary" })
local fp_a2 = ClipGrade.fingerprint({ cdl = CDL_A, fidelity = "primary" })
local fp_b  = ClipGrade.fingerprint({ cdl = CDL_B, fidelity = "primary" })
check("fingerprint stable for identical grade", fp_a1 == fp_a2)
check("fingerprint differs when saturation changes",  fp_a1 ~= fp_b)

ledger.upsert("resolve-dbid-imported", {
    resolve_item_id = "resolve-dbid-imported",
    grade_fingerprint = fp_a1,
}, db)
local r3 = ledger.load("resolve-dbid-imported", db)
check("grade_fingerprint stored",
    r3 and r3.grade_fingerprint == fp_a1)

ledger.upsert("resolve-dbid-imported", {
    resolve_item_id = "resolve-dbid-imported",
    grade_fingerprint = fp_b,
}, db)
local r4 = ledger.load("resolve-dbid-imported", db)
check("grade_fingerprint updated on grade change",
    r4 and r4.grade_fingerprint == fp_b)

-- ─── delete clip cascades the link row (FR-013a) ─────────────────────
db:exec("DELETE FROM clips WHERE id = 'resolve-dbid-imported';")
check("link gone after clip delete (cascade)",
    ledger.load("resolve-dbid-imported", db) == nil)
check("sibling link unaffected",
    ledger.load("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", db) ~= nil)

print(string.format("\n=== %d passed / %d failed ===", pass, fail))
assert(fail == 0, "test_identity_ledger.lua: failures present")
print("✅ test_identity_ledger.lua passed")
