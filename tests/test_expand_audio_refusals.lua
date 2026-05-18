-- 018 INV-3 inline subframe migration applied (count=4)
-- T056b / CT-C20b (013): ExpandAudio refusal cases.
--
-- Per FR-023 + commands.md §ExpandAudio: refusals are loud (rule 1.14)
-- and leave NO partial DB state (rule 2.32):
--
--   * 1-audio-track master ("nothing to expand").
--   * Already-expanded clip (master_audio_track_id is non-NULL).
--   * Collision: an existing clip on any of A2..AN in the source's
--     time range — error names the offending clip id.
--   * sequence_id mismatch with clip.owner_sequence_id (rule 2.29).
--   * Clip is on a VIDEO track (only audio clips can be expanded).

require("test_env")
local database = require("core.database")

local DB_PATH = "/tmp/jve/test_expand_audio_refusals.db"

local function fresh_db()
    os.remove(DB_PATH)
    assert(database.init(DB_PATH), "schema.sql init failed")
    return database.get_connection()
end

local function multi_track_fixture()
    local db = fresh_db()
    assert(db:exec([[
        INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at)
        VALUES ('p1', 'p', 'passthrough', 0, 0);
        INSERT INTO sequences (id, project_id, name, kind,
            fps_numerator, fps_denominator, audio_sample_rate, width, height,
            created_at, modified_at)
        VALUES ('m', 'p1', 'master', 'master', 24, 1, NULL, 1920, 1080, 0, 0);
        INSERT INTO sequences (id, project_id, name, kind,
            fps_numerator, fps_denominator, audio_sample_rate, width, height,
            created_at, modified_at)
        VALUES ('e', 'p1', 'edit', 'sequence', 24, 1, 48000, 1920, 1080, 0, 0);
        INSERT INTO tracks (id, sequence_id, name, track_type, track_index)
        VALUES ('m-v1', 'm', 'V1', 'VIDEO', 1),
               ('m-a1', 'm', 'A1', 'AUDIO', 1),
               ('m-a2', 'm', 'A2', 'AUDIO', 2),
               ('e-v1', 'e', 'V1', 'VIDEO', 1),
               ('e-a1', 'e', 'A1', 'AUDIO', 1);
        UPDATE sequences SET default_video_layer_track_id = 'm-v1' WHERE id = 'm';
        INSERT INTO media (id, project_id, name, file_path, duration_frames,
            fps_numerator, fps_denominator, audio_channels,
            created_at, modified_at)
        VALUES ('vid', 'p1', 'v.mov', '/tmp/v.mov', 100, 24, 1, 0, 0, 0),
               ('a1', 'p1', 'a1.wav', '/tmp/a1.wav', 200000, 48000, 1, 1, 0, 0),
               ('a2', 'p1', 'a2.wav', '/tmp/a2.wav', 200000, 48000, 1, 1, 0, 0);
        INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id,
            media_id, source_in_frame, source_out_frame,
            sequence_start_frame, duration_frames,
            enabled, volume, playhead_frame, created_at, modified_at)
        VALUES ('mr-v',  'p1', 'm', 'm-v1', 'vid', 0, 100,    0, 100,    1, 1.0, 0, 0, 0),
               ('mr-a1', 'p1', 'm', 'm-a1', 'a1',  0, 200000, 0, 200000, 1, 1.0, 0, 0, 0),
               ('mr-a2', 'p1', 'm', 'm-a2', 'a2',  0, 200000, 0, 200000, 1, 1.0, 0, 0, 0);
        INSERT INTO clips (id, project_id, owner_sequence_id, track_id,
            sequence_id, name,
            sequence_start_frame, duration_frames,
            source_in_frame, source_out_frame,
            source_in_subframe, source_out_subframe,
            master_layer_track_id, master_audio_track_id, fps_mismatch_policy,
            enabled, volume, playhead_frame, created_at, modified_at)
        VALUES ('ca', 'p1', 'e', 'e-a1', 'm', 'ca',
                0, 100, 0, 200000, 0, 0, NULL, NULL, 'passthrough',
                1, 1.0, 0, 0, 0);
    ]]))
    require("test_env").touch_media_fixtures()
    return db
