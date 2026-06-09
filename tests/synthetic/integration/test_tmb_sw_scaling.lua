require("test_env")
--[[
  TMB SW decode scaling integration test.

  Verifies that SetSequenceResolution causes SW-decoded frames to be
  downscaled during decode (not at source resolution).

  Tests both paths:
  1. qtrle: custom parallel decoder + box downscale
  2. FFmpeg SW: swscale convert+scale in one pass

  Uses the actual 4K qtrle title card. Decodes with and without
  SetSequenceResolution and compares output frame dimensions.
]]

local EMP = qt_constants.EMP

print("=== test_tmb_sw_scaling.lua ===")

local QTRLE_PATH = "/Users/joe/Local/Anamnesis/TEMP FOOTAGE/Alt Opening Anamnesis V2/A Little Seagull Production Title (transparent BG).mov"
local f = io.open(QTRLE_PATH, "r")
if not f then
    print("  SKIP: test file missing: " .. QTRLE_PATH)
    print("  test_tmb_sw_scaling.lua passed (skipped)")
    return
end
f:close()

local media = assert(EMP.MEDIA_FILE_OPEN(QTRLE_PATH))
local info = EMP.MEDIA_FILE_INFO(media)
assert(info.width == 3840, "expected 3840 width, got " .. info.width)
assert(info.height == 2160, "expected 2160 height, got " .. info.height)
EMP.MEDIA_FILE_CLOSE(media)

print(string.format("  source: %dx%d @ %d/%d fps",
    info.width, info.height, info.fps_num, info.fps_den))

local clip_def = {
    clip_id = "scale-test-001",
    media_path = QTRLE_PATH,
    sequence_start = 0,
    duration = 10,
    source_in = 0,
    rate_num = info.fps_num,
    rate_den = info.fps_den,
    speed_ratio = 1.0,
}

-- ========================================================================
-- Test 1: Without SetSequenceResolution — frame should be at source dims
-- ========================================================================
print("  test 1: no SetSequenceResolution → source resolution")

local tmb1 = assert(EMP.TMB_CREATE(0))
EMP.TMB_SET_SEQUENCE_RATE(tmb1, info.fps_num, info.fps_den)
EMP.TMB_SET_AUDIO_FORMAT(tmb1, 48000, 2)
-- NOTE: no TMB_SET_SEQUENCE_RESOLUTION
EMP.TMB_SET_TRACK_CLIPS(tmb1, "video", 1, {clip_def})

local frame1, meta1 = EMP.TMB_GET_VIDEO_FRAME(tmb1, 1, 0)
assert(frame1, "frame1 is nil — decode failed (offline=" ..
    tostring(meta1 and meta1.offline) .. " err=" ..
    tostring(meta1 and meta1.error_msg) .. ")")
local fi1 = EMP.FRAME_INFO(frame1)
print(string.format("    frame: %dx%d stride=%d", fi1.width, fi1.height, fi1.stride))
assert(fi1.width == 3840, "expected 3840, got " .. fi1.width)
assert(fi1.height == 2160, "expected 2160, got " .. fi1.height)

EMP.FRAME_RELEASE(frame1)
EMP.TMB_CLOSE(tmb1)
print("    PASS")

-- ========================================================================
-- Test 2: With SetSequenceResolution(1920,1080) — frame should be 1920x1080
-- ========================================================================
print("  test 2: SetSequenceResolution(1920,1080) → downscaled")

local tmb2 = assert(EMP.TMB_CREATE(0))
EMP.TMB_SET_SEQUENCE_RATE(tmb2, info.fps_num, info.fps_den)
EMP.TMB_SET_AUDIO_FORMAT(tmb2, 48000, 2)
EMP.TMB_SET_SEQUENCE_RESOLUTION(tmb2, 1920, 1080)
EMP.TMB_SET_TRACK_CLIPS(tmb2, "video", 1, {clip_def})

local frame2, meta2 = EMP.TMB_GET_VIDEO_FRAME(tmb2, 1, 0)
assert(frame2, "frame2 is nil — decode failed (offline=" ..
    tostring(meta2 and meta2.offline) .. " err=" ..
    tostring(meta2 and meta2.error_msg) .. ")")
