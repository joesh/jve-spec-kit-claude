-- Integration test: Real timeline gap recovery (from anamnesis project)
--
-- Reproduces the exact scenario that fails in the real app:
--   V1: CountdownVidevo (source_in past EOF) → 25-frame gap → LITTLE_SEAGULL → 75-frame gap → 40-393-3
--   V2: "A Little Seagull Production Title" starts during gap 2
--
-- The bug: after playing through a gap following an EOF clip, the next clip's
-- frames never render. Surface stays black.
--
-- Uses real media from the project's external drive.
-- Skips gracefully if media is not available (CI/other machines).
--
-- Must run via: JVEEditor --test tests/integration/test_playback_real_timeline_gap.lua

require('test_env')

local env = require("integration.integration_test_env")
local EMP = env.require_emp()
local PLAYBACK = qt_constants.PLAYBACK
local WIDGET = qt_constants.WIDGET
local CONTROL = qt_constants.CONTROL

local ok_surf, test_surface = pcall(WIDGET.CREATE_GPU_VIDEO_SURFACE)
if not ok_surf or not test_surface then
    print("  Skipping: GPU surface not available (headless?)")
    print("✅ test_playback_real_timeline_gap.lua passed (skipped)")
    return
end

--- Check if a file exists (for skip-on-missing-media).
local function file_exists(path)
    local f = io.open(path, "r")
    if f then f:close() return true end
    return false
end

-- Real media paths from the anamnesis project.
-- These are on an external drive — skip if not mounted.
local COUNTDOWN = "/Volumes/AnamBack4 Joe/Assets/OldFashionedFilmLeaderCountdownVidevo.mov"
local SEAGULL_ANIM = "/Volumes/AnamBack4 Joe/Assets/Film Titles/LITTLE_SEAGULL_ANIMATION_4K_PRORES.mov"
local CLIP_40_393 = "/Volumes/AnamBack4 Joe/Footage/Day 14/A040/A040_12031506_C003.mov"
-- V2 title clip (not used yet — V1-only is sufficient to reproduce the bug)
-- local SEAGULL_TITLE = "/Volumes/AnamBack4 Joe/Assets/Film Titles/A Little Seagull Production Title (transparent BG).mov"

if not file_exists(COUNTDOWN) then
    print("  Skipping: external drive not mounted (need AnamBack4 Joe)")
    print("✅ test_playback_real_timeline_gap.lua passed (skipped)")
    return
end
assert(file_exists(SEAGULL_ANIM), "SEAGULL_ANIM missing: " .. SEAGULL_ANIM)
assert(file_exists(CLIP_40_393), "CLIP_40_393 missing: " .. CLIP_40_393)

--- Poll with TICK fallback for headless mode.
-- CVDisplayLink drives real async playback on a private thread, but
-- fails in headless/CI (no display). TICK advances position on main
-- thread so the test still validates gap clear/recovery logic.
local function poll_sleep(pc_handle, seconds)
    os.execute(string.format("sleep %.3f", seconds))
    if pc_handle then
        PLAYBACK.TICK(pc_handle)
    end
    CONTROL.PROCESS_EVENTS()
end

print("Testing real timeline gap recovery (anamnesis project)...")

local RATE_NUM = 25
local RATE_DEN = 1

-- Reproduce the exact timeline layout from the project:
--   V1: CountdownVidevo frames 0-250 (source_in=47, media=250 frames → EOF at source 250 = frame 203)
--       gap: frames 250-275
--       LITTLE_SEAGULL frames 275-375 (source_in=0, media=100 frames, no EOF)
--       gap: frames 375-450
--       40-393-3 frames 450-701 (source_in=3513, media=7596 frames, no EOF)
--   V2: (omitted for simplicity — V1-only is sufficient to reproduce)
--
-- Offset everything to start at 0 for simplicity. The relative layout is identical.

local tmb = EMP.TMB_CREATE(2)
assert(tmb, "TMB_CREATE failed")
EMP.TMB_SET_SEQUENCE_RATE(tmb, RATE_NUM, RATE_DEN)

local clips = {
    {
        clip_id = "countdown",
        media_path = COUNTDOWN,
        timeline_start = 0,
        duration = 250,
        source_in = 47,
        rate_num = RATE_NUM,
        rate_den = RATE_DEN,
        speed_ratio = 1.0,
    },
    {
        clip_id = "seagull-anim",
        media_path = SEAGULL_ANIM,
        timeline_start = 275,
        duration = 100,
        source_in = 0,
        rate_num = RATE_NUM,
        rate_den = RATE_DEN,
        speed_ratio = 1.0,
    },
    {
        clip_id = "40-393-3",
        media_path = CLIP_40_393,
        timeline_start = 450,
        duration = 251,
        source_in = 3513,
        rate_num = RATE_NUM,
        rate_den = RATE_DEN,
        speed_ratio = 1.0,
    },
}

