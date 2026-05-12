-- 013: Insert gap coverage — downstream ripple + single-medium masters.
--
-- CT-C1 (T032) exercises Insert into an empty track with a V+A master.
-- These scenarios are distinct behaviors not covered there:
--
--   * Downstream ripple preserves relative spacing among existing clips
--     on target tracks. An Insert at frame F with duration D shifts every
--     clip with timeline_start >= F forward by D on each target track;
--     non-target tracks are untouched (differs from legacy AddClips which
--     rippled ALL tracks).
--
--   * Video-only master → exactly 1 clip, no link_group row.
--
--   * Audio-only master → exactly 1 clip (not N per channel), no link_group.
--
-- Black-box: all assertions read DB state; values derive from domain
-- (ripple shift == inserted duration; linked pairs only when both mediums
-- present).

require("test_env")
local database = require("core.database")

local DB_PATH = "/tmp/jve/test_insert_downstream_and_single_medium.db"

local function fresh_db()
    os.remove(DB_PATH)
    assert(database.init(DB_PATH), "schema.sql init failed")
    return database.get_connection()
end

local Insert = require("core.commands.insert")
assert(type(Insert.execute) == "function",
    "core.commands.insert must export .execute")

local function clips_on_track(db, track_id)
    local stmt = db:prepare([[
        SELECT id, timeline_start_frame, duration_frames
        FROM clips WHERE track_id = ? ORDER BY timeline_start_frame
    ]])
    stmt:bind_value(1, track_id)
    assert(stmt:exec(), "clips_on_track: exec failed")
    local list = {}
    while stmt:next() do
        list[#list + 1] = {
            id = stmt:value(0),
            timeline_start = stmt:value(1),
            duration = stmt:value(2),
        }
    end
    stmt:finalize()
    return list
end

local function count_link_rows(db)
    local stmt = db:prepare("SELECT COUNT(*) FROM clip_links")
    assert(stmt:exec() and stmt:next(), "count_link_rows: exec failed")
    local n = stmt:value(0)
    stmt:finalize()
    return n
end

