#!/usr/bin/env luajit

-- 015 F2: edit-time patch routing — patches are the SOLE routing mechanism.
--
-- Domain rules:
--   - A source channel participates in an edit iff a patch row exists with
--     enabled=1. Routing target = patch.record_track_index.
--   - patch.enabled=0 drops the source channel.
--   - Identity patches are auto-seeded at Insert/Overwrite time
--     (Patch.ensure_identity_for_source) — pre-patch identity behavior
--     survives without explicit setup.
--   - autoselect is unrelated to patching (gates selection-driven ops only).
--
-- Fixture: master m has V1 + A1..A3 (each its own media_ref).
--          edit e has V1 + A1..A3.
--   Pre-existing patches on edit:
--     A2: A2→A3 enabled  → routes to rec A3 (custom).
--     A3: A3→A3 enabled=0 → dropped.
--   A1 gets identity-seeded automatically → rec A1.
-- Expected after expanded Insert: rec_a1 gets A1, rec_a3 gets A2, no A3.

require("test_env")
local database = require("core.database")

local DB = "/tmp/jve/test_patch_routing_edit_time.db"

local function fresh_db()
    os.remove(DB)
    assert(database.init(DB), "schema.sql init failed")
    return database.get_connection()
end

local function build_fixture()
    local db = fresh_db()
    assert(db:exec([[
        INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at)
        VALUES ('p1', 'p', 'passthrough', 0, 0);
        INSERT INTO sequences (id, project_id, name, kind,
            fps_numerator, fps_denominator, audio_sample_rate, width, height,
            created_at, modified_at)
        VALUES ('m', 'p1', 'master', 'master', 24, 1, 48000, 1920, 1080, 0, 0),
               ('e', 'p1', 'edit',   'sequence', 24, 1, 48000, 1920, 1080, 0, 0);
        INSERT INTO tracks (id, sequence_id, name, track_type, track_index)
        VALUES ('m-v1','m','V1','VIDEO',1),
               ('m-a1','m','A1','AUDIO',1),
               ('m-a2','m','A2','AUDIO',2),
               ('m-a3','m','A3','AUDIO',3),
               ('e-v1','e','V1','VIDEO',1),
               ('e-a1','e','A1','AUDIO',1),
               ('e-a2','e','A2','AUDIO',2),
               ('e-a3','e','A3','AUDIO',3);
        UPDATE sequences SET default_video_layer_track_id = 'm-v1' WHERE id = 'm';
        INSERT INTO media (id, project_id, name, file_path, duration_frames,
            fps_numerator, fps_denominator, audio_channels,
            created_at, modified_at)
        VALUES ('vid','p1','v.mov','/tmp/v.mov', 100,    24, 1, 0, 0, 0),
               ('a1','p1','a1.wav','/tmp/a1.wav', 200000, 48000, 1, 1, 0, 0),
               ('a2','p1','a2.wav','/tmp/a2.wav', 200000, 48000, 1, 1, 0, 0),
               ('a3','p1','a3.wav','/tmp/a3.wav', 200000, 48000, 1, 1, 0, 0);
        INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id,
            media_id, source_in_frame, source_out_frame,
            timeline_start_frame, duration_frames,
            enabled, volume, playhead_frame, created_at, modified_at)
        VALUES ('mr-v', 'p1','m','m-v1','vid', 0,100,    0,100,    1,1.0,0,0,0),
               ('mr-a1','p1','m','m-a1','a1',  0,200000, 0,200000, 1,1.0,0,0,0),
               ('mr-a2','p1','m','m-a2','a2',  0,200000, 0,200000, 1,1.0,0,0,0),
               ('mr-a3','p1','m','m-a3','a3',  0,200000, 0,200000, 1,1.0,0,0,0);
        -- Seed pre-existing patches for A2 and A3. Identity for A1 will be
        -- seeded automatically at the top of Insert.execute via
        -- Patch.ensure_identity_for_source.
        -- Source has 3 audio tracks → source_shape = 3 for AUDIO routing.
        INSERT INTO patches (id, sequence_id, track_type, source_shape,
            source_track_index, record_track_index, enabled, created_at)
        VALUES ('p-a2','e','AUDIO',3,2,3,1,0),  -- A2 routes to A3 (custom)
               ('p-a3','e','AUDIO',3,3,3,0,0);  -- A3 disabled → dropped
    ]]))
    require("test_env").touch_media_fixtures()
    return db
end

local function audio_clips_by_rec_track(db, owner)
    local stmt = db:prepare([[
        SELECT t.track_index, COUNT(c.id)
        FROM tracks t LEFT JOIN clips c
          ON c.track_id = t.id AND c.owner_sequence_id = ?
        WHERE t.sequence_id = ? AND t.track_type = 'AUDIO'
        GROUP BY t.track_index
        ORDER BY t.track_index
    ]])
    stmt:bind_value(1, owner); stmt:bind_value(2, owner)
    assert(stmt:exec())
    local counts = {}
    while stmt:next() do counts[stmt:value(0)] = stmt:value(1) end
    stmt:finalize()
    return counts
end

local Insert = require("core.commands.insert")

print("=== test_patch_routing_edit_time.lua ===")

print("-- seeded identity + custom routing + disabled drop --")
do
    local db = build_fixture()
    local r = Insert.execute({
        sequence_id          = "e",
        source_sequence_id   = "m",
        timeline_start_frame = 0,
        audio_drop_mode      = "expanded",
    })
    assert(r, "Insert returned nil")
    local c = audio_clips_by_rec_track(db, "e")
    print(string.format("  rec a1=%d a2=%d a3=%d",
        c[1] or 0, c[2] or 0, c[3] or 0))
    assert(c[1] == 1, string.format(
        "FAIL: A1 identity-seeded by Insert → rec_a1 expected 1; got %d",
        c[1] or 0))
    assert((c[2] or 0) == 0, string.format(
        "FAIL: rec_a2 has no source routed to it; expected 0, got %d",
        c[2] or 0))
    assert(c[3] == 1, string.format(
        "FAIL: A2→A3 enabled patch must place 1 clip on rec_a3; got %d",
        c[3] or 0))
    print("  ok")
end

print("✅ test_patch_routing_edit_time.lua passed")
