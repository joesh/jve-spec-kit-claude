#!/usr/bin/env luajit
-- Test timeline_resolver: finds topmost clip at given playhead time
-- Following test pattern from test_batch_move_block_cross_track_occludes_dest.lua

package.path = "tests/?.lua;src/lua/?.lua;src/lua/?/init.lua;" .. package.path
require('test_env')

local database = require("core.database")
local import_schema = require("import_schema")
local Rational = require("core.rational")

-- Initialize database
local DB_PATH = "/tmp/jve/test_timeline_resolver.db"
os.remove(DB_PATH)
assert(database.init(DB_PATH))
local db = database.get_connection()
assert(db:exec(import_schema))

-- Create minimal project/sequence
assert(db:exec([[
    INSERT INTO projects(id, name, created_at, modified_at)
    VALUES('proj', 'TestProject', strftime('%s','now'), strftime('%s','now'))
]]))

assert(db:exec([[
    INSERT INTO sequences(id, project_id, name, kind, fps_numerator, fps_denominator,
                         audio_rate, width, height, view_start_frame, view_duration_frames,
                         playhead_frame, created_at, modified_at)
    VALUES('seq', 'proj', 'TestSeq', 'timeline', 24, 1, 48000, 1920, 1080, 0, 2000, 0,
           strftime('%s','now'), strftime('%s','now'))
]]))

