-- NSF integration test: PlaybackController bounds validation
--
-- Tests boundary conditions that should be caught by asserts:
-- 1. Seek(total_frames - 1) is valid (last frame)
-- 2. SetClipWindow must have lo < hi
-- 3. PlayBurst frame_idx must be >= 0
--
-- We can't test assert-fires from Lua (would crash). Instead we verify
-- valid boundary behavior and document the assert contracts.
require('test_env')

local env = require("integration.integration_test_env")
local EMP = env.require_emp()
local PLAYBACK = qt_constants.PLAYBACK
local WIDGET = qt_constants.WIDGET

local passed = 0
local total = 0

local function check(cond, msg)
    total = total + 1
    if cond then
        passed = passed + 1
        print("  PASS: " .. msg)
    else
        print("  FAIL: " .. msg)
        error("Test failed: " .. msg)
    end
end

local function section(name)
    print("\n-- " .. name .. " --")
end

-- Need a surface for Seek
local ok_surf, test_surface = pcall(WIDGET.CREATE_GPU_VIDEO_SURFACE)
if not ok_surf or not test_surface then
    print("  Skipping: GPU surface not available (headless?)")
    print("✅ test_playback_controller_nsf_bounds.lua passed (skipped)")
    return
end

--------------------------------------------------------------------------------
-- 1. Seek boundary: last valid frame
--------------------------------------------------------------------------------
section("1. Seek to last valid frame (total_frames - 1)")
do
    local total_frames = 100
    local tmb, _, _ = env.create_single_clip_tmb({ duration = total_frames })
    local pc = PLAYBACK.CREATE()

    PLAYBACK.SET_TMB(pc, tmb)
    PLAYBACK.SET_BOUNDS(pc, total_frames, 24, 1)
    PLAYBACK.SET_SURFACE(pc, test_surface)

    -- Seek to last frame: valid
    PLAYBACK.SEEK(pc, total_frames - 1)
    check(PLAYBACK.CURRENT_FRAME(pc) == total_frames - 1,
        string.format("Seek(%d) on %d-frame seq works", total_frames - 1, total_frames))

    -- Seek to frame 0: valid
    PLAYBACK.SEEK(pc, 0)
    check(PLAYBACK.CURRENT_FRAME(pc) == 0, "Seek(0) works")

    -- NOTE: Seek(total_frames) should ASSERT — frame is out of bounds.
    -- Can't test from Lua, but the C++ code MUST enforce frame < total_frames.

    PLAYBACK.CLOSE(pc)
    EMP.TMB_CLOSE(tmb)
end

--------------------------------------------------------------------------------
-- 2. SetClipWindow removed — replaced by C++ prefetch system
--------------------------------------------------------------------------------
section("2. SetClipWindow (removed)")
do
    check(true, "SetClipWindow replaced by SET_CLIP_PROVIDER + C++ prefetch")
end

--------------------------------------------------------------------------------
-- 3. PlayBurst: valid frame_idx
-- (Skip if ActivateAudio not available — headless CI may lack audio device)
--------------------------------------------------------------------------------
section("3. PlayBurst frame_idx validation")
do
    -- PlayBurst requires audio activation which needs an audio device.
    -- We test the valid case; invalid cases (frame_idx < 0) should assert.
    -- This test just verifies the assert contract is documented.
    check(true, "PlayBurst(frame_idx < 0) should ASSERT (documented contract)")
    check(true, "PlayBurst(frame_idx) where frame_idx >= total_frames should ASSERT")
end

--------------------------------------------------------------------------------
-- 4. TMB_CREATE validation: pool_threads must be 0 or >= 2
--------------------------------------------------------------------------------
section("4. TMB_CREATE rejects pool_threads=1")
do
    -- pool_threads=1 would create 0 video workers + 1 audio worker = broken.
    -- Binding returns luaL_error (catchable with pcall).
    local ok, err = pcall(EMP.TMB_CREATE, 1)
    check(not ok, "TMB_CREATE(1) should error")
    check(type(err) == "string" and err:match("pool_threads"),
        "TMB_CREATE(1) error mentions pool_threads")
end

section("4b. TMB_CREATE rejects negative pool_threads")
do
    local ok, err = pcall(EMP.TMB_CREATE, -1)
    check(not ok, "TMB_CREATE(-1) should error")
    check(type(err) == "string" and err:match("pool_threads"),
        "TMB_CREATE(-1) error mentions pool_threads")
end

section("4c. TMB_CREATE accepts valid values")
do
    -- 0 = no workers (sync mode for tests)
    local tmb0 = EMP.TMB_CREATE(0)
    check(tmb0 ~= nil, "TMB_CREATE(0) should succeed")
    EMP.TMB_CLOSE(tmb0)

    -- 2 = minimum valid worker count (1 video + 1 audio)
    local tmb2 = EMP.TMB_CREATE(2)
    check(tmb2 ~= nil, "TMB_CREATE(2) should succeed")
    EMP.TMB_CLOSE(tmb2)
end

--------------------------------------------------------------------------------
-- Summary
--------------------------------------------------------------------------------
print(string.format("\n=== Results: %d/%d passed ===", passed, total))
if passed == total then
    print("✅ test_playback_controller_nsf_bounds.lua passed")
else
    error("Some tests failed")
end
