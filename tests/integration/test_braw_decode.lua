require("test_env")
--[[
  BRAW SDK integration test — probes and decodes a .braw file.

  Uses the SDK sample file (always present if SDK is installed).
  Tests: MediaFile::Open metadata extraction, Reader frame decode,
  SetSequenceResolution scaling, frame data integrity.
]]

local EMP = qt_constants.EMP

print("=== test_braw_decode.lua ===")

-- Try a real multi-frame BRAW file first (external drive), fall back to SDK sample
local BRAW_CANDIDATES = {
    "/Volumes/AnamBack4 Joe/Footage/Day 15/A001/A001_07232345_C010.braw",
    "/Applications/Blackmagic RAW/Blackmagic RAW SDK/Media/sample.braw",
}
local BRAW_PATH
for _, path in ipairs(BRAW_CANDIDATES) do
    local f = io.open(path, "r")
    if f then
        f:close()
        BRAW_PATH = path
        break
    end
end
if not BRAW_PATH then
    print("  SKIP: no BRAW test file found")
    print("  test_braw_decode.lua passed (skipped)")
    return
end

-- ========================================================================
-- Test 1: MediaFile::Open probes BRAW metadata
-- ========================================================================
print("  test 1: BRAW metadata probe")

local media, err = EMP.MEDIA_FILE_OPEN(BRAW_PATH)
assert(media, "MEDIA_FILE_OPEN failed: " .. tostring(err))
local info = EMP.MEDIA_FILE_INFO(media)

assert(info.width > 0, "width must be > 0, got " .. info.width)
assert(info.height > 0, "height must be > 0, got " .. info.height)
assert(info.fps_num > 0, "fps_num must be > 0, got " .. info.fps_num)
assert(info.fps_den > 0, "fps_den must be > 0, got " .. info.fps_den)
assert(info.duration_us > 0, "duration_us must be > 0")
assert(info.has_video, "BRAW file should have video")

print(string.format("    %dx%d @ %d/%d fps, duration=%.2fs",
    info.width, info.height, info.fps_num, info.fps_den,
    info.duration_us / 1000000.0))

-- Round up to handle single-frame files (duration math rounds down to 0)
local total_frames = math.max(1, math.floor(
    info.duration_us * info.fps_num / (1000000 * info.fps_den) + 0.5))
print(string.format("    %d frames, first_frame_tc=%d", total_frames, info.first_frame_tc or 0))
assert(total_frames > 0, "total_frames must be > 0, got " .. total_frames
    .. " (duration_us=" .. info.duration_us .. ")")

EMP.MEDIA_FILE_CLOSE(media)
print("    PASS")

-- ========================================================================
-- Test 2: TMB sync decode — frame at source resolution
-- ========================================================================
print("  test 2: BRAW frame decode (source resolution)")

local tmb = assert(EMP.TMB_CREATE(0))
EMP.TMB_SET_SEQUENCE_RATE(tmb, info.fps_num, info.fps_den)
EMP.TMB_SET_AUDIO_FORMAT(tmb, 48000, 2)
-- No SetSequenceResolution — decode at native resolution

EMP.TMB_SET_TRACK_CLIPS(tmb, "video", 1, {{
    clip_id = "braw-test-001",
    media_path = BRAW_PATH,
    sequence_start = 0,
    duration = math.min(10, total_frames),
    source_in = info.first_frame_tc or 0,
    rate_num = info.fps_num,
    rate_den = info.fps_den,
    speed_ratio = 1.0,
}})

local frame, meta = EMP.TMB_GET_VIDEO_FRAME(tmb, 1, 0)
assert(frame, "frame is nil (offline=" .. tostring(meta and meta.offline)
    .. " err=" .. tostring(meta and meta.error_msg) .. ")")

local fi = EMP.FRAME_INFO(frame)
print(string.format("    frame: %dx%d stride=%d pts=%d",
    fi.width, fi.height, fi.stride, fi.source_pts_us))
