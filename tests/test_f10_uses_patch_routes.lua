#!/usr/bin/env luajit
-- 018 INV-3 inline subframe migration applied (count=1)

-- 015 F2 regression: F9/F10 (Insert/Overwrite from keymap) must honor patch
-- routes for both VIDEO and AUDIO without the caller having to pass
-- audio_drop_mode. Patches are the SOLE routing mechanism — a clip dragged
-- from V1's src-btn onto rec V2 MUST land on V2, and a disabled patch on
-- A2 MUST drop that channel.
--
-- This test mimics the keymap invocation: no audio_drop_mode, no per-target
-- track override. The only routing information available is the patch table.

require("test_env")
local database = require("core.database")

local DB = "/tmp/jve/test_f10_uses_patch_routes.db"

local function fresh_db()
    os.remove(DB)
    assert(database.init(DB), "schema.sql init failed")
    return database.get_connection()
end

local function build_fixture()
    local db = fresh_db()
    assert(db:exec([[
        INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
        VALUES ('p1', 'p', 'passthrough', '{"master_clock_hz":192000,"default_fps":{"num":24,"den":1}}', 0, 0);
        INSERT INTO sequences (id, project_id, name, kind,
            fps_numerator, fps_denominator, audio_sample_rate, width, height,
            created_at, modified_at)
        VALUES ('m', 'p1', 'master', 'master', 24, 1, NULL, 1920, 1080, 0, 0),
               ('e', 'p1', 'edit',   'sequence', 24, 1, 48000, 1920, 1080, 0, 0);
        -- Record has V1+V2 and A1+A2+A3 so patches can route into varied
        -- target rows.
        INSERT INTO tracks (id, sequence_id, name, track_type, track_index)
        VALUES ('m-v1','m','V1','VIDEO',1),
               ('m-a1','m','A1','AUDIO',1),
               ('m-a2','m','A2','AUDIO',2),
               ('e-v1','e','V1','VIDEO',1),
               ('e-v2','e','V2','VIDEO',2),
               ('e-a1','e','A1','AUDIO',1),
               ('e-a2','e','A2','AUDIO',2),
               ('e-a3','e','A3','AUDIO',3);
        UPDATE sequences SET default_video_layer_track_id = 'm-v1' WHERE id = 'm';
        INSERT INTO media (id, project_id, name, file_path, duration_frames,
            fps_numerator, fps_denominator, audio_channels,
            created_at, modified_at)
        VALUES ('vid','p1','v.mov','/tmp/v.mov', 100,    24, 1, 0, 0, 0),
               ('a1','p1','a1.wav','/tmp/a1.wav', 200000, 48000, 1, 1, 0, 0),
               ('a2','p1','a2.wav','/tmp/a2.wav', 200000, 48000, 1, 1, 0, 0);
        INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id,
            media_id, source_in_frame, source_out_frame,
            sequence_start_frame, duration_frames,
            audio_sample_rate, enabled, volume, playhead_frame, created_at, modified_at)
        VALUES ('mr-v', 'p1','m','m-v1','vid', 0,100,    0,100, 48000,    1,1.0,0,0,0),
               ('mr-a1','p1','m','m-a1','a1',  0,200000, 0,200000, 48000, 1,1.0,0,0,0),
               ('mr-a2','p1','m','m-a2','a2',  0,200000, 0,200000, 48000, 1,1.0,0,0,0);
        -- Patches:
        --   V1 (shape 1) → V2  : user dragged V src-btn onto rec V2
        --   A1 (shape 2) → A3  : user dragged A1 src-btn onto rec A3
        --   A2 (shape 2) → A2  enabled=0  : user toggled A2 off
        -- Identity rows for V are seeded by ensure_identity; but the V1→V2
        -- override is the only V row → it must win.
        INSERT INTO patches (id, sequence_id, track_type, source_shape,
            source_track_index, record_track_index, enabled, created_at)
        VALUES ('p-v1','e','VIDEO',1,1,2,1,0),
               ('p-a1','e','AUDIO',2,1,3,1,0),
               ('p-a2','e','AUDIO',2,2,2,0,0);
    ]]))
    require("test_env").touch_media_fixtures()
    return db
end

local function clips_on_track(db, track_id, owner)
    local s = db:prepare(
        "SELECT COUNT(*) FROM clips "
        .. "WHERE track_id = ? AND owner_sequence_id = ?")
    s:bind_value(1, track_id); s:bind_value(2, owner)
    assert(s:exec()); s:next()
    local n = s:value(0); s:finalize()
    return n
