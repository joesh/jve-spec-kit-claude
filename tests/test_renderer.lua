#!/usr/bin/env luajit
-- Test Sequence:get_video_at(), :get_audio_at(), and Renderer module.
-- Sequence accessors tested with real DB. Renderer tested with mock media_cache.

package.path = "tests/?.lua;src/lua/?.lua;src/lua/?/init.lua;" .. package.path
require('test_env')

local database = require("core.database")
local import_schema = require("import_schema")
local Sequence = require("models.sequence")

-- Initialize database
local DB_PATH = "/tmp/jve/test_renderer.db"
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
    VALUES('seq', 'proj', 'TestTimeline', 'timeline', 24, 1, 48000, 1920, 1080, 0, 2000, 0,
           strftime('%s','now'), strftime('%s','now'))
]]))

-- Create video tracks: V1 (index 1), V2 (index 2)
-- Lower index = topmost (V1 wins over V2)
assert(db:exec([[
    INSERT INTO tracks(id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
    VALUES('v1', 'seq', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0),
          ('v2', 'seq', 'V2', 'VIDEO', 2, 1, 0, 0, 0, 1.0, 0.0)
]]))

-- Create audio tracks: A1, A2
assert(db:exec([[
    INSERT INTO tracks(id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
    VALUES('a1', 'seq', 'A1', 'AUDIO', 1, 1, 0, 0, 0, 1.0, 0.0),
          ('a2', 'seq', 'A2', 'AUDIO', 2, 1, 0, 0, 0, 0.8, 0.0)
]]))

-- Create test media
assert(db:exec([[
    INSERT INTO media(id, project_id, file_path, name, duration_frames, fps_numerator, fps_denominator,
                     width, height, audio_channels, codec, created_at, modified_at, metadata)
    VALUES('media_a', 'proj', '/test/clip_a.mov', 'clip_a', 100, 24, 1, 1920, 1080, 2, 'h264',
           strftime('%s','now'), strftime('%s','now'), '{}'),
          ('media_b', 'proj', '/test/clip_b.mov', 'clip_b', 200, 24, 1, 1920, 1080, 2, 'h264',
           strftime('%s','now'), strftime('%s','now'), '{}'),
          ('media_audio', 'proj', '/test/audio.wav', 'audio', 480000, 48000, 1, 0, 0, 2, 'pcm',
           strftime('%s','now'), strftime('%s','now'), '{}')
]]))

-- Create video clips:
-- V2: clip at frames 0-48 (2 seconds at 24fps)
-- V1: clip at frames 24-72 (overlaps V2, higher priority)
assert(db:exec([[
    INSERT INTO clips(id, project_id, clip_kind, name, track_id, media_id,
                     timeline_start_frame, duration_frames, source_in_frame, source_out_frame,
                     fps_numerator, fps_denominator, enabled, offline, created_at, modified_at)
    VALUES('clip_v2', 'proj', 'timeline', 'ClipV2', 'v2', 'media_b', 0, 48, 0, 48, 24, 1, 1, 0,
           strftime('%s','now'), strftime('%s','now')),
          ('clip_v1', 'proj', 'timeline', 'ClipV1', 'v1', 'media_a', 24, 48, 10, 58, 24, 1, 1, 0,
           strftime('%s','now'), strftime('%s','now'))
]]))

-- Create audio clips:
-- A1: audio clip at frames 0-96
-- A2: audio clip at frames 48-144 (overlapping A1)
assert(db:exec([[
    INSERT INTO clips(id, project_id, clip_kind, name, track_id, media_id,
                     timeline_start_frame, duration_frames, source_in_frame, source_out_frame,
                     fps_numerator, fps_denominator, enabled, offline, created_at, modified_at)
    VALUES('clip_a1', 'proj', 'timeline', 'ClipA1', 'a1', 'media_audio', 0, 96, 0, 96000, 48000, 1, 1, 0,
           strftime('%s','now'), strftime('%s','now')),
          ('clip_a2', 'proj', 'timeline', 'ClipA2', 'a2', 'media_b', 48, 96, 0, 96, 24, 1, 1, 0,
           strftime('%s','now'), strftime('%s','now'))
]]))

-- Load the sequence
local seq = Sequence.load("seq")
assert(seq, "Failed to load test sequence")

-- ============================================================================
-- Test Sequence:get_video_at()
-- ============================================================================

local function test_get_video_at_single_clip()
    -- Frame 10: only V2 is present (V1 starts at 24)
    local results = seq:get_video_at(10)
    assert(#results == 1, string.format("Expected 1 video entry at frame 10, got %d", #results))
    assert(results[1].clip.id == "clip_v2", "Expected clip_v2 at frame 10")
    assert(results[1].media_path == "/test/clip_b.mov", "Wrong media path")
    -- source_frame = source_in(0) + offset(10) = 10
    assert(results[1].source_frame == 10, string.format("Expected source_frame=10, got %d", results[1].source_frame))
    print("  test_get_video_at_single_clip passed")
end

local function test_get_video_at_overlapping_topmost()
    -- Frame 30: V1(24-72) and V2(0-48) overlap. V1 = topmost (index 1)
    local results = seq:get_video_at(30)
    assert(#results == 2, string.format("Expected 2 video entries at frame 30, got %d", #results))
    -- First entry should be V1 (topmost, lowest track_index)
    assert(results[1].clip.id == "clip_v1", "Expected clip_v1 as topmost at frame 30, got " .. results[1].clip.id)
    assert(results[2].clip.id == "clip_v2", "Expected clip_v2 as second at frame 30")
    -- V1 source_frame: source_in(10) + (30 - 24) = 16
    assert(results[1].source_frame == 16, string.format("Expected source_frame=16, got %d", results[1].source_frame))
    print("  test_get_video_at_overlapping_topmost passed")
end

local function test_get_video_at_gap()
    -- Frame 100: no clips (V2 ends at 48, V1 ends at 72)
    local results = seq:get_video_at(100)
    assert(#results == 0, "Expected empty list for gap at frame 100")
    print("  test_get_video_at_gap passed")
end

local function test_get_video_at_source_time()
    -- Frame 30, clip V1: source_in=10, offset=30-24=6, source_frame=16
    -- source_time_us = 16 * 1000000 * 1 / 24 = 666666
    local results = seq:get_video_at(30)
    local expected_us = math.floor(16 * 1000000 / 24)
    assert(math.abs(results[1].source_time_us - expected_us) < 2,
        string.format("Expected source_time_us~%d, got %d", expected_us, results[1].source_time_us))
    print("  test_get_video_at_source_time passed")
end

-- ============================================================================
-- Test Sequence:get_audio_at()
-- ============================================================================

local function test_get_audio_at_single()
    -- Frame 10: only A1 is active (A2 starts at 48)
    local results = seq:get_audio_at(10)
    assert(#results == 1, string.format("Expected 1 audio entry at frame 10, got %d", #results))
    assert(results[1].clip.id == "clip_a1", "Expected clip_a1 at frame 10")
    assert(results[1].media_path == "/test/audio.wav", "Wrong audio media path")
    -- A1: source_in=0, offset=10, source_frame=10, rate=48000/1
    assert(results[1].source_frame == 10, string.format("Expected audio source_frame=10, got %d", results[1].source_frame))
    assert(results[1].media_fps_num == 48000, "Expected media_fps_num=48000")
    assert(results[1].media_fps_den == 1, "Expected media_fps_den=1")
    print("  test_get_audio_at_single passed")
end

local function test_get_audio_at_multi_track()
    -- Frame 60: A1(0-96) and A2(48-144) both active
    local results = seq:get_audio_at(60)
    assert(#results == 2, string.format("Expected 2 audio entries at frame 60, got %d", #results))
    -- Both clips present (order by track_index)
    local ids = {}
    for _, r in ipairs(results) do ids[r.clip.id] = true end
    assert(ids["clip_a1"], "Expected clip_a1 at frame 60")
    assert(ids["clip_a2"], "Expected clip_a2 at frame 60")
    print("  test_get_audio_at_multi_track passed")
end

local function test_get_audio_at_gap()
    -- Frame 200: no audio clips
    local results = seq:get_audio_at(200)
    assert(#results == 0, "Expected empty list for audio gap at frame 200")
    print("  test_get_audio_at_gap passed")
end

-- ============================================================================
-- Test Renderer.get_sequence_info()
-- ============================================================================

local function test_get_sequence_info()
    local renderer = require("core.renderer")
    local info = renderer.get_sequence_info("seq")
    assert(info.fps_num == 24, "Expected fps_num=24")
    assert(info.fps_den == 1, "Expected fps_den=1")
    assert(info.width == 1920, "Expected width=1920")
    assert(info.height == 1080, "Expected height=1080")
    assert(info.name == "TestTimeline", "Expected name=TestTimeline")
    assert(info.kind == "timeline", "Expected kind=timeline")
    assert(info.audio_sample_rate == 48000, "Expected audio_sample_rate=48000")
    print("  test_get_sequence_info passed")
end

-- ============================================================================
-- Test Renderer.get_video_frame() with mocked media_cache
-- ============================================================================

-- renderer is loaded here (before mocks) so the module captures media_cache ref
local renderer = require("core.renderer")

-- Mock media_cache on the already-loaded module table so renderer sees the mocks.
local mc = require("core.media.media_cache")
local orig_activate = mc.activate
local orig_get_video_frame = mc.get_video_frame

local function test_get_video_frame_passes_clip_fps()
    -- Track what fps gets passed to media_cache.get_video_frame
    local captured_fps_num, captured_fps_den
    mc.activate = function(_path, _ctx)
        return { start_tc = 0, rotation = 0 }
    end
    mc.get_video_frame = function(_frame_idx, _ctx, fps_num, fps_den)
        captured_fps_num = fps_num
        captured_fps_den = fps_den
        return "mock_frame_handle"
    end

    -- Frame 10 → clip_v2 (on V2, fps_numerator=24, fps_denominator=1 in DB)
    -- Clip model stores these as clip.rate = {fps_numerator=24, fps_denominator=1}
    -- Renderer must access clip.rate.fps_numerator, NOT clip.fps_numerator (which is nil)
    local frame, meta = renderer.get_video_frame(seq, 10, "test_ctx")
    assert(frame == "mock_frame_handle", "Expected mock frame handle back")
    assert(meta, "Expected metadata")
    assert(captured_fps_num == 24, string.format(
        "media_cache.get_video_frame should receive clip fps_num=24, got %s",
        tostring(captured_fps_num)))
    assert(captured_fps_den == 1, string.format(
        "media_cache.get_video_frame should receive clip fps_den=1, got %s",
        tostring(captured_fps_den)))
    -- Metadata should also carry clip fps
    assert(meta.clip_fps_num == 24, string.format(
        "metadata.clip_fps_num should be 24, got %s", tostring(meta.clip_fps_num)))
    assert(meta.clip_fps_den == 1, string.format(
        "metadata.clip_fps_den should be 1, got %s", tostring(meta.clip_fps_den)))

    -- Restore
    mc.activate = orig_activate
    mc.get_video_frame = orig_get_video_frame
    print("  test_get_video_frame_passes_clip_fps passed")
end

local function test_get_video_frame_start_tc_subtracted()
    local captured_frame_idx
    mc.activate = function(_path, _ctx)
        return { start_tc = 1000, rotation = 90 }
    end
    mc.get_video_frame = function(frame_idx, _ctx, _fps_num, _fps_den)
        captured_frame_idx = frame_idx
        return "mock_frame"
    end

    -- Frame 10 → clip_v2: source_in=0, offset=10, source_frame=10
    -- file_frame = source_frame(10) - start_tc(1000) = -990
    -- But renderer should still pass it (decoder handles negative → assert or clamp)
    -- Actually, the assert in media_cache requires frame_idx >= 0, so this would fail.
    -- Use frame 30 → clip_v1: source_in=10, offset=30-24=6, source_frame=16
    -- file_frame = 16 - 1000 = -984... still negative.
    -- Use start_tc=5 instead for a sane test
    mc.activate = function(_path, _ctx)
        return { start_tc = 5, rotation = 90 }
    end
    local frame, meta = renderer.get_video_frame(seq, 10, "test_ctx")
    assert(frame == "mock_frame", "Expected mock frame")
    -- source_frame=10, start_tc=5 → file_frame=5
    assert(captured_frame_idx == 5, string.format(
        "file_frame should be source_frame(10) - start_tc(5) = 5, got %d",
        captured_frame_idx))
    assert(meta.rotation == 90, "rotation should come from info")

    mc.activate = orig_activate
    mc.get_video_frame = orig_get_video_frame
    print("  test_get_video_frame_start_tc_subtracted passed")
end

local function test_get_video_frame_returns_nil_on_eof()
    mc.activate = function() return { start_tc = 0, rotation = 0 } end
    mc.get_video_frame = function() return nil end  -- simulate EOF

    local frame, meta = renderer.get_video_frame(seq, 10, "test_ctx")
    assert(frame == nil, "Should return nil on decode failure")
    assert(meta == nil, "Metadata should be nil on decode failure")

    mc.activate = orig_activate
    mc.get_video_frame = orig_get_video_frame
    print("  test_get_video_frame_returns_nil_on_eof passed")
end

local function test_get_video_frame_clip_bounds_in_metadata()
    mc.activate = function() return { start_tc = 0, rotation = 0 } end
    mc.get_video_frame = function() return "mock_frame" end

    -- Frame 10 → clip_v2 (timeline_start=0, duration=48)
    local _, meta = renderer.get_video_frame(seq, 10, "test_ctx")
    assert(meta, "Expected metadata")
    assert(meta.clip_end_frame == 48, string.format(
        "clip_end_frame should be 0+48=48, got %s", tostring(meta.clip_end_frame)))
    assert(meta.clip_start_frame == 0, string.format(
        "clip_start_frame should be 0, got %s", tostring(meta.clip_start_frame)))

    -- Frame 30 → clip_v1 (timeline_start=24, duration=48)
    local _, meta2 = renderer.get_video_frame(seq, 30, "test_ctx")
    assert(meta2, "Expected metadata at frame 30")
    assert(meta2.clip_end_frame == 72, string.format(
        "clip_end_frame should be 24+48=72, got %s", tostring(meta2.clip_end_frame)))
    assert(meta2.clip_start_frame == 24, string.format(
        "clip_start_frame should be 24, got %s", tostring(meta2.clip_start_frame)))

    mc.activate = orig_activate
    mc.get_video_frame = orig_get_video_frame
    print("  test_get_video_frame_clip_bounds_in_metadata passed")
end

-- ============================================================================
-- NSF: Parameter validation tests
-- ============================================================================

local function test_get_sequence_info_nil_id_asserts()
    local ok, err = pcall(function()
        renderer.get_sequence_info(nil)
    end)
    assert(not ok, "nil sequence_id should assert")
    assert(string.find(tostring(err), "sequence_id"),
        "Error should mention sequence_id, got: " .. tostring(err))
    print("  test_get_sequence_info_nil_id_asserts passed")
end

local function test_get_sequence_info_empty_id_asserts()
    local ok, err = pcall(function()
        renderer.get_sequence_info("")
    end)
    assert(not ok, "empty sequence_id should assert")
    assert(string.find(tostring(err), "sequence_id"),
        "Error should mention sequence_id, got: " .. tostring(err))
    print("  test_get_sequence_info_empty_id_asserts passed")
end

local function test_get_sequence_info_nonexistent_asserts()
    local ok, err = pcall(function()
        renderer.get_sequence_info("nonexistent_seq_id_12345")
    end)
    assert(not ok, "nonexistent sequence_id should assert")
    assert(string.find(tostring(err), "not found"),
        "Error should mention not found, got: " .. tostring(err))
    print("  test_get_sequence_info_nonexistent_asserts passed")
end

local function test_get_video_frame_nil_sequence_asserts()
    local ok, err = pcall(function()
        renderer.get_video_frame(nil, 0, "test")
    end)
    assert(not ok, "nil sequence should assert")
    assert(string.find(tostring(err), "sequence"),
        "Error should mention sequence, got: " .. tostring(err))
    print("  test_get_video_frame_nil_sequence_asserts passed")
end

local function test_get_video_frame_nil_playhead_asserts()
    local ok, err = pcall(function()
        renderer.get_video_frame(seq, nil, "test")
    end)
    assert(not ok, "nil playhead should assert")
    assert(string.find(tostring(err), "playhead_frame"),
        "Error should mention playhead_frame, got: " .. tostring(err))
    print("  test_get_video_frame_nil_playhead_asserts passed")
end

local function test_get_video_frame_nil_context_asserts()
    local ok, err = pcall(function()
        renderer.get_video_frame(seq, 0, nil)
    end)
    assert(not ok, "nil context_id should assert")
    assert(string.find(tostring(err), "context_id"),
        "Error should mention context_id, got: " .. tostring(err))
    print("  test_get_video_frame_nil_context_asserts passed")
end

-- ============================================================================
-- Run all tests
-- ============================================================================

print("Testing Sequence:get_video_at()...")
test_get_video_at_single_clip()
test_get_video_at_overlapping_topmost()
test_get_video_at_gap()
test_get_video_at_source_time()

print("Testing Sequence:get_audio_at()...")
test_get_audio_at_single()
test_get_audio_at_multi_track()
test_get_audio_at_gap()

print("Testing Renderer.get_sequence_info()...")
test_get_sequence_info()

print("Testing Renderer.get_video_frame() with mock media_cache...")
test_get_video_frame_passes_clip_fps()
test_get_video_frame_start_tc_subtracted()
test_get_video_frame_returns_nil_on_eof()
test_get_video_frame_clip_bounds_in_metadata()

local function test_get_video_frame_negative_file_frame_asserts()
    -- If start_tc > source_frame, file_frame goes negative — renderer should assert
    mc.activate = function() return { start_tc = 9999, rotation = 0 } end
    mc.get_video_frame = function() return "mock_frame" end

    -- Frame 10 → clip_v2: source_frame=10, start_tc=9999 → file_frame = -9989
    local ok, err = pcall(function()
        renderer.get_video_frame(seq, 10, "test_ctx")
    end)
    assert(not ok, "Negative file_frame should assert")
    assert(tostring(err):find("file_frame"), "Error should mention file_frame, got: " .. tostring(err))

    mc.activate = orig_activate
    mc.get_video_frame = orig_get_video_frame
    print("  test_get_video_frame_negative_file_frame_asserts passed")
end

print("Testing Renderer NSF: parameter validation...")
test_get_sequence_info_nil_id_asserts()
test_get_sequence_info_empty_id_asserts()
test_get_sequence_info_nonexistent_asserts()
test_get_video_frame_nil_sequence_asserts()
test_get_video_frame_nil_playhead_asserts()
test_get_video_frame_nil_context_asserts()
test_get_video_frame_negative_file_frame_asserts()

print("✅ test_renderer.lua passed")
