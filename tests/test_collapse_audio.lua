-- T056d / CT-C21 (013): CollapseAudio happy path.
--
-- Per FR-024 + commands.md §CollapseAudio:
--   Given V + 4 expanded A clips referencing the same master, all 4
--   A clips selected: produces V + 1 composite A clip on the topmost
--   selected track (lowest track_index) with master_audio_track_id=NULL.
--   Link group rewired: V + 1 A. Per-channel state preserved (so
--   audibly identical pre/post for the trivial selection where all
--   tracks are present and identical).

require("test_env")
local database = require("core.database")

local DB_PATH = "/tmp/jve/test_collapse_audio.db"

local function fresh_db()
    os.remove(DB_PATH)
    assert(database.init(DB_PATH), "schema.sql init failed")
    return database.get_connection()
end

-- Build edit with V + 4 expanded A clips (state matching what
-- ExpandAudio produces), then CollapseAudio on the 4.
local function build_fixture()
    local db = fresh_db()
    assert(db:exec([[
        INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at)
        VALUES ('p1', 'p', 'passthrough', 0, 0);
        INSERT INTO sequences (id, project_id, name, kind,
            fps_numerator, fps_denominator, audio_sample_rate, width, height,
            created_at, modified_at)
        VALUES ('m', 'p1', 'master', 'master', 24, 1, 48000, 1920, 1080, 0, 0);
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
               ('e-v1', 'e', 'V1', 'VIDEO', 1),
               ('e-a1', 'e', 'A1', 'AUDIO', 1),
               ('e-a2', 'e', 'A2', 'AUDIO', 2),
               ('e-a3', 'e', 'A3', 'AUDIO', 3),
               ('e-a4', 'e', 'A4', 'AUDIO', 4);
        UPDATE sequences SET default_video_layer_track_id = 'm-v1' WHERE id = 'm';
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
            timeline_start_frame, duration_frames,
            enabled, volume, playhead_frame, created_at, modified_at)
        VALUES ('mr-v',  'p1', 'm', 'm-v1', 'vid', 0, 100,    0, 100,    1, 1.0, 0, 0, 0),
               ('mr-a1', 'p1', 'm', 'm-a1', 'a1',  0, 200000, 0, 200000, 1, 1.0, 0, 0, 0),
               ('mr-a2', 'p1', 'm', 'm-a2', 'a2',  0, 200000, 0, 200000, 1, 1.0, 0, 0, 0),
               ('mr-a3', 'p1', 'm', 'm-a3', 'a3',  0, 200000, 0, 200000, 1, 1.0, 0, 0, 0),
               ('mr-a4', 'p1', 'm', 'm-a4', 'a4',  0, 200000, 0, 200000, 1, 1.0, 0, 0, 0);
        -- V + 4 expanded A clips, all in one link_group 'lg'.
        INSERT INTO clips (id, project_id, owner_sequence_id, track_id,
            sequence_id, name,
            timeline_start_frame, duration_frames,
            source_in_frame, source_out_frame,
            master_layer_track_id, master_audio_track_id, fps_mismatch_policy,
            enabled, volume, playhead_frame, created_at, modified_at)
        VALUES ('cv',  'p1', 'e', 'e-v1', 'm', 'cv',  0, 100, 0, 100,    NULL, NULL,  'passthrough', 1, 1.0, 0, 0, 0),
               ('ca1', 'p1', 'e', 'e-a1', 'm', 'ca1', 0, 100, 0, 200000, NULL, 'm-a1','passthrough', 1, 1.0, 0, 0, 0),
               ('ca2', 'p1', 'e', 'e-a2', 'm', 'ca2', 0, 100, 0, 200000, NULL, 'm-a2','passthrough', 1, 1.0, 0, 0, 0),
               ('ca3', 'p1', 'e', 'e-a3', 'm', 'ca3', 0, 100, 0, 200000, NULL, 'm-a3','passthrough', 1, 1.0, 0, 0, 0),
               ('ca4', 'p1', 'e', 'e-a4', 'm', 'ca4', 0, 100, 0, 200000, NULL, 'm-a4','passthrough', 1, 1.0, 0, 0, 0);
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

local function audio_clips_in(db, seq_id)
    local stmt = db:prepare([[
        SELECT c.id, c.track_id, c.master_audio_track_id, t.track_index
        FROM clips c JOIN tracks t ON t.id = c.track_id
        WHERE c.owner_sequence_id = ? AND t.track_type = 'AUDIO'
        ORDER BY t.track_index ASC, c.id ASC
    ]])
    stmt:bind_value(1, seq_id)
    assert(stmt:exec())
    local rows = {}
    while stmt:next() do
        rows[#rows + 1] = {
            id = stmt:value(0),
            track_id = stmt:value(1),
            master_audio_track_id = stmt:value(2),
            track_index = stmt:value(3),
        }
    end
    stmt:finalize()
    return rows
end

local function clips_in_link_group(db, lg)
    local stmt = db:prepare("SELECT clip_id FROM clip_links WHERE link_group_id = ? ORDER BY clip_id")
    stmt:bind_value(1, lg)
    assert(stmt:exec())
    local rows = {}
    while stmt:next() do rows[#rows + 1] = stmt:value(0) end
    stmt:finalize()
    return rows
end

local CollapseAudio = require("core.commands.collapse_audio")

print("-- happy path: 4 expanded → 1 composite on topmost track (A1) --")
do
    local db = build_fixture()

    local result = CollapseAudio.execute({
        sequence_id = "e",
        clip_ids    = { "ca1", "ca2", "ca3", "ca4" },
    })

    assert(result.composite_clip_id and result.composite_clip_id ~= "",
        "result reports composite_clip_id")

    local a_clips = audio_clips_in(db, "e")
    assert(#a_clips == 1, string.format(
        "expected exactly 1 A clip post-collapse; got %d", #a_clips))
    assert(a_clips[1].master_audio_track_id == nil,
        "composite has NULL master_audio_track_id (composite mode)")
    assert(a_clips[1].track_index == 1,
        "composite lands on the topmost selected track (A1, lowest index)")

    -- Link group rewired to V + composite.
    local lg_clips = clips_in_link_group(db, "lg")
    assert(#lg_clips == 2, string.format(
        "link group has V + composite (2); got %d", #lg_clips))
    print("  ok")
end

print("✅ test_collapse_audio.lua passed")
