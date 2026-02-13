#!/usr/bin/env luajit

-- Test: Source viewer marks live on sequence, NOT on stream clips.
-- Regression: marks stored as source_in/source_out on stream clips constrained
-- the rendering view — source viewer couldn't show frames before mark_in.

require('test_env')

local database = require('core.database')
local Sequence = require('models.sequence')
local Track = require('models.track')
local Clip = require('models.clip')
local Media = require('models.media')

print("=== test_source_viewer_marks.lua ===\n")

-- Setup DB
local db_path = "/tmp/jve/test_source_viewer_marks.db"
os.remove(db_path)
os.execute("mkdir -p /tmp/jve")
database.init(db_path)
local db = database.get_connection()
db:exec(require('import_schema'))

local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, created_at, modified_at)
    VALUES ('project', 'Test', %d, %d);
]], now, now))

-- Create media (A/V, 24fps, 48kHz, 100s = 2400 frames)
local media = Media.create({
    id = "media_1",
    project_id = "project",
    file_path = "/tmp/jve/test_video.mov",
    name = "Test Video",
    duration_frames = 2400,
    fps_numerator = 24,
    fps_denominator = 1,
    width = 1920,
    height = 1080,
    audio_channels = 2,
    audio_sample_rate = 48000,
})
media:save(db)

-- Create masterclip sequence with stream clips at full range
local mc = Sequence.create("Test MC", "project",
    {fps_numerator = 24, fps_denominator = 1},
    1920, 1080,
    {kind = "masterclip"})
assert(mc:save(), "Failed to save masterclip")

local v_track = Track.create_video("V1", mc.id, {index = 1})
assert(v_track:save(), "Failed to save video track")
local a_track = Track.create_audio("A1", mc.id, {index = 1})
assert(a_track:save(), "Failed to save audio track")

local v_clip = Clip.create("Video Stream", "media_1", {
    track_id = v_track.id,
    owner_sequence_id = mc.id,
    timeline_start = 0,
    duration = 2400,
    source_in = 0,
    source_out = 2400,
    fps_numerator = 24,
    fps_denominator = 1,
})
assert(v_clip:save({skip_occlusion = true}), "Failed to save video clip")

local a_clip = Clip.create("Audio Stream", "media_1", {
    track_id = a_track.id,
    owner_sequence_id = mc.id,
    timeline_start = 0,
    duration = 4800000,  -- 2400 frames * 2000 samples/frame
    source_in = 0,
    source_out = 4800000,
    fps_numerator = 48000,
    fps_denominator = 1,
})
assert(a_clip:save({skip_occlusion = true}), "Failed to save audio clip")

mc:invalidate_stream_cache()

local pass_count = 0
local fail_count = 0

local function check(label, condition, msg)
    if condition then
        pass_count = pass_count + 1
    else
        fail_count = fail_count + 1
        print("FAIL: " .. label .. (msg and (" — " .. msg) or ""))
    end
end

--------------------------------------------------------------------------------
-- 1. Initial state: no marks set
--------------------------------------------------------------------------------
print("--- Initial state ---")
check("mark_in starts nil", mc:get_in() == nil)
check("mark_out starts nil", mc:get_out() == nil)
check("video source_in is 0", mc:video_stream().source_in == 0)
check("video source_out is 2400", mc:video_stream().source_out == 2400)

--------------------------------------------------------------------------------
-- 2. Set marks — stream clips must NOT change
--------------------------------------------------------------------------------
print("\n--- Set marks ---")
mc:set_in(100)
mc:set_out(200)

check("mark_in is 100", mc.mark_in == 100,
    "got " .. tostring(mc.mark_in))
check("mark_out is 200", mc.mark_out == 200,
    "got " .. tostring(mc.mark_out))

-- CRITICAL: stream clips must be untouched
mc:invalidate_stream_cache()
local v = mc:video_stream()
check("video source_in still 0 after set_in",
    v.source_in == 0, "got " .. tostring(v.source_in))
check("video source_out still 2400 after set_out",
    v.source_out == 2400, "got " .. tostring(v.source_out))

