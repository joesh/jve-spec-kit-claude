-- Integration test: 4K qtrle playback delivers near-realtime unique frames.
--
-- DOMAIN INVARIANT: When the editor plays a 4K QuickTime RLE file at 25 fps,
-- the viewer should see ~25 visually distinct frames per second. Anything
-- drastically less means the decode/prefetch/cache/delivery pipeline is
-- stalling or collapsing frames (e.g. stride > 1 from inflated decode-speed
-- measurements, refill worker starvation, reader pool starvation, etc.).
--
-- This is a COARSE smoke test for the full playback path — NOT a precise
-- regression guard for any single knob. If 4K qtrle playback breaks in a way
-- that kills frame delivery (any cause), this should catch it.
--
-- BLACK-BOX: real PlaybackController, TMB, GPUVideoSurface, 4K qtrle file.
-- 120 ticks × 16ms ≈ 2 s of playback. At 25 fps that is 48–50 delivered
-- frames. Observed baseline: 45–48 unique (variance from startup pre-roll
-- and boundary stop). Threshold 40 leaves headroom for jitter while still
-- catching any gross pipeline failure (e.g. ≤ 12 unique under stride = 4,
-- ≤ 1 under sync-decode cache miss, 0 under total refill collapse).

local env = require("synthetic.integration.integration_test_env")

print("=== test_tmb_qtrle_stride.lua ===")

local EMP = env.require_emp()
local PLAYBACK = qt_constants.PLAYBACK
assert(PLAYBACK, "PLAYBACK bindings not available")

local WIDGET = qt_constants.WIDGET
assert(WIDGET and WIDGET.CREATE_GPU_VIDEO_SURFACE,
    "CREATE_GPU_VIDEO_SURFACE not available")

local QTRLE_PATH = "/tmp/test_qtrle_4k.mov"
local f = io.open(QTRLE_PATH, "r")
if not f then
    print("  SKIP: test file missing: " .. QTRLE_PATH)
    print("✅ test_tmb_qtrle_stride.lua passed (skipped)")
    return
end
f:close()

-- Create surface
local ok_surf, surface = pcall(WIDGET.CREATE_GPU_VIDEO_SURFACE)
if not ok_surf or not surface then
    print("  SKIP: GPU surface creation failed (headless?)")
    print("✅ test_tmb_qtrle_stride.lua passed (skipped)")
    return
end

-- Probe file
local media = assert(EMP.MEDIA_FILE_OPEN(QTRLE_PATH))
local info = EMP.MEDIA_FILE_INFO(media)
EMP.MEDIA_FILE_CLOSE(media)
print(string.format("  qtrle: %dx%d @ %d/%d fps, %d frames",
    info.width, info.height, info.fps_num, info.fps_den,
    math.floor(info.duration_us * info.fps_num / (1000000 * info.fps_den))))

-- pool_threads=3 is the minimum for playback (1 prep + 1 video + 1 audio).
-- pool_threads=0 cannot be used: deliverFrame() during Tick calls
-- GetVideoFrame(cache_only=true), which skips sync decode. Without prefetch
-- workers the video cache stays empty and no frames arrive during Play.
local tmb = assert(EMP.TMB_CREATE(3))
EMP.TMB_SET_SEQUENCE_RATE(tmb, info.fps_num, info.fps_den)
EMP.TMB_SET_AUDIO_FORMAT(tmb, 48000, 2)

EMP.TMB_SET_TRACK_CLIPS(tmb, "video", 1, {{
    clip_id = "qtrle-stride-001",
    media_path = QTRLE_PATH,
    sequence_start = 0,
    duration = 50,
    source_in = 0,
    rate_num = info.fps_num,
    rate_den = info.fps_den,
    speed_ratio = 1.0,
}})

-- Create PlaybackController
local pc = PLAYBACK.CREATE()
assert(pc, "Failed to create PlaybackController")

PLAYBACK.SET_TMB(pc, tmb)
PLAYBACK.SET_BOUNDS(pc, 0, 50, info.fps_num, info.fps_den)
PLAYBACK.SET_SURFACE(pc, surface)
PLAYBACK.SET_CLIP_PROVIDER(pc, function() end)
PLAYBACK.SET_POSITION_CALLBACK(pc, function() end)
PLAYBACK.SET_CLIP_TRANSITION_CALLBACK(pc, function() end)

PLAYBACK.PARK(pc, 0)

local before_unique = EMP.SURFACE_UNIQUE_FRAME_COUNT(surface)
local before_total = EMP.SURFACE_FRAME_COUNT(surface)
print(string.format("  before play: total=%d unique=%d", before_total, before_unique))

-- Play for ~2 seconds at ~60Hz tick rate (same pattern as test_playback_av_sync.lua)
local CONTROL = qt_constants.CONTROL
local function poll_sleep(pc_h, seconds)
    os.execute(string.format("sleep %.3f", seconds))
    if pc_h then PLAYBACK.TICK(pc_h) end
    CONTROL.PROCESS_EVENTS()
end

PLAYBACK.PLAY(pc, 1, 1.0)
local NUM_TICKS = 120  -- 120 × 16ms ≈ 2 seconds
for i = 1, NUM_TICKS do
    poll_sleep(pc, 0.016)
end

PLAYBACK.STOP(pc)
poll_sleep(nil, 0.2)

local after_unique = EMP.SURFACE_UNIQUE_FRAME_COUNT(surface)
local after_total = EMP.SURFACE_FRAME_COUNT(surface)
local unique_during_play = after_unique - before_unique
local total_during_play = after_total - before_total

print(string.format("  after play: total=%d unique=%d (delta: total=%d unique=%d)",
    after_total, after_unique, total_during_play, unique_during_play))

-- At 25 fps × 2 s = 50 expected unique frames. Baseline: 45–48.
-- Threshold 40 leaves room for jitter but catches gross failure modes
-- (stride inflation, pipeline collapse, sync/prefetch races).
local min_unique = 40
local play_seconds = NUM_TICKS * 0.016  -- approximate
assert(unique_during_play >= min_unique, string.format(
    "4K qtrle playback: only %d unique frames in %.1fs (expected >= %d). "..
    "Gross pipeline failure — check refill workers, reader pool, stride_for_clip.",
    unique_during_play, play_seconds, min_unique))

print(string.format("  PASS: %d unique frames in %.1fs (%.1f unique fps)",
    unique_during_play, play_seconds, unique_during_play / play_seconds))

-- Cleanup
PLAYBACK.CLOSE(pc)
EMP.TMB_CLOSE(tmb)
print("✅ test_tmb_qtrle_stride.lua passed")