-- Create video tracks: V1 (index 1), V2 (index 2), V3 (index 3)
-- Lower index = topmost (V1 wins over V2 wins over V3)
assert(db:exec([[
    INSERT INTO tracks(id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
    VALUES('v1', 'seq', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0),
          ('v2', 'seq', 'V2', 'VIDEO', 2, 1, 0, 0, 0, 1.0, 0.0),
          ('v3', 'seq', 'V3', 'VIDEO', 3, 1, 0, 0, 0, 1.0, 0.0)
]]))

-- Create test media
assert(db:exec([[
    INSERT INTO media(id, project_id, file_path, name, duration_frames, fps_numerator, fps_denominator,
                     width, height, audio_channels, codec, created_at, modified_at, metadata)
    VALUES('media_a', 'proj', '/test/clip_a.mov', 'clip_a', 100, 24, 1, 1920, 1080, 2, 'h264',
           strftime('%s','now'), strftime('%s','now'), '{}'),
          ('media_b', 'proj', '/test/clip_b.mov', 'clip_b', 100, 24, 1, 1920, 1080, 2, 'h264',
           strftime('%s','now'), strftime('%s','now'), '{}'),
          ('media_c', 'proj', '/test/clip_c.mov', 'clip_c', 100, 24, 1, 1920, 1080, 2, 'h264',
           strftime('%s','now'), strftime('%s','now'), '{}')
]]))

-- Create clips:
-- V3: clip at frames 0-48 (2 seconds)
-- V2: clip at frames 24-72 (overlaps V3)
-- V1: clip at frames 48-96 (overlaps V2)
-- Gap at frames 96+
assert(db:exec([[
    INSERT INTO clips(id, project_id, clip_kind, name, track_id, media_id,
                     timeline_start_frame, duration_frames, source_in_frame, source_out_frame,
                     fps_numerator, fps_denominator, enabled, offline, created_at, modified_at)
    VALUES('clip_v3', 'proj', 'timeline', 'ClipV3', 'v3', 'media_c', 0, 48, 0, 48, 24, 1, 1, 0,
           strftime('%s','now'), strftime('%s','now')),
          ('clip_v2', 'proj', 'timeline', 'ClipV2', 'v2', 'media_b', 24, 48, 0, 48, 24, 1, 1, 0,
           strftime('%s','now'), strftime('%s','now')),
          ('clip_v1', 'proj', 'timeline', 'ClipV1', 'v1', 'media_a', 48, 48, 10, 58, 24, 1, 1, 0,
           strftime('%s','now'), strftime('%s','now'))
]]))

-- Now run the tests
local timeline_resolver = require("core.playback.timeline_resolver")

-- Test 1: Resolve at frame 10 - should return V3 clip (only clip present)
local function test_resolve_single_clip()
    -- Frame 10 is in V3 only (V3: 0-48, V2: 24-72, V1: 48-96)
    local playhead = Rational.new(10, 24, 1)
    local result = timeline_resolver.resolve_at_time(playhead, "seq")

    assert(result, "resolve_at_time should return result at frame 10")
    assert(result.clip.id == "clip_v3", "Should return V3 clip at frame 10, got " .. tostring(result.clip.id))
    assert(result.media_path == "/test/clip_c.mov", "Should return correct media path")

    -- Source time: playhead (10) - timeline_start (0) + source_in (0) = 10 frames = 10/24 * 1000000 us
    local expected_source_time_us = math.floor(10 * 1000000 / 24)
    assert(math.abs(result.source_time_us - expected_source_time_us) < 1000,
        string.format("Source time should be ~%d us, got %d", expected_source_time_us, result.source_time_us))

    print("✅ test_resolve_single_clip passed")
end

-- Test 2: Resolve at frame 30 - V2 overlaps V3, V2 should win (lower track_index)
local function test_resolve_overlapping_clips_v2_wins()
    -- Frame 30: V3 (0-48) and V2 (24-72) overlap. V2 has lower track_index, V2 wins.
    local playhead = Rational.new(30, 24, 1)
    local result = timeline_resolver.resolve_at_time(playhead, "seq")

    assert(result, "resolve_at_time should return result at frame 30")
    assert(result.clip.id == "clip_v2", "Should return V2 clip at frame 30 (topmost), got " .. tostring(result.clip.id))
    assert(result.media_path == "/test/clip_b.mov", "Should return V2 media path")

    print("✅ test_resolve_overlapping_clips_v2_wins passed")
end

-- Test 3: Resolve at frame 60 - V1 overlaps V2, V1 should win
local function test_resolve_overlapping_clips_v1_wins()
    -- Frame 60: V2 (24-72) and V1 (48-96) overlap. V1 has lower track_index, V1 wins.
    local playhead = Rational.new(60, 24, 1)
    local result = timeline_resolver.resolve_at_time(playhead, "seq")

    assert(result, "resolve_at_time should return result at frame 60")
    assert(result.clip.id == "clip_v1", "Should return V1 clip at frame 60 (topmost), got " .. tostring(result.clip.id))
    assert(result.media_path == "/test/clip_a.mov", "Should return V1 media path")

    -- V1 has source_in=10, so at timeline frame 60, source frame = (60-48)+10 = 22
    local expected_source_time_us = math.floor(22 * 1000000 / 24)
    assert(math.abs(result.source_time_us - expected_source_time_us) < 1000,
        string.format("Source time should be ~%d us, got %d", expected_source_time_us, result.source_time_us))

    print("✅ test_resolve_overlapping_clips_v1_wins passed")
end

-- Test 4: Resolve at frame 100 - gap, should return nil
local function test_resolve_gap_returns_nil()
    -- Frame 100 is in gap (all clips end at or before 96)
    local playhead = Rational.new(100, 24, 1)
    local result = timeline_resolver.resolve_at_time(playhead, "seq")

    assert(result == nil, "resolve_at_time should return nil for gap at frame 100")

    print("✅ test_resolve_gap_returns_nil passed")
end

-- Test 5: Resolve at frame 0 - edge case at clip start
local function test_resolve_at_clip_start()
    local playhead = Rational.new(0, 24, 1)
    local result = timeline_resolver.resolve_at_time(playhead, "seq")

    assert(result, "resolve_at_time should return result at frame 0")
    assert(result.clip.id == "clip_v3", "Should return V3 clip at frame 0")

    print("✅ test_resolve_at_clip_start passed")
end

-- Run all tests
test_resolve_single_clip()
test_resolve_overlapping_clips_v2_wins()
test_resolve_overlapping_clips_v1_wins()
test_resolve_gap_returns_nil()
test_resolve_at_clip_start()

print("✅ test_timeline_resolver.lua passed")
