require("test_env")
--[[
  TMB qtrle prefetch regression test — real 4K file, full clip duration.

  Uses the actual 4K qtrle title card (3840x2160, 50 frames at 25fps = 2s).
  Simulates real playback by advancing the playhead at 25fps and checking
  that the prefetch keeps up (frames available in cache when needed).

  Production config: 7 worker threads, sequence resolution 1920x1080.

  The bug: 4K SW-decoded frames cause 130ms page fault overhead per
  allocation. Prefetch falls behind the playhead and frames show as
  cache misses (has_frame=0) during playback.
]]

local EMP = qt_constants.EMP

print("=== test_tmb_qtrle_prefetch.lua ===")

-- Use the ACTUAL title card from the project — the real file that fails.
local QTRLE_PATH = "/Users/joe/Local/Anamnesis/TEMP FOOTAGE/Alt Opening Anamnesis V2/A Little Seagull Production Title (transparent BG).mov"
local f = io.open(QTRLE_PATH, "r")
if not f then
    print("  SKIP: test file missing: " .. QTRLE_PATH)
    print("✅ test_tmb_qtrle_prefetch.lua passed (skipped)")
    return
end
f:close()

local media, err = EMP.MEDIA_FILE_OPEN(QTRLE_PATH)
assert(media, "MEDIA_FILE_OPEN failed: " .. tostring(err))
local info = EMP.MEDIA_FILE_INFO(media)
local total_frames = math.floor(info.duration_us * info.fps_num / (1000000 * info.fps_den))
print(string.format("  qtrle: %dx%d @ %d/%d fps, %d frames (%.1fs)",
    info.width, info.height, info.fps_num, info.fps_den,
    total_frames, total_frames * info.fps_den / info.fps_num))
EMP.MEDIA_FILE_CLOSE(media)

-- Production config: 7 threads (6 video + 1 audio), 1080p sequence
local tmb = assert(EMP.TMB_CREATE(7))
EMP.TMB_SET_SEQUENCE_RATE(tmb, info.fps_num, info.fps_den)
EMP.TMB_SET_AUDIO_FORMAT(tmb, 48000, 2)
EMP.TMB_SET_SEQUENCE_RESOLUTION(tmb, 1920, 1080)

EMP.TMB_SET_TRACK_CLIPS(tmb, "video", 1, {{
    clip_id = "test-qtrle-001",
    media_path = QTRLE_PATH,
    timeline_start = 0,
    duration = total_frames,
    source_in = 0,
    rate_num = info.fps_num,
    rate_den = info.fps_den,
    speed_ratio = 1.0,
}})

-- Simulate playback: advance playhead and check cache at real frame rate.
-- Uses os.execute("sleep") to yield CPU so GCD prefetch workers can run.
-- (A busy-wait loop starves GCD's global queue — workers can't decode.)
print("  simulating " .. total_frames .. " frames of playback...")
local hits = 0
local misses = 0
local BATCH_SIZE = 5  -- check 5 frames per sleep to reduce subprocess overhead
local frame_period_s = info.fps_den / info.fps_num  -- 0.04s at 25fps

EMP.TMB_SET_PLAYHEAD(tmb, 0, 1, 1.0)

-- Let prefetch warm up (first frame decode + pool init)
os.execute("sleep 0.5")

for frame = 0, total_frames - 1 do
    EMP.TMB_SET_PLAYHEAD(tmb, frame, 1, 1.0)
    -- Yield CPU every BATCH_SIZE frames so prefetch workers can run
    if frame % BATCH_SIZE == 0 then
        os.execute(string.format("sleep %.3f", frame_period_s * BATCH_SIZE))
    end
    local result = EMP.TMB_GET_VIDEO_FRAME(tmb, 1, frame, true)
    if result then
        hits = hits + 1
    else
        misses = misses + 1
    end
end

local hit_pct = hits * 100 / total_frames
print(string.format("  result: %d/%d cache hits (%.0f%%), %d misses",
    hits, total_frames, hit_pct, misses))

-- Require >= 90% cache hit rate. A few misses at the start (cold cache)
-- are acceptable. Sustained misses mean prefetch can't keep up.
assert(hit_pct >= 90, string.format(
    "qtrle prefetch can't sustain real-time: %.0f%% hit rate (%d/%d). "..
    "Prefetch decode (%.0fms budget) is too slow for %dfps playback.",
    hit_pct, hits, total_frames, frame_period_s * 1000, info.fps_num / info.fps_den))

EMP.TMB_CLOSE(tmb)
print("✅ test_tmb_qtrle_prefetch.lua passed")
