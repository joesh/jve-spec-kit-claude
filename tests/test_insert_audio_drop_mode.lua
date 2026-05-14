-- T056h / CT-C1b (013): Insert audio_drop_mode arg.
--
-- Per FR-002 + FR-025 + commands.md §Insert/Overwrite:
--   audio_drop_mode ∈ {'composite','expanded'}, default 'composite'.
--   * 'composite' (default): emit 1 A clip with master_audio_track_id=NULL.
--     Today's behavior — regression check.
--   * 'expanded': emit N A clips with distinct non-NULL
--     master_audio_track_id values (one per nested A track), auto-create
--     missing A tracks on the owner sequence. All V + A clips share one
--     link_group_id. Refused on collision with existing clips on any of
--     the target A tracks in the time range.
--
-- Black-box DB-state assertions.

require("test_env")
local database = require("core.database")

local DB_PATH = "/tmp/jve/test_insert_audio_drop_mode.db"

local function fresh_db()
    os.remove(DB_PATH)
    assert(database.init(DB_PATH), "schema.sql init failed")
    return database.get_connection()
end

-- Master with V1 + A1..A4 (4 audio tracks, each its own media file).
-- Edit has V1 + A1 only — A2/A3/A4 must be auto-created in expanded mode.
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
            timeline_start_frame, duration_frames,
            enabled, volume, playhead_frame, created_at, modified_at)
        VALUES ('mr-v',  'p1', 'm', 'm-v1', 'vid', 0, 100,    0, 100,    1, 1.0, 0, 0, 0),
               ('mr-a1', 'p1', 'm', 'm-a1', 'a1',  0, 200000, 0, 200000, 1, 1.0, 0, 0, 0),
               ('mr-a2', 'p1', 'm', 'm-a2', 'a2',  0, 200000, 0, 200000, 1, 1.0, 0, 0, 0),
               ('mr-a3', 'p1', 'm', 'm-a3', 'a3',  0, 200000, 0, 200000, 1, 1.0, 0, 0, 0),
               ('mr-a4', 'p1', 'm', 'm-a4', 'a4',  0, 200000, 0, 200000, 1, 1.0, 0, 0, 0);
    ]]))
    require("test_env").touch_media_fixtures()
    return db
end

local function clips_in_seq(db, owner)
    local stmt = db:prepare([[
        SELECT c.id, c.track_id, c.master_audio_track_id, t.track_type, t.track_index
        FROM clips c JOIN tracks t ON t.id = c.track_id
        WHERE c.owner_sequence_id = ?
        ORDER BY t.track_type DESC, t.track_index ASC, c.timeline_start_frame ASC
    ]])
    stmt:bind_value(1, owner)
    assert(stmt:exec())
    local rows = {}
    while stmt:next() do
        rows[#rows + 1] = {
            id = stmt:value(0),
            track_id = stmt:value(1),
            master_audio_track_id = stmt:value(2),
            track_type = stmt:value(3),
            track_index = stmt:value(4),
        }
    end
    stmt:finalize()
    return rows
end