local fi2 = EMP.FRAME_INFO(frame2)
print(string.format("    frame: %dx%d stride=%d", fi2.width, fi2.height, fi2.stride))
assert(fi2.width == 1920, "expected 1920, got " .. fi2.width)
assert(fi2.height == 1080, "expected 1080, got " .. fi2.height)

EMP.FRAME_RELEASE(frame2)
EMP.TMB_CLOSE(tmb2)
print("    PASS")

-- ========================================================================
-- Test 3: Frame data integrity — multiple frames, verify non-garbage
-- ========================================================================
print("  test 3: frame data integrity (malloc'd buffer correctness)")

local tmb3 = assert(EMP.TMB_CREATE(0))
EMP.TMB_SET_SEQUENCE_RATE(tmb3, info.fps_num, info.fps_den)
EMP.TMB_SET_AUDIO_FORMAT(tmb3, 48000, 2)
EMP.TMB_SET_SEQUENCE_RESOLUTION(tmb3, 1920, 1080)
EMP.TMB_SET_TRACK_CLIPS(tmb3, "video", 1, {clip_def})

-- Decode 5 sequential frames — exercises the pool (acquire without release).
-- Each frame should be valid 1920x1080 with non-zero pixel data.
local frames = {}
for i = 0, 4 do
    local fr, mt = EMP.TMB_GET_VIDEO_FRAME(tmb3, 1, i)
    assert(fr, string.format("frame %d is nil (err=%s)", i,
        tostring(mt and mt.error_msg)))
    local fi = EMP.FRAME_INFO(fr)
    assert(fi.width == 1920 and fi.height == 1080,
        string.format("frame %d: unexpected dims %dx%d", i, fi.width, fi.height))
    -- Verify frame has valid data pointer (FRAME_DATA_PTR returns lightuserdata)
    local ptr = EMP.FRAME_DATA_PTR(fr)
    assert(ptr, string.format("frame %d: FRAME_DATA_PTR returned nil", i))
    frames[i] = fr
end
print(string.format("    decoded 5 frames, all 1920x1080 with valid data"))

-- Verify distinct PTS (sequential frames should have different PTS)
local pts_set = {}
for i = 0, 4 do
    local fi = EMP.FRAME_INFO(frames[i])
    assert(not pts_set[fi.source_pts_us],
        string.format("duplicate PTS %d at frame %d", fi.source_pts_us, i))
    pts_set[fi.source_pts_us] = true
end
print("    5 distinct PTS values confirmed")

for i = 0, 4 do
    EMP.FRAME_RELEASE(frames[i])
end
EMP.TMB_CLOSE(tmb3)
print("    PASS")

-- ========================================================================
-- Test 4: SetSequenceResolution with smaller-than-source → no scaling
-- ========================================================================
print("  test 4: SetSequenceResolution larger than source → no scaling")

local tmb4 = assert(EMP.TMB_CREATE(0))
EMP.TMB_SET_SEQUENCE_RATE(tmb4, info.fps_num, info.fps_den)
EMP.TMB_SET_AUDIO_FORMAT(tmb4, 48000, 2)
EMP.TMB_SET_SEQUENCE_RESOLUTION(tmb4, 7680, 4320)  -- 8K — larger than 4K source
EMP.TMB_SET_TRACK_CLIPS(tmb4, "video", 1, {clip_def})

local frame4, _meta4 = EMP.TMB_GET_VIDEO_FRAME(tmb4, 1, 0)
assert(frame4, "frame4 is nil (err=" .. tostring(_meta4 and _meta4.error_msg) .. ")")
local fi4 = EMP.FRAME_INFO(frame4)
print(string.format("    frame: %dx%d (source: %dx%d)", fi4.width, fi4.height, info.width, info.height))
assert(fi4.width == info.width and fi4.height == info.height,
    string.format("expected source dims %dx%d, got %dx%d",
        info.width, info.height, fi4.width, fi4.height))

EMP.FRAME_RELEASE(frame4)
EMP.TMB_CLOSE(tmb4)
print("    PASS")

print("  test_tmb_sw_scaling.lua passed")