EMP.TMB_SET_TRACK_CLIPS(tmb, "video", 1, clips)

local BOUNDS = 750  -- total timeline length
local pc = PLAYBACK.CREATE()
assert(pc, "PLAYBACK.CREATE failed")

PLAYBACK.SET_TMB(pc, tmb)
PLAYBACK.SET_BOUNDS(pc, BOUNDS, RATE_NUM, RATE_DEN)
PLAYBACK.SET_SURFACE(pc, test_surface)

-- Clip provider: clips already loaded via TMB_SET_TRACK_CLIPS above.
-- Provider is a no-op — TMB already has all clips for this test.
PLAYBACK.SET_CLIP_PROVIDER(pc, function(from, to, track_type) end)

-- Phase 1: Seek inside CountdownVidevo (near end, past EOF point)
-- EOF at source 250 = timeline frame 203. Seek to frame 240 (post-EOF, holding last frame).
PLAYBACK.SEEK(pc, 240)
local w, h = EMP.SURFACE_FRAME_SIZE(test_surface)
assert(w > 0 and h > 0,
    string.format("Seek to frame 240 (post-EOF): expected content, got %dx%d", w, h))
print(string.format("  PASS: Seek to frame 240 (post-EOF hold): %dx%d", w, h))

-- Phase 2: Play through gap 1 into LITTLE_SEAGULL, through gap 2 into 40-393-3
PLAYBACK.PLAY(pc, 1, 1.0)

-- Wait for gap 1 (frames 250-275)
local gap1_detected = false
for i = 1, 200 do
    poll_sleep(pc, 0.016)
    w, h = EMP.SURFACE_FRAME_SIZE(test_surface)
    if w == 0 and h == 0 then
        gap1_detected = true
        print(string.format("  PASS: Gap 1 detected (black) after %d polls", i))
        break
    end
end
assert(gap1_detected,
    string.format("Gap 1 never detected (still %dx%d after 3.2s)", w, h))

-- Wait for LITTLE_SEAGULL recovery (frames 275-375)
local seagull_recovered = false
for i = 1, 200 do
    poll_sleep(pc, 0.016)
    w, h = EMP.SURFACE_FRAME_SIZE(test_surface)
    if w > 0 and h > 0 then
        seagull_recovered = true
        print(string.format("  PASS: SEAGULL recovered (%dx%d) after %d polls", w, h, i))
        break
    end
end
assert(seagull_recovered,
    string.format("SEAGULL never recovered after gap 1 (still %dx%d after 3.2s)", w, h))

-- Wait for gap 2 (frames 375-450)
local gap2_detected = false
for i = 1, 200 do
    poll_sleep(pc, 0.016)
    w, h = EMP.SURFACE_FRAME_SIZE(test_surface)
    if w == 0 and h == 0 then
        gap2_detected = true
        print(string.format("  PASS: Gap 2 detected (black) after %d polls", i))
        break
    end
end
assert(gap2_detected,
    string.format("Gap 2 never detected (still %dx%d after 3.2s)", w, h))

-- Wait for 40-393-3 recovery (frames 450+)
local clip3_recovered = false
for i = 1, 200 do
    poll_sleep(pc, 0.016)
    w, h = EMP.SURFACE_FRAME_SIZE(test_surface)
    if w > 0 and h > 0 then
        clip3_recovered = true
        print(string.format("  PASS: 40-393-3 recovered (%dx%d) after %d polls", w, h, i))
        break
    end
end
assert(clip3_recovered,
    string.format("40-393-3 never recovered after gap 2 (still %dx%d after 3.2s)", w, h))

-- Phase 3: Verify sustained delivery — frame count must increase
local count_at_recovery = EMP.SURFACE_FRAME_COUNT(test_surface)
local MIN_NEW_FRAMES = 3
for i = 1, 100 do
    poll_sleep(pc, 0.016)
end
local count_after = EMP.SURFACE_FRAME_COUNT(test_surface)
local new_frames = count_after - count_at_recovery
assert(new_frames >= MIN_NEW_FRAMES,
    string.format("Playback stalled after 40-393-3 recovery — only %d new frames in 1.6s "
        .. "(count %d → %d, need >= %d)",
        new_frames, count_at_recovery, count_after, MIN_NEW_FRAMES))
print(string.format("  PASS: Sustained delivery — %d new frames after recovery", new_frames))

PLAYBACK.STOP(pc)
PLAYBACK.CLOSE(pc)
EMP.TMB_CLOSE(tmb)

print("✅ test_playback_real_timeline_gap.lua passed")
