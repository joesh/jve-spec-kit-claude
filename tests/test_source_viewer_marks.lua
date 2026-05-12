#!/usr/bin/env luajit

-- Test: Source viewer marks live on sequence, NOT on stream clips.
-- Regression: marks stored as source_in/source_out on stream clips constrained
-- the rendering view — source viewer couldn't show frames before mark_in.

require('test_env')

local database = require('core.database')
local Sequence = require('models.sequence')
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
    INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at)
    VALUES ('project', 'Test', 'resample', %d, %d);
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
media:save(db)  -- must persist BEFORE ensure_master loads it

-- V13: master sequence wrapping the media for clip references.
do
    local _Media = require("models.media")
    local _json = require("dkjson")
    local _m = _Media.load("media_1")
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
-- V13: ensure_master creates the master Sequence + V/A tracks + media_refs
-- in one shot. video_stream / audio_streams read from media_refs (no
-- 'clips inside master' table — clips must be owned by a kind='sequence' sequence).
local MC_TEST = Sequence.ensure_master("media_1", "project")
local mc = Sequence.load(MC_TEST)
assert(mc, "ensure_master should produce a loadable master")
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
-- 7. Marks work on any sequence kind (no is_masterclip guard)
--------------------------------------------------------------------------------
print("\n--- Marks on timeline (any sequence kind) ---")
local tl = Sequence.create("Timeline", "project",
    { fps_numerator = 24, fps_denominator = 1}, 1920, 1080,
    {kind = "sequence", audio_sample_rate = 48000 })
assert(tl:save(), "Failed to save timeline")

tl:set_in(10)
check("set_in works on timeline", tl:get_in() == 10)

tl:set_out(90)
check("set_out works on timeline", tl:get_out() == 90)

tl:clear_marks()
check("clear_marks works on timeline (in)", tl:get_in() == nil)
check("clear_marks works on timeline (out)", tl:get_out() == nil)

--------------------------------------------------------------------------------
-- 8. Implicit mark boundaries (one mark set → other at begin/end)
--------------------------------------------------------------------------------
print("\n--- Implicit mark boundaries ---")

-- Use masterclip mc for these tests (100 frames of video)
mc:clear_marks()

-- has_marks: false when neither set
check("has_marks false when both nil", mc:has_marks() == false)

-- Only mark_in set → effective_out = total_frames
mc:set_in(20)
check("has_marks true with mark_in only", mc:has_marks() == true)
check("get_effective_in returns mark_in", mc:get_effective_in() == 20)
check("get_effective_out returns total_frames",
    mc:get_effective_out(100) == 100,
    "expected 100, got " .. tostring(mc:get_effective_out(100)))
check("raw get_out still nil", mc:get_out() == nil)

-- Only mark_out set → effective_in = 0
mc:clear_marks()
mc:set_out(80)
check("has_marks true with mark_out only", mc:has_marks() == true)
check("get_effective_in returns 0", mc:get_effective_in() == 0)
check("get_effective_out returns mark_out", mc:get_effective_out(100) == 80)
check("raw get_in still nil", mc:get_in() == nil)

-- Both set → effective = raw
mc:set_in(10)
check("both set: effective_in = mark_in", mc:get_effective_in() == 10)
check("both set: effective_out = mark_out", mc:get_effective_out(100) == 80)

-- Neither set → effective = full range
mc:clear_marks()
check("neither set: effective_in = 0", mc:get_effective_in() == 0)
check("neither set: effective_out = total_frames", mc:get_effective_out(100) == 100)

-- Error: get_effective_out requires total_frames
local ok_eff = pcall(function() mc:get_effective_out() end)
check("get_effective_out asserts without total_frames", not ok_eff)

local ok_eff2 = pcall(function() mc:get_effective_out("bad") end)
check("get_effective_out asserts on non-number", not ok_eff2)

--------------------------------------------------------------------------------
-- Summary
--------------------------------------------------------------------------------
print(string.format("\n%d passed, %d failed", pass_count, fail_count))
assert(fail_count == 0, fail_count .. " tests failed")
print("\n✅ test_source_viewer_marks.lua passed")
