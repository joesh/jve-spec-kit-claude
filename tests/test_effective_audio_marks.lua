#!/usr/bin/env luajit

-- Regression test: resolve_audio_stream_timing with mark_in set on a masterclip
-- that has absolute TC video source_in and relative audio source_in.
--
-- Bug: mark_in (absolute TC video frame) was converted to samples via
-- frame_to_samples() which is a pure unit conversion — result was an absolute
-- sample position, but audio.source_out was relative. Duration went negative.

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
local test_env = require('test_env')

local database = require('core.database')
local Sequence = require('models.sequence')
local Track = require('models.track')
local Clip = require('models.clip')
local clip_edit_helper = require('core.clip_edit_helper')

print("=== Effective Audio Marks Tests ===\n")

-- Setup DB
local db_path = "/tmp/jve/test_effective_audio_marks.db"
os.remove(db_path)
os.execute("mkdir -p /tmp/jve")
database.init(db_path)
local db = database.get_connection()
db:exec(require('import_schema'))

local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at)
    VALUES ('project', 'Test', 'resample', %d, %d);
]], now, now))

-- Constants
local VIDEO_FPS = 24
local SAMPLE_RATE = 48000
local VIDEO_SOURCE_IN = 1136444   -- absolute TC frame (~13 hours at 24fps)
local VIDEO_DURATION = 100        -- 100 video frames
local VIDEO_SOURCE_OUT = VIDEO_SOURCE_IN + VIDEO_DURATION
-- Audio: 100 frames worth of samples at 48kHz/24fps = 2000 samples/frame
local AUDIO_SAMPLES_PER_FRAME = SAMPLE_RATE / VIDEO_FPS  -- 2000
local AUDIO_DURATION_SAMPLES = VIDEO_DURATION * AUDIO_SAMPLES_PER_FRAME  -- 200000
local AUDIO_SOURCE_IN = 0
local AUDIO_SOURCE_OUT = AUDIO_DURATION_SAMPLES

-- Create media record FIRST (FK target for clips)
test_env.create_test_media({
    id = "media_v",
    project_id = "project",
    file_path = "/tmp/jve/test.mov",
    name = "TestMedia",
    duration_frames = VIDEO_DURATION,
    fps_numerator = VIDEO_FPS,
    fps_denominator = 1,
    audio_channels = 2,
    audio_sample_rate = SAMPLE_RATE,
    width = 1920,
    height = 1080,
    start_tc = VIDEO_SOURCE_IN,  -- video TC origin matches our source_in
})

-- V13: master sequence wrapping the media for clip references.
do
    local _Media = require("models.media")
    local _json = require("dkjson")
    local _m = _Media.load("media_v")
    if _m then
        if not _m.width or _m.width == 0 then _m.width = 1920 end
        if not _m.height or _m.height == 0 then _m.height = 1080 end
        local _parsed = _m.metadata and (function() local ok,v = pcall(_json.decode, _m.metadata); return ok and v end)()
        if not _parsed or _parsed.start_tc_value == nil then
            _m.metadata = _json.encode({ start_tc_value = 0,
                start_tc_rate = (_m.frame_rate and _m.frame_rate.fps_numerator) or 24,
                start_tc_audio_samples = 0,
                start_tc_audio_rate = (_m.audio_channels and _m.audio_channels > 0)
                    and (_m.audio_sample_rate or 48000) or nil })
        end
        _m:save()
    end
end
-- V13: ensure_master builds the master sequence with V + A media_refs
-- from media_v's metadata (start_tc=VIDEO_SOURCE_IN, audio_channels=2,
-- audio_sample_rate=48000). The master itself becomes the test subject —
-- clip_edit_helper.resolve_audio_stream_timing reads its media_refs to
-- compute the audio stream timing under marks. No clips on a master under
-- INV-2 (master holds media_refs only).
local mc_id = Sequence.ensure_master("media_v", "project")
local mc = Sequence.load(mc_id)
assert(mc, "Failed to load master sequence")

-- Module imports kept for readability of the original test plan.
local _unused = { Track, Clip, AUDIO_SOURCE_IN, AUDIO_SOURCE_OUT, VIDEO_SOURCE_OUT }
local _ = _unused

