-- 018 INV-3 inline subframe migration applied (count=1)
-- T056f / CT-C21c (013): CollapseAudio refusal cases.
--
-- Per FR-024 + commands.md §CollapseAudio: every refusal leaves NO
-- partial DB state.
--
--   * Empty selection.
--   * sequence_id mismatch (rule 2.29).
--   * Already-composite clip in selection (master_audio_track_id IS NULL).
--   * Different source_sequence_id across selection.
--   * Divergent source windows (per-track slip — refused, the genuine
--     expressiveness Expand buys).
--   * Different sequence_start/duration across selection.
--   * Different fps_mismatch_policy.
--   * Not all in one link group.
--   * Duplicate master_audio_track_id values in selection.

require("test_env")
local database = require("core.database")

local DB_PATH = "/tmp/jve/test_collapse_audio_refusals.db"

local function fresh_db()
    os.remove(DB_PATH)
    assert(database.init(DB_PATH), "schema.sql init failed")
    return database.get_connection()
end

-- Same starting fixture as test_collapse_audio.lua: V + 4 expanded A
-- clips on edit, all in lg.
local function build_fixture()
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
        VALUES ('m2', 'p1', 'master2', 'master', 24, 1, NULL, 1920, 1080, 0, 0);
        INSERT INTO sequences (id, project_id, name, kind,
            fps_numerator, fps_denominator, audio_sample_rate, width, height,
            created_at, modified_at)
        VALUES ('e', 'p1', 'edit', 'sequence', 24, 1, 48000, 1920, 1080, 0, 0);
        INSERT INTO tracks (id, sequence_id, name, track_type, track_index)
        VALUES ('m-v1', 'm', 'V1', 'VIDEO', 1),
               ('m-a1', 'm', 'A1', 'AUDIO', 1),
               ('m-a2', 'm', 'A2', 'AUDIO', 2),
               ('m-a3', 'm', 'A3', 'AUDIO', 3),
               ('m-a4', 'm', 'A4', 'AUDIO', 4),
               ('m2-v1', 'm2', 'V1', 'VIDEO', 1),
               ('m2-a1', 'm2', 'A1', 'AUDIO', 1),
               ('e-v1', 'e', 'V1', 'VIDEO', 1),
               ('e-a1', 'e', 'A1', 'AUDIO', 1),
               ('e-a2', 'e', 'A2', 'AUDIO', 2),
               ('e-a3', 'e', 'A3', 'AUDIO', 3),
               ('e-a4', 'e', 'A4', 'AUDIO', 4);
        UPDATE sequences SET default_video_layer_track_id = 'm-v1' WHERE id = 'm';
        UPDATE sequences SET default_video_layer_track_id = 'm2-v1' WHERE id = 'm2';
        INSERT INTO media (id, project_id, name, file_path, duration_frames,
            fps_numerator, fps_denominator, audio_channels,
            created_at, modified_at)
        VALUES ('vid', 'p1', 'v.mov', '/tmp/v.mov', 100, 24, 1, 0, 0, 0),
               ('a1', 'p1', 'a1.wav', '/tmp/a1.wav', 200000, 48000, 1, 1, 0, 0),
               ('a2', 'p1', 'a2.wav', '/tmp/a2.wav', 200000, 48000, 1, 1, 0, 0),
               ('a3', 'p1', 'a3.wav', '/tmp/a3.wav', 200000, 48000, 1, 1, 0, 0),
               ('a4', 'p1', 'a4.wav', '/tmp/a4.wav', 200000, 48000, 1, 1, 0, 0);
        INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id,
            media_id, source_in_frame, source_out_frame,
            sequence_start_frame, duration_frames,
            enabled, volume, playhead_frame, created_at, modified_at)
        VALUES ('mr-v',  'p1', 'm', 'm-v1', 'vid', 0, 100,    0, 100,    1, 1.0, 0, 0, 0),
               ('mr-a1', 'p1', 'm', 'm-a1', 'a1',  0, 200000, 0, 200000, 1, 1.0, 0, 0, 0),
               ('mr-a2', 'p1', 'm', 'm-a2', 'a2',  0, 200000, 0, 200000, 1, 1.0, 0, 0, 0),
               ('mr-a3', 'p1', 'm', 'm-a3', 'a3',  0, 200000, 0, 200000, 1, 1.0, 0, 0, 0),
               ('mr-a4', 'p1', 'm', 'm-a4', 'a4',  0, 200000, 0, 200000, 1, 1.0, 0, 0, 0);
        INSERT INTO clips (id, project_id, owner_sequence_id, track_id,
            sequence_id, name,
            sequence_start_frame, duration_frames,
            source_in_frame, source_out_frame,
            source_in_subframe, source_out_subframe,
            master_layer_track_id, master_audio_track_id, fps_mismatch_policy,
            enabled, volume, playhead_frame, created_at, modified_at)
        VALUES ('cv',  'p1', 'e', 'e-v1', 'm', 'cv',  0, 100, 0, 100,    NULL, NULL, NULL, NULL,  'passthrough', 1, 1.0, 0, 0, 0),
               ('ca1', 'p1', 'e', 'e-a1', 'm', 'ca1', 0, 100, 0, 200000, 0,    0,    NULL, 'm-a1','passthrough', 1, 1.0, 0, 0, 0),
               ('ca2', 'p1', 'e', 'e-a2', 'm', 'ca2', 0, 100, 0, 200000, 0,    0,    NULL, 'm-a2','passthrough', 1, 1.0, 0, 0, 0),
               ('ca3', 'p1', 'e', 'e-a3', 'm', 'ca3', 0, 100, 0, 200000, 0,    0,    NULL, 'm-a3','passthrough', 1, 1.0, 0, 0, 0),
               ('ca4', 'p1', 'e', 'e-a4', 'm', 'ca4', 0, 100, 0, 200000, 0,    0,    NULL, 'm-a4','passthrough', 1, 1.0, 0, 0, 0);
        INSERT INTO clip_links (link_group_id, clip_id, role, time_offset, enabled)
        VALUES ('lg', 'cv',  'video', 0, 1),
               ('lg', 'ca1', 'audio', 0, 1),
               ('lg', 'ca2', 'audio', 0, 1),
               ('lg', 'ca3', 'audio', 0, 1),
               ('lg', 'ca4', 'audio', 0, 1);
    ]]))
    require("test_env").touch_media_fixtures()
    return db
