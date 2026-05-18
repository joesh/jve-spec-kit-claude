#!/usr/bin/env luajit

-- Test: database.load_clips returns integer frame coordinates
-- Updated for integer-based coordinates (rational refactor complete)
--
-- Verifies that clip coordinates are plain integers, NOT Rationals.
-- The fps metadata is stored separately in clip.frame_rate.

package.path = package.path
    .. ";../src/lua/?.lua"
    .. ";../src/lua/?/init.lua"
    .. ";./?.lua"
    .. ";./?/init.lua"

require("test_env")

local database = require("core.database")

local DB_PATH = "/tmp/jve/test_database_load_clips_integer.db"
os.remove(DB_PATH)

assert(database.init(DB_PATH))
local db = database.get_connection()
assert(db:exec(require("import_schema")))

print("=== database.load_clips Integer Coords Tests ===")

--------------------------------------------------------------------------------
-- Setup: Create sequence with 25fps, clip with 30000/1001 fps
--------------------------------------------------------------------------------
assert(db:exec([[

    INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at, settings)
    VALUES ('proj', 'Project', 'resample', 0, 0, '{}');

    INSERT INTO sequences (
        id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_sample_rate,
        width, height,
        view_start_frame, view_duration_frames, playhead_frame,
        selected_clip_ids, selected_edge_infos, selected_gap_infos,
        current_sequence_number, created_at, modified_at
    )
    VALUES (
        'seq', 'proj', 'Sequence', 'sequence',
        25, 1, 48000,
        1920, 1080,
        0, 250, 0,
        '[]', '[]', '[]',
        0, 0, 0
    );

    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
    VALUES ('v1', 'seq', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);

    -- V13 placeholder master sequence (was V8 NULL media_id)
INSERT INTO media (id, project_id, name, file_path, duration_frames, fps_numerator, fps_denominator, width, height, audio_channels, codec, created_at, modified_at)
VALUES ('_v13_placeholder_media', 'proj', 'placeholder', '_placeholder', 3000, 30000, 1001, 1920, 1080, 0, 'raw', 0, 0);
INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, audio_sample_rate, width, height, created_at, modified_at)
VALUES ('_v13_placeholder_master', 'proj', 'placeholder_master', 'master', 30000, 1001, NULL, 1920, 1080, 0, 0);
INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
VALUES ('_v13_placeholder_track', '_v13_placeholder_master', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
UPDATE sequences SET default_video_layer_track_id = '_v13_placeholder_track' WHERE id = '_v13_placeholder_master';
INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id, media_id, source_in_frame, source_out_frame, sequence_start_frame, duration_frames, audio_sample_rate, enabled, volume, playhead_frame, created_at, modified_at)
VALUES ('_v13_placeholder_mr', 'proj', '_v13_placeholder_master', '_v13_placeholder_track', '_v13_placeholder_media', 0, 3000, 0, 3000, 48000, 1, 1.0, 0, 0, 0);

INSERT INTO clips (id, project_id, name, track_id, sequence_id, owner_sequence_id, sequence_start_frame, duration_frames, source_in_frame, source_out_frame, enabled, created_at, modified_at, master_layer_track_id, master_audio_track_id, fps_mismatch_policy, volume, playhead_frame) VALUES
    
    ('clip1', 'proj', 'Clip', 'v1', '_v13_placeholder_master', 'seq', 1500, 100, 0, 3000, 1, 0, 0, NULL, NULL, 'resample', 1.0, 0);
]]))

--------------------------------------------------------------------------------
-- HAPPY PATH: Verify integer coordinates
--------------------------------------------------------------------------------

print("Test 1: load_clips returns integer sequence_start")
local clips = database.load_clips("seq")
assert(clips and #clips == 1, "expected exactly one clip, got " .. tostring(clips and #clips))

local clip = clips[1]
assert(type(clip.sequence_start) == "number",
    "sequence_start should be number, got " .. type(clip.sequence_start))
assert(clip.sequence_start == 1500,
    "expected sequence_start == 1500, got " .. tostring(clip.sequence_start))
print("  ✓ sequence_start is integer 1500")

print("Test 2: load_clips returns integer duration")
assert(type(clip.duration) == "number",
    "duration should be number, got " .. type(clip.duration))
assert(clip.duration == 100,
    "expected duration == 100, got " .. tostring(clip.duration))
print("  ✓ duration is integer 100")

print("Test 3: load_clips returns integer source_in")
assert(type(clip.source_in) == "number",
    "source_in should be number, got " .. type(clip.source_in))
assert(clip.source_in == 0,
    "expected source_in == 0, got " .. tostring(clip.source_in))
print("  ✓ source_in is integer 0")

print("Test 4: load_clips returns integer source_out")
assert(type(clip.source_out) == "number",
    "source_out should be number, got " .. type(clip.source_out))
assert(clip.source_out == 3000,
    "expected source_out == 3000, got " .. tostring(clip.source_out))
print("  ✓ source_out is integer 3000")

print("Test 5: clip.frame_rate contains fps metadata")
assert(clip.frame_rate, "clip should have rate metadata")
assert(clip.frame_rate.fps_numerator == 30000,
    "expected clip.frame_rate.fps_numerator == 30000, got " .. tostring(clip.frame_rate.fps_numerator))
assert(clip.frame_rate.fps_denominator == 1001,
    "expected clip.frame_rate.fps_denominator == 1001, got " .. tostring(clip.frame_rate.fps_denominator))
print("  ✓ clip.frame_rate has correct fps metadata")

print("Test 6: timeline coords are NOT Rationals (are plain numbers)")
-- Verify coords are plain numbers (Rationals would be tables)
assert(type(clip.sequence_start) == "number",
    "sequence_start should be number, not Rational table")
assert(type(clip.duration) == "number",
    "duration should be number, not Rational table")
print("  ✓ coords are plain integers, not Rationals")

print("✅ test_database_load_clips_uses_sequence_fps.lua passed")
os.remove(DB_PATH)
