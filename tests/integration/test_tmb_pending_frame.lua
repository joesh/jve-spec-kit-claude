-- Integration Test: TMB Always-Sync Frame Decode
-- Exercises real C++ TMB decode path — verifies GetVideoFrame always
-- returns a frame synchronously (no pending concept).
--
-- Must run via: JVEEditor --test tests/integration/test_tmb_pending_frame.lua

local ienv = require("integration.integration_test_env")
local EMP = ienv.require_emp()

print("=== test_tmb_pending_frame.lua ===")

local passed = 0
local total = 0

local function check(cond, msg)
    total = total + 1
    if cond then
        passed = passed + 1
        print("  PASS: " .. msg)
    else
        print("  FAIL: " .. msg)
    end
end

local function section(name)
    print("\n-- " .. name .. " --")
end

--------------------------------------------------------------------------------
-- 1. Park mode decode: direction=0 always decodes synchronously
--------------------------------------------------------------------------------
section("1. Park mode decode")
do
    local tmb = ienv.create_single_clip_tmb({ pool_threads = 0 })

    -- Park at frame 10
    EMP.TMB_SET_PLAYHEAD(tmb, 10, 0, 1.0)

    local frame, info = EMP.TMB_GET_VIDEO_FRAME(tmb, 1, 10)
    check(frame ~= nil, "park mode returns a frame (not nil)")
    check(info.clip_id == "test-clip-001", "park mode clip_id matches")
    check(info.offline == false, "park mode frame is not offline")

    EMP.TMB_RELEASE_ALL(tmb)
    EMP.TMB_CLOSE(tmb)
end

--------------------------------------------------------------------------------
-- 2. Sequential park decode: direction=0 always decodes synchronously
--------------------------------------------------------------------------------
section("2. Sequential park decode (direction=0)")
do
    local tmb = ienv.create_single_clip_tmb({ pool_threads = 0 })

    -- Decode several frames in park mode — each should be immediate
    local all_sync = true
    for f = 0, 4 do
        EMP.TMB_SET_PLAYHEAD(tmb, f, 0, 1.0)
        local frame, info = EMP.TMB_GET_VIDEO_FRAME(tmb, 1, f)
        if frame == nil then
            all_sync = false
            print(string.format("    frame %d: frame=nil offline=%s",
                f, tostring(info.offline)))
        end
    end
    check(all_sync, "park mode: 5 sequential frames decoded")

    EMP.TMB_RELEASE_ALL(tmb)
    EMP.TMB_CLOSE(tmb)
end

--------------------------------------------------------------------------------
-- 3. Play mode also returns frames immediately (sync decode on miss)
--------------------------------------------------------------------------------
section("3. Play mode sync decode (pool_threads=2)")
do
    local tmb = ienv.create_single_clip_tmb({ pool_threads = 2 })

    EMP.TMB_SET_PLAYHEAD(tmb, 0, 1, 1.0)

    local frames_resolved = 0
    local frames_tested = 5

    for f = 0, frames_tested - 1 do
        EMP.TMB_SET_PLAYHEAD(tmb, f, 1, 1.0)
        local frame = EMP.TMB_GET_VIDEO_FRAME(tmb, 1, f)

        if frame ~= nil then
            frames_resolved = frames_resolved + 1
        else
            print(string.format("    frame %d: nil (offline or gap?)", f))
        end
    end

    check(frames_resolved == frames_tested,
        string.format("play mode: all %d frames decoded immediately",
            frames_tested))

    EMP.TMB_RELEASE_ALL(tmb)
    EMP.TMB_CLOSE(tmb)
end

--------------------------------------------------------------------------------
-- 4. Clip boundary crossing: two clips, verify clip_id switches
--------------------------------------------------------------------------------
section("4. Clip boundary crossing")
do
    local tmb = ienv.create_two_clip_tmb({
        pool_threads = 0,
        clip_a_duration = 50,
        clip_b_duration = 50,
    })

    -- Frame 49 should be clip A
    EMP.TMB_SET_PLAYHEAD(tmb, 49, 0, 1.0)
    local frame_a, info_a = EMP.TMB_GET_VIDEO_FRAME(tmb, 1, 49)
    check(frame_a ~= nil, "boundary: frame 49 (clip A) decoded")
    check(info_a.clip_id == "clip-A",
        string.format("boundary: frame 49 clip_id = %q (expect clip-A)", info_a.clip_id))

    -- Frame 50 should be clip B
    EMP.TMB_SET_PLAYHEAD(tmb, 50, 0, 1.0)
    local frame_b, info_b = EMP.TMB_GET_VIDEO_FRAME(tmb, 1, 50)
    check(frame_b ~= nil, "boundary: frame 50 (clip B) decoded")
    check(info_b.clip_id == "clip-B",
        string.format("boundary: frame 50 clip_id = %q (expect clip-B)", info_b.clip_id))

    EMP.TMB_RELEASE_ALL(tmb)
    EMP.TMB_CLOSE(tmb)
end

--------------------------------------------------------------------------------
-- 5. Frame handle validity: FRAME_INFO returns real dimensions
--------------------------------------------------------------------------------
section("5. Frame handle validity")
do
    local tmb = ienv.create_single_clip_tmb({ pool_threads = 0 })

    EMP.TMB_SET_PLAYHEAD(tmb, 0, 0, 1.0)
    local frame = EMP.TMB_GET_VIDEO_FRAME(tmb, 1, 0)
    check(frame ~= nil, "frame handle: got a frame")

    if frame then
        local fi = EMP.FRAME_INFO(frame)
        check(fi.width > 0, string.format("frame handle: width=%d > 0", fi.width))
        check(fi.height > 0, string.format("frame handle: height=%d > 0", fi.height))
        check(fi.stride > 0, string.format("frame handle: stride=%d > 0", fi.stride))
    end

    EMP.TMB_RELEASE_ALL(tmb)
    EMP.TMB_CLOSE(tmb)
end

--------------------------------------------------------------------------------
-- Summary
--------------------------------------------------------------------------------
print(string.format("\n%d/%d checks passed", passed, total))
if passed == total then
    print("✅ test_tmb_pending_frame.lua passed")
else
    error(string.format("FAILED: %d/%d checks failed", total - passed, total))
end
