#!/usr/bin/env luajit
-- TDD test: Clip.find_next_on_track and Clip.find_prev_on_track
-- These queries find the next/previous enabled clip on a track relative to
-- a timeline frame position. Used by engine lookahead for pre-buffering.

require('test_env')

print("=== test_clip_find_next_prev.lua ===")

local database = require("core.database")
local import_schema = require("import_schema")
local Clip = require("models.clip")

-- Initialize database
local DB_PATH = "/tmp/jve/test_clip_find_next_prev.db"
os.remove(DB_PATH)
os.remove(DB_PATH .. "-wal")
os.remove(DB_PATH .. "-shm")
assert(database.init(DB_PATH))
local db = database.get_connection()
assert(db:exec(import_schema))

-- Create project + sequence + tracks
assert(db:exec([[
    INSERT INTO projects(id, name, created_at, modified_at)
    VALUES('proj', 'TestProject', strftime('%s','now'), strftime('%s','now'))
]]))

assert(db:exec([[
    INSERT INTO sequences(id, project_id, name, kind, fps_numerator, fps_denominator,
                         audio_rate, width, height, view_start_frame, view_duration_frames,
                         playhead_frame, created_at, modified_at)
    VALUES('seq', 'proj', 'TestTimeline', 'timeline', 24, 1, 48000, 1920, 1080, 0, 2000, 0,
           strftime('%s','now'), strftime('%s','now'))
]]))

