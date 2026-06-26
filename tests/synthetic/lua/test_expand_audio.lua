-- 018 INV-3 inline subframe migration applied (count=1)
-- T056a / CT-C20 (013): ExpandAudio happy path — Phase 4a (master_track_id identity).
--
-- Per FR-023 + commands.md §ExpandAudio:
--   Args: { sequence_id, clip_id }. sequence_id is the clip's
--     owner_sequence_id (rule 2.29).
--   Pre: clip exists; clip is on an AUDIO track;
--     clip.master_audio_track_id IS NULL (composite — already-expanded
--     refuses); nested sequence has >= 2 A tracks; no collision on
--     auto-create target tracks.
--   Mutation:
--     1. For each A track of the nested sequence: auto-create the
--        owner's matching-index A track if missing; INSERT a clip on
--        it with master_audio_track_id = nested A track id, mirroring
--        the source clip's sequence_start/duration/fps_mismatch_policy.
--     2. Link all expanded clips into the source clip's link_group
--        (creating one if the source had none).
--     3. Project per-clip channel overrides onto the corresponding
--        expanded clip(s) — for first-landing 1-channel-per-track
--        masters, override(source, master_track_id='m-aN') maps to
--        override(expanded[N], master_track_id='m-aN', ch single-channel).
--     4. DELETE the source clip.
--
-- This test pins the happy path: V + composite A clip referencing a
-- 4-A-track master, target sequence has only A1, ExpandAudio creates
-- A2..A4 + 4 expanded clips replacing the source A clip + V's link
-- group now contains V + 4 A clips.

require("test_env")
local database = require("core.database")

local DB_PATH = "/tmp/jve/test_expand_audio.db"

local function fresh_db()
    os.remove(DB_PATH)
    assert(database.init(DB_PATH), "schema.sql init failed")
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
               ('m-a4', 'm', 'A4', 'AUDIO', 4),
               ('e-v1', 'e', 'V1', 'VIDEO', 1),
               ('e-a1', 'e', 'A1', 'AUDIO', 1);
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
            sequence_start_frame, duration_frames,
            audio_sample_rate, enabled, volume, playhead_frame, created_at, modified_at)
        VALUES ('mr-v',  'p1', 'm', 'm-v1', 'vid', 0, 100,    0, 100, 48000,    1, 1.0, 0, 0, 0),
               ('mr-a1', 'p1', 'm', 'm-a1', 'a1',  0, 200000, 0, 200000, 48000, 1, 1.0, 0, 0, 0),
               ('mr-a2', 'p1', 'm', 'm-a2', 'a2',  0, 200000, 0, 200000, 48000, 1, 1.0, 0, 0, 0),
               ('mr-a3', 'p1', 'm', 'm-a3', 'a3',  0, 200000, 0, 200000, 48000, 1, 1.0, 0, 0, 0),
               ('mr-a4', 'p1', 'm', 'm-a4', 'a4',  0, 200000, 0, 200000, 48000, 1, 1.0, 0, 0, 0);
        -- Composite V + A drop on edit (today's behavior).
        INSERT INTO clips (id, project_id, owner_sequence_id, track_id,
            sequence_id, name,
            sequence_start_frame, duration_frames,
            source_in_frame, source_out_frame,
            source_in_subframe, source_out_subframe,
            master_layer_track_id, master_audio_track_id, fps_mismatch_policy,
            enabled, volume, playhead_frame, created_at, modified_at)
        VALUES ('cv', 'p1', 'e', 'e-v1', 'm', 'cv',
                0, 100, 0, 100, NULL, NULL, NULL, NULL, 'passthrough',
                1, 1.0, 0, 0, 0),
               ('ca', 'p1', 'e', 'e-a1', 'm', 'ca',
                0, 100, 0, 200000, 0, 0, NULL, NULL, 'passthrough',
                1, 1.0, 0, 0, 0);
        INSERT INTO clip_links (link_group_id, clip_id, role, time_offset, enabled)
        VALUES ('lg', 'cv', 'video', 0, 1),
               ('lg', 'ca', 'audio', 0, 1);
    ]]))
    require("test_env").touch_media_fixtures()
    return db
end

