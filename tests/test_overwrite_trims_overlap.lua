-- T033 (013): CT-C2 Overwrite contract test.
--
-- Overwrite has the same shape as Insert (writes 1 or 2 clips rows per
-- Insert-at-a-frame, linked via clip_links, with fps_mismatch_policy frozen
-- on the row) — except clips already on the target tracks that overlap the
-- new clip's [start, start + duration) are removed or trimmed, not rippled.
--
-- Contract (commands.md §Overwrite / CT-C2):
--   Given a timeline with an existing clip from [50, 150) on V1,
--   when Overwrite at frame 100 with a 60-frame nested sequence,
--   the existing clip is trimmed to [50, 100) and the new clip
--   occupies [100, 100 + duration_under_policy).
--
-- Parametrized over both policies: 25fps master (60 video frames) onto
-- 24fps timeline → duration_under_resample = round(60 * 24/25) = 58,
-- duration_under_passthrough = 60. Existing [50,150) clip is trimmed to
-- [50, 100) in both cases (the trim is in owner frames and pegs to
-- new clip's timeline_start).
--
-- Black-box: exercises overwrite.execute against a directly-built DB.

require("test_env")
local database = require("core.database")

local DB_PATH = "/tmp/jve/test_overwrite_trims_overlap.db"

local function fresh_db()
    os.remove(DB_PATH)
    assert(database.init(DB_PATH), "schema.sql init failed")
    return database.get_connection()
end

-- Fixture: project w/ policy, 25fps V-only master of 60 frames, 24fps edit
-- sequence with an existing V clip at [50, 150). Minimal — audio omitted to
-- keep occlusion math focused on the V trim case the contract specifies.
local function build_fixture(project_policy, existing_clip_policy)
    local db = fresh_db()
    assert(db:exec(string.format([[
        INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at)
        VALUES ('p1', 'p', '%s', 0, 0)
    ]], project_policy)))

    -- V-only master (60 frames at 25fps).
    assert(db:exec([[
        INSERT INTO sequences (id, project_id, name, kind,
            fps_numerator, fps_denominator, audio_sample_rate, width, height,
            default_video_layer_track_id, created_at, modified_at)
        VALUES ('m', 'p1', 'master', 'master', 25, 1, 48000, 1920, 1080,
            NULL, 0, 0)
    ]]))
    -- Second V-only master for the pre-existing clip. Independent so the
    -- test asserts interaction with "any clip on the track", not "same
    -- master".
    assert(db:exec([[
        INSERT INTO sequences (id, project_id, name, kind,
            fps_numerator, fps_denominator, audio_sample_rate, width, height,
            default_video_layer_track_id, created_at, modified_at)
        VALUES ('m-pre', 'p1', 'master-pre', 'master', 25, 1, 48000, 1920, 1080,
            NULL, 0, 0)
    ]]))
    -- Edit sequence (nested) at 24/1.
    assert(db:exec([[
        INSERT INTO sequences (id, project_id, name, kind,
            fps_numerator, fps_denominator, audio_sample_rate, width, height,
            created_at, modified_at)
        VALUES ('e', 'p1', 'edit', 'sequence', 24, 1, 48000, 1920, 1080, 0, 0)
    ]]))

    assert(db:exec([[
        INSERT INTO tracks (id, sequence_id, name, track_type, track_index)
        VALUES ('m-v1', 'm', 'V1', 'VIDEO', 1);
        INSERT INTO tracks (id, sequence_id, name, track_type, track_index)
        VALUES ('m-pre-v1', 'm-pre', 'V1', 'VIDEO', 1);
        INSERT INTO tracks (id, sequence_id, name, track_type, track_index)
        VALUES ('e-v1', 'e', 'V1', 'VIDEO', 1);
    ]]))
    assert(db:exec([[
        UPDATE sequences SET default_video_layer_track_id = 'm-v1' WHERE id = 'm';
        UPDATE sequences SET default_video_layer_track_id = 'm-pre-v1' WHERE id = 'm-pre';
    ]]))

    -- Masters' video media refs (60 frames @ 25fps for 'm', 200 frames for
    -- 'm-pre' so the pre-existing clip's source window is well-defined).
    assert(db:exec([[
        INSERT INTO media (id, project_id, name, file_path, duration_frames,
            fps_numerator, fps_denominator, audio_channels, created_at, modified_at)
        VALUES ('med-v', 'p1', 'v.mov', '/tmp/v.mov', 60, 25, 1, 0, 0, 0)
    ]]))
    assert(db:exec([[
        INSERT INTO media (id, project_id, name, file_path, duration_frames,
            fps_numerator, fps_denominator, audio_channels, created_at, modified_at)
        VALUES ('med-v-pre', 'p1', 'pre.mov', '/tmp/pre.mov', 200, 25, 1, 0, 0, 0)
    ]]))
    assert(db:exec([[
        INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id,
            media_id, source_in_frame, source_out_frame,
            timeline_start_frame, duration_frames,
            enabled, volume, playhead_frame, created_at, modified_at)
        VALUES ('mr-v', 'p1', 'm', 'm-v1', 'med-v', 0, 60, 0, 60,
            1, 1.0, 0, 0, 0)
    ]]))
    assert(db:exec([[
        INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id,
            media_id, source_in_frame, source_out_frame,
            timeline_start_frame, duration_frames,
            enabled, volume, playhead_frame, created_at, modified_at)
        VALUES ('mr-v-pre', 'p1', 'm-pre', 'm-pre-v1', 'med-v-pre',
            0, 200, 0, 200, 1, 1.0, 0, 0, 0)
    ]]))

    -- Pre-existing clip on edit.V1 at [50, 150). Uses 'passthrough' policy
    -- so source_out - source_in == duration (100 owner frames = 100 master
    -- frames since passthrough treats them 1:1). source range [0, 100)
    -- within m-pre's 200-frame native duration.
    assert(db:exec(string.format([[
        INSERT INTO clips (id, project_id, owner_sequence_id, track_id,
            sequence_id, name, timeline_start_frame, duration_frames,
            source_in_frame, source_out_frame,
            fps_mismatch_policy, enabled, volume, playhead_frame,
            created_at, modified_at)
        VALUES ('pre-v', 'p1', 'e', 'e-v1', 'm-pre',
            'pre', 50, 100, 0, 100,
            '%s', 1, 1.0, 0, 0, 0)
    ]], existing_clip_policy)))

    return {
        project_id = "p1",
        master_id = "m",
        edit_id = "e",
        edit_v1 = "e-v1",
        pre_clip_id = "pre-v",
    }