end

print("=== test_f10_uses_patch_routes.lua ===")

-- ── Insert without audio_drop_mode (F9 path) ─────────────────────────────
print("-- F9 Insert: no audio_drop_mode, patches drive V + A routing --")
do
    local db = build_fixture()
    local Insert = require("core.commands.insert")
    local r = Insert.execute({
        sequence_id          = "e",
        source_sequence_id   = "m",
        sequence_start_frame = 0,
        -- NO audio_drop_mode — exactly what F9 from keymap sends.
        -- NO target_*_track_id either.
    })
    assert(r, "Insert returned nil")

    -- VIDEO: V1 (source) → V2 (record), per patch. V1 record track gets nothing.
    assert(clips_on_track(db, "e-v1", "e") == 0, string.format(
        "FAIL: rec V1 expected 0 clips (V1→V2 patch); got %d",
        clips_on_track(db, "e-v1", "e")))
    assert(clips_on_track(db, "e-v2", "e") == 1, string.format(
        "FAIL: rec V2 expected 1 clip (V1→V2 patch); got %d",
        clips_on_track(db, "e-v2", "e")))

    -- AUDIO: A1→A3 enabled, A2→A2 disabled. So rec A3 gets one, rec A1 and A2 get zero.
    assert(clips_on_track(db, "e-a1", "e") == 0, string.format(
        "FAIL: rec A1 expected 0 (no patch routes here); got %d",
        clips_on_track(db, "e-a1", "e")))
    assert(clips_on_track(db, "e-a2", "e") == 0, string.format(
        "FAIL: rec A2 expected 0 (A2 disabled); got %d",
        clips_on_track(db, "e-a2", "e")))
    assert(clips_on_track(db, "e-a3", "e") == 1, string.format(
        "FAIL: rec A3 expected 1 (A1→A3 enabled); got %d",
        clips_on_track(db, "e-a3", "e")))
    print("  V1→V2, A1→A3, A2 dropped — OK")
end

-- ── Overwrite onto a populated rec track (production scenario) ──────────
-- The real-world bug: rec sequence already has clips on the patch-routed
-- tracks. F10 must occlude (Overwrite) — not refuse — and the new clip
-- lands where the patch says.
print("-- F10 Overwrite: routed rec track already populated → occlude --")
do
    local db = build_fixture()
    -- Seed a blocker on rec V2 (the routed VIDEO target) and on rec A3
    -- (the A1-routed AUDIO target). Both fully contained in the placement
    -- window [0, 100) so Overwrite's occlude path should DELETE them.
    assert(db:exec([[
        INSERT INTO clips (id, project_id, owner_sequence_id, track_id,
            sequence_id, name,
            sequence_start_frame, duration_frames,
            source_in_frame, source_out_frame,
            source_in_subframe, source_out_subframe,
            master_layer_track_id, master_audio_track_id, fps_mismatch_policy,
            enabled, volume, playhead_frame, created_at, modified_at)
        VALUES
          ('blk-v', 'p1','e','e-v2','m','blk-v',  0, 50,  0, 50, NULL, NULL,  NULL, NULL, 'passthrough', 1, 1.0, 0, 0, 0),
          ('blk-a', 'p1','e','e-a3','m','blk-a',  0, 50,  0, 50,  0,    0,    NULL, NULL, 'passthrough', 1, 1.0, 0, 0, 0);
    ]]))
    local Overwrite = require("core.commands.overwrite")
    local r = Overwrite.execute({
        sequence_id          = "e",
        source_sequence_id   = "m",
        sequence_start_frame = 0,
        -- F10 keymap passes no audio_drop_mode.
    })
    assert(r, "Overwrite returned nil — refused when it should occlude")

    -- New clip lands on routed V2; blocker is gone.
    assert(clips_on_track(db, "e-v2", "e") == 1, string.format(
        "rec V2 expected exactly 1 clip after Overwrite (blocker occluded, new clip placed); got %d",
        clips_on_track(db, "e-v2", "e")))
    -- New clip lands on routed A3; blocker is gone.
    assert(clips_on_track(db, "e-a3", "e") == 1, string.format(
        "rec A3 expected exactly 1 clip after Overwrite (blocker occluded, new clip placed); got %d",
        clips_on_track(db, "e-a3", "e")))
    print("  blockers occluded, routed clips placed — OK")
end

print("\n✅ test_f10_uses_patch_routes.lua passed")
