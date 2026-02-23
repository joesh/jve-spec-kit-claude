-- Integration Test: TMB Pending Frame Resolution
-- Exercises real C++ TMB decode path — catches the freeze bug pattern
-- where pending=true never resolves.
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
-- 1. Park mode decode: direction=0 should decode synchronously, no pending
--------------------------------------------------------------------------------
section("1. Park mode decode")
do
    local tmb = ienv.create_single_clip_tmb({ pool_threads = 0 })

    -- Park at frame 10
    EMP.TMB_SET_PLAYHEAD(tmb, 10, 0, 1.0)

    local frame, info = EMP.TMB_GET_VIDEO_FRAME(tmb, 1, 10)
    check(frame ~= nil, "park mode returns a frame (not nil)")
    check(info.pending == false, "park mode frame is not pending")
    check(info.clip_id == "test-clip-001", "park mode clip_id matches")
    check(info.offline == false, "park mode frame is not offline")

    EMP.TMB_RELEASE_ALL(tmb)
    EMP.TMB_CLOSE(tmb)
end

--------------------------------------------------------------------------------
-- 2. Sequential park decode: direction=0 always decodes synchronously
--    (Play mode uses stale-return + async pre-buffer regardless of pool_threads.
--     Park mode is the only guaranteed-sync path.)
--------------------------------------------------------------------------------
section("2. Sequential park decode (direction=0)")
do
    local tmb = ienv.create_single_clip_tmb({ pool_threads = 0 })

    -- Decode several frames in park mode — each should be immediate
    local all_sync = true
    for f = 0, 4 do
        EMP.TMB_SET_PLAYHEAD(tmb, f, 0, 1.0)
        local frame, info = EMP.TMB_GET_VIDEO_FRAME(tmb, 1, f)
        if frame == nil or info.pending then
            all_sync = false
            print(string.format("    frame %d: frame=%s pending=%s",
                f, tostring(frame ~= nil), tostring(info.pending)))
        end
    end
    check(all_sync, "park mode: 5 sequential frames decoded without pending")

    EMP.TMB_RELEASE_ALL(tmb)
    EMP.TMB_CLOSE(tmb)
end

--------------------------------------------------------------------------------
-- 3. Async pool play + pending resolution
--    pool_threads=2: if a frame returns pending=true, poll until it resolves.
--    Failure here = the freeze bug.
--------------------------------------------------------------------------------
section("3. Async pool play (pool_threads=2)")
do
    local tmb = ienv.create_single_clip_tmb({ pool_threads = 2 })

    EMP.TMB_SET_PLAYHEAD(tmb, 0, 1, 1.0)

    local MAX_RETRIES = 50
    local SLEEP_CMD = "sleep 0.01"

    local frames_resolved = 0
    local frames_tested = 5
    local worst_retries = 0

    for f = 0, frames_tested - 1 do
        EMP.TMB_SET_PLAYHEAD(tmb, f, 1, 1.0)
        local frame, info = EMP.TMB_GET_VIDEO_FRAME(tmb, 1, f)

        local retries = 0
        while (frame == nil or info.pending) and retries < MAX_RETRIES do
            os.execute(SLEEP_CMD)
            frame, info = EMP.TMB_GET_VIDEO_FRAME(tmb, 1, f)
            retries = retries + 1
        end

        if retries > worst_retries then worst_retries = retries end

        if frame ~= nil and not info.pending then
            frames_resolved = frames_resolved + 1
        else
            print(string.format("    frame %d: STUCK pending after %d retries", f, retries))
        end
    end

    check(frames_resolved == frames_tested,
        string.format("async pool: all %d frames resolved (worst poll: %d retries)",
            frames_tested, worst_retries))

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