assert(fi.width == info.width, "expected width " .. info.width .. " got " .. fi.width)
assert(fi.height == info.height, "expected height " .. info.height .. " got " .. fi.height)

-- Verify frame has valid data pointer
local ptr = EMP.FRAME_DATA_PTR(frame)
assert(ptr, "FRAME_DATA_PTR returned nil")

EMP.FRAME_RELEASE(frame)
EMP.TMB_CLOSE(tmb)
print("    PASS")

-- ========================================================================
-- Test 3: Decode with SetSequenceResolution — should downscale
-- ========================================================================
print("  test 3: BRAW decode with resolution scaling")

local tmb2 = assert(EMP.TMB_CREATE(0))
EMP.TMB_SET_SEQUENCE_RATE(tmb2, info.fps_num, info.fps_den)
EMP.TMB_SET_AUDIO_FORMAT(tmb2, 48000, 2)
EMP.TMB_SET_SEQUENCE_RESOLUTION(tmb2, 1920, 1080)

EMP.TMB_SET_TRACK_CLIPS(tmb2, "video", 1, {{
    clip_id = "braw-scale-001",
    media_path = BRAW_PATH,
    sequence_start = 0,
    duration = math.min(10, total_frames),
    source_in = info.first_frame_tc or 0,
    rate_num = info.fps_num,
    rate_den = info.fps_den,
    speed_ratio = 1.0,
}})

local frame2, meta2 = EMP.TMB_GET_VIDEO_FRAME(tmb2, 1, 0)
assert(frame2, "frame2 is nil (err=" .. tostring(meta2 and meta2.error_msg) .. ")")

local fi2 = EMP.FRAME_INFO(frame2)
print(string.format("    frame: %dx%d (source: %dx%d)", fi2.width, fi2.height, info.width, info.height))
-- SDK scales to Half/Quarter/Eighth — output should be <= sequence resolution
assert(fi2.width <= info.width, "scaled width should be <= source")
assert(fi2.height <= info.height, "scaled height should be <= source")
-- If source > 1920x1080, output should be smaller than source
if info.width > 1920 or info.height > 1080 then
    assert(fi2.width < info.width or fi2.height < info.height,
        "source > 1080p but output wasn't scaled down")
end

EMP.FRAME_RELEASE(frame2)
EMP.TMB_CLOSE(tmb2)
print("    PASS")

-- ========================================================================
-- Test 4: Multiple sequential frames — distinct PTS
-- ========================================================================
print("  test 4: sequential frames have distinct PTS")

local tmb3 = assert(EMP.TMB_CREATE(0))
EMP.TMB_SET_SEQUENCE_RATE(tmb3, info.fps_num, info.fps_den)
EMP.TMB_SET_AUDIO_FORMAT(tmb3, 48000, 2)

EMP.TMB_SET_TRACK_CLIPS(tmb3, "video", 1, {{
    clip_id = "braw-seq-001",
    media_path = BRAW_PATH,
    sequence_start = 0,
    duration = math.min(10, total_frames),
    source_in = info.first_frame_tc or 0,
    rate_num = info.fps_num,
    rate_den = info.fps_den,
    speed_ratio = 1.0,
}})

local pts_set = {}
local num_frames = math.min(5, total_frames)
for i = 0, num_frames - 1 do
    local fr = assert(EMP.TMB_GET_VIDEO_FRAME(tmb3, 1, i))
    local fi_n = EMP.FRAME_INFO(fr)
    pts_set[fi_n.source_pts_us] = true
    EMP.FRAME_RELEASE(fr)
end

local num_distinct = 0
for _ in pairs(pts_set) do num_distinct = num_distinct + 1 end
print(string.format("    %d frames, %d distinct PTS", num_frames, num_distinct))
assert(num_distinct >= num_frames - 1,
    "expected distinct PTS for sequential frames, got " .. num_distinct)

EMP.TMB_CLOSE(tmb3)
print("    PASS")

print("  test_braw_decode.lua passed")
