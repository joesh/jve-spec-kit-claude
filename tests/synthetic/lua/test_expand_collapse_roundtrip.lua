-- 018 INV-3 inline subframe migration applied (count=1)
-- T056g / CT-C21d (013): Expand → delete → Collapse → ExpandAudio roundtrip —
-- Phase 4a (master_track_id identity).
--
-- Per FR-024 + Edge Cases: deleting an expanded clip is audibly
-- equivalent to muting it. So Collapse over a partial selection
-- (where one of the expanded clips has been deleted) projects the
-- missing-track to per-channel disables on the composite. Subsequent
-- ExpandAudio re-creates N per-track clips with the disabled channels
-- preserved. Clearing the disable override restores audibility.
--
-- Lossless roundtrip on the audible-state level.
--
-- Under Phase 4a: overrides are keyed by master_track_id (track UUID),
-- not by integer channel_index. ClearClipOverride takes master_track_id.

require("test_env")
local database = require("core.database")

local DB_PATH = "/tmp/jve/test_expand_collapse_roundtrip.db"

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

local function audio_clip_by_master_track(db, seq_id, master_track_id)
    local stmt = db:prepare([[
        SELECT id FROM clips
        WHERE owner_sequence_id = ? AND master_audio_track_id = ?
    ]])
    stmt:bind_value(1, seq_id)
    stmt:bind_value(2, master_track_id)
    assert(stmt:exec())
    local id
    if stmt:next() then id = stmt:value(0) end
    stmt:finalize()
    return id
end

-- Returns override row for (clip_id, master_track_id), or nil if absent.
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

local CollapseAudio  = require("core.commands.collapse_audio")
local ExpandAudio    = require("core.commands.expand_audio")
local ClearOverride  = require("core.commands.clear_clip_override")

print("-- delete A2-clip → Collapse remaining → ExpandAudio: A2 stays disabled --")
do
    local db = build_fixture()

    -- Step 1: delete ca2 (the user's "remove this expanded track").
    -- Direct DB delete to mimic "cleared from the timeline" — the spec
    -- treats this as audibly equivalent to muting.
    assert(db:exec("DELETE FROM clips WHERE id = 'ca2'"))

    -- Step 2: Collapse remaining {ca1, ca3, ca4}.
    local collapse_result = CollapseAudio.execute({
        sequence_id = "e",
        clip_ids    = { "ca1", "ca3", "ca4" },
    })
    local composite_id = collapse_result.composite_clip_id
    assert(composite_id, "Collapse produces a composite clip")

    -- Composite has disable override for m-a2 (unselected via deletion).
    local ov_a2 = override_for(db, composite_id, "m-a2")
    assert(ov_a2 and ov_a2.enabled == false and ov_a2.gain_db == 0,
        "composite has disable for m-a2 (A2 unselected via deletion)")
    -- Selected tracks m-a1/m-a3/m-a4 must NOT have an override.
    assert(override_for(db, composite_id, "m-a1") == nil,
        "m-a1 (selected A1) inherits default state")
    assert(override_for(db, composite_id, "m-a3") == nil,
        "m-a3 (selected A3) inherits default state")
    assert(override_for(db, composite_id, "m-a4") == nil,
        "m-a4 (selected A4) inherits default state")

    -- Step 3: Expand the composite.
    local expand_result = ExpandAudio.execute({
        sequence_id = "e",
        clip_id     = composite_id,
    })
    assert(expand_result.expanded_clip_ids and #expand_result.expanded_clip_ids == 4,
        "Expand produces 4 per-track clips")

    -- Step 4: the A2-clip (master_audio_track_id = m-a2) has override
    -- for m-a2, enabled=false. Other 3 have no override for their track.
    local a2_clip_id = audio_clip_by_master_track(db, "e", "m-a2")
    assert(a2_clip_id, "expanded clip on m-a2 exists")
    local a2_ov = override_for(db, a2_clip_id, "m-a2")
    assert(a2_ov and a2_ov.enabled == false,
        "expanded A2-clip has disable override for m-a2 (preserved through "
        .. "Collapse → Expand roundtrip)")

    for _, mt in ipairs({ "m-a1", "m-a3", "m-a4" }) do
        local cid = audio_clip_by_master_track(db, "e", mt)
        assert(cid, "expanded clip on " .. mt .. " exists")
        assert(override_for(db, cid, mt) == nil,
            "expanded " .. mt .. " has no disable (it was selected at Collapse)")
    end

    -- Step 5: clear the disable override on the A2-clip → audibility restored.
    ClearOverride.execute({
        sequence_id    = "e",
        clip_id        = a2_clip_id,
        kind           = "channel",
        master_track_id = "m-a2",
    })
    assert(override_for(db, a2_clip_id, "m-a2") == nil,
        "after ClearClipOverride, A2-clip m-a2 inherits default (audible)")

    print("  ok")
end

print("✅ test_expand_collapse_roundtrip.lua passed")
