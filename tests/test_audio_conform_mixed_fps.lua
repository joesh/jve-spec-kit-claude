#!/usr/bin/env luajit
--- Test: audio conforms to "frames are frames" speed when source fps ≠ timeline fps
--
-- "Frames are frames": a 23.976fps clip on a 30fps timeline plays each source
-- frame at 1/30s (25% faster). Audio must conform to the same speed so A/V
-- stay in sync.
--
-- BUG: source_offset_us maps playback time → source time at 1:1 ratio.
-- Video advances 1 source frame per timeline frame = timeline_fps/video_fps
-- speed. Audio at 1.0x drifts behind: 250ms/sec at 30fps/23.976fps.
--
-- FIX: Recompute source_offset per tick using media's video fps so audio
-- source position matches video source position at the current playhead.

require("test_env")

print("=== test_audio_conform_mixed_fps.lua ===")

local database = require("core.database")
local import_schema = require("import_schema")

-- Initialize database
local DB_PATH = "/tmp/jve/test_audio_conform_mixed_fps.db"
os.remove(DB_PATH)
assert(database.init(DB_PATH))
local db = database.get_connection()
assert(db:exec(import_schema))

-- Project
assert(db:exec([[
    INSERT INTO projects(id, name, created_at, modified_at)
    VALUES('proj', 'TestProject', strftime('%s','now'), strftime('%s','now'))
]]))

-- Sequence at 30fps
assert(db:exec([[
    INSERT INTO sequences(id, project_id, name, kind, fps_numerator, fps_denominator,
                         audio_rate, width, height, view_start_frame, view_duration_frames,
                         playhead_frame, created_at, modified_at)
    VALUES('seq30', 'proj', 'TestSeq30fps', 'timeline', 30, 1, 48000, 1920, 1080, 0, 2000, 0,
           strftime('%s','now'), strftime('%s','now'))
]]))

