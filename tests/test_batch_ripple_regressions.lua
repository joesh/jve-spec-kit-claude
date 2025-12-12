#!/usr/bin/env luajit

require("test_env")

local Command = require("command")
local command_manager = require("core.command_manager")
local Clip = require("models.clip")
local ripple_layout = require("tests.helpers.ripple_layout")
local database = require("core.database")
local SCHEMA_SQL = require("import_schema")

local function compute_gap_frames(left_clip, right_clip)
    return right_clip.timeline_start.frames - (left_clip.timeline_start.frames + left_clip.duration.frames)
end

local function build_manual_timeline(config)
    local db_path = config.db_path
    os.remove(db_path)
    assert(database.init(db_path))
    local db = database.get_connection()
    assert(db:exec(SCHEMA_SQL))
    local now = os.time()
    assert(db:exec(string.format([[
        INSERT INTO projects (id, name, created_at, modified_at)
        VALUES ('default_project', 'Default', %d, %d);

        INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, audio_rate,
                               width, height, view_start_frame, view_duration_frames, playhead_frame,
                               created_at, modified_at)
        VALUES ('default_sequence', 'default_project', 'Timeline', 'timeline',
                1000, 1, 48000, 1920, 1080, 0, 6000, 0, %d, %d);

        INSERT INTO media (id, project_id, name, file_path, duration_frames, fps_numerator, fps_denominator,
                           width, height, audio_channels, codec, metadata, created_at, modified_at)
        VALUES ('media_main', 'default_project', 'Media', 'synthetic://main', 24000, 1000, 1, 1920, 1080, 0, 'raw', '{}', %d, %d);
    ]], now, now, now, now, now, now)))

    for _, track in ipairs(config.tracks or {}) do
        assert(db:exec(string.format([[INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
            VALUES ('%s', 'default_sequence', '%s', '%s', %d, 1);]],
            track.id, track.name, track.track_type or "VIDEO", track.index or 1)))
    end

    for _, clip in ipairs(config.clips or {}) do
        assert(db:exec(string.format([[INSERT INTO clips (
            id, project_id, clip_kind, name, track_id, media_id, owner_sequence_id,
            timeline_start_frame, duration_frames, source_in_frame, source_out_frame,
            fps_numerator, fps_denominator, enabled, offline, created_at, modified_at)
            VALUES ('%s', 'default_project', 'timeline', '%s', '%s', 'media_main', 'default_sequence',
                    %d, %d, 0, %d, 1000, 1, 1, 0, %d, %d);]],
            clip.id, clip.name, clip.track_id, clip.timeline_start, clip.duration, clip.source_out or clip.duration,
            now, now)))
    end

    command_manager.init(db, "default_sequence", "default_project")
    return {db = db, project_id = "default_project", sequence_id = "default_sequence"}
end
-- Scenario 1: gap_before only selection should shrink the gap when dragged left.
do
    local TEST_DB = "/tmp/jve/test_batch_ripple_gap_before_only.db"
    local layout = ripple_layout.create({
        db_path = TEST_DB,
        clips = {
            v1_left = {timeline_start = 0, duration = 1000},
            v1_right = {timeline_start = 3200, duration = 800},
            v2 = {timeline_start = 1800, duration = 900}
        }
    })
    local clips = layout.clips
    local tracks = layout.tracks

    local left_before = Clip.load(clips.v1_left.id, layout.db)
    local right_before = Clip.load(clips.v1_right.id, layout.db)
    local gap_frames_before = compute_gap_frames(left_before, right_before)

    local cmd = Command.create("BatchRippleEdit", layout.project_id)
    cmd:set_parameter("sequence_id", layout.sequence_id)
    cmd:set_parameter("edge_infos", {
        {clip_id = clips.v1_right.id, edge_type = "gap_before", track_id = tracks.v1.id, trim_type = "ripple"}
    })
    cmd:set_parameter("delta_frames", -400)

    local result = command_manager.execute(cmd)
    assert(result.success, result.error_message or "gap_before ripple failed")

    local left_after = Clip.load(clips.v1_left.id, layout.db)
    local right_after = Clip.load(clips.v1_right.id, layout.db)
    local gap_frames_after = compute_gap_frames(left_after, right_after)

    assert(right_after.timeline_start.frames == right_before.timeline_start.frames - 400,
        string.format("gap_before trim should move right clip left; expected %d, got %d",
            right_before.timeline_start.frames - 400, right_after.timeline_start.frames))
    assert(gap_frames_after == gap_frames_before - 400,
        string.format("Gap should shrink by 400 frames; expected %d, got %d",
            gap_frames_before - 400, gap_frames_after))

    layout:cleanup()
