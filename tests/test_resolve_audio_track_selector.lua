-- 018 INV-3 inline subframe migration applied (count=3)
-- T021a / CT-R4b (013): audio-track selector — symmetric to video.
--
-- Per FR-005 / FR-023 + resolver.md track-selector step:
--
--   * NULL master_audio_track_id (composite, today's behavior): resolver
--     emits entries for every audio media_ref of the nested sequence.
--     Regression check — this test must continue to pass after T056l.
--
--   * Non-NULL master_audio_track_id = a single A track of the nested
--     sequence: resolver restricts audio resolution to that track's
--     media_ref only. Symmetric to clip.master_layer_track_id for video.
--
--   * Dangling non-NULL value (the track was direct-SQL deleted, FK
--     bypassed): resolver asserts loudly per G-R5 with the clip id and
--     the dangling track id.
--
-- This file is the failing-test gate for T056l (resolver extension).

require("test_env")
local database = require("core.database")

local DB_PATH = "/tmp/jve/test_resolve_audio_track_selector.db"

local function fresh_db()
    os.remove(DB_PATH)
    assert(database.init(DB_PATH), "schema.sql init failed")
    return database.get_connection()
end

-- Master with one V track + 3 A tracks (A1/A2/A3), each pointing at a
-- distinct media file so we can tell them apart by media_path.
local function build_fixture()
    local db = fresh_db()
    assert(db:exec([[
        INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
        VALUES ('p1', 'p', 'passthrough', '{"master_clock_hz":192000,"default_fps":{"num":24,"den":1}}', 0, 0);
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
               ('m-a3', 'm', 'A3', 'AUDIO', 3),
               ('e-v1', 'e', 'V1', 'VIDEO', 1),
               ('e-a1', 'e', 'A1', 'AUDIO', 1);
        UPDATE sequences SET default_video_layer_track_id = 'm-v1' WHERE id = 'm';
        INSERT INTO media (id, project_id, name, file_path, duration_frames,
            fps_numerator, fps_denominator, audio_channels, audio_sample_rate,
            created_at, modified_at)
        VALUES ('vid', 'p1', 'v.mov', '/tmp/v.mov', 100, 24, 1, 0, NULL, 0, 0),
               ('a1', 'p1', 'a1.wav', '/tmp/a1.wav', 200000, 48000, 1, 1, 48000, 0, 0),
               ('a2', 'p1', 'a2.wav', '/tmp/a2.wav', 200000, 48000, 1, 1, 48000, 0, 0),
               ('a3', 'p1', 'a3.wav', '/tmp/a3.wav', 200000, 48000, 1, 1, 48000, 0, 0);
        INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id,
            media_id, source_in_frame, source_out_frame,
            sequence_start_frame, duration_frames,
            audio_sample_rate, enabled, volume, playhead_frame, created_at, modified_at)
        VALUES ('mr-v',  'p1', 'm', 'm-v1', 'vid', 0, 100,    0, 100, 48000,    1, 1.0, 0, 0, 0),
               ('mr-a1', 'p1', 'm', 'm-a1', 'a1',  0, 200000, 0, 200000, 48000, 1, 1.0, 0, 0, 0),
               ('mr-a2', 'p1', 'm', 'm-a2', 'a2',  0, 200000, 0, 200000, 48000, 1, 1.0, 0, 0, 0),
               ('mr-a3', 'p1', 'm', 'm-a3', 'a3',  0, 200000, 0, 200000, 48000, 1, 1.0, 0, 0, 0);
    ]]))
    require("test_env").touch_media_fixtures()
    return db
end

