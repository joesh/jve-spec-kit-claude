#!/usr/bin/env luajit

-- 015 F2 — Shape-keyed patch routing (acceptance §2a, §2b, §2b-i, §2c).
--
-- Domain behavior under test (described independent of implementation):
--
--   * A record sequence remembers a SEPARATE patch map per source SHAPE.
--     Shape = count of source tracks of the relevant track_type.
--     A 4-ch source and a 2-ch source loaded against the same record
--     sequence have INDEPENDENT remembered maps; mutating one does not
--     mutate the other.
--
--   * src-btn visibility on the timeline is "one per source track at
--     the current shape, placed at its routed rec_track_index". With
--     no source loaded, ZERO src-btns render — regardless of how many
--     `patches` rows exist for the record sequence.
--
--   * Restore-defaults clears EVERY shape's rows for the record sequence;
--     a subsequent source load reseeds identity for the loaded shape.
--
-- These tests are black-box at the Patch-model + render-projection level.
-- They derive expected values from the spec's acceptance scenarios, not
-- from the implementation (CLAUDE.md "test domain behavior, not impl").

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require("test_env")

local database = require("core.database")
local Patch    = require("models.patch")

_G.qt_create_single_shot_timer = function(_d, cb) cb(); return nil end

print("=== test_patch_shape_keyed_routing.lua ===")

local DB = "/tmp/jve/test_patch_shape_keyed_routing.db"
os.remove(DB); os.execute("mkdir -p /tmp/jve")
database.init(DB)
local db = database.get_connection()
db:exec(require("import_schema"))

local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at)
    VALUES ('proj', 'P', 'resample', %d, %d)
]], now, now))

-- Record sequence R1 — 4 audio tracks so any test routing fits.
db:exec(string.format([[
    INSERT INTO sequences (id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_sample_rate,
        width, height, created_at, modified_at)
    VALUES ('R1', 'proj', 'R1', 'sequence', 24, 1, 48000, 1920, 1080, %d, %d)
]], now, now))
db:exec([[
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
    VALUES ('r1_a1','R1','A1','AUDIO',1,1),
           ('r1_a2','R1','A2','AUDIO',2,1),
           ('r1_a3','R1','A3','AUDIO',3,1),
           ('r1_a4','R1','A4','AUDIO',4,1)
]])

-- Record sequence R2 — independence test.
db:exec(string.format([[
    INSERT INTO sequences (id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_sample_rate,
        width, height, created_at, modified_at)
    VALUES ('R2', 'proj', 'R2', 'sequence', 24, 1, 48000, 1920, 1080, %d, %d)
]], now, now))
db:exec([[
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
    VALUES ('r2_a1','R2','A1','AUDIO',1,1),
           ('r2_a2','R2','A2','AUDIO',2,1)
]])

-- Two source clips of different shapes.
-- src_4ch: A1..A4 (shape = 4)
-- src_2ch: A1..A2 (shape = 2)
db:exec(string.format([[
    INSERT INTO sequences (id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_sample_rate,
        width, height, created_at, modified_at)
    VALUES ('src_4ch', 'proj', 'src4', 'master', 24, 1, NULL, 1920, 1080, %d, %d),
           ('src_2ch', 'proj', 'src2', 'master', 24, 1, NULL, 1920, 1080, %d, %d),
           ('src_4ch_alt','proj','src4b','master', 24, 1, NULL, 1920, 1080, %d, %d)
]], now, now, now, now, now, now))
db:exec([[
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
    VALUES ('s4_a1','src_4ch','A1','AUDIO',1,1),
           ('s4_a2','src_4ch','A2','AUDIO',2,1),
           ('s4_a3','src_4ch','A3','AUDIO',3,1),
           ('s4_a4','src_4ch','A4','AUDIO',4,1),
           ('s2_a1','src_2ch','A1','AUDIO',1,1),
           ('s2_a2','src_2ch','A2','AUDIO',2,1),
           ('s4b_a1','src_4ch_alt','A1','AUDIO',1,1),
           ('s4b_a2','src_4ch_alt','A2','AUDIO',2,1),
           ('s4b_a3','src_4ch_alt','A3','AUDIO',3,1),
           ('s4b_a4','src_4ch_alt','A4','AUDIO',4,1)
]])