local a = mc:audio_streams()[1]
check("audio source_in still 0 after set_in",
    a.source_in == 0, "got " .. tostring(a.source_in))
check("audio source_out still 4800000 after set_out",
    a.source_out == 4800000, "got " .. tostring(a.source_out))

--------------------------------------------------------------------------------
-- 3. Rendering unaffected: get_video_at reads clip.source_in (always 0)
--------------------------------------------------------------------------------
print("\n--- Rendering unaffected ---")
local results_at_0 = mc:get_video_at(0)
assert(#results_at_0 > 0, "get_video_at(0) should return a result")
check("source_frame at playhead 0 is 0 (not 100)",
    results_at_0[1].source_frame == 0,
    "got " .. tostring(results_at_0[1].source_frame))

local results_at_50 = mc:get_video_at(50)
assert(#results_at_50 > 0, "get_video_at(50) should return a result")
check("source_frame at playhead 50 is 50",
    results_at_50[1].source_frame == 50,
    "got " .. tostring(results_at_50[1].source_frame))

local results_at_150 = mc:get_video_at(150)
assert(#results_at_150 > 0, "get_video_at(150) should return a result")
check("source_frame at playhead 150 is 150",
    results_at_150[1].source_frame == 150,
    "got " .. tostring(results_at_150[1].source_frame))

--------------------------------------------------------------------------------
-- 4. get_in / get_out read from sequence
--------------------------------------------------------------------------------
print("\n--- get_in / get_out ---")
check("get_in() returns 100", mc:get_in() == 100,
    "got " .. tostring(mc:get_in()))
check("get_out() returns 200", mc:get_out() == 200,
    "got " .. tostring(mc:get_out()))

--------------------------------------------------------------------------------
-- 5. Clear marks
--------------------------------------------------------------------------------
print("\n--- Clear marks ---")
mc:clear_marks()
check("mark_in nil after clear", mc:get_in() == nil)
check("mark_out nil after clear", mc:get_out() == nil)

-- Stream clips still untouched
mc:invalidate_stream_cache()
check("video source_in still 0 after clear",
    mc:video_stream().source_in == 0)
check("video source_out still 2400 after clear",
    mc:video_stream().source_out == 2400)

--------------------------------------------------------------------------------
-- 6. Marks persist through save/load cycle
--------------------------------------------------------------------------------
print("\n--- Persistence ---")
mc:set_in(300)
mc:set_out(500)

local mc_reloaded = Sequence.load(mc.id)
assert(mc_reloaded, "Failed to reload masterclip")
check("mark_in persists after reload", mc_reloaded.mark_in == 300,
    "got " .. tostring(mc_reloaded.mark_in))
check("mark_out persists after reload", mc_reloaded.mark_out == 500,
    "got " .. tostring(mc_reloaded.mark_out))

-- Clear persists too
mc:clear_marks()
mc_reloaded = Sequence.load(mc.id)
check("nil mark_in persists after clear+reload", mc_reloaded.mark_in == nil)
check("nil mark_out persists after clear+reload", mc_reloaded.mark_out == nil)

--------------------------------------------------------------------------------
-- 7. Asserts on non-masterclip
--------------------------------------------------------------------------------
print("\n--- Non-masterclip guards ---")
local timeline = Sequence.create("Timeline", "project",
    {fps_numerator = 24, fps_denominator = 1}, 1920, 1080)
assert(timeline:save(), "Failed to save timeline")

local ok = pcall(function() timeline:set_in(10) end)
check("set_in asserts on timeline", not ok)

ok = pcall(function() timeline:set_out(10) end)
check("set_out asserts on timeline", not ok)

ok = pcall(function() timeline:get_in() end)
check("get_in asserts on timeline", not ok)

ok = pcall(function() timeline:get_out() end)
check("get_out asserts on timeline", not ok)

ok = pcall(function() timeline:clear_marks() end)
check("clear_marks asserts on timeline", not ok)

--------------------------------------------------------------------------------
-- Summary
--------------------------------------------------------------------------------
print(string.format("\n%d passed, %d failed", pass_count, fail_count))
assert(fail_count == 0, fail_count .. " tests failed")
print("\n✅ test_source_viewer_marks.lua passed")
