-- 018 INV-3 inline subframe migration applied (count=1)
-- T056e / CT-C21b (013): CollapseAudio partial selection.
--
-- Per FR-024 + commands.md §CollapseAudio:
--   Given V + 4 expanded A clips (A1..A4), CollapseAudio on {A1, A2}
--   produces V + composite-on-A1 (with per-channel disables for the
--   nested tracks NOT covered by the selection — A3, A4) + A3 + A4
--   untouched. Audibly identical to pre-collapse.
--
-- The per-channel disable projection is the FR-024 / Edge Cases
-- "incomplete coverage doesn't refuse — it projects" contract.

require("test_env")
local database = require("core.database")

local DB_PATH = "/tmp/jve/test_collapse_audio_partial.db"

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
            sequence_start_frame, duration_frames,
            audio_sample_rate, enabled, volume, playhead_frame, created_at, modified_at)
        VALUES ('mr-v',  'p1', 'm', 'm-v1', 'vid', 0, 100,    0, 100, 48000,    1, 1.0, 0, 0, 0),
               ('mr-a1', 'p1', 'm', 'm-a1', 'a1',  0, 200000, 0, 200000, 48000, 1, 1.0, 0, 0, 0),
               ('mr-a2', 'p1', 'm', 'm-a2', 'a2',  0, 200000, 0, 200000, 48000, 1, 1.0, 0, 0, 0),
               ('mr-a3', 'p1', 'm', 'm-a3', 'a3',  0, 200000, 0, 200000, 48000, 1, 1.0, 0, 0, 0),
               ('mr-a4', 'p1', 'm', 'm-a4', 'a4',  0, 200000, 0, 200000, 48000, 1, 1.0, 0, 0, 0);
        INSERT INTO clips (id, project_id, owner_sequence_id, track_id,
            sequence_id, name,
            sequence_start_frame, duration_frames,
            source_in_frame, source_out_frame,
            source_in_subframe, source_out_subframe,
            master_layer_track_id, master_audio_track_id, fps_mismatch_policy,
            enabled, volume, playhead_frame, created_at, modified_at)
        VALUES ('cv',  'p1', 'e', 'e-v1', 'm', 'cv',  0, 100, 0, 100, NULL, NULL,    NULL, NULL,  'passthrough', 1, 1.0, 0, 0, 0),
               ('ca1', 'p1', 'e', 'e-a1', 'm', 'ca1', 0, 100, 0, 200000, 0, 0, NULL, 'm-a1','passthrough', 1, 1.0, 0, 0, 0),
               ('ca2', 'p1', 'e', 'e-a2', 'm', 'ca2', 0, 100, 0, 200000, 0, 0, NULL, 'm-a2','passthrough', 1, 1.0, 0, 0, 0),
               ('ca3', 'p1', 'e', 'e-a3', 'm', 'ca3', 0, 100, 0, 200000, 0, 0, NULL, 'm-a3','passthrough', 1, 1.0, 0, 0, 0),
               ('ca4', 'p1', 'e', 'e-a4', 'm', 'ca4', 0, 100, 0, 200000, 0, 0, NULL, 'm-a4','passthrough', 1, 1.0, 0, 0, 0);
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
        SELECT c.id, c.master_audio_track_id, t.track_index
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
            master_audio_track_id = stmt:value(1),
            track_index = stmt:value(2),
        }
    end
    stmt:finalize()
    return rows
end

local function override_for(db, clip_id, channel_index)
    local stmt = db:prepare(
        "SELECT enabled, gain_db FROM clip_channel_override "
        .. "WHERE clip_id = ? AND channel_index = ?")
    stmt:bind_value(1, clip_id)
    stmt:bind_value(2, channel_index)
    assert(stmt:exec())
    local row
    if stmt:next() then
        row = { enabled = stmt:value(0) == 1, gain_db = stmt:value(1) }
    end
    stmt:finalize()
    return row
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

print("-- partial {ca1, ca2}: composite-on-A1 + ca3 + ca4 untouched --")
do
    local db = build_fixture()

    local result = CollapseAudio.execute({
        sequence_id = "e",
        clip_ids    = { "ca1", "ca2" },
    })
    assert(result.composite_clip_id and result.composite_clip_id ~= "")
    local composite_id = result.composite_clip_id

    local a_clips = audio_clips_in(db, "e")
    -- Expect: composite on A1 (track_index=1) + ca3 (A3) + ca4 (A4).
    assert(#a_clips == 3, string.format(
        "expected composite + ca3 + ca4 (3 audio clips); got %d", #a_clips))

    -- Find composite (track_index=1, master_audio_track_id IS NULL).
    local comp = nil
    local survivors_by_id = {}
    for _, c in ipairs(a_clips) do
        if c.id == composite_id then
            comp = c
        else
            survivors_by_id[c.id] = c
        end
    end
    assert(comp and comp.track_index == 1
       and comp.master_audio_track_id == nil,
        "composite is on A1 with NULL master_audio_track_id")
    assert(survivors_by_id["ca3"] and survivors_by_id["ca3"].track_index == 3
       and survivors_by_id["ca3"].master_audio_track_id == "m-a3",
        "ca3 untouched on A3")
    assert(survivors_by_id["ca4"] and survivors_by_id["ca4"].track_index == 4
       and survivors_by_id["ca4"].master_audio_track_id == "m-a4",
        "ca4 untouched on A4")

    -- Per-channel disables on composite: tracks not covered by selection
    -- are A3 (track_index=3, channel=2) and A4 (track_index=4, channel=3).
    -- Selected tracks A1/A2 → channels 0/1 — no disable, inherit master.
    local ch2 = override_for(db, composite_id, 2)
    assert(ch2 and ch2.enabled == false and ch2.gain_db == 0,
        "composite has disable override on ch=2 (A3 unselected)")
    local ch3 = override_for(db, composite_id, 3)
    assert(ch3 and ch3.enabled == false and ch3.gain_db == 0,
        "composite has disable override on ch=3 (A4 unselected)")
    -- Channels 0 and 1 should NOT have an override row (selected clips
    -- had unity volume + no per-channel override → composite tracks
    -- inherited state; absent override row).
    assert(override_for(db, composite_id, 0) == nil,
        "composite ch=0 has no override (selected, default state)")
    assert(override_for(db, composite_id, 1) == nil,
        "composite ch=1 has no override (selected, default state)")

    -- Link group: V + composite + ca3 + ca4 = 4 entries.
    local lg_clips = clips_in_link_group(db, "lg")
    assert(#lg_clips == 4, string.format(
        "link group has V + composite + ca3 + ca4 (4); got %d", #lg_clips))

    print("  ok")
end

print("✅ test_collapse_audio_partial.lua passed")