local function audio_tracks_in(db, seq_id)
    local stmt = db:prepare(
        "SELECT id, track_index FROM tracks "
        .. "WHERE sequence_id = ? AND track_type = 'AUDIO' "
        .. "ORDER BY track_index ASC")
    stmt:bind_value(1, seq_id)
    assert(stmt:exec())
    local rows = {}
    while stmt:next() do
        rows[#rows + 1] = { id = stmt:value(0), track_index = stmt:value(1) }
    end
    stmt:finalize()
    return rows
end

local function audio_clips_in(db, seq_id)
    local stmt = db:prepare([[
        SELECT c.id, c.track_id, c.master_audio_track_id, t.track_index,
               c.sequence_start_frame, c.duration_frames
        FROM clips c JOIN tracks t ON t.id = c.track_id
        WHERE c.owner_sequence_id = ? AND t.track_type = 'AUDIO'
        ORDER BY t.track_index ASC
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
            sequence_start = stmt:value(4),
            duration = stmt:value(5),
        }
    end
    stmt:finalize()
    return rows
end

local function clips_in_link_group(db, lg)
    local stmt = db:prepare(
        "SELECT clip_id FROM clip_links WHERE link_group_id = ? "
        .. "ORDER BY clip_id ASC")
    stmt:bind_value(1, lg)
    assert(stmt:exec())
    local rows = {}
    while stmt:next() do rows[#rows + 1] = stmt:value(0) end
    stmt:finalize()
    return rows
end

-- Returns the override row for (clip_id, master_track_id), or nil.
local function override_for(db, clip_id, master_track_id)
    local stmt = db:prepare(
        "SELECT enabled, gain_db FROM clip_channel_override "
        .. "WHERE clip_id = ? AND master_track_id = ?")
    stmt:bind_value(1, clip_id)
    stmt:bind_value(2, master_track_id)
    assert(stmt:exec())
    local row
    if stmt:next() then
        row = { enabled = stmt:value(0) == 1, gain_db = stmt:value(1) }
    end
    stmt:finalize()
    return row
end

local ExpandAudio = require("core.commands.expand_audio")

print("-- happy path: 4 A tracks created, 4 A clips replace source --")
do
    local db = build_fixture()
    -- Add a per-channel override on the source: master track m-a3 disabled.
    -- Under 1-channel-per-track masters this represents the 3rd audio stream.
    assert(db:exec([[
        INSERT INTO clip_channel_override (clip_id, master_track_id, enabled, gain_db)
        VALUES ('ca', 'm-a3', 0, -3.0)
    ]]))

    local result = ExpandAudio.execute({
        sequence_id = "e",
        clip_id     = "ca",
    })

    -- Edit's A tracks: A1..A4 (3 auto-created).
    local tracks = audio_tracks_in(db, "e")
    assert(#tracks == 4, string.format(
        "expected 4 A tracks on edit; got %d", #tracks))
    for i = 1, 4 do
        assert(tracks[i].track_index == i, "tracks dense at indices 1..4")
    end

    -- Edit's A clips: 4 (one per track), each with distinct non-NULL
    -- master_audio_track_id; source 'ca' is gone.
    local a_clips = audio_clips_in(db, "e")
    assert(#a_clips == 4, string.format(
        "expected 4 expanded A clips; got %d", #a_clips))
    local seen = {}
    for _, c in ipairs(a_clips) do
        assert(c.id ~= "ca", "source clip 'ca' is deleted")
        assert(c.master_audio_track_id ~= nil,
            "expanded clips have non-NULL master_audio_track_id")
        seen[c.master_audio_track_id] = c
        assert(c.sequence_start == 0 and c.duration == 100,
            "expanded clips mirror source's timeline window")
    end
    for _, expected in ipairs({ "m-a1", "m-a2", "m-a3", "m-a4" }) do
        assert(seen[expected], string.format(
            "missing expanded clip for nested track %s", expected))
    end

    -- Link group: V + 4 A clips.
    local lg_clips = clips_in_link_group(db, "lg")
    assert(#lg_clips == 5, string.format(
        "link group should contain V + 4 expanded A clips (5); got %d",
        #lg_clips))

    -- Override projection: source had m-a3 disabled. The expanded clip
    -- whose master_audio_track_id = 'm-a3' should carry override(m-a3,
    -- enabled=false, gain=-3). Other expanded clips have no override.
    local a3_clip = seen["m-a3"]
    assert(a3_clip, "no expanded clip for m-a3")
    local ov = override_for(db, a3_clip.id, "m-a3")
    assert(ov, "expected override on a3-clip for m-a3")
    assert(ov.enabled == false and math.abs(ov.gain_db - (-3.0)) < 1e-9,
        "override projected: enabled=false gain=-3")

    -- Other expanded clips must have no override.
    for _, mt in ipairs({ "m-a1", "m-a2", "m-a4" }) do
        local c = seen[mt]
        assert(override_for(db, c.id, mt) == nil,
            "expanded clip for " .. mt .. " must have no override")
    end

    -- Result reports.
    assert(result.expanded_clip_ids and #result.expanded_clip_ids == 4,
        "result reports 4 expanded clip ids")
    print("  ok")
end

print("✅ test_expand_audio.lua passed")
