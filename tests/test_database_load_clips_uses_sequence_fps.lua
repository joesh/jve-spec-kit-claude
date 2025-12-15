#!/usr/bin/env luajit

-- Regression: timeline_start/duration are stored in the owning sequence timebase,
-- even when the clip's own fps metadata differs (media/source rate).

package.path = package.path
    .. ";../src/lua/?.lua"
    .. ";../src/lua/?/init.lua"
    .. ";./?.lua"
    .. ";./?/init.lua"

require("test_env")

local database = require("core.database")

local DB_PATH = "/tmp/jve/test_database_load_clips_uses_sequence_fps.db"
os.remove(DB_PATH)

assert(database.init(DB_PATH))
local db = database.get_connection()
assert(db:exec(require("import_schema")))

assert(db:exec([[
    INSERT INTO projects (id, name, created_at, modified_at, settings)
    VALUES ('proj', 'Project', strftime('%s','now'), strftime('%s','now'), '{}');

    INSERT INTO sequences (
        id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_rate,
        width, height,
        view_start_frame, view_duration_frames, playhead_frame,
        selected_clip_ids, selected_edge_infos, selected_gap_infos,
        current_sequence_number, created_at, modified_at
    )
    VALUES (
        'seq', 'proj', 'Sequence', 'timeline',
        25, 1, 48000,
        1920, 1080,
        0, 250, 0,
        '[]', '[]', '[]',
        0, strftime('%s','now'), strftime('%s','now')
    );

    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
    VALUES ('v1', 'seq', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);

    INSERT INTO clips (
        id, project_id, clip_kind, name,
        track_id, media_id,
        source_sequence_id, parent_clip_id, owner_sequence_id,
        timeline_start_frame, duration_frames,
        source_in_frame, source_out_frame,
        enabled, offline,
        fps_numerator, fps_denominator,
        created_at, modified_at
    )
    VALUES (
        'clip1', 'proj', 'clip', 'Clip',
        'v1', NULL,
        NULL, NULL, 'seq',
        1500, 100,
        0, 3000,
        1, 0,
        30000, 1001,
        strftime('%s','now'), strftime('%s','now')
    );
]]))

local clips = database.load_clips("seq")
assert(clips and #clips == 1, "expected exactly one clip")

local clip = clips[1]
assert(clip.timeline_start and clip.timeline_start.frames == 1500, "expected timeline_start.frames == 1500")
assert(clip.duration and clip.duration.frames == 100, "expected duration.frames == 100")

assert(clip.timeline_start.fps_numerator == 25 and clip.timeline_start.fps_denominator == 1,
    "expected timeline_start to use sequence fps 25/1")
assert(clip.duration.fps_numerator == 25 and clip.duration.fps_denominator == 1,
    "expected duration to use sequence fps 25/1")

assert(clip.source_in.fps_numerator == 30000 and clip.source_in.fps_denominator == 1001,
    "expected source_in to use clip fps 30000/1001")
assert(clip.source_out.fps_numerator == 30000 and clip.source_out.fps_denominator == 1001,
    "expected source_out to use clip fps 30000/1001")

print("✅ database.load_clips uses sequence fps for timeline fields")
os.remove(DB_PATH)