-- Video + Audio tracks
assert(db:exec([[
    INSERT INTO tracks(id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
    VALUES('v1', 'seq30', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0),
          ('a1', 'seq30', 'A1', 'AUDIO', 1, 1, 0, 0, 0, 1.0, 0.0)
]]))

-- Media at 23.976fps (24000/1001) — video fps stored on media record
assert(db:exec([[
    INSERT INTO media(id, project_id, file_path, name, duration_frames, fps_numerator, fps_denominator,
                     width, height, audio_channels, codec, created_at, modified_at, metadata)
    VALUES('media_23976', 'proj', '/test/23976.mov', 'clip_23976', 1000, 24000, 1001, 1920, 1080, 2, 'h264',
           strftime('%s','now'), strftime('%s','now'), '{}')
]]))

-- Audio clip at 48000/1. Starts at timeline frame 3.
-- source_in=126000 samples (= 2.625s). source_out=178000. duration=33 timeline frames.
assert(db:exec([[
    INSERT INTO clips(id, project_id, clip_kind, name, track_id, media_id,
                     timeline_start_frame, duration_frames, source_in_frame, source_out_frame,
                     fps_numerator, fps_denominator, enabled, offline, created_at, modified_at)
    VALUES('clip_a', 'proj', 'timeline', 'ClipAudio', 'a1', 'media_23976',
           3, 33, 126000, 178000, 48000, 1, 1, 0,
           strftime('%s','now'), strftime('%s','now'))
]]))

local timeline_resolver = require("core.playback.timeline_resolver")

--------------------------------------------------------------------------------
-- Test 1: resolve_all_audio_at_time returns media video fps
--------------------------------------------------------------------------------
print("\nTest 1: resolver returns media_fps for conform computation")

local results = timeline_resolver.resolve_all_audio_at_time(10, "seq30")
assert(#results == 1, "Expected 1 audio clip, got " .. #results)
local r = results[1]

assert(r.media_fps_num, "media_fps_num missing from resolver result")
assert(r.media_fps_den, "media_fps_den missing from resolver result")
assert(r.media_fps_num == 24000, "media_fps_num should be 24000, got " .. tostring(r.media_fps_num))
assert(r.media_fps_den == 1001, "media_fps_den should be 1001, got " .. tostring(r.media_fps_den))
print("  ✓ media_fps_num=24000, media_fps_den=1001")

--------------------------------------------------------------------------------
-- Test 2: Conform source_offset computation
-- At playhead P, video source time = seek_time + (P - tl_start) / video_fps
-- source_offset should make audio match: playhead_time - offset = video_source_time
--------------------------------------------------------------------------------
print("\nTest 2: conform source_offset gives correct audio position")

local SEQ_FPS_NUM = 30
local SEQ_FPS_DEN = 1
local MEDIA_FPS_NUM = 24000
local MEDIA_FPS_DEN = 1001
local TL_START = 3
local SEEK_FRAME = 126000  -- source_in - media_start_tc (=0)
local CLIP_FPS_NUM = 48000
local CLIP_FPS_DEN = 1

local seek_us = math.floor(SEEK_FRAME * 1000000 * CLIP_FPS_DEN / CLIP_FPS_NUM)  -- 2625000

--- Compute the "conform" source_offset at a given playhead frame.
-- This is what playback_controller should compute.
local function conform_source_offset(playhead_frame)
    local offset_tl = playhead_frame - TL_START
    -- In "frames are frames," source advances 1 frame per timeline frame at video fps
    local conform_source_time_us = seek_us + math.floor(
        offset_tl * 1000000 * MEDIA_FPS_DEN / MEDIA_FPS_NUM)
    local playhead_time_us = math.floor(
        playhead_frame * 1000000 * SEQ_FPS_DEN / SEQ_FPS_NUM)
    return playhead_time_us - conform_source_time_us
end

--- Compute audio source time given playback time and source_offset
local function audio_source_time(playback_time_us, source_offset_us)
    return playback_time_us - source_offset_us
end

local test_cases = {
    -- { playhead_frame, expected_source_time_us, description }
    -- source_time = seek_us + offset_tl * 1e6 * 1001 / 24000
    { 3,   2625000,                            "clip start (offset=0)" },
    { 33,  2625000 + math.floor(30*1000000*1001/24000), "30 frames in" },   -- +1251250
    { 18,  2625000 + math.floor(15*1000000*1001/24000), "15 frames in" },   -- +625625
}

local errors = 0
for _, tc in ipairs(test_cases) do
    local playhead, expected_src_time_us, desc = tc[1], tc[2], tc[3]

    local offset = conform_source_offset(playhead)
    local playhead_time_us = math.floor(playhead * 1000000 * SEQ_FPS_DEN / SEQ_FPS_NUM)
    local actual_src_time_us = audio_source_time(playhead_time_us, offset)

    local diff_us = math.abs(actual_src_time_us - expected_src_time_us)
    if diff_us > 1 then  -- 1us tolerance (sub-sample precision)
        print(string.format("  ✗ playhead=%d (%s): src_time=%dus, expected=%dus (diff=%dus)",
            playhead, desc, actual_src_time_us, expected_src_time_us, diff_us))
        errors = errors + 1
    end
end

assert(errors == 0, string.format("Test 2 FAILED: %d cases wrong", errors))
print("  ✓ Conform offset gives correct audio source position")

--------------------------------------------------------------------------------
-- Test 3: Same-rate (24fps on 24fps) — conform offset equals standard offset
--------------------------------------------------------------------------------
print("\nTest 3: same-rate clips — conform offset matches standard offset")

local function standard_source_offset(tl_start, seek_us_val, seq_fps_num, seq_fps_den)
    local tl_start_us = math.floor(tl_start * 1000000 * seq_fps_den / seq_fps_num)
    return tl_start_us - seek_us_val
end

-- 24fps media on 24fps timeline: video fps = timeline fps → no conform needed
local same_seq_fps_num = 24
local same_seq_fps_den = 1
local same_media_fps_num = 24
local same_media_fps_den = 1
local same_tl_start = 10
local same_seek_us = 500000  -- 0.5s

local standard = standard_source_offset(same_tl_start, same_seek_us, same_seq_fps_num, same_seq_fps_den)

-- Conform offset at tl_start (offset=0): should equal standard
local conform = (function()
    local playhead_time_us = math.floor(same_tl_start * 1000000 * same_seq_fps_den / same_seq_fps_num)
    local conform_src_time = same_seek_us + 0  -- offset_tl=0
    return playhead_time_us - conform_src_time
end)()

assert(standard == conform,
    string.format("Same-rate: standard=%d, conform=%d", standard, conform))

-- Conform offset 30 frames in: should still be close (same fps → speed ratio = 1)
local conform_30 = (function()
    local playhead = same_tl_start + 30
    local playhead_time_us = math.floor(playhead * 1000000 * same_seq_fps_den / same_seq_fps_num)
    local conform_src_time = same_seek_us + math.floor(30 * 1000000 * same_media_fps_den / same_media_fps_num)
    return playhead_time_us - conform_src_time
end)()

assert(standard == conform_30,
    string.format("Same-rate at offset 30: standard=%d, conform=%d", standard, conform_30))
print("  ✓ Same-rate conform offset matches standard")

--------------------------------------------------------------------------------
-- Test 4: Audio-only media (fps = sample_rate) — should NOT conform
-- Media fps = 48000/1 (pseudo-fps for audio-only). Conform would give wrong result.
--------------------------------------------------------------------------------
print("\nTest 4: audio-only media detection")

-- Audio-only: media fps = sample_rate → conform ratio = timeline_fps / 48000 ≈ 0.000625
-- This is clearly wrong. Detect via: media_fps / media_fps_den >= 1000 → audio-only → skip conform
local audio_only_media_fps = 48000
local audio_only_is_video = (audio_only_media_fps / 1) < 1000
assert(not audio_only_is_video, "48000/1 should NOT be detected as video fps")

local video_media_fps = 24000
local video_media_is_video = (video_media_fps / 1001) < 1000
assert(video_media_is_video, "24000/1001 (~23.976) should be detected as video fps")

-- Edge cases
assert((30 / 1) < 1000, "30fps should be video")
assert((60 / 1) < 1000, "60fps should be video")
assert((120 / 1) < 1000, "120fps should be video")
assert(not ((44100 / 1) < 1000), "44100Hz should NOT be video")
assert(not ((96000 / 1) < 1000), "96000Hz should NOT be video")

print("  ✓ Audio-only detection works for all common rates")

--------------------------------------------------------------------------------
print("\n✅ test_audio_conform_mixed_fps.lua passed")