end

local function single_track_fixture()
    local db = fresh_db()
    assert(db:exec([[
        INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at)
        VALUES ('p1', 'p', 'passthrough', 0, 0);
        INSERT INTO sequences (id, project_id, name, kind,
            fps_numerator, fps_denominator, audio_sample_rate, width, height,
            created_at, modified_at)
        VALUES ('m', 'p1', 'master', 'master', 24, 1, NULL, 1920, 1080, 0, 0);
        INSERT INTO sequences (id, project_id, name, kind,
            fps_numerator, fps_denominator, audio_sample_rate, width, height,
            created_at, modified_at)
        VALUES ('e', 'p1', 'edit', 'sequence', 24, 1, 48000, 1920, 1080, 0, 0);
        INSERT INTO tracks (id, sequence_id, name, track_type, track_index)
        VALUES ('m-v1', 'm', 'V1', 'VIDEO', 1),
               ('m-a1', 'm', 'A1', 'AUDIO', 1),
               ('e-v1', 'e', 'V1', 'VIDEO', 1),
               ('e-a1', 'e', 'A1', 'AUDIO', 1);
        UPDATE sequences SET default_video_layer_track_id = 'm-v1' WHERE id = 'm';
        INSERT INTO media (id, project_id, name, file_path, duration_frames,
            fps_numerator, fps_denominator, audio_channels,
            created_at, modified_at)
        VALUES ('vid', 'p1', 'v.mov', '/tmp/v.mov', 100, 24, 1, 0, 0, 0),
               ('a1', 'p1', 'a1.wav', '/tmp/a1.wav', 200000, 48000, 1, 1, 0, 0);
        INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id,
            media_id, source_in_frame, source_out_frame,
            sequence_start_frame, duration_frames,
            enabled, volume, playhead_frame, created_at, modified_at)
        VALUES ('mr-v',  'p1', 'm', 'm-v1', 'vid', 0, 100,    0, 100,    1, 1.0, 0, 0, 0),
               ('mr-a1', 'p1', 'm', 'm-a1', 'a1',  0, 200000, 0, 200000, 1, 1.0, 0, 0, 0);
        INSERT INTO clips (id, project_id, owner_sequence_id, track_id,
            sequence_id, name,
            sequence_start_frame, duration_frames,
            source_in_frame, source_out_frame,
            source_in_subframe, source_out_subframe,
            master_layer_track_id, master_audio_track_id, fps_mismatch_policy,
            enabled, volume, playhead_frame, created_at, modified_at)
        VALUES ('ca', 'p1', 'e', 'e-a1', 'm', 'ca',
                0, 100, 0, 200000, 0, 0, NULL, NULL, 'passthrough',
                1, 1.0, 0, 0, 0);
    ]]))
    require("test_env").touch_media_fixtures()
    return db
end

local function clip_count(db, owner)
    local stmt = db:prepare(
        "SELECT COUNT(*) FROM clips WHERE owner_sequence_id = ?")
    stmt:bind_value(1, owner)
    assert(stmt:exec() and stmt:next())
    local n = stmt:value(0)
    stmt:finalize()
    return n
end

local ExpandAudio = require("core.commands.expand_audio")

print("-- 1-audio-track master: refused (nothing to expand) --")
do
    local db = single_track_fixture()
    local pre = clip_count(db, "e")
    local ok, err = pcall(ExpandAudio.execute, {
        sequence_id = "e", clip_id = "ca",
    })
    assert(not ok)
    assert(tostring(err):find("expand")
        or tostring(err):find("track")
        or tostring(err):find("nothing"),
        "error explains the no-op; got: " .. tostring(err))
    assert(clip_count(db, "e") == pre, "no DB mutation on refusal")
    print("  ok")