-- Helper: count patches keyed by (rec_seq, shape).
local function patch_count(rec_seq, shape)
    local s = db:prepare(
        "SELECT COUNT(*) FROM patches WHERE sequence_id=? AND source_shape=?")
    s:bind_value(1, rec_seq); s:bind_value(2, shape)
    s:exec(); s:next(); local n = s:value(0); s:finalize(); return n
end

-- ============================================================================
-- §2a — Same-shape stickiness across source swaps.
-- ============================================================================
do
    print("\n-- §2a: Same-shape stickiness")

    -- Seed identity for 4-ch shape on R1.
    Patch.ensure_identity_for_source("R1", "src_4ch")
    assert(patch_count("R1", 4) == 4,
        "§2a precondition: 4 identity rows seeded at shape=4")

    -- User customisation: A1→A3, disable A4.
    local pA1 = Patch.find_by_source("R1", "AUDIO", 4, 1)
    assert(pA1, "§2a: A1 patch row exists at shape=4")
    pA1.record_track_index = 3; pA1:save()
    local pA4 = Patch.find_by_source("R1", "AUDIO", 4, 4)
    pA4.enabled = 0; pA4:save()

    -- Load a DIFFERENT 4-ch source. Ensure does NOT clobber customisations.
    Patch.ensure_identity_for_source("R1", "src_4ch_alt")
    assert(patch_count("R1", 4) == 4,
        "§2a: still 4 rows at shape=4 after swapping to same-shape source")

    local pA1_after = Patch.find_by_source("R1", "AUDIO", 4, 1)
    assert(pA1_after.record_track_index == 3,
        "§2a: A1→A3 routing PRESERVED across same-shape source swap")
    local pA4_after = Patch.find_by_source("R1", "AUDIO", 4, 4)
    assert(pA4_after.enabled == 0,
        "§2a: A4 disabled state PRESERVED across same-shape source swap")
    print("  ✓ same-shape source swap preserves user-customised routing")
end

-- ============================================================================
-- §2b — Per-shape independence: 4-ch and 2-ch maps are separate rows.
-- ============================================================================
do
    print("\n-- §2b: Per-shape independence")

    -- Load 2-ch source against R1 with R1's 4-ch map already customised.
    Patch.ensure_identity_for_source("R1", "src_2ch")
    assert(patch_count("R1", 2) == 2,
        "§2b: 2-ch source seeds exactly 2 rows at shape=2")
    assert(patch_count("R1", 4) == 4,
        "§2b: 4-ch rows untouched (still 4) after seeding 2-ch")

    -- 2-ch rows are identity by default.
    local p2_a1 = Patch.find_by_source("R1", "AUDIO", 2, 1)
    local p2_a2 = Patch.find_by_source("R1", "AUDIO", 2, 2)
    assert(p2_a1 and p2_a1.record_track_index == 1,
        "§2b: 2-ch A1 identity by default")
    assert(p2_a2 and p2_a2.record_track_index == 2,
        "§2b: 2-ch A2 identity by default")

    -- Customise the 2-ch map only.
    p2_a2.record_track_index = 4; p2_a2:save()

    -- Lookups at shape=4 still reflect 4-ch customisation; shape=2 reflects new.
    local p4_a1 = Patch.find_by_source("R1", "AUDIO", 4, 1)
    assert(p4_a1.record_track_index == 3,
        "§2b: 4-ch A1→A3 UNCHANGED by 2-ch mutation")
    local p2_a2_after = Patch.find_by_source("R1", "AUDIO", 2, 2)
    assert(p2_a2_after.record_track_index == 4,
        "§2b: 2-ch A2→A4 stored independently")
    print("  ✓ 4-ch and 2-ch maps are independent rows; neither mutates the other")
end