end

local function clip_count(db, owner)
    local stmt = db:prepare("SELECT COUNT(*) FROM clips WHERE owner_sequence_id = ?")
    stmt:bind_value(1, owner)
    assert(stmt:exec() and stmt:next())
    local n = stmt:value(0)
    stmt:finalize()
    return n
end

local CollapseAudio = require("core.commands.collapse_audio")

local function refuse_test(label, fixture_mutate, args, error_must_contain)
    local db = build_fixture()
    if fixture_mutate then fixture_mutate(db) end
    local pre = clip_count(db, "e")
    local ok, err = pcall(CollapseAudio.execute, args)
    assert(not ok, label .. ": expected refusal")
    if error_must_contain then
        assert(tostring(err):find(error_must_contain),
            string.format("%s: error must mention '%s'; got: %s",
                label, error_must_contain, tostring(err)))
    end
    assert(clip_count(db, "e") == pre,
        label .. ": no DB mutation on refusal")
    print("  ok " .. label)
end

print("-- refusals --")
refuse_test("empty selection", nil,
    { sequence_id = "e", clip_ids = {} }, nil)

refuse_test("sequence_id mismatch", nil,
    { sequence_id = "m", clip_ids = { "ca1", "ca2" } }, "sequence_id")

refuse_test("already-composite clip", function(db)
    -- Pre-flip ca2 to composite.
    assert(db:exec("UPDATE clips SET master_audio_track_id = NULL WHERE id = 'ca2'"))
end, { sequence_id = "e", clip_ids = { "ca1", "ca2" } }, "composite")

refuse_test("different nested", function(db)
    -- Re-point ca2 to a different master.
    assert(db:exec(string.format([[
        INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id,
            media_id, source_in_frame, source_out_frame,
            sequence_start_frame, duration_frames,
            enabled, volume, playhead_frame, created_at, modified_at)
        VALUES ('mr2-a1', 'p1', 'm2', 'm2-a1', 'a1', 0, 200000, 0, 200000,
                1, 1.0, 0, 0, 0);
        UPDATE clips SET sequence_id = 'm2', master_audio_track_id = 'm2-a1'
            WHERE id = 'ca2';
    ]])))
end, { sequence_id = "e", clip_ids = { "ca1", "ca2" } }, "master")

refuse_test("divergent source windows", function(db)
    assert(db:exec("UPDATE clips SET source_in_frame = 100 WHERE id = 'ca2'"))
end, { sequence_id = "e", clip_ids = { "ca1", "ca2" } }, "window")

refuse_test("not all in one link group", function(db)
    -- Move ca2 out of lg by deleting its link entry.
    assert(db:exec("DELETE FROM clip_links WHERE clip_id = 'ca2'"))
end, { sequence_id = "e", clip_ids = { "ca1", "ca2" } }, "link")

refuse_test("duplicate master_audio_track_id", function(db)
    -- Make ca2 also point at m-a1.
    assert(db:exec("UPDATE clips SET track_id='e-a1', master_audio_track_id = 'm-a1' WHERE id = 'ca2'"))
    -- Move ca2 out of overlap with ca1 to avoid the schema's video-overlap-
    -- type collision (here it's audio so no trigger; safe).
    assert(db:exec("UPDATE clips SET sequence_start_frame = 200 WHERE id = 'ca2'"))
end, { sequence_id = "e", clip_ids = { "ca1", "ca2" } }, "distinct")

print("✅ test_collapse_audio_refusals.lua passed")
