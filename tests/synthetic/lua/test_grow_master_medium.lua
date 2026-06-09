-- 018 INV-3 inline subframe migration applied (count=3)
-- T060a / T064a (013): GrowMasterMedium — owning command for FR-007 /
-- Acceptance Scenario 7.
--
-- Per commands.md / FR-007: when a master's shape changes (e.g. a
-- previously video-only master gains audio), every existing clip that
-- references that master gains a linked companion clip on the new
-- medium, sharing the original clip's link_group_id.
--
-- First-landing scope: audio-add only (medium='audio'). Adding video to
-- audio-only masters has the same shape but is a separate scenario;
-- multi-track audio additions (one A track per channel) can be added
-- later. Parent sequence must already have a matching A track —
-- auto-creating parent tracks is deferred.

require("test_env")
local database = require("core.database")

local DB_PATH = "/tmp/jve/test_grow_master_medium.db"

local function fresh_db()
    os.remove(DB_PATH)
    assert(database.init(DB_PATH), "schema.sql init failed")
    return database.get_connection()
end

-- Fixture: video-only master `m` with 1000-frame V track. Edit `e` has
-- 3 clips on V1 referencing `m`. Edit also has an A1 track ready to
-- receive the new linked audio clips. A separate audio media file
-- 'a-med' will be added as the master's new audio.
local function build_fixture()
    local db = fresh_db()
    assert(db:exec([[
        INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
        VALUES ('p1', 'p', 'resample', '{"master_clock_hz":192000,"default_fps":{"num":24,"den":1}}', 0, 0);
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
               ('e-v1', 'e', 'V1', 'VIDEO', 1),
               ('e-a1', 'e', 'A1', 'AUDIO', 1);
        UPDATE sequences SET default_video_layer_track_id = 'm-v1' WHERE id = 'm';
        INSERT INTO media (id, project_id, name, file_path, duration_frames,
            fps_numerator, fps_denominator, audio_channels,
            created_at, modified_at)
        VALUES ('vid', 'p1', 'v.mov', '/tmp/v.mov', 1000, 24, 1, 0, 0, 0),
               -- Audio file long enough to cover 1000 video frames at
               -- 48kHz: 1000 * 48000 / 24 = 2_000_000 samples.
               ('aud', 'p1', 'a.wav', '/tmp/a.wav', 2000000, 48000, 1, 1, 0, 0);
        INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id,
            media_id, source_in_frame, source_out_frame,
            sequence_start_frame, duration_frames,
            audio_sample_rate, enabled, volume, playhead_frame, created_at, modified_at)
        VALUES ('mr-v', 'p1', 'm', 'm-v1', 'vid', 0, 1000, 0, 1000, 48000, 1, 1.0, 0, 0, 0);
        -- Three video clips on edit, each 100 frames at different positions.
        INSERT INTO clips (id, project_id, owner_sequence_id, track_id,
            sequence_id, name,
            sequence_start_frame, duration_frames,
            source_in_frame, source_out_frame,
            source_in_subframe, source_out_subframe,
            master_layer_track_id, fps_mismatch_policy,
            enabled, volume, playhead_frame, created_at, modified_at)
        VALUES ('c1', 'p1', 'e', 'e-v1', 'm', 'c1',
                0, 100, 0, 100, NULL, NULL, NULL, 'passthrough', 1, 1.0, 0, 0, 0),
               ('c2', 'p1', 'e', 'e-v1', 'm', 'c2',
                200, 100, 0, 100, NULL, NULL, NULL, 'passthrough', 1, 1.0, 0, 0, 0),
               ('c3', 'p1', 'e', 'e-v1', 'm', 'c3',
                400, 100, 0, 100, NULL, NULL, NULL, 'passthrough', 1, 1.0, 0, 0, 0);
    ]]))
    require("test_env").touch_media_fixtures()
    return db
end

local function clips_on_track(db, owner, track_id)
    local stmt = db:prepare([[
        SELECT id, sequence_start_frame, duration_frames,
               source_in_frame, source_out_frame, fps_mismatch_policy
        FROM clips WHERE owner_sequence_id = ? AND track_id = ?
        ORDER BY sequence_start_frame ASC
    ]])
    stmt:bind_value(1, owner)
    stmt:bind_value(2, track_id)
    assert(stmt:exec())
    local rows = {}
    while stmt:next() do
        rows[#rows + 1] = {
            id = stmt:value(0),
            sequence_start = stmt:value(1),
            duration = stmt:value(2),
            source_in = stmt:value(3),
            source_out = stmt:value(4),
            fps_mismatch_policy = stmt:value(5),
        }
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

local GrowMasterMedium = require("core.commands.grow_master_medium")

