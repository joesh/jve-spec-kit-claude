-- Integration test: PlaybackController Seek delivers a frame to the surface.
--
-- BLACK-BOX: Uses REAL C++ PlaybackController, REAL TMB, REAL media,
-- REAL GPUVideoSurface. Observes the surface's frameCount() — the only
-- output that matters. No mocks.
--
-- This is the test that would have caught the "video doesn't display" bug.
-- The mock-based test_playback_video_display.lua can't catch it because
-- its mock PLAYBACK.SEEK directly pushes to the surface, bypassing the
-- real C++ pipeline (TMB → GetVideoFrame → deliverFrame → setFrame).

local env = require("integration.integration_test_env")

print("=== test_playback_seek_delivers_frame.lua ===")

-- 1. Prerequisites: real C++ bindings available
local EMP = env.require_emp()
local PLAYBACK = qt_constants.PLAYBACK
assert(PLAYBACK, "PLAYBACK bindings not available")

local WIDGET = qt_constants.WIDGET
assert(WIDGET and WIDGET.CREATE_GPU_VIDEO_SURFACE,
    "CREATE_GPU_VIDEO_SURFACE not available")

-- 2. Create real GPUVideoSurface
local ok_surf, surface = pcall(WIDGET.CREATE_GPU_VIDEO_SURFACE)
if not ok_surf or not surface then
    print("  SKIP: GPU surface creation failed (headless?)")
    print("✅ test_playback_seek_delivers_frame.lua passed (skipped)")
    return
end
print("  ✓ Created real GPUVideoSurface")

-- 3. Create real TMB with real media (640x360 24000/1001)
local tmb, clip_info = env.create_single_clip_tmb({ pool_threads = 0, duration = 50 })
print(string.format("  ✓ Created TMB with clip: %s (%d frames)",
    clip_info.clip_id, clip_info.duration))

-- 4. Create real PlaybackController, wire everything
local pc = PLAYBACK.CREATE()
assert(pc, "Failed to create PlaybackController")

PLAYBACK.SET_TMB(pc, tmb)
PLAYBACK.SET_BOUNDS(pc, clip_info.duration, clip_info.rate_num, clip_info.rate_den)
PLAYBACK.SET_SURFACE(pc, surface)

-- Clip provider: clips already loaded via create_single_clip_tmb above.
-- Provider is a no-op — TMB already has all clips for this test.
PLAYBACK.SET_CLIP_PROVIDER(pc, function(from, to, track_type) end)
PLAYBACK.SET_POSITION_CALLBACK(pc, function() end)
PLAYBACK.SET_CLIP_TRANSITION_CALLBACK(pc, function() end)

print("  ✓ Wired PlaybackController (TMB, surface, bounds, tracks, callbacks)")

-- 5. Verify surface has no frames yet
local count_before = EMP.SURFACE_FRAME_COUNT(surface)
assert(count_before == 0, string.format(
    "surface should have 0 frames before seek, got %d", count_before))
print(string.format("  ✓ Surface frame count before seek: %d", count_before))

-- 6. SEEK to frame 2 — the real C++ pipeline:
--    PlaybackController::Seek → TMB::SetPlayhead → TMB::GetVideoFrame
--    → deliverFrame(synchronous=true) → surface->setFrame
print("  → Seeking to frame 2...")
PLAYBACK.SEEK(pc, 2)

-- 7. Check: did the surface actually receive a frame?
local count_after = EMP.SURFACE_FRAME_COUNT(surface)
print(string.format("  ✓ Surface frame count after seek: %d", count_after))
assert(count_after > count_before, string.format(
    "SEEK did not deliver a frame to the surface! count before=%d after=%d",
    count_before, count_after))

-- 8. Seek to a different frame — frame count should increase again
local count_mid = count_after
PLAYBACK.SEEK(pc, 5)
local count_after2 = EMP.SURFACE_FRAME_COUNT(surface)
print(string.format("  ✓ Surface frame count after second seek: %d", count_after2))
assert(count_after2 > count_mid, string.format(
    "Second SEEK did not deliver a frame! count before=%d after=%d",
    count_mid, count_after2))

-- 10. Cleanup
PLAYBACK.CLOSE(pc)
EMP.TMB_CLOSE(tmb)
print("  ✓ Cleaned up")

print("✅ test_playback_seek_delivers_frame.lua passed")
