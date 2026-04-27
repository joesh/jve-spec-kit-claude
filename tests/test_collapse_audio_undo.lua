-- T056j undo (013): CollapseAudio.undo restores selected clips +
-- overrides + link group membership; removes the composite + its
-- projected overrides. Atomic.

require("test_env")
local database = require("core.database")

local DB_PATH = "/tmp/jve/test_collapse_audio_undo.db"

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
        VALUES ('m', 'p1', 'master', 'master', 24, 1, 48000, 1920, 1080, 0, 0);
        INSERT INTO sequences (id, project_id, name, kind,
            fps_numerator, fps_denominator, audio_sample_rate, width, height,
            created_at, modified_at)
        VALUES ('e', 'p1', 'edit', 'nested', 24, 1, 48000, 1920, 1080, 0, 0);
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
        INSERT INTO clips (id, project_id, owner_sequence_id, track_id,
            nested_sequence_id, name,
            timeline_start_frame, duration_frames,
            source_in_frame, source_out_frame,
            master_layer_track_id, master_audio_track_id, fps_mismatch_policy,
            enabled, volume, playhead_frame, created_at, modified_at)
        VALUES ('cv',  'p1', 'e', 'e-v1', 'm', 'cv',  0, 100, 0, 100,    NULL, NULL,  'passthrough', 1, 1.0, 0, 0, 0),
               ('ca1', 'p1', 'e', 'e-a1', 'm', 'ca1', 0, 100, 0, 200000, NULL, 'm-a1','passthrough', 1, 1.0, 0, 0, 0),
               ('ca2', 'p1', 'e', 'e-a2', 'm', 'ca2', 0, 100, 0, 200000, NULL, 'm-a2','passthrough', 1, 1.0, 0, 0, 0),
               ('ca3', 'p1', 'e', 'e-a3', 'm', 'ca3', 0, 100, 0, 200000, NULL, 'm-a3','passthrough', 1, 1.0, 0, 0, 0),
               ('ca4', 'p1', 'e', 'e-a4', 'm', 'ca4', 0, 100, 0, 200000, NULL, 'm-a4','passthrough', 1, 1.0, 0, 0, 0);
        -- Add an override on ca2 so the round-trip preserves a non-trivial state.
        INSERT INTO clip_channel_override (clip_id, channel_index, enabled, gain_db)
        VALUES ('ca2', 0, 0, -6.0);
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

local function snapshot_state(db)
    local snap = { clips = {}, links = {}, overrides = {} }
    do
        local stmt = db:prepare([[
            SELECT id, owner_sequence_id, track_id, master_audio_track_id,
                   timeline_start_frame, duration_frames,
                   source_in_frame, source_out_frame, volume, enabled
            FROM clips ORDER BY id
        ]])
        assert(stmt:exec())
        while stmt:next() do
            snap.clips[stmt:value(0)] = {
                owner = stmt:value(1),
                track_id = stmt:value(2),
                master_audio_track_id = stmt:value(3),
                timeline_start = stmt:value(4),
                duration = stmt:value(5),
                source_in = stmt:value(6),
                source_out = stmt:value(7),
                volume = stmt:value(8),
                enabled = stmt:value(9) == 1,
            }
        end
        stmt:finalize()
    end
    do
        local stmt = db:prepare(
            "SELECT clip_id, link_group_id, role FROM clip_links ORDER BY clip_id")
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
            local k = stmt:value(0) .. ":" .. stmt:value(1)
            snap.overrides[k] = {
                enabled = stmt:value(2) == 1,
                gain_db = stmt:value(3),
            }
        end
        stmt:finalize()
    end
    return snap
end

local function snapshots_equal(a, b)
    local function table_eq(t1, t2, label)
        local k1, k2 = 0, 0
        for k, v in pairs(t1) do
            k1 = k1 + 1
            local v2 = t2[k]
            if v2 == nil then return false, label .. ": key " .. k .. " missing in B" end
            for fk, fv in pairs(v) do
                if v2[fk] ~= fv then
                    return false, string.format("%s: %s.%s differs (%s vs %s)",
                        label, k, fk, tostring(fv), tostring(v2[fk]))
                end
            end
        end
        for _ in pairs(t2) do k2 = k2 + 1 end
        if k1 ~= k2 then
            return false, string.format("%s: counts %d vs %d", label, k1, k2)
        end
        return true
    end
    for _, k in ipairs({ "clips", "links", "overrides" }) do
        local ok, err = table_eq(a[k], b[k], k)
        if not ok then return false, err end
    end
    return true
end

local CollapseAudio = require("core.commands.collapse_audio")

print("-- CollapseAudio.undo restores selected clips + overrides + link entries --")
do
    local db = build_fixture()
    local pre = snapshot_state(db)

    local cap = CollapseAudio.execute({
        sequence_id = "e",
        clip_ids    = { "ca1", "ca2", "ca3", "ca4" },
    })
    assert(cap.composite_clip_id and cap.composite_clip_id ~= "")

    -- Sanity: composite present, selected gone.
    local mid = snapshot_state(db)
    assert(mid.clips[cap.composite_clip_id], "composite present mid-state")
    for _, sid in ipairs({ "ca1", "ca2", "ca3", "ca4" }) do
        assert(mid.clips[sid] == nil, sid .. " gone mid-state")
    end

    CollapseAudio.undo(cap)

    local post = snapshot_state(db)
    local ok, err = snapshots_equal(pre, post)
    assert(ok, "CollapseAudio.undo restores byte-for-byte: " .. tostring(err))
    print("  ok")
end

print("✅ test_collapse_audio_undo.lua passed")
