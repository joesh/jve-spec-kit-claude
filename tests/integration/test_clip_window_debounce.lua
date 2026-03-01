-- Integration test: SetClipWindow debounce
--
-- NSF regression test for NeedClips spam fix.
-- When Lua returns the same clip window (end of timeline — nothing more to load),
-- need_clips_pending must stay true so checkClipWindow won't re-fire.
--
-- Test strategy: Create a short clip, set window covering it, start playback,
-- wait for NeedClips. On each NeedClips call, respond with the SAME window.
-- Count total NeedClips calls over ~500ms — should be small (≤6).
-- Without the fix: NeedClips fires every tick (12-15 calls in 500ms at 25fps).
-- With the fix: NeedClips fires 1-2 times (initial + one retry), then stops.
--
-- Must run via: JVEEditor --test tests/integration/test_clip_window_debounce.lua

require('test_env')

local env = require("integration.integration_test_env")
local EMP = env.require_emp()
local PLAYBACK = qt_constants.PLAYBACK
local WIDGET = qt_constants.WIDGET
local CONTROL = qt_constants.CONTROL

-- Need a surface
local ok_surf, test_surface = pcall(WIDGET.CREATE_GPU_VIDEO_SURFACE)
if not ok_surf or not test_surface then
    print("  Skipping: GPU surface not available (headless?)")
    print("✅ test_clip_window_debounce.lua passed (skipped)")
    return
end

local function poll_sleep(pc_handle, seconds)
    os.execute(string.format("sleep %.3f", seconds))
    if pc_handle then
        PLAYBACK.TICK(pc_handle)
    end
    CONTROL.PROCESS_EVENTS()
end

print("Testing SetClipWindow debounce (NeedClips spam prevention)...")

-- Create a short clip (20 frames = ~0.8s at 24fps)
local tmb, clip_info = env.create_single_clip_tmb({
    pool_threads = 2,
    duration = 20,
})

local pc = PLAYBACK.CREATE()
assert(pc, "test_clip_window_debounce: CREATE failed")

PLAYBACK.SET_TMB(pc, tmb)
PLAYBACK.SET_BOUNDS(pc, 100, 24, 1)  -- 100 frames total, clip only covers 0-20
PLAYBACK.SET_VIDEO_TRACKS(pc, {1})
PLAYBACK.SET_SURFACE(pc, test_surface)

-- Track NeedClips calls — respond with the same fixed window every time
local need_clips_count = 0
local WINDOW_LO = 0
local WINDOW_HI = 20

PLAYBACK.SET_NEED_CLIPS_CALLBACK(pc, function(frame, direction, track_type)
    need_clips_count = need_clips_count + 1
    -- Always respond with the same window (simulates end-of-timeline)
    PLAYBACK.SET_CLIP_WINDOW(pc, track_type, WINDOW_LO, WINDOW_HI)
    EMP.TMB_SET_TRACK_CLIPS(tmb, track_type, 1, { clip_info })
end)

-- Set initial clip window
PLAYBACK.SET_CLIP_WINDOW(pc, "video", WINDOW_LO, WINDOW_HI)
PLAYBACK.SET_CLIP_WINDOW(pc, "audio", WINDOW_LO, WINDOW_HI)

-- Seek to near end of clip (frame 18) so playhead quickly passes the window
PLAYBACK.SEEK(pc, 18)

-- Reset counter after seek (seek may trigger NeedClips)
need_clips_count = 0

-- Start playback — playhead will advance past frame 20 into the gap
PLAYBACK.PLAY(pc, 1, 1.0)

-- Poll for ~600ms to let playhead advance and NeedClips fire
for _ = 1, 38 do  -- 38 × 16ms ≈ 600ms
    poll_sleep(pc, 0.016)
end

-- Stop playback
PLAYBACK.STOP(pc)

print(string.format("  NeedClips fired %d times in ~600ms", need_clips_count))

-- With debounce: NeedClips fires a few times (initial discovery + 1-2 retries
-- from audio/video both asking), then stops because SetClipWindow with same
-- values keeps need_clips_pending=true.
-- Without debounce: fires every tick — at 25fps that's ~15 calls in 600ms,
-- at 60fps display link ~36 calls.
-- Threshold: ≤6 calls is debounced. >10 is spam.
assert(need_clips_count <= 6,
    string.format("NeedClips spam: %d calls in 600ms (threshold ≤6) — "
        .. "SetClipWindow debounce may be broken", need_clips_count))

-- Must have fired at least once (playhead crossed into gap)
assert(need_clips_count >= 1,
    "NeedClips never fired — playhead didn't cross clip boundary?")

print(string.format("  ✓ NeedClips debounce working (%d calls, ≤6 threshold)", need_clips_count))

-- Cleanup
PLAYBACK.CLOSE(pc)
EMP.TMB_CLOSE(tmb)

print("✅ test_clip_window_debounce.lua passed")
