-- T032 (013): CT-C1 Insert contract test.
--
-- Given a master sequence with V + stereo audio, when Insert at a frame on a
-- nested edit sequence, the clips table has exactly 2 new rows (one V, one A —
-- NOT per-channel — channels live in media_refs_channel_state / clip_channel_
-- override and are resolved at playback, per FR-003 and resolver.md §CT-R5).
-- Both clips reference the master via nested_sequence_id; master_layer_track_id
-- is NULL (tracks master default); fps_mismatch_policy is non-NULL (frozen at
-- Insert per data-model.md §Decisions). One clip_links.link_group_id groups
-- them.
--
-- Parametrized over both policies:
--   25fps master (100 frames in its timebase) inserted onto 24fps timeline
--   resample    → duration_frames = round(100 * 24/25) = 96
--   passthrough → duration_frames = 100
-- source_out_frame = 100 in both (master's native-timebase duration).
--
-- Black-box: exercises the insert command's pure execute entry point against
-- a DB built via direct SQL. Does NOT go through command_manager (its pre-hash
-- path reads columns dropped by V9; that's T042+ territory).

require("test_env")
local database = require("core.database")

local DB_PATH = "/tmp/jve/test_insert_creates_linked_clips.db"

local function fresh_db()
    os.remove(DB_PATH)
    assert(database.init(DB_PATH), "schema.sql init failed")
    local db = database.get_connection()
    assert(db, "no db connection")
    return db
end

-- Build a project + 25fps master with V + stereo A + 24fps edit sequence.
-- Returns the ids of interest.
local function build_fixture(project_fps_mismatch_policy)
    local db = fresh_db()
    assert(db:exec(string.format(
        [[INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at)
          VALUES ('p1', 'p', '%s', 0, 0)]], project_fps_mismatch_policy)))

    -- Master at 25/1, stereo 48k audio, 1920x1080.
    assert(db:exec([[
        INSERT INTO sequences (id, project_id, name, kind,
            fps_numerator, fps_denominator, audio_rate, width, height,
            created_at, modified_at)
        VALUES ('m', 'p1', 'master', 'master', 25, 1, 48000, 1920, 1080, 0, 0)
    ]]))
    -- Edit sequence (nested) at 24/1.
    assert(db:exec([[
        INSERT INTO sequences (id, project_id, name, kind,
            fps_numerator, fps_denominator, audio_rate, width, height,
            created_at, modified_at)
        VALUES ('e', 'p1', 'edit', 'nested', 24, 1, 48000, 1920, 1080, 0, 0)
    ]]))

    -- Tracks.
    assert(db:exec([[
        INSERT INTO tracks (id, sequence_id, name, track_type, track_index)
        VALUES ('m-v1', 'm', 'V1', 'VIDEO', 1);
        INSERT INTO tracks (id, sequence_id, name, track_type, track_index)
        VALUES ('m-a1', 'm', 'A1', 'AUDIO', 1);
        INSERT INTO tracks (id, sequence_id, name, track_type, track_index)
        VALUES ('e-v1', 'e', 'V1', 'VIDEO', 1);
        INSERT INTO tracks (id, sequence_id, name, track_type, track_index)
        VALUES ('e-a1', 'e', 'A1', 'AUDIO', 1);
    ]]))

    -- Master's default video layer — INV-8 requires non-NULL when a master has
    -- any video track.
    assert(db:exec([[
        UPDATE sequences SET default_video_layer_track_id = 'm-v1' WHERE id = 'm'
    ]]))

    -- Media rows. Video: 100 frames @ 25fps. Audio: 192000 samples stereo
    -- (4 seconds at 48kHz, matches the 100-frame/25fps video wall-clock).
    assert(db:exec([[
        INSERT INTO media (id, project_id, name, file_path, duration_frames,
            fps_numerator, fps_denominator, audio_channels, created_at, modified_at)
        VALUES ('med-v', 'p1', 'v.mov', '/tmp/v.mov', 100, 25, 1, 0, 0, 0)
    ]]))
    assert(db:exec([[
        INSERT INTO media (id, project_id, name, file_path, duration_frames,
            fps_numerator, fps_denominator, audio_channels, created_at, modified_at)
        VALUES ('med-a', 'p1', 'a.wav', '/tmp/a.wav', 192000, 48000, 1, 2, 0, 0)
    ]]))

    -- Media refs inside the master (V1 + A1, full range).
    assert(db:exec([[
        INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id,
            media_id, source_in_frame, source_out_frame,
            timeline_start_frame, duration_frames,
            enabled, volume, playhead_frame, created_at, modified_at)
        VALUES ('mr-v', 'p1', 'm', 'm-v1', 'med-v', 0, 100, 0, 100,
            1, 1.0, 0, 0, 0)
    ]]))
    assert(db:exec([[
        INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id,
            media_id, source_in_frame, source_out_frame,
            timeline_start_frame, duration_frames,
            enabled, volume, playhead_frame, created_at, modified_at)
        VALUES ('mr-a', 'p1', 'm', 'm-a1', 'med-a', 0, 192000, 0, 192000,
            1, 1.0, 0, 0, 0)
    ]]))

    return {
        project_id = "p1",
        master_id = "m",
        edit_id = "e",
        edit_v1 = "e-v1",
        edit_a1 = "e-a1",
    }
