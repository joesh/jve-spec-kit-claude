require("test_env")
--[[
  TMB test: two clips from the SAME media file on different tracks.

  Verifies that two clips referencing the same file on V1 and V2 can both
  decode correctly during overlapping timeline regions (separate readers,
  independent seek positions).
]]

local EMP = qt_constants.EMP

print("=== test_tmb_same_file_two_tracks.lua ===")

-- Use the qtrle title card (local, reliable, SW decode).
-- Any multi-frame video file works — the bug is about same-file reader sharing.
local TEST_PATH = "/Users/joe/Local/Anamnesis/TEMP FOOTAGE/Alt Opening Anamnesis V2/A Little Seagull Production Title (transparent BG).mov"
local f = io.open(TEST_PATH, "r")
if not f then
    print("  SKIP: test file missing: " .. TEST_PATH)
    print("  test_tmb_same_file_two_tracks.lua passed (skipped)")
    return
end
f:close()

local media = assert(EMP.MEDIA_FILE_OPEN(TEST_PATH))
local info = EMP.MEDIA_FILE_INFO(media)
EMP.MEDIA_FILE_CLOSE(media)

local total_frames = math.floor(info.duration_us * info.fps_num / (1000000 * info.fps_den))
assert(total_frames >= 50, "need at least 50 frames, got " .. total_frames)
print(string.format("  file: %dx%d @ %d/%d fps, %d frames",
    info.width, info.height, info.fps_num, info.fps_den, total_frames))

-- Create TMB with 7 workers (prefetch mode) to test concurrent decode
local tmb = assert(EMP.TMB_CREATE(7))
EMP.TMB_SET_SEQUENCE_RATE(tmb, info.fps_num, info.fps_den)
EMP.TMB_SET_AUDIO_FORMAT(tmb, 48000, 2)
EMP.TMB_SET_SEQUENCE_RESOLUTION(tmb, 1920, 1080)

-- V1: frames 0..99 from source_in=0
EMP.TMB_SET_TRACK_CLIPS(tmb, "video", 1, {{
    clip_id = "same-file-v1",
    media_path = TEST_PATH,
    timeline_start = 0,
    duration = math.min(100, total_frames),
    source_in = 0,
    rate_num = info.fps_num,
    rate_den = info.fps_den,
    speed_ratio = 1.0,
}})

-- V2: frames 50..99 from source_in=25 (different source region, overlapping timeline)
local v2_source_in = 25
local v2_start = 50
local v2_duration = math.min(50, total_frames - v2_source_in)
EMP.TMB_SET_TRACK_CLIPS(tmb, "video", 2, {{
    clip_id = "same-file-v2",
    media_path = TEST_PATH,
    timeline_start = v2_start,
    duration = v2_duration,
    source_in = v2_source_in,
    rate_num = info.fps_num,
    rate_den = info.fps_den,
    speed_ratio = 1.0,
}})

print(string.format("  V1: tl=[0..%d) source_in=0", math.min(100, total_frames)))
print(string.format("  V2: tl=[%d..%d) source_in=%d", v2_start, v2_start + v2_duration, v2_source_in))

-- ========================================================================
-- Test: simulate playback through the overlap. V2 source PTS must advance.
-- ========================================================================
print("  simulating playback through overlap region...")

-- Start playback direction, let prefetch run
EMP.TMB_SET_PLAYHEAD(tmb, 0, 1, 1.0)
os.execute("sleep 0.5")  -- let prefetch warm up

local v2_source_frames = {}
local num_test_frames = math.min(10, v2_duration)

for i = 0, num_test_frames - 1 do
    local tl_frame = v2_start + i
    EMP.TMB_SET_PLAYHEAD(tmb, tl_frame, 1, 1.0)
    os.execute("sleep 0.05")  -- yield for prefetch

    -- Try cache first (playback mode), fall back to sync
    local frame, meta = EMP.TMB_GET_VIDEO_FRAME(tmb, 2, tl_frame, true)
    if not frame then
        frame, meta = EMP.TMB_GET_VIDEO_FRAME(tmb, 2, tl_frame, false)
    end
    assert(frame, string.format("V2 frame at tl=%d is nil (err=%s)",
        tl_frame, tostring(meta and meta.error_msg)))

    local fi = EMP.FRAME_INFO(frame)
    v2_source_frames[i] = fi.source_pts_us
    EMP.FRAME_RELEASE(frame)
end

-- Verify source PTS advances (not all the same = frozen)
local distinct_pts = {}
for i = 0, num_test_frames - 1 do
    distinct_pts[v2_source_frames[i]] = true
end

local num_distinct = 0
for _ in pairs(distinct_pts) do num_distinct = num_distinct + 1 end

print(string.format("  V2: %d frames decoded, %d distinct source PTS", num_test_frames, num_distinct))

-- At speed_ratio=1.0 with sequential source frames, each should have a unique PTS.
-- Allow 1 less than total (rounding) but definitely not 1 (frozen).
assert(num_distinct >= num_test_frames - 1, string.format(
    "V2 FROZEN: only %d distinct source PTS out of %d frames. "..
    "Same-file clips on different tracks cause V2 to repeat first frame.",
    num_distinct, num_test_frames))

-- Also verify V1 still works during the overlap
print("  verifying V1 during overlap...")
local v1_source_frames = {}
for i = 0, num_test_frames - 1 do
    local tl_frame = v2_start + i
    local frame, meta = EMP.TMB_GET_VIDEO_FRAME(tmb, 1, tl_frame)
    assert(frame, string.format("V1 frame at tl=%d is nil (err=%s)",
        tl_frame, tostring(meta and meta.error_msg)))
    local fi = EMP.FRAME_INFO(frame)
    v1_source_frames[i] = fi.source_pts_us
    EMP.FRAME_RELEASE(frame)
end

local v1_distinct = {}
for i = 0, num_test_frames - 1 do
    v1_distinct[v1_source_frames[i]] = true
end
local v1_num_distinct = 0
for _ in pairs(v1_distinct) do v1_num_distinct = v1_num_distinct + 1 end

print(string.format("  V1: %d frames decoded, %d distinct source PTS", num_test_frames, v1_num_distinct))
assert(v1_num_distinct >= num_test_frames - 1, string.format(
    "V1 FROZEN during overlap: only %d distinct PTS out of %d frames.",
    v1_num_distinct, num_test_frames))

-- Verify V1 and V2 have DIFFERENT source PTS (they read different regions)
local same_count = 0
for i = 0, num_test_frames - 1 do
    if v1_source_frames[i] == v2_source_frames[i] then
        same_count = same_count + 1
    end
end
assert(same_count < num_test_frames / 2, string.format(
    "V1 and V2 source PTS overlap too much (%d/%d same). "..
    "Clips should read different source regions.",
    same_count, num_test_frames))

EMP.TMB_CLOSE(tmb)
print("  test_tmb_same_file_two_tracks.lua passed")