-- -------------------------------------------------------------------------
-- Downstream ripple: Insert at a frame with existing clips past that frame
-- on target tracks. Those clips shift forward by the insertion's owner-
-- timebase duration. Clips BEFORE the insertion frame are untouched. A
-- non-target track's clips are untouched regardless of frame position.
-- -------------------------------------------------------------------------
print("-- downstream ripple preserves spacing --")
do
    local db = fresh_db()
    -- Project + V+stereo-A master (60 frames video, 96000 samples audio
    -- = 2 seconds at 48kHz to match video wall-clock), edit seq at 24/1.
    assert(db:exec([[
        INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at)
        VALUES ('p1', 'p', 'passthrough', 0, 0);
        INSERT INTO sequences (id, project_id, name, kind,
            fps_numerator, fps_denominator, audio_sample_rate, width, height,
            created_at, modified_at)
        VALUES ('m', 'p1', 'm', 'master', 24, 1, 48000, 1920, 1080, 0, 0);
        INSERT INTO sequences (id, project_id, name, kind,
            fps_numerator, fps_denominator, audio_sample_rate, width, height,
            created_at, modified_at)
        VALUES ('m-pre', 'p1', 'pre', 'master', 24, 1, 48000, 1920, 1080, 0, 0);
        INSERT INTO sequences (id, project_id, name, kind,
            fps_numerator, fps_denominator, audio_sample_rate, width, height,
            created_at, modified_at)
        VALUES ('e', 'p1', 'edit', 'sequence', 24, 1, 48000, 1920, 1080, 0, 0);
        INSERT INTO tracks (id, sequence_id, name, track_type, track_index)
        VALUES ('m-v1', 'm', 'V1', 'VIDEO', 1),
               ('m-a1', 'm', 'A1', 'AUDIO', 1),
               ('m-pre-v1', 'm-pre', 'V1', 'VIDEO', 1),
               ('e-v1', 'e', 'V1', 'VIDEO', 1),
               ('e-v2', 'e', 'V2', 'VIDEO', 2),
               ('e-a1', 'e', 'A1', 'AUDIO', 1);
        UPDATE sequences SET default_video_layer_track_id = 'm-v1' WHERE id = 'm';
        UPDATE sequences SET default_video_layer_track_id = 'm-pre-v1' WHERE id = 'm-pre';
        INSERT INTO media (id, project_id, name, file_path, duration_frames,
            fps_numerator, fps_denominator, audio_channels, created_at, modified_at)
        VALUES ('med-v', 'p1', 'v.mov', '/tmp/v.mov', 60, 24, 1, 0, 0, 0),
               ('med-a', 'p1', 'a.wav', '/tmp/a.wav', 96000, 48000, 1, 2, 0, 0),
               ('med-v-pre', 'p1', 'pre.mov', '/tmp/pre.mov', 1000, 24, 1, 0, 0, 0);
        INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id,
            media_id, source_in_frame, source_out_frame,
            timeline_start_frame, duration_frames, enabled, volume, playhead_frame,
            created_at, modified_at)
        VALUES ('mr-v', 'p1', 'm', 'm-v1', 'med-v', 0, 60, 0, 60, 1, 1.0, 0, 0, 0),
               ('mr-a', 'p1', 'm', 'm-a1', 'med-a', 0, 96000, 0, 96000, 1, 1.0, 0, 0, 0),
               ('mr-v-pre', 'p1', 'm-pre', 'm-pre-v1', 'med-v-pre',
                    0, 1000, 0, 1000, 1, 1.0, 0, 0, 0);
    ]]))

    -- Three existing clips on edit:
    --   pre_v_early: V1 at [0, 50)        — before insertion, must NOT shift
    --   pre_v_late:  V1 at [100, 150)     — after insertion, shifts by 60
    --   pre_v2_late: V2 at [100, 150)     — non-target track, must NOT shift
    for _, row in ipairs({
        { "pre_v_early", "e-v1", 0,   50, 0 },
        { "pre_v_late",  "e-v1", 100, 50, 200 },
        { "pre_v2_late", "e-v2", 100, 50, 400 },
    }) do
        assert(db:exec(string.format([[
            INSERT INTO clips (id, project_id, owner_sequence_id, track_id,
                sequence_id, name, timeline_start_frame, duration_frames,
                source_in_frame, source_out_frame,
                fps_mismatch_policy, enabled, volume, playhead_frame,
                created_at, modified_at)
            VALUES ('%s', 'p1', 'e', '%s', 'm-pre', '%s', %d, %d, %d, %d,
                'passthrough', 1, 1.0, 0, 0, 0)
        ]], row[1], row[2], row[1], row[3], row[4], row[5], row[5] + row[4])))
    end

    -- Insert at frame 50 — V+A master, 60 owner frames under passthrough.
    -- Target tracks: V1 (explicit) + A1 (default pick).
    Insert.execute({
        sequence_id = "e", source_sequence_id = "m",
        timeline_start_frame = 50,
        target_video_track_id = "e-v1",
        fps_mismatch_policy = "passthrough",
    })

    -- V1: pre_v_early [0, 50) untouched; pre_v_late shifted from [100, 150)
    -- to [160, 210); new inserted at [50, 110). So V1 has 3 clips in order:
    --   [0, 50), [50, 110) new, [160, 210).
    local v1 = clips_on_track(db, "e-v1")
    assert(#v1 == 3, string.format("V1 should have 3 clips; got %d", #v1))
    assert(v1[1].id == "pre_v_early"
           and v1[1].timeline_start == 0 and v1[1].duration == 50,
        "pre_v_early must be untouched")
    assert(v1[2].timeline_start == 50 and v1[2].duration == 60,
        string.format("new V clip at [50, 110); got [%d, %d)",
            v1[2].timeline_start, v1[2].timeline_start + v1[2].duration))
    assert(v1[3].id == "pre_v_late"
           and v1[3].timeline_start == 160 and v1[3].duration == 50,
        string.format("pre_v_late expected shifted to [160,210); got [%d,%d)",
            v1[3].timeline_start, v1[3].timeline_start + v1[3].duration))

    -- V2: non-target track. pre_v2_late must be untouched at [100, 150).
    local v2 = clips_on_track(db, "e-v2")
    assert(#v2 == 1 and v2[1].id == "pre_v2_late"
           and v2[1].timeline_start == 100 and v2[1].duration == 50,
        "pre_v2_late on V2 (non-target) must be untouched by Insert's ripple")

    -- A1 is a target track; only the new A clip. No pre-existing clips to
    -- ripple. One clip at [50, 110).
    local a1 = clips_on_track(db, "e-a1")
    assert(#a1 == 1 and a1[1].timeline_start == 50 and a1[1].duration == 60,
        "A1 should have just the new A clip at [50, 110)")

    print("  ok")
end

-- -------------------------------------------------------------------------
-- Video-only master: 1 clip, no link_group.
-- -------------------------------------------------------------------------
print("-- video-only master = 1 clip, no link group --")
do
    local db = fresh_db()
    assert(db:exec([[
        INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at)
        VALUES ('p1', 'p', 'passthrough', 0, 0);
        INSERT INTO sequences (id, project_id, name, kind,
            fps_numerator, fps_denominator, audio_sample_rate, width, height,
            created_at, modified_at)
        VALUES ('m', 'p1', 'm', 'master', 24, 1, 48000, 1920, 1080, 0, 0);
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
            fps_numerator, fps_denominator, audio_channels, created_at, modified_at)
        VALUES ('med-v', 'p1', 'v.mov', '/tmp/v.mov', 100, 24, 1, 0, 0, 0);
        INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id,
            media_id, source_in_frame, source_out_frame,
            timeline_start_frame, duration_frames, enabled, volume, playhead_frame,
            created_at, modified_at)
        VALUES ('mr-v', 'p1', 'm', 'm-v1', 'med-v', 0, 100, 0, 100, 1, 1.0, 0, 0, 0);
    ]]))

    local result = Insert.execute({
        sequence_id = "e", source_sequence_id = "m",
        timeline_start_frame = 0,
        fps_mismatch_policy = "passthrough",
    })

    assert(#result.created_clip_ids == 1,
        string.format("V-only master yields 1 clip; got %d",
            #result.created_clip_ids))
    assert(result.video_clip_id and not result.audio_clip_id,
        "video-only master should yield video_clip_id set and audio_clip_id nil")
    assert(result.link_group_id == nil,
        "single-medium Insert must not create a link group")
    assert(count_link_rows(db) == 0,
        "clip_links table must be empty for single-medium Insert")
    assert(#clips_on_track(db, "e-v1") == 1, "V1 should have 1 clip")
    assert(#clips_on_track(db, "e-a1") == 0,
        "A1 must have no clip (V-only master)")
    print("  ok")
end

-- -------------------------------------------------------------------------
-- Audio-only master: 1 clip on A track, no link_group.
-- -------------------------------------------------------------------------
print("-- audio-only master = 1 A clip, no link group --")
do
    local db = fresh_db()
    assert(db:exec([[
        INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at)
        VALUES ('p1', 'p', 'passthrough', 0, 0);
        INSERT INTO sequences (id, project_id, name, kind,
            fps_numerator, fps_denominator, audio_sample_rate, width, height,
            created_at, modified_at)
        VALUES ('m', 'p1', 'm', 'master', 24, 1, 48000, 1920, 1080, 0, 0);
        INSERT INTO sequences (id, project_id, name, kind,
            fps_numerator, fps_denominator, audio_sample_rate, width, height,
            created_at, modified_at)
        VALUES ('e', 'p1', 'edit', 'sequence', 24, 1, 48000, 1920, 1080, 0, 0);
        INSERT INTO tracks (id, sequence_id, name, track_type, track_index)
        VALUES ('m-a1', 'm', 'A1', 'AUDIO', 1),
               ('e-v1', 'e', 'V1', 'VIDEO', 1),
               ('e-a1', 'e', 'A1', 'AUDIO', 1);
        INSERT INTO media (id, project_id, name, file_path, duration_frames,
            fps_numerator, fps_denominator, audio_channels, created_at, modified_at)
        VALUES ('med-a', 'p1', 'a.wav', '/tmp/a.wav', 48000, 48000, 1, 2, 0, 0);
        INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id,
            media_id, source_in_frame, source_out_frame,
            timeline_start_frame, duration_frames, enabled, volume, playhead_frame,
            created_at, modified_at)
        VALUES ('mr-a', 'p1', 'm', 'm-a1', 'med-a', 0, 48000, 0, 48000,
            1, 1.0, 0, 0, 0);
    ]]))

    local result = Insert.execute({
        sequence_id = "e", source_sequence_id = "m",
        timeline_start_frame = 0,
        fps_mismatch_policy = "passthrough",
    })

    assert(#result.created_clip_ids == 1,
        "A-only master yields 1 clip")
    assert(result.audio_clip_id and not result.video_clip_id,
        "audio-only master should yield audio_clip_id set and video_clip_id nil")
    assert(result.link_group_id == nil,
        "single-medium Insert must not create a link group")
    assert(count_link_rows(db) == 0, "clip_links must be empty")
    assert(#clips_on_track(db, "e-v1") == 0,
        "V1 must have no clip (A-only master)")
    assert(#clips_on_track(db, "e-a1") == 1, "A1 should have 1 clip")

    -- audio-only owner_duration computes from audio samples via
    -- nested.audio_sample_rate: 48000 samples / 48000 Hz = 1 second;
    -- at owner 24/1 = 24 owner frames. Domain-derived; not from code.
    local a1 = clips_on_track(db, "e-a1")
    assert(a1[1].timeline_start == 0 and a1[1].duration == 24, string.format(
        "A-only owner duration expected 24 (48000 samples @ 48k → 1s @ 24fps); got [%d,%d)",
        a1[1].timeline_start, a1[1].timeline_start + a1[1].duration))
    print("  ok")
end

print("✅ test_insert_downstream_and_single_medium.lua passed")
