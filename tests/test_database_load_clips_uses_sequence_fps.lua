#!/usr/bin/env luajit

-- Test: database.load_clips returns integer frame coordinates
-- Updated for integer-based coordinates (rational refactor complete)
--
-- Verifies that clip coordinates are plain integers, NOT Rationals.
-- The fps metadata is stored separately in clip.rate.

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
        master_clip_id, owner_sequence_id,
        timeline_start_frame, duration_frames,
        source_in_frame, source_out_frame,
        enabled, offline,
        fps_numerator, fps_denominator,
        created_at, modified_at
    )
    VALUES (
        'clip1', 'proj', 'timeline', 'Clip',
        'v1', NULL,
        NULL, 'seq',
        1500, 100,
        0, 3000,
        1, 0,
        30000, 1001,
        strftime('%s','now'), strftime('%s','now')
    );
]]))

--------------------------------------------------------------------------------
-- HAPPY PATH: Verify integer coordinates
--------------------------------------------------------------------------------

print("Test 1: load_clips returns integer timeline_start")
local clips = database.load_clips("seq")
assert(clips and #clips == 1, "expected exactly one clip, got " .. tostring(clips and #clips))

local clip = clips[1]
assert(type(clip.timeline_start) == "number",
    "timeline_start should be number, got " .. type(clip.timeline_start))
assert(clip.timeline_start == 1500,
    "expected timeline_start == 1500, got " .. tostring(clip.timeline_start))
print("  ✓ timeline_start is integer 1500")

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

print("Test 5: clip.rate contains fps metadata")
assert(clip.rate, "clip should have rate metadata")
assert(clip.rate.fps_numerator == 30000,
    "expected clip.rate.fps_numerator == 30000, got " .. tostring(clip.rate.fps_numerator))
assert(clip.rate.fps_denominator == 1001,
    "expected clip.rate.fps_denominator == 1001, got " .. tostring(clip.rate.fps_denominator))
print("  ✓ clip.rate has correct fps metadata")

print("Test 6: timeline coords are NOT Rationals (are plain numbers)")
-- Verify coords are plain numbers (Rationals would be tables)
assert(type(clip.timeline_start) == "number",
    "timeline_start should be number, not Rational table")
assert(type(clip.duration) == "number",
    "duration should be number, not Rational table")
print("  ✓ coords are plain integers, not Rationals")

print("✅ test_database_load_clips_uses_sequence_fps.lua passed")
os.remove(DB_PATH)