end

-- Scenario 2: Gap + clip roll should remain local (no downstream shifts).
do
    local TEST_DB = "/tmp/jve/test_batch_ripple_gap_roll.db"
    local layout = ripple_layout.create({
        db_path = TEST_DB,
        clips = {
            v1_left = {timeline_start = 0, duration = 1000},
            v1_right = {timeline_start = 2500, duration = 800}
        }
    })
    local clips = layout.clips
    local tracks = layout.tracks

    local cmd = Command.create("BatchRippleEdit", layout.project_id)
    cmd:set_parameter("sequence_id", layout.sequence_id)
    cmd:set_parameter("dry_run", true)
    cmd:set_parameter("edge_infos", {
        {clip_id = clips.v1_left.id, edge_type = "gap_after", track_id = tracks.v1.id, trim_type = "roll"},
        {clip_id = clips.v1_right.id, edge_type = "in", track_id = tracks.v1.id, trim_type = "roll"}
    })
    cmd:set_parameter("delta_frames", 200)

    local executor = command_manager.get_executor("BatchRippleEdit")
    local ok, payload = executor(cmd)
    assert(ok, payload or "Gap roll dry run failed")
    for _, entry in ipairs(payload.shifted_clips or {}) do
        assert(entry.clip_id ~= clips.v1_right.id, "Gap roll should not shift real timeline clips")
    end

    -- Execute for real and ensure downstream clip stays put.
    cmd:set_parameter("dry_run", nil)
    local result = command_manager.execute(cmd)
    assert(result.success, result.error_message or "Gap roll execute failed")

    local right_after = Clip.load(clips.v1_right.id, layout.db)
    assert(right_after.timeline_start.frames == clips.v1_right.timeline_start + 200,
        string.format("Gap roll should push the trailing clip right by 200, got %d", right_after.timeline_start.frames))

    layout:cleanup()
end

-- Scenario 3: Conflicting roll constraints (overlapping clips) collapse the delta to zero.
do
    local TEST_DB = "/tmp/jve/test_batch_ripple_roll_conflict.db"
    local layout = ripple_layout.create({
        db_path = TEST_DB,
        clips = {
            v1_left = {timeline_start = 0, duration = 1000},
            v1_right = {timeline_start = 2000, duration = 900}
        }
    })
    local clips = layout.clips
    local tracks = layout.tracks

    local cmd = Command.create("BatchRippleEdit", layout.project_id)
    cmd:set_parameter("sequence_id", layout.sequence_id)
    cmd:set_parameter("edge_infos", {
        {clip_id = clips.v1_left.id, edge_type = "out", track_id = tracks.v1.id, trim_type = "roll"},
        {clip_id = clips.v1_right.id, edge_type = "in", track_id = tracks.v1.id, trim_type = "roll"}
    })
    cmd:set_parameter("delta_frames", 500)
    cmd:set_parameter("__force_conflict_delta", true)

    local result = command_manager.execute(cmd)
    assert(result.success, result.error_message or "Roll conflict execute failed")

    local left_after = Clip.load(clips.v1_left.id, layout.db)
    local right_after = Clip.load(clips.v1_right.id, layout.db)

    assert(left_after.duration.frames == clips.v1_left.duration,
        "Conflicting roll constraints should leave the first clip unchanged")
    assert(right_after.timeline_start.frames == clips.v1_right.timeline_start,
        "Conflicting roll constraints should leave the second clip unchanged")

    local clamped = cmd:get_parameter("clamped_delta_ms")
    assert(clamped == 0, "Conflicting constraints should clamp the delta to zero")

    layout:cleanup()
end

-- Scenario 4: Gap + clip roll at the same edit point keeps downstream clips stationary.
do
    local TEST_DB = "/tmp/jve/test_batch_ripple_gap_partner_roll.db"
    local layout = build_manual_timeline({
        db_path = TEST_DB,
        tracks = {
            {id = "track_v1", name = "Video 1", index = 1}
        },
        clips = {
            {id = "clip_left", name = "Left", track_id = "track_v1", timeline_start = 0, duration = 1000},
            {id = "clip_gap", name = "GapClip", track_id = "track_v1", timeline_start = 2200, duration = 600},
            {id = "clip_downstream", name = "Downstream", track_id = "track_v1", timeline_start = 3200, duration = 500}
        }
    })

    local cmd = Command.create("BatchRippleEdit", layout.project_id)
    cmd:set_parameter("sequence_id", layout.sequence_id)
    cmd:set_parameter("edge_infos", {
        {clip_id = "clip_left", edge_type = "gap_after", track_id = "track_v1", trim_type = "roll"},
        {clip_id = "clip_gap", edge_type = "in", track_id = "track_v1", trim_type = "roll"}
    })
    cmd:set_parameter("delta_frames", 200)

    local result = command_manager.execute(cmd)
    assert(result.success, result.error_message or "Gap partner roll execute failed")

    local downstream = Clip.load("clip_downstream", layout.db)
    assert(downstream.timeline_start.frames == 3200,
        "Gap roll with partner clip should not shift downstream clips")

    os.remove(TEST_DB)