-- ============================================================================
-- §2b-i — No source loaded ⇒ zero src-btns visible (render projection empty).
-- ============================================================================
do
    print("\n-- §2b-i: No source loaded ⇒ zero src-btns")

    -- R1 has many patch rows from previous tests. Render projection with
    -- NO source must produce an empty list regardless.
    local rows = Patch.source_routing_for_rec("R1", nil)
    assert(type(rows) == "table",
        "§2b-i: source_routing_for_rec must always return a table")
    assert(#rows == 0,
        "§2b-i: no source ⇒ zero render entries, got " .. tostring(#rows))
    print("  ✓ no source ⇒ render projection is empty")

    -- Sanity: with the 2-ch source, projection has exactly 2 entries.
    local rows2 = Patch.source_routing_for_rec("R1", "src_2ch")
    assert(#rows2 == 2,
        "§2b-i sanity: 2-ch source ⇒ 2 entries, got " .. tostring(#rows2))
    -- A1→A1, A2→A4 (customised above).
    local by_src = {}
    for _, r in ipairs(rows2) do by_src[r.source_track_index] = r end
    assert(by_src[1] and by_src[1].record_track_index == 1,
        "§2b-i: src A1 maps to rec A1 (identity)")
    assert(by_src[2] and by_src[2].record_track_index == 4,
        "§2b-i: src A2 maps to rec A4 (customised)")
    print("  ✓ render projection iterates source tracks and applies shape's map")

    -- And with the 4-ch source, projection has exactly 4 entries reflecting
    -- the 4-ch map.
    local rows4 = Patch.source_routing_for_rec("R1", "src_4ch")
    assert(#rows4 == 4,
        "§2b-i sanity: 4-ch source ⇒ 4 entries, got " .. tostring(#rows4))
end

-- ============================================================================
-- §2c — Restore Default Patch deletes all rows across every shape.
-- ============================================================================
do
    print("\n-- §2c: Restore Default Patch (full reset)")

    -- R1 has both 4-ch and 2-ch rows from above.
    assert(patch_count("R1", 4) > 0 and patch_count("R1", 2) > 0,
        "§2c precondition: R1 has rows at both shapes")

    -- Independence with R2: seed something on R2 first.
    Patch.ensure_identity_for_source("R2", "src_2ch")
    assert(patch_count("R2", 2) == 2,
        "§2c precondition: R2 seeded at 2-ch shape")

    Patch.restore_defaults_for_sequence("R1")

    assert(patch_count("R1", 4) == 0,
        "§2c: R1 4-ch rows deleted")
    assert(patch_count("R1", 2) == 0,
        "§2c: R1 2-ch rows deleted")
    assert(patch_count("R2", 2) == 2,
        "§2c: R2 rows untouched")

    -- Reseed: source load after reset gives identity for that shape.
    Patch.ensure_identity_for_source("R1", "src_4ch")
    assert(patch_count("R1", 4) == 4,
        "§2c: re-seed restores 4 identity rows at shape=4 after reset")
    local p = Patch.find_by_source("R1", "AUDIO", 4, 1)
    assert(p and p.record_track_index == 1 and p.enabled == 1,
        "§2c: post-reset rows are identity-and-enabled")
    print("  ✓ Restore Default deletes all shapes for R1; reseed produces identity")
end

-- ============================================================================
-- DB-level: shape=0 is rejected (no row exists for "no source").
-- ============================================================================
do
    print("\n-- shape=0 rejected at DB level (CHECK constraint)")
    -- Use raw DB insert to confirm — the model-layer API would also assert
    -- before reaching the DB.
    local ok = pcall(function()
        local s = db:prepare([[
            INSERT INTO patches
                (id, sequence_id, track_type, source_shape, source_track_index,
                 record_track_index, enabled, created_at)
            VALUES ('bad', 'R1', 'AUDIO', 0, 1, 1, 1, 0)
        ]])
        assert(s:exec(), "insert failed")
        s:finalize()
    end)
    assert(not ok, "shape=0 must be rejected by CHECK(source_shape > 0)")
    print("  ✓ shape=0 inserts are rejected at the DB layer")
end

print("\n✅ test_patch_shape_keyed_routing.lua passed")