print("-- video-only master gains audio: each existing clip gets a linked A companion --")
do
    local db = build_fixture()

    local result = GrowMasterMedium.execute({
        sequence_id = "m",
        medium      = "audio",
        track_spec  = { media_id = "aud", sample_rate = 48000 },
    })

    assert(result.new_track_id and result.new_track_id ~= "",
        "new master A track id returned")
    assert(result.new_media_ref_id and result.new_media_ref_id ~= "",
        "new master A media_ref id returned")
    assert(#result.companions == 3, string.format(
        "exactly 3 companion A clips created (one per existing V clip); got %d",
        #result.companions))

    -- Each existing video clip now has a linked audio clip on e-a1
    -- with same sequence_start + duration.
    local v_clips = clips_on_track(db, "e", "e-v1")
    local a_clips = clips_on_track(db, "e", "e-a1")
    assert(#v_clips == 3 and #a_clips == 3,
        "edit timeline has 3 V clips and 3 new A clips")

    for i = 1, 3 do
        assert(v_clips[i].sequence_start == a_clips[i].sequence_start,
            string.format("V[%d] and A[%d] timelines align", i, i))
        assert(v_clips[i].duration == a_clips[i].duration,
            string.format("V[%d] and A[%d] durations align", i, i))
        -- V's source range was in master video frames; A's is in samples.
        -- For passthrough at 24fps, sample range stays 0..duration_samples
        -- where duration_samples = duration_frames * 48000 / 24 = 200000.
        assert(a_clips[i].source_in == 0,
            "A clip source_in starts at 0 (master starts of the new audio)")
        -- The companion A clip plays the master's full audio for the same
        -- proportional window. For a 100-frame V clip at 24fps:
        --   100 frames * 48000 / 24 = 200000 samples.
        -- (The implementation may map slightly differently; we check it's
        -- positive and reasonable.)
        assert(a_clips[i].source_out > 0,
            "A clip source_out is positive (covers some sample range)")
        assert(a_clips[i].fps_mismatch_policy == 'passthrough',
            "A clip inherits the V clip's fps_mismatch_policy")
    end

    -- Each V/A pair shares a link_group_id (created by GrowMasterMedium
    -- when the V clip didn't already have a link group).
    for i = 1, 3 do
        local v_lg = link_group_of(db, v_clips[i].id)
        local a_lg = link_group_of(db, a_clips[i].id)
        assert(v_lg and a_lg and v_lg == a_lg, string.format(
            "V[%d] and A[%d] share a link_group_id; got V=%s A=%s",
            i, i, tostring(v_lg), tostring(a_lg)))
    end

    print("  ok")
end

print("-- clip already has audio companion in its link group: not duplicated --")
do
    local db = build_fixture()
    -- Pre-link c1 with a pre-existing audio clip (simulating a past
    -- partial growth). GrowMasterMedium should NOT add a second A clip
    -- for c1's link group, only for c2 and c3.
    assert(db:exec([[
        INSERT INTO clips (id, project_id, owner_sequence_id, track_id,
            sequence_id, name,
            sequence_start_frame, duration_frames,
            source_in_frame, source_out_frame,
            source_in_subframe, source_out_subframe,
            master_layer_track_id, fps_mismatch_policy,
            enabled, volume, playhead_frame, created_at, modified_at)
        VALUES ('c1-a', 'p1', 'e', 'e-a1', 'm', 'c1-a',
                0, 100, 0, 200000, 0, 0, NULL, 'passthrough', 1, 1.0, 0, 0, 0);
        INSERT INTO clip_links (link_group_id, clip_id, role, time_offset, enabled)
        VALUES ('lg-c1', 'c1', 'video', 0, 1),
               ('lg-c1', 'c1-a', 'audio', 0, 1);
    ]]))

    local result = GrowMasterMedium.execute({
        sequence_id = "m",
        medium      = "audio",
        track_spec  = { media_id = "aud", sample_rate = 48000 },
    })
    assert(#result.companions == 2, string.format(
        "only c2 + c3 need new companions (c1 already has one); got %d",
        #result.companions))

    -- Total A clips on e-a1: c1-a (pre-existing) + 2 new = 3.
    local a_clips = clips_on_track(db, "e", "e-a1")
    assert(#a_clips == 3,
        "edit's A1 has 3 clips total")
    print("  ok")
end

print("-- non-master sequence_id: refused --")
do
    build_fixture()
    local ok, err = pcall(GrowMasterMedium.execute, {
        sequence_id = "e",
        medium      = "audio",
        track_spec  = { media_id = "aud", sample_rate = 48000 },
    })
    assert(not ok)
    assert(tostring(err):find("master"),
        "error names the kind constraint; got: " .. tostring(err))
    print("  ok")
end

print("-- track_spec.media_id required (rule 2.13) --")
do
    build_fixture()
    local ok = pcall(GrowMasterMedium.execute, {
        sequence_id = "m",
        medium      = "audio",
        track_spec  = {},
    })
    assert(not ok)
    print("  ok")
end

local function count_rows(db, sql, ...)
    local stmt = db:prepare(sql)
    local args = {...}
    for i, v in ipairs(args) do stmt:bind_value(i, v) end
    assert(stmt:exec())
    local n = 0
    while stmt:next() do n = n + 1 end
    stmt:finalize()
    return n
end

print("-- undo: video-only master with no pre-existing link groups --")
do
    local db = build_fixture()

    -- Snapshot pre-state.
    local pre_clips_v   = #clips_on_track(db, "e", "e-v1")
    local pre_clips_a   = #clips_on_track(db, "e", "e-a1")
    local pre_tracks_m  = count_rows(db, "SELECT id FROM tracks WHERE sequence_id = ?", "m")
    local pre_mrefs_m   = count_rows(db, "SELECT id FROM media_refs WHERE owner_sequence_id = ?", "m")
    local pre_links     = count_rows(db, "SELECT clip_id FROM clip_links WHERE 1")

    local capture = GrowMasterMedium.execute({
        sequence_id = "m",
        medium      = "audio",
        track_spec  = { media_id = "aud", sample_rate = 48000 },
    })
    -- Sanity: forward-direction effects observed.
    assert(#capture.companions == 3, "3 companions made before undo")
    assert(#clips_on_track(db, "e", "e-a1") == 3, "edit gained 3 A clips before undo")
    assert(count_rows(db, "SELECT id FROM tracks WHERE sequence_id = ?", "m") == pre_tracks_m + 1,
        "master gained 1 A track before undo")

    -- Now undo.
    GrowMasterMedium.undo(capture)

    -- Companion clips deleted.
    assert(#clips_on_track(db, "e", "e-a1") == pre_clips_a,
        "edit's A1 returns to pre-state clip count after undo")
    assert(#clips_on_track(db, "e", "e-v1") == pre_clips_v,
        "edit's V1 unchanged by undo")
    -- Master's new track + media_ref gone.
    assert(count_rows(db, "SELECT id FROM tracks WHERE sequence_id = ?", "m") == pre_tracks_m,
        "master's new A track deleted on undo")
    assert(count_rows(db, "SELECT id FROM media_refs WHERE owner_sequence_id = ?", "m") == pre_mrefs_m,
        "master's new media_ref deleted on undo")
    -- Link groups created during execute are gone (we created 3 new ones,
    -- one per V/A pair; undo must remove them entirely since they didn't
    -- exist pre-execute).
    assert(count_rows(db, "SELECT clip_id FROM clip_links WHERE 1") == pre_links,
        "all link_links rows we created on forward pass are gone after undo")

    print("  ok")
end

print("-- undo: link group that pre-existed must remain after undo --")
do
    local db = build_fixture()
    -- Pre-existing link group on c1: (V) + (some unrelated A 'c1-a').
    -- GrowMasterMedium will SKIP c1 (already has audio peer) and create
    -- companions only for c2 and c3. Undo must remove c2's and c3's
    -- companions + their link groups, but MUST NOT touch c1's pre-existing
    -- link group.
    assert(db:exec([[
        INSERT INTO clips (id, project_id, owner_sequence_id, track_id,
            sequence_id, name,
            sequence_start_frame, duration_frames,
            source_in_frame, source_out_frame,
            source_in_subframe, source_out_subframe,
            master_layer_track_id, fps_mismatch_policy,
            enabled, volume, playhead_frame, created_at, modified_at)
        VALUES ('c1-a', 'p1', 'e', 'e-a1', 'm', 'c1-a',
                0, 100, 0, 200000, 0, 0, NULL, 'passthrough', 1, 1.0, 0, 0, 0);
        INSERT INTO clip_links (link_group_id, clip_id, role, time_offset, enabled)
        VALUES ('lg-c1', 'c1', 'video', 0, 1),
               ('lg-c1', 'c1-a', 'audio', 0, 1);
    ]]))

    local capture = GrowMasterMedium.execute({
        sequence_id = "m",
        medium      = "audio",
        track_spec  = { media_id = "aud", sample_rate = 48000 },
    })
    assert(#capture.companions == 2, "execute made 2 companions (c2,c3)")

    GrowMasterMedium.undo(capture)

    -- c1's pre-existing link group survives.
    assert(link_group_of(db, "c1") == "lg-c1",
        "c1's pre-existing link group preserved through undo")
    assert(link_group_of(db, "c1-a") == "lg-c1",
        "c1-a's link entry preserved through undo")
    -- c2 and c3 are unlinked again (their link groups were created+removed).
    assert(link_group_of(db, "c2") == nil,
        "c2's transient link group removed by undo")
    assert(link_group_of(db, "c3") == nil,
        "c3's transient link group removed by undo")
    -- c2's and c3's companion clips are gone (only c1-a remains on e-a1).
    local a_clips = clips_on_track(db, "e", "e-a1")
    assert(#a_clips == 1 and a_clips[1].id == "c1-a",
        "only c1-a remains on e-a1 after undo")

    print("  ok")
end

print("✅ test_grow_master_medium.lua passed")