end

local function count_clips_on(db, track_id)
    local stmt = db:prepare("SELECT COUNT(*) FROM clips WHERE track_id = ?")
    stmt:bind_value(1, track_id)
    assert(stmt:exec() and stmt:next(), "count_clips_on: exec failed")
    local n = stmt:value(0)
    stmt:finalize()
    return n
end

local function load_clip_row(db, clip_id)
    local stmt = db:prepare([[
        SELECT id, owner_sequence_id, track_id, nested_sequence_id,
               source_in_frame, source_out_frame,
               timeline_start_frame, duration_frames,
               master_layer_track_id, fps_mismatch_policy,
               name, enabled, volume, playhead_frame
        FROM clips WHERE id = ?
    ]])
    stmt:bind_value(1, clip_id)
    assert(stmt:exec(), "load_clip_row: exec failed")
    assert(stmt:next(), "load_clip_row: not found: " .. tostring(clip_id))
    local row = {
        id                     = stmt:value(0),
        owner_sequence_id      = stmt:value(1),
        track_id               = stmt:value(2),
        nested_sequence_id     = stmt:value(3),
        source_in_frame        = stmt:value(4),
        source_out_frame       = stmt:value(5),
        timeline_start_frame   = stmt:value(6),
        duration_frames        = stmt:value(7),
        master_layer_track_id  = stmt:value(8),
        fps_mismatch_policy    = stmt:value(9),
        name                   = stmt:value(10),
        enabled                = stmt:value(11),
        volume                 = stmt:value(12),
        playhead_frame         = stmt:value(13),
    }
    stmt:finalize()
    return row
end

local function link_group_of(db, clip_id)
    local stmt = db:prepare("SELECT link_group_id FROM clip_links WHERE clip_id = ?")
    stmt:bind_value(1, clip_id)
    assert(stmt:exec(), "link_group_of: exec failed")
    if not stmt:next() then stmt:finalize(); return nil end
    local gid = stmt:value(0)
    stmt:finalize()
    return gid
end

