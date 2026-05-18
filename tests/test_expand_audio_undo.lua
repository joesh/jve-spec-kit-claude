-- T056c / CT-C20c (013): ExpandAudio undo.
--
-- A single ExpandAudio.undo restores the source composite clip + its
-- per-channel overrides + its link_group membership AND removes all N
-- expanded clips + any auto-created owner tracks. Atomic per FR-020
-- commentary (multi-row structural commands undo as one unit).

require("test_env")
local database = require("core.database")

local DB_PATH = "/tmp/jve/test_expand_audio_undo.db"

local function fresh_db()
    os.remove(DB_PATH)
    assert(database.init(DB_PATH), "schema.sql init failed")
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
            master_layer_track_id, master_audio_track_id, fps_mismatch_policy,
            enabled, volume, playhead_frame, created_at, modified_at)
        VALUES ('cv', 'p1', 'e', 'e-v1', 'm', 'cv',
                0, 100, 0, 100, NULL, NULL, 'passthrough', 1, 1.0, 0, 0, 0),
               ('ca', 'p1', 'e', 'e-a1', 'm', 'ca',
                0, 100, 0, 200000, NULL, NULL, 'passthrough', 1, 0.75, 0, 0, 0);
        INSERT INTO clip_links (link_group_id, clip_id, role, time_offset, enabled)
        VALUES ('lg', 'cv', 'video', 0, 1),
               ('lg', 'ca', 'audio', 0, 1);
        INSERT INTO clip_channel_override (clip_id, channel_index, enabled, gain_db)
        VALUES ('ca', 1, 0, -6.0),
               ('ca', 2, 1, -3.0);
    ]]))
    require("test_env").touch_media_fixtures()
    return db
end

local function snapshot_state(db)
    local snap = { clips = {}, tracks = {}, links = {}, overrides = {} }
    for _, owner in ipairs({ "e", "m" }) do
        local stmt = db:prepare([[
            SELECT id, owner_sequence_id, track_id, master_audio_track_id,
                   sequence_start_frame, duration_frames, volume
            FROM clips WHERE owner_sequence_id = ?
            ORDER BY id
        ]])
        stmt:bind_value(1, owner)
        assert(stmt:exec())
        while stmt:next() do
            snap.clips[stmt:value(0)] = {
                owner = stmt:value(1),
                track_id = stmt:value(2),
                master_audio_track_id = stmt:value(3),
                sequence_start = stmt:value(4),
                duration = stmt:value(5),
                volume = stmt:value(6),
            }
        end
        stmt:finalize()
    end
    do
        local stmt = db:prepare("SELECT id, sequence_id, track_index FROM tracks ORDER BY id")
        assert(stmt:exec())
        while stmt:next() do
            snap.tracks[stmt:value(0)] = {
                sequence_id = stmt:value(1),
                track_index = stmt:value(2),
            }
        end
        stmt:finalize()
    end
    do
        local stmt = db:prepare("SELECT clip_id, link_group_id, role FROM clip_links ORDER BY clip_id")
        assert(stmt:exec())
        while stmt:next() do
            snap.links[stmt:value(0)] = {
                link_group_id = stmt:value(1),
                role = stmt:value(2),
            }
        end
        stmt:finalize()
    end
    do
        local stmt = db:prepare(
            "SELECT clip_id, channel_index, enabled, gain_db "
            .. "FROM clip_channel_override ORDER BY clip_id, channel_index")
        assert(stmt:exec())
        while stmt:next() do
            local key = stmt:value(0) .. ":" .. stmt:value(1)
            snap.overrides[key] = {
                enabled = stmt:value(2) == 1,
                gain_db = stmt:value(3),
            }
        end
        stmt:finalize()
    end
    return snap
end

local function snapshots_equal(a, b)
    -- Shallow compare of the four sub-tables.
    local function table_eq(t1, t2, label)
        local k_count_1, k_count_2 = 0, 0
        for k, v in pairs(t1) do
            k_count_1 = k_count_1 + 1
            local v2 = t2[k]
            if v2 == nil then
                return false, string.format("%s: key %s missing in B", label, k)
            end
            for fk, fv in pairs(v) do
                if v2[fk] ~= fv then
                    return false, string.format("%s: %s.%s differs (%s vs %s)",
                        label, k, fk, tostring(fv), tostring(v2[fk]))
                end
            end
        end
        for _ in pairs(t2) do k_count_2 = k_count_2 + 1 end
        if k_count_1 ~= k_count_2 then
            return false, string.format("%s: key count differs (%d vs %d)",
                label, k_count_1, k_count_2)
        end
        return true
    end
    for _, k in ipairs({ "clips", "tracks", "links", "overrides" }) do
        local ok, err = table_eq(a[k], b[k], k)
        if not ok then return false, err end
    end
    return true
end

local ExpandAudio = require("core.commands.expand_audio")

print("-- ExpandAudio.undo restores source + overrides + link; removes expanded + auto-tracks --")
do
    local db = build_fixture()
    local pre = snapshot_state(db)

    local cap = ExpandAudio.execute({
        sequence_id = "e",
        clip_id     = "ca",
    })

    -- Sanity: post-expand state differs from pre.
    local mid = snapshot_state(db)
    assert(mid.clips["ca"] == nil, "source 'ca' is gone after expand")
    assert(#cap.expanded_clip_ids == 4, "4 expanded clips created")
    assert(#cap.created_track_ids == 3, "3 owner A tracks auto-created")

    ExpandAudio.undo(cap)

    local post = snapshot_state(db)
    local ok, err = snapshots_equal(pre, post)
    assert(ok, "ExpandAudio.undo restores byte-for-byte: " .. tostring(err))
    print("  ok")
end

print("✅ test_expand_audio_undo.lua passed")