local function audio_paths(entries)
    local paths = {}
    for _, e in ipairs(entries) do
        if e.media_kind == "audio" then paths[#paths + 1] = e.media_path end
    end
    table.sort(paths)
    return paths
end

local Sequence = require("models.sequence")

print("-- NULL master_audio_track_id: composite (all 3 audio tracks emit) --")
do
    local db = build_fixture()
    assert(db:exec([[
        INSERT INTO clips (id, project_id, owner_sequence_id, track_id,
            sequence_id, name,
            sequence_start_frame, duration_frames,
            source_in_frame, source_out_frame,
            source_in_subframe, source_out_subframe,
            master_layer_track_id, master_audio_track_id, fps_mismatch_policy,
            enabled, volume, playhead_frame, created_at, modified_at)
        VALUES ('c-comp', 'p1', 'e', 'e-a1', 'm', 'composite',
                0, 100, 0, 100, 0, 0,
                NULL, NULL, 'passthrough',
                1, 1.0, 0, 0, 0)
    ]]))

    local entries = Sequence:resolve_in_range("e", 0, 1000, {
        recursing_into = {},
        depth = 0,
        export_mode = false,
        project_fps_mismatch_policy = "passthrough",
    })
    local paths = audio_paths(entries)
    assert(#paths == 3, string.format(
        "composite: 3 audio media_paths emitted; got %d", #paths))
    assert(paths[1] == "/tmp/a1.wav"
       and paths[2] == "/tmp/a2.wav"
       and paths[3] == "/tmp/a3.wav",
        "composite: all 3 audio paths present")
    print("  ok")
end

print("-- master_audio_track_id = m-a2: audio restricted to A2 only --")
do
    local db = build_fixture()
    assert(db:exec([[
        INSERT INTO clips (id, project_id, owner_sequence_id, track_id,
            sequence_id, name,
            sequence_start_frame, duration_frames,
            source_in_frame, source_out_frame,
            source_in_subframe, source_out_subframe,
            master_layer_track_id, master_audio_track_id, fps_mismatch_policy,
            enabled, volume, playhead_frame, created_at, modified_at)
        VALUES ('c-a2', 'p1', 'e', 'e-a1', 'm', 'expanded-A2',
                0, 100, 0, 100, 0, 0,
                NULL, 'm-a2', 'passthrough',
                1, 1.0, 0, 0, 0)
    ]]))

    local entries = Sequence:resolve_in_range("e", 0, 1000, {
        recursing_into = {},
        depth = 0,
        export_mode = false,
        project_fps_mismatch_policy = "passthrough",
    })
    local paths = audio_paths(entries)
    assert(#paths == 1, string.format(
        "expanded-A2: exactly 1 audio media_path emitted; got %d (paths=[%s])",
        #paths, table.concat(paths, ",")))
    assert(paths[1] == "/tmp/a2.wav",
        "expanded-A2: only A2's media file emits; got " .. tostring(paths[1]))
    print("  ok")
end

print("-- dangling master_audio_track_id (FK bypassed): G-R5 loud assert --")
do
    local db = build_fixture()
    assert(db:exec([[
        INSERT INTO clips (id, project_id, owner_sequence_id, track_id,
            sequence_id, name,
            sequence_start_frame, duration_frames,
            source_in_frame, source_out_frame,
            source_in_subframe, source_out_subframe,
            master_layer_track_id, master_audio_track_id, fps_mismatch_policy,
            enabled, volume, playhead_frame, created_at, modified_at)
        VALUES ('c-d', 'p1', 'e', 'e-a1', 'm', 'dangling',
                0, 100, 0, 100, 0, 0,
                NULL, 'm-a2', 'passthrough',
                1, 1.0, 0, 0, 0)
    ]]))
    -- Direct SQL delete with FK off so the column stays non-NULL but
    -- references a non-existent track. Mimics a corrupt state per the
    -- contract.
    assert(db:exec("PRAGMA foreign_keys = OFF"))
    assert(db:exec("DELETE FROM tracks WHERE id = 'm-a2'"))
    assert(db:exec("PRAGMA foreign_keys = ON"))

    local ok, err = pcall(function()
        Sequence:resolve_in_range("e", 0, 1000, {
            recursing_into = {},
            depth = 0,
            export_mode = false,
            project_fps_mismatch_policy = "passthrough",
        })
    end)
    assert(not ok, "dangling master_audio_track_id must trigger G-R5 assert")
    assert(tostring(err):find("c-d"),
        "G-R5 message must name the clip id; got: " .. tostring(err))
    assert(tostring(err):find("m-a2"),
        "G-R5 message must name the dangling track id; got: " .. tostring(err))
    print("  ok")
end

print("✅ test_resolve_audio_track_selector.lua passed")