end

local function load_clip(db, id)
    local stmt = db:prepare([[
        SELECT timeline_start_frame, duration_frames,
               source_in_frame, source_out_frame,
               sequence_id, fps_mismatch_policy, enabled
        FROM clips WHERE id = ?
    ]])
    stmt:bind_value(1, id)
    assert(stmt:exec(), "load_clip: exec failed")
    if not stmt:next() then stmt:finalize(); return nil end
    local row = {
        timeline_start  = stmt:value(0),
        duration        = stmt:value(1),
        source_in       = stmt:value(2),
        source_out      = stmt:value(3),
        nested_seq_id   = stmt:value(4),
        policy          = stmt:value(5),
        enabled         = stmt:value(6),
    }
    stmt:finalize()
    return row
end

local function clips_on_track(db, track_id)
    local stmt = db:prepare([[
        SELECT id FROM clips WHERE track_id = ?
        ORDER BY timeline_start_frame
    ]])
    stmt:bind_value(1, track_id)
    assert(stmt:exec(), "clips_on_track: exec failed")
    local ids = {}
    while stmt:next() do ids[#ids + 1] = stmt:value(0) end
    stmt:finalize()
    return ids
end

local function run_case(label, new_clip_policy_arg, expected_new_policy,
                       expected_new_duration)
    print(string.format("-- case: %s --", label))
    -- existing_clip_policy is fixed at 'passthrough' per fixture so the
    -- pre-existing clip's owner/source units are 1:1; keeps the "trim to
    -- [50, 100)" assertion unambiguous.
    local ids = build_fixture("resample", "passthrough")
    local overwrite = require("core.commands.overwrite")
    assert(type(overwrite.execute) == "function",
        "T041 not yet landed: core.commands.overwrite must export .execute(args)")

    local result = overwrite.execute({
        sequence_id = ids.edit_id,
        source_sequence_id = ids.master_id,
        timeline_start_frame = 100,
        target_video_track_id = ids.edit_v1,
        fps_mismatch_policy = new_clip_policy_arg,
    })
    assert(type(result) == "table",     "overwrite.execute must return a table")
    assert(type(result.created_clip_ids) == "table",
        "overwrite.execute must return created_clip_ids list")
    assert(#result.created_clip_ids == 1,
        string.format("expected 1 new V clip; got %d", #result.created_clip_ids))
    assert(type(result.occluded) == "table",
        "overwrite.execute must return occluded capture")

    local db = database.get_connection()

    -- Pre-existing clip trimmed to [50, 100).
    local pre = load_clip(db, ids.pre_clip_id)
    assert(pre, "pre-existing clip must still exist (head-overlap trim, not delete)")
    assert(pre.timeline_start == 50, string.format(
        "pre clip timeline_start=%d expected 50", pre.timeline_start))
    assert(pre.duration == 50, string.format(
        "pre clip duration=%d expected 50 (trimmed from 100 to [50, 100))",
        pre.duration))
    -- source_out shrinks proportionally. Pre clip is passthrough 1:1, so
    -- source_out goes from 100 to 50.
    assert(pre.source_out == 50, string.format(
        "pre clip source_out=%d expected 50 (passthrough 1:1 of 50 trim)",
        pre.source_out))
    -- source_in unchanged on a tail-trim (we cut from the right).
    assert(pre.source_in == 0, string.format(
        "pre clip source_in=%d expected 0 (unchanged by tail-trim)",
        pre.source_in))

    -- New clip lives at [100, 100 + expected_duration).
    local new_id = result.created_clip_ids[1]
    local nc = load_clip(db, new_id)
    assert(nc.timeline_start == 100, "new clip must start at frame 100")
    assert(nc.duration == expected_new_duration, string.format(
        "new clip duration=%d expected %d", nc.duration, expected_new_duration))
    assert(nc.policy == expected_new_policy, string.format(
        "new clip fps_mismatch_policy=%s expected=%s",
        nc.policy, expected_new_policy))
    assert(nc.nested_seq_id == ids.master_id,
        "new clip must reference master m")
    assert(nc.source_in == 0 and nc.source_out == 60,
        string.format("new clip source window [%d,%d) expected [0,60)",
            nc.source_in, nc.source_out))

    -- Track now has exactly 2 clips: pre (trimmed) + new.
    local all = clips_on_track(db, ids.edit_v1)
    assert(#all == 2, string.format("edit V1 should have 2 clips; has %d", #all))

    print(string.format("  ok (new_duration=%d, policy=%s, pre_trimmed_to=[50,%d))",
        expected_new_duration, expected_new_policy, pre.timeline_start + pre.duration))
end

run_case("resample new clip (policy arg)", "resample", "resample", 58)
run_case("passthrough new clip (policy arg)", "passthrough", "passthrough", 60)
run_case("inherit project default (=resample)", nil, "resample", 58)

print("✅ test_overwrite_trims_overlap.lua passed")