end

-- Scenario 5: Retry path triggers when downstream shift exceeds available room.
do
    local TEST_DB = "/tmp/jve/test_batch_ripple_retry_path.db"
    local layout = build_manual_timeline({
        db_path = TEST_DB,
        tracks = {
            {id = "track_v1", name = "Video 1", index = 1}
        },
        clips = {
            {id = "clip_left", name = "Left", track_id = "track_v1", timeline_start = 0, duration = 1000},
            {id = "clip_right", name = "Right", track_id = "track_v1", timeline_start = 1800, duration = 700},
            {id = "clip_blocker", name = "Blocker", track_id = "track_v1", timeline_start = 2600, duration = 600},
            {id = "clip_tail", name = "Tail", track_id = "track_v1", timeline_start = 3400, duration = 400}
        }
    })

    local cmd = Command.create("BatchRippleEdit", layout.project_id)
    cmd:set_parameter("sequence_id", layout.sequence_id)
    cmd:set_parameter("edge_infos", {
        {clip_id = "clip_right", edge_type = "out", track_id = "track_v1", trim_type = "ripple"}
    })
    cmd:set_parameter("delta_frames", 500)
    cmd:set_parameter("__force_retry_delta", 200)

    local result = command_manager.execute(cmd)
    assert(result.success, result.error_message or "Retry scenario execute failed")

    local blocker_after = Clip.load("clip_blocker", layout.db)
    assert(blocker_after.timeline_start.frames == 2800,
        "Downstream clip should shift only by the clamped amount")

    os.remove(TEST_DB)
end

-- Scenario 6: Multi-track asymmetric shifts honor per-track orientations.
do
    local TEST_DB = "/tmp/jve/test_batch_ripple_multitrack_asym.db"
    local layout = build_manual_timeline({
        db_path = TEST_DB,
        tracks = {
            {id = "track_v1", name = "Video 1", index = 1},
            {id = "track_v2", name = "Video 2", index = 2}
        },
        clips = {
            {id = "clip_v1_left", name = "V1 Left", track_id = "track_v1", timeline_start = 0, duration = 1000},
            {id = "clip_v1_right", name = "V1 Right", track_id = "track_v1", timeline_start = 2600, duration = 600},
            {id = "clip_v2_left", name = "V2 Left", track_id = "track_v2", timeline_start = 0, duration = 1000},
            {id = "clip_v2_right", name = "V2 Right", track_id = "track_v2", timeline_start = 2600, duration = 600}
        }
    })

    local cmd = Command.create("BatchRippleEdit", layout.project_id)
    cmd:set_parameter("sequence_id", layout.sequence_id)
    cmd:set_parameter("dry_run", true)
    cmd:set_parameter("edge_infos", {
        {clip_id = "clip_v1_left", edge_type = "out", track_id = "track_v1", trim_type = "ripple"},
        {clip_id = "clip_v2_left", edge_type = "in", track_id = "track_v2", trim_type = "ripple"}
    })
    cmd:set_parameter("lead_edge", {clip_id = "clip_v1_left", edge_type = "out", track_id = "track_v1", trim_type = "ripple"})
    cmd:set_parameter("delta_frames", 300)

    local executor = command_manager.get_executor("BatchRippleEdit")
    local ok, payload = executor(cmd)
    assert(ok and payload, payload or "Multitrack dry run failed")

    local function find_shift(clip_id)
        for _, entry in ipairs(payload.shifted_clips or {}) do
            if entry.clip_id == clip_id then
                return entry
            end
        end
    end

    local v1_shift = find_shift("clip_v1_right")
    local v2_shift = find_shift("clip_v2_right")
    assert(v1_shift and v1_shift.new_start_value.frames == 2900,
        "Track V1 downstream clip should move right by the delta")
    assert(v2_shift and v2_shift.new_start_value.frames == 2300,
        "Track V2 downstream clip should move left because its lead edge is an in-bracket")

    os.remove(TEST_DB)
end

print("✅ BatchRippleEdit regression scenarios verified")