local function clips_on_track(db, track_id)
    local stmt = db:prepare(
        "SELECT id FROM clips WHERE track_id = ? ORDER BY timeline_start_frame")
    stmt:bind_value(1, track_id)
    assert(stmt:exec(), "clips_on_track: exec failed")
    local ids = {}
    while stmt:next() do ids[#ids + 1] = stmt:value(0) end
    stmt:finalize()
    return ids
end

-- Exercise the contract: one case per policy.
local function run_case(label, project_policy, explicit_arg_policy,
                       expected_policy, expected_duration_frames)
    print(string.format("-- case: %s --", label))
    local ids = build_fixture(project_policy)
    local insert_mod = require("core.commands.insert")
    assert(type(insert_mod.execute) == "function",
        "T040 not yet landed: core.commands.insert must export .execute(args)")

    local result = insert_mod.execute({
        sequence_id = ids.edit_id,
        nested_sequence_id = ids.master_id,
        timeline_start_frame = 0,
        target_video_track_id = ids.edit_v1,
        target_audio_track_id = ids.edit_a1,
        fps_mismatch_policy = explicit_arg_policy,  -- nil = inherit
    })
    assert(type(result) == "table", "insert.execute must return a table")
    assert(type(result.created_clip_ids) == "table",
        "insert.execute must return created_clip_ids")
    assert(#result.created_clip_ids == 2, string.format(
        "expected 2 created clips; got %d", #result.created_clip_ids))
    assert(type(result.link_group_id) == "string" and result.link_group_id ~= "",
        "insert.execute must return a link_group_id for V+A linked pair")

    -- One clip on each target track.
    local db = database.get_connection()
    local v_clips = clips_on_track(db, ids.edit_v1)
    local a_clips = clips_on_track(db, ids.edit_a1)
    assert(#v_clips == 1, string.format(
        "expected 1 clip on V1; got %d (clip ids=%s)",
        #v_clips, table.concat(v_clips, ",")))
    assert(#a_clips == 1, string.format(
        "expected 1 clip on A1 (not N-per-channel); got %d",
        #a_clips))

    -- NO per-channel audio rows (FR-001 / FR-003 semantics — a single stereo
    -- Insert creates one A clip, channels live in override tables).
    assert(count_clips_on(db, "m-v1") == 0, "master V1 must not have clips")
    assert(count_clips_on(db, "m-a1") == 0, "master A1 must not have clips")

    local vc = load_clip_row(db, v_clips[1])
    local ac = load_clip_row(db, a_clips[1])

    -- Fields shared by both V and A: owner/nested, layer override NULL,
    -- policy frozen, source_in 0, timeline_start 0, owner-timebase duration,
    -- enabled, name.
    for _, c in ipairs({ vc, ac }) do
        assert(c.owner_sequence_id == ids.edit_id, string.format(
            "clip %s owner_sequence_id=%s expected=%s",
            c.id, c.owner_sequence_id, ids.edit_id))
        assert(c.nested_sequence_id == ids.master_id, string.format(
            "clip %s nested_sequence_id=%s expected=%s",
            c.id, c.nested_sequence_id, ids.master_id))
        assert(c.master_layer_track_id == nil,
            string.format("clip %s master_layer_track_id must be NULL (inherit master default); got %s",
                c.id, tostring(c.master_layer_track_id)))
        assert(c.fps_mismatch_policy == expected_policy, string.format(
            "clip %s fps_mismatch_policy=%s expected=%s",
            c.id, tostring(c.fps_mismatch_policy), expected_policy))
        assert(c.source_in_frame == 0, string.format(
            "clip %s source_in_frame=%d expected 0", c.id, c.source_in_frame))
        assert(c.timeline_start_frame == 0, string.format(
            "clip %s timeline_start_frame=%d expected 0",
            c.id, c.timeline_start_frame))
        assert(c.duration_frames == expected_duration_frames, string.format(
            "clip %s duration_frames=%d expected %d (%s)",
            c.id, c.duration_frames, expected_duration_frames, expected_policy))
        assert(c.enabled == 1, string.format("clip %s enabled must be 1", c.id))
        assert(type(c.name) == "string" and c.name ~= "",
            "clip name must be non-empty string (schema NOT NULL)")
    end

    -- Per-medium source_out: different units on purpose. Video clip's
    -- source range is in master video frames (100 at 25fps); audio clip's
    -- is in master audio samples (192000 at 48kHz) — both four wall-clock
    -- seconds, different unit systems.
    assert(vc.source_out_frame == 100, string.format(
        "video clip source_out_frame=%d expected 100 (master video frames)",
        vc.source_out_frame))
    assert(ac.source_out_frame == 192000, string.format(
        "audio clip source_out_frame=%d expected 192000 (master audio samples)",
        ac.source_out_frame))

    -- Link group: one id shared between the V and A clips.
    local gv = link_group_of(db, vc.id)
    local ga = link_group_of(db, ac.id)
    assert(gv ~= nil, "V clip must have a clip_links row")
    assert(ga ~= nil, "A clip must have a clip_links row")
    assert(gv == ga, string.format(
        "V and A clips must share link_group_id; got V=%s A=%s",
        tostring(gv), tostring(ga)))
    assert(gv == result.link_group_id, "returned link_group_id must match DB")

    print(string.format("  ok (duration=%d, policy=%s, link_group=%s)",
        expected_duration_frames, expected_policy, gv:sub(1, 8)))
end

-- Case A: project default is resample, no explicit arg → resample, 96 frames.
run_case("project resample, inherit",
    "resample", nil, "resample", 96)

-- Case B: project default is resample but explicit arg overrides to
-- passthrough, 100 frames.
run_case("explicit passthrough overrides project default",
    "resample", "passthrough", "passthrough", 100)

-- Case C: project default is passthrough, no explicit arg → passthrough, 100.
run_case("project passthrough, inherit",
    "passthrough", nil, "passthrough", 100)

-- Case D: project default is passthrough but explicit resample arg → resample,
-- 96 frames.
run_case("explicit resample overrides project default",
    "passthrough", "resample", "resample", 96)

print("✅ test_insert_creates_linked_clips.lua passed")