end

print("-- already-expanded clip (master_audio_track_id non-NULL): refused --")
do
    local db = multi_track_fixture()
    -- Pre-mark ca as expanded to A1.
    assert(db:exec("UPDATE clips SET master_audio_track_id='m-a1' WHERE id='ca'"))
    local pre = clip_count(db, "e")
    local ok, err = pcall(ExpandAudio.execute, {
        sequence_id = "e", clip_id = "ca",
    })
    assert(not ok)
    assert(tostring(err):find("expand")
        or tostring(err):find("already"),
        "error explains; got: " .. tostring(err))
    assert(clip_count(db, "e") == pre, "no DB mutation on refusal")
    print("  ok")
end

print("-- collision on auto-create target: refused, named offender --")
do
    local db = multi_track_fixture()
    -- Pre-create A2 on edit and put a blocker clip there overlapping ca.
    assert(db:exec([[
        INSERT INTO tracks (id, sequence_id, name, track_type, track_index)
        VALUES ('e-a2', 'e', 'A2', 'AUDIO', 2);
        INSERT INTO clips (id, project_id, owner_sequence_id, track_id,
            sequence_id, name,
            sequence_start_frame, duration_frames,
            source_in_frame, source_out_frame,
            source_in_subframe, source_out_subframe,
            master_layer_track_id, master_audio_track_id, fps_mismatch_policy,
            enabled, volume, playhead_frame, created_at, modified_at)
        VALUES ('blocker', 'p1', 'e', 'e-a2', 'm', 'blocker',
                50, 100, 0, 200000, 0, 0, NULL, NULL, 'passthrough',
                1, 1.0, 0, 0, 0);
    ]]))
    local pre = clip_count(db, "e")
    local ok, err = pcall(ExpandAudio.execute, {
        sequence_id = "e", clip_id = "ca",
    })
    assert(not ok)
    assert(tostring(err):find("blocker")
        or tostring(err):find("collision")
        or tostring(err):find("overlap"),
        "error names the collision; got: " .. tostring(err))
    assert(clip_count(db, "e") == pre, "no DB mutation on refusal")
    print("  ok")
end

print("-- sequence_id mismatch (rule 2.29): refused --")
do
    local db = multi_track_fixture()
    local pre = clip_count(db, "e")
    local ok = pcall(ExpandAudio.execute, {
        sequence_id = "m", clip_id = "ca",
    })
    assert(not ok)
    assert(clip_count(db, "e") == pre)
    print("  ok")
end

print("-- video clip: refused --")
do
    local db = multi_track_fixture()
    -- Add a V clip on edit.
    assert(db:exec([[
        INSERT INTO clips (id, project_id, owner_sequence_id, track_id,
            sequence_id, name,
            sequence_start_frame, duration_frames,
            source_in_frame, source_out_frame,
            source_in_subframe, source_out_subframe,
            master_layer_track_id, master_audio_track_id, fps_mismatch_policy,
            enabled, volume, playhead_frame, created_at, modified_at)
        VALUES ('cv', 'p1', 'e', 'e-v1', 'm', 'cv',
                0, 100, 0, 100, NULL, NULL, NULL, NULL, 'passthrough',
                1, 1.0, 0, 0, 0);
    ]]))
    local pre = clip_count(db, "e")
    local ok, err = pcall(ExpandAudio.execute, {
        sequence_id = "e", clip_id = "cv",
    })
    assert(not ok)
    assert(tostring(err):lower():find("audio")
        or tostring(err):find("track_type"),
        "error explains video-clip refusal; got: " .. tostring(err))
    assert(clip_count(db, "e") == pre, "no DB mutation on refusal")
    print("  ok")
end

print("✅ test_expand_audio_refusals.lua passed")