local function audio_tracks_in_seq(db, seq_id)
    local stmt = db:prepare([[
        SELECT id, track_index FROM tracks
        WHERE sequence_id = ? AND track_type = 'AUDIO'
        ORDER BY track_index ASC
    ]])
    stmt:bind_value(1, seq_id)
    assert(stmt:exec())
    local rows = {}
    while stmt:next() do
        rows[#rows + 1] = { id = stmt:value(0), track_index = stmt:value(1) }
    end
    stmt:finalize()
    return rows
end

local function link_group_of(db, clip_id)
    local stmt = db:prepare("SELECT link_group_id FROM clip_links WHERE clip_id = ?")
    stmt:bind_value(1, clip_id)
    assert(stmt:exec())
    local g
    if stmt:next() then g = stmt:value(0) end
    stmt:finalize()
    return g
end

local Insert = require("core.commands.insert")

-- Default is 'expanded' per spec §F2 — patches are the sole routing
-- mechanism, and patches route per-channel, so a default that collapses
-- channels (composite) cannot honor them. Explicit 'composite' still works
-- as a legacy mixdown opt-in (see next case).
print("-- default is expanded: 1 V + 4 A clips (one per source A track) --")
do
    local db = build_fixture()
    local result = Insert.execute({
        sequence_id          = "e",
        source_sequence_id   = "m",
        timeline_start_frame = 0,
    })
    local clips = clips_in_seq(db, "e")
    assert(#clips == 5, string.format(
        "expanded default emits 1 V + 4 A = 5 clips; got %d", #clips))
    -- Result reports exactly the same count.
    assert(result.created_clip_ids and #result.created_clip_ids == 5,
        "result reports 5 created clip ids")
end

print("-- explicit composite: 1 V + 1 A clip, A has NULL selector --")
do
    local db = build_fixture()
    Insert.execute({
        sequence_id          = "e",
        source_sequence_id   = "m",
        timeline_start_frame = 0,
        audio_drop_mode      = "composite",
    })
    local clips = clips_in_seq(db, "e")
    assert(#clips == 2, string.format(
        "composite emits exactly 2 clips (1 V + 1 A); got %d", #clips))
    local v = clips[1]
    local a = clips[2]
    assert(v.track_type == "VIDEO" and a.track_type == "AUDIO")
    assert(a.master_audio_track_id == nil,
        "composite A clip has NULL master_audio_track_id")
    print("  ok")
end

print("-- expanded: 1 V + 4 A clips with distinct master_audio_track_id --")
do
    local db = build_fixture()
    local result = Insert.execute({
        sequence_id          = "e",
        source_sequence_id   = "m",
        timeline_start_frame = 0,
        audio_drop_mode      = "expanded",
    })
    -- Edit should now have A1..A4 (3 auto-created).
    local a_tracks = audio_tracks_in_seq(db, "e")
    assert(#a_tracks == 4, string.format(
        "expanded mode auto-creates A2..A4 on edit; got %d A tracks", #a_tracks))
    for i = 1, 4 do
        assert(a_tracks[i].track_index == i,
            "A tracks are dense at indices 1..4")
    end

    local clips = clips_in_seq(db, "e")
    assert(#clips == 5, string.format(
        "expanded emits 1 V + 4 A clips (5 total); got %d", #clips))
    local v = clips[1]
    assert(v.track_type == "VIDEO" and v.master_audio_track_id == nil)

    -- The 4 A clips: distinct master_audio_track_id values matching the
    -- master's m-a1..m-a4.
    local seen = {}
    for i = 2, 5 do
        local a = clips[i]
        assert(a.track_type == "AUDIO")
        assert(a.master_audio_track_id ~= nil,
            "expanded A clips MUST have non-NULL master_audio_track_id")
        assert(not seen[a.master_audio_track_id],
            "each expanded A clip points at a distinct master A track")
        seen[a.master_audio_track_id] = true
    end
    -- Specifically, the four selectors are exactly m-a1..m-a4.
    for _, expected in ipairs({ "m-a1", "m-a2", "m-a3", "m-a4" }) do
        assert(seen[expected], string.format(
            "expected master_audio_track_id=%s among the 4 A clips", expected))
    end

    -- All 5 clips share a single link_group_id.
    local v_lg = link_group_of(db, v.id)
    assert(v_lg, "V clip has a link_group_id under expanded mode")
    for i = 2, 5 do
        local a_lg = link_group_of(db, clips[i].id)
        assert(a_lg == v_lg, string.format(
            "A clip %d shares the V's link_group; got V=%s A=%s",
            i - 1, tostring(v_lg), tostring(a_lg)))
    end

    assert(result.created_clip_ids and #result.created_clip_ids == 5,
        "result reports 5 created clip ids")
    print("  ok")
end

-- Pre-existing clip on a routed track: Insert's ripple shifts it forward
-- to make room. Refusing here would defeat the whole point of patches
-- driving routing (a user with a populated timeline could never F9).
print("-- expanded: pre-existing clip on routed rec track → ripple makes room --")
do
    local db = build_fixture()
    -- Pre-place a blocker on rec A2 (a track the source's A2 patch will
    -- identity-route into). Manually create A2 so the blocker has a home.
    assert(db:exec([[
        INSERT INTO tracks (id, sequence_id, name, track_type, track_index)
        VALUES ('e-a2', 'e', 'A2', 'AUDIO', 2);
        INSERT INTO clips (id, project_id, owner_sequence_id, track_id,
            sequence_id, name,
            timeline_start_frame, duration_frames,
            source_in_frame, source_out_frame,
            master_layer_track_id, master_audio_track_id, fps_mismatch_policy,
            enabled, volume, playhead_frame, created_at, modified_at)
        VALUES ('blocker', 'p1', 'e', 'e-a2', 'm', 'blocker',
                0, 100, 0, 200000, NULL, NULL, 'passthrough',
                1, 1.0, 0, 0, 0);
    ]]))

    local r = Insert.execute({
        sequence_id          = "e",
        source_sequence_id   = "m",
        timeline_start_frame = 0,
        audio_drop_mode      = "expanded",
    })
    assert(r, "Insert with expanded must succeed when ripple can clear the way")

    -- Blocker shifted forward; new expanded clips occupy frame 0.
    local s = db:prepare(
        "SELECT timeline_start_frame FROM clips WHERE id='blocker'")
    s:exec(); s:next()
    local blocker_start = s:value(0); s:finalize()
    assert(blocker_start > 0, string.format(
        "ripple must have shifted the blocker forward; got start=%d",
        blocker_start))
    print("  blocker rippled forward — OK")
end

print("-- unknown audio_drop_mode value: refused --")
do
    build_fixture()
    local ok = pcall(Insert.execute, {
        sequence_id          = "e",
        source_sequence_id   = "m",
        timeline_start_frame = 0,
        audio_drop_mode      = "channels",
    })
    assert(not ok, "unknown audio_drop_mode refused")
    print("  ok")
end

print("✅ test_insert_audio_drop_mode.lua passed")