-- Sanity: streams exist
assert(mc:video_stream(), "No video stream")
assert(#mc:audio_streams() > 0, "No audio streams")

-- ===================================================================
-- TEST 1: No marks — resolve_audio_stream_timing returns full range
-- ===================================================================
print("Test 1: No marks — full audio range")
local timing, err = clip_edit_helper.resolve_audio_stream_timing(mc)
assert(timing, "resolve_audio_stream_timing failed: " .. tostring(err))
assert(timing.duration == AUDIO_DURATION_SAMPLES,
    string.format("Expected duration=%d, got %d", AUDIO_DURATION_SAMPLES, timing.duration))
assert(timing.source_in == AUDIO_SOURCE_IN,
    string.format("Expected source_in=%d, got %d", AUDIO_SOURCE_IN, timing.source_in))
assert(timing.source_out == AUDIO_SOURCE_OUT,
    string.format("Expected source_out=%d, got %d", AUDIO_SOURCE_OUT, timing.source_out))
print("  PASS: duration=" .. timing.duration)

-- ===================================================================
-- TEST 2: mark_in set (absolute TC video frame) — audio duration must
--         be positive and correct
-- ===================================================================
print("\nTest 2: mark_in set — audio range must be positive and correct")
local mark_in_frame = VIDEO_SOURCE_IN + 10  -- 10 frames into clip
mc.mark_in = mark_in_frame
mc:save()
mc = Sequence.load(mc.id)

timing, err = clip_edit_helper.resolve_audio_stream_timing(mc)
assert(timing, "resolve_audio_stream_timing failed with mark_in: " .. tostring(err))
assert(timing.duration > 0,
    string.format("BUG: duration=%d (must be positive)", timing.duration))

-- Expected: 90 frames worth of samples = 90 * 2000 = 180000
local expected_audio_duration = (VIDEO_DURATION - 10) * AUDIO_SAMPLES_PER_FRAME
assert(timing.duration == expected_audio_duration,
    string.format("Expected duration=%d, got %d", expected_audio_duration, timing.duration))

-- source_in should be 10 frames into the audio = 10 * 2000 = 20000
local expected_audio_in = AUDIO_SOURCE_IN + 10 * AUDIO_SAMPLES_PER_FRAME
assert(timing.source_in == expected_audio_in,
    string.format("Expected source_in=%d, got %d", expected_audio_in, timing.source_in))
print("  PASS: duration=" .. timing.duration .. " source_in=" .. timing.source_in)

-- ===================================================================
-- TEST 3: mark_out set — audio range must be positive and correct
-- ===================================================================
print("\nTest 3: mark_out set — audio range must be positive and correct")
mc.mark_in = nil
mc.mark_out = VIDEO_SOURCE_IN + 50  -- 50 frames into clip
mc:save()
mc = Sequence.load(mc.id)

timing, err = clip_edit_helper.resolve_audio_stream_timing(mc)
assert(timing, "resolve_audio_stream_timing failed with mark_out: " .. tostring(err))
assert(timing.duration > 0,
    string.format("BUG: duration=%d (must be positive)", timing.duration))

local expected_audio_out = AUDIO_SOURCE_IN + 50 * AUDIO_SAMPLES_PER_FRAME
assert(timing.duration == expected_audio_out - AUDIO_SOURCE_IN,
    string.format("Expected duration=%d, got %d", expected_audio_out - AUDIO_SOURCE_IN, timing.duration))
print("  PASS: duration=" .. timing.duration)

-- ===================================================================
-- TEST 4: Both marks set
-- ===================================================================
print("\nTest 4: Both marks set — audio range must be positive and correct")
mc.mark_in = VIDEO_SOURCE_IN + 10
mc.mark_out = VIDEO_SOURCE_IN + 50
mc:save()
mc = Sequence.load(mc.id)

timing, err = clip_edit_helper.resolve_audio_stream_timing(mc)
assert(timing, "resolve_audio_stream_timing failed with both marks: " .. tostring(err))

local expected_duration = 40 * AUDIO_SAMPLES_PER_FRAME  -- 40 frames of audio
assert(timing.duration == expected_duration,
    string.format("Expected duration=%d, got %d", expected_duration, timing.duration))
expected_audio_in = AUDIO_SOURCE_IN + 10 * AUDIO_SAMPLES_PER_FRAME
expected_audio_out = AUDIO_SOURCE_IN + 50 * AUDIO_SAMPLES_PER_FRAME
assert(timing.source_in == expected_audio_in,
    string.format("Expected source_in=%d, got %d", expected_audio_in, timing.source_in))
assert(timing.source_out == expected_audio_out,
    string.format("Expected source_out=%d, got %d", expected_audio_out, timing.source_out))
print("  PASS: duration=" .. timing.duration .. " in=" .. timing.source_in .. " out=" .. timing.source_out)

-- ===================================================================
-- TEST 5: get_effective_video_in / get_effective_video_out
-- ===================================================================
print("\nTest 5: get_effective_video_in / get_effective_video_out")
mc.mark_in = VIDEO_SOURCE_IN + 10
mc.mark_out = VIDEO_SOURCE_IN + 50
assert(mc:get_effective_video_in() == VIDEO_SOURCE_IN + 10,
    "get_effective_video_in with mark_in")
assert(mc:get_effective_video_out() == VIDEO_SOURCE_IN + 50,
    "get_effective_video_out with mark_out")

mc.mark_in = nil
mc.mark_out = nil
assert(mc:get_effective_video_in() == VIDEO_SOURCE_IN,
    "get_effective_video_in without mark — should return video.source_in")
assert(mc:get_effective_video_out() == VIDEO_SOURCE_OUT,
    "get_effective_video_out without mark — should return video.source_out")
print("  PASS")

-- ===================================================================
-- TEST 6: get_effective_audio_in / get_effective_audio_out
-- ===================================================================
print("\nTest 6: get_effective_audio_in / get_effective_audio_out")
mc.mark_in = VIDEO_SOURCE_IN + 10
mc.mark_out = VIDEO_SOURCE_IN + 50

assert(mc:get_effective_audio_in() == AUDIO_SOURCE_IN + 10 * AUDIO_SAMPLES_PER_FRAME,
    "get_effective_audio_in with mark_in")
assert(mc:get_effective_audio_out() == AUDIO_SOURCE_IN + 50 * AUDIO_SAMPLES_PER_FRAME,
    "get_effective_audio_out with mark_out")

mc.mark_in = nil
mc.mark_out = nil
assert(mc:get_effective_audio_in() == AUDIO_SOURCE_IN,
    "get_effective_audio_in without mark — should return audio.source_in")
assert(mc:get_effective_audio_out() == AUDIO_SOURCE_OUT,
    "get_effective_audio_out without mark — should return audio.source_out")
print("  PASS")

-- ===================================================================
-- TEST 7: video_frame_to_audio_sample (coordinate-aware)
-- ===================================================================
print("\nTest 7: video_frame_to_audio_sample (coordinate-aware conversion)")
-- 10 frames into the clip → 10 * 2000 = 20000 samples from audio origin
local sample_pos = mc:video_frame_to_audio_sample(VIDEO_SOURCE_IN + 10)
assert(sample_pos == AUDIO_SOURCE_IN + 10 * AUDIO_SAMPLES_PER_FRAME,
    string.format("Expected %d, got %s", AUDIO_SOURCE_IN + 10 * AUDIO_SAMPLES_PER_FRAME, tostring(sample_pos)))

-- At video origin → audio origin
sample_pos = mc:video_frame_to_audio_sample(VIDEO_SOURCE_IN)
assert(sample_pos == AUDIO_SOURCE_IN,
    string.format("Expected %d, got %s", AUDIO_SOURCE_IN, tostring(sample_pos)))

-- At video end → audio end
sample_pos = mc:video_frame_to_audio_sample(VIDEO_SOURCE_OUT)
assert(sample_pos == AUDIO_SOURCE_OUT,
    string.format("Expected %d, got %s", AUDIO_SOURCE_OUT, tostring(sample_pos)))
print("  PASS")

print("\n✅ test_effective_audio_marks.lua passed")