assert(db:exec([[
    INSERT INTO tracks(id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
    VALUES('v1', 'seq', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0)
]]))

-- Create test media
assert(db:exec([[
    INSERT INTO media(id, project_id, file_path, name, duration_frames, fps_numerator, fps_denominator,
                     width, height, audio_channels, codec, created_at, modified_at, metadata)
    VALUES('media_a', 'proj', '/test/a.mov', 'a', 100, 24, 1, 1920, 1080, 2, 'h264',
           strftime('%s','now'), strftime('%s','now'), '{}')
]]))

-- Layout on track v1:
--   clip_1: frames [0, 48)    (timeline_start=0, duration=48)
--   gap:    frames [48, 100)
--   clip_2: frames [100, 200) (timeline_start=100, duration=100)
--   clip_3: frames [200, 300) (timeline_start=200, duration=100, DISABLED)
--   clip_4: frames [300, 400) (timeline_start=300, duration=100)
assert(db:exec([[
    INSERT INTO clips(id, project_id, clip_kind, name, track_id, media_id,
                     timeline_start_frame, duration_frames, source_in_frame, source_out_frame,
                     fps_numerator, fps_denominator, enabled, offline, created_at, modified_at)
    VALUES
        ('clip_1', 'proj', 'timeline', 'Clip1', 'v1', 'media_a', 0,   48,  0, 48,  24, 1, 1, 0, strftime('%s','now'), strftime('%s','now')),
        ('clip_2', 'proj', 'timeline', 'Clip2', 'v1', 'media_a', 100, 100, 0, 100, 24, 1, 1, 0, strftime('%s','now'), strftime('%s','now')),
        ('clip_3', 'proj', 'timeline', 'Clip3', 'v1', 'media_a', 200, 100, 0, 100, 24, 1, 0, 0, strftime('%s','now'), strftime('%s','now')),
        ('clip_4', 'proj', 'timeline', 'Clip4', 'v1', 'media_a', 300, 100, 0, 100, 24, 1, 1, 0, strftime('%s','now'), strftime('%s','now'))
]]))

--------------------------------------------------------------------------------
-- Test find_next_on_track
--------------------------------------------------------------------------------

print("\n--- find_next_on_track: basic next clip ---")
do
    -- After frame 48 (end of clip_1), next clip is clip_2 at frame 100
    local clip = Clip.find_next_on_track('v1', 48)
    assert(clip, "Expected to find next clip after frame 48")
    assert(clip.id == 'clip_2', string.format(
        "Expected clip_2 after frame 48, got %s", tostring(clip.id)))
    print("  find_next after gap returns clip_2 passed")
end

print("\n--- find_next_on_track: at exact clip start ---")
do
    -- At frame 100 (start of clip_2), should return clip_2 itself
    local clip = Clip.find_next_on_track('v1', 100)
    assert(clip, "Expected to find clip at exact start frame 100")
    assert(clip.id == 'clip_2', string.format(
        "Expected clip_2 at frame 100, got %s", tostring(clip.id)))
    print("  find_next at exact start returns that clip passed")
end

print("\n--- find_next_on_track: skips disabled clips ---")
do
    -- After frame 200 (clip_3 is disabled), should return clip_4 at 300
    local clip = Clip.find_next_on_track('v1', 200)
    assert(clip, "Expected to find next enabled clip after frame 200")
    assert(clip.id == 'clip_4', string.format(
        "Expected clip_4 (skipping disabled clip_3), got %s", tostring(clip.id)))
    print("  find_next skips disabled clips passed")
end

print("\n--- find_next_on_track: nil at end ---")
do
    -- After frame 400, no more clips
    local clip = Clip.find_next_on_track('v1', 400)
    assert(clip == nil, "Expected nil at end of track")
    print("  find_next returns nil at end passed")
end

print("\n--- find_next_on_track: asserts on nil track_id ---")
do
    local ok, err = pcall(Clip.find_next_on_track, nil, 0)
    assert(not ok, "Should assert on nil track_id")
    assert(err:find("track_id"), "Error should mention track_id, got: " .. err)
    print("  find_next asserts on nil track_id passed")
end

print("\n--- find_next_on_track: asserts on non-number frame ---")
do
    local ok, err = pcall(Clip.find_next_on_track, 'v1', "abc")
    assert(not ok, "Should assert on non-number frame")
    assert(err:find("after_frame"), "Error should mention after_frame, got: " .. err)
    print("  find_next asserts on non-number frame passed")
end

--------------------------------------------------------------------------------
-- Test find_prev_on_track
--------------------------------------------------------------------------------

print("\n--- find_prev_on_track: basic prev clip ---")
do
    -- Before frame 100 (start of clip_2), prev clip ending <= 100 is clip_1 (ends at 48)
    local clip = Clip.find_prev_on_track('v1', 100)
    assert(clip, "Expected to find prev clip before frame 100")
    assert(clip.id == 'clip_1', string.format(
        "Expected clip_1 before frame 100, got %s", tostring(clip.id)))
    print("  find_prev before gap returns clip_1 passed")
end

print("\n--- find_prev_on_track: at exact clip end ---")
do
    -- Before frame 48 (end of clip_1), clip_1 ends at exactly 48
    local clip = Clip.find_prev_on_track('v1', 48)
    assert(clip, "Expected to find clip ending at exactly frame 48")
    assert(clip.id == 'clip_1', string.format(
        "Expected clip_1 ending at frame 48, got %s", tostring(clip.id)))
    print("  find_prev at exact end returns that clip passed")
end

print("\n--- find_prev_on_track: skips disabled clips ---")
do
    -- Before frame 300 (start of clip_4), clip_3 is disabled at 200
    -- Should return clip_2 (ends at 200)
    local clip = Clip.find_prev_on_track('v1', 300)
    assert(clip, "Expected to find prev enabled clip before frame 300")
    assert(clip.id == 'clip_2', string.format(
        "Expected clip_2 (skipping disabled clip_3), got %s", tostring(clip.id)))
    print("  find_prev skips disabled clips passed")
end

print("\n--- find_prev_on_track: nil at start ---")
do
    -- Before frame 0, no clips end before this
    local clip = Clip.find_prev_on_track('v1', 0)
    assert(clip == nil, "Expected nil at start of track")
    print("  find_prev returns nil at start passed")
end

print("\n--- find_prev_on_track: asserts on nil track_id ---")
do
    local ok, err = pcall(Clip.find_prev_on_track, nil, 100)
    assert(not ok, "Should assert on nil track_id")
    assert(err:find("track_id"), "Error should mention track_id, got: " .. err)
    print("  find_prev asserts on nil track_id passed")
end

print("\n✅ test_clip_find_next_prev.lua passed")
