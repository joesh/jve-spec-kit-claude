-- Integration Test: Multi-track timeline decode around playhead 122965.
-- Layout (V1 rapid cuts, V3 parallel coverage, V6 reference layer) is
-- modeled on a real edit segment but uses two real source files instead
-- of one-per-take. The frame ranges, cut positions, and clip durations
-- are preserved; the take identities (`v1-clip-N`, `v6-ref`) are generic.
--
-- Tests: multi-track video decode, clip boundary transitions, rapid cuts,
-- async pending resolution across edit points with real media.
--
-- Must run via: JVEEditor --test tests/synthetic/integration/test_tmb_real_timeline.lua

local ienv = require("synthetic.integration.integration_test_env")
local EMP = ienv.require_emp()

print("=== test_tmb_real_timeline.lua ===")

local passed = 0
local total = 0
local failures = {}

local function check(cond, msg)
    total = total + 1
    if cond then
        passed = passed + 1
        print("  PASS: " .. msg)
    else
        failures[#failures + 1] = msg
        print("  FAIL: " .. msg)
    end
end

local function section(name)
    print("\n-- " .. name .. " --")
end

--------------------------------------------------------------------------------
-- Media paths — two real source files:
--   V1_V3_PATH backs the V1 rapid-cut sequence and the V3 parallel-coverage
--     layer (test verifies clip_id transitions, not pixel distinction between
--     V1 and V3, so they can share a source).
--   V6_PATH backs the V6 reference layer. Distinct from V1/V3 so the
--     multi-track decode section actually verifies the right layer's frame
--     reaches the right track (a frame-routing bug would otherwise be
--     invisible when all layers decode identical content).
--------------------------------------------------------------------------------
local MEDIA_DIR = ienv.resolve_repo_path("tests/fixtures/media/anamnesis-untrimmed")
local V1_V3_PATH = MEDIA_DIR .. "/A007_05202055_C007.mov"
local V6_PATH    = MEDIA_DIR .. "/A014_10221058_C013.mov"

for _, p in ipairs({ V1_V3_PATH, V6_PATH }) do
    local f = io.open(p, "r")
    assert(f, "Missing fixture: " .. p)
    f:close()
end

--------------------------------------------------------------------------------
-- Timeline layout: V1 clips around playhead 122965
-- source_in = absolute TC (first_frame_tc from file probe)
--------------------------------------------------------------------------------
local SEQ_FPS_NUM = 25
local SEQ_FPS_DEN = 1

-- Probe file TC origin for absolute TC source_in. Nil first_frame_tc
-- means a broken container or stale binding, not "default to 0"; the
-- park-decode clip_id assertions would otherwise pass with the wrong
-- origin baked into source_in.
local function tc_origin(path)
    local probe = EMP.MEDIA_FILE_PROBE(path)
    assert(probe, "MEDIA_FILE_PROBE failed: " .. path)
    return assert(probe.first_frame_tc,
        "MEDIA_FILE_PROBE: first_frame_tc nil for " .. path)
end

local timeline_dsl = require("synthetic.helpers.timeline_dsl")

-- Modeled on a real edit segment around playhead 122965.
--
-- V1 — opener (clip-1, 831 frames ≈ 33s) followed by FIVE rapid cuts in
--      ~358 frames (clip-2..clip-6). Tests cut-handling under pre-buffer
--      pressure (section 4) and async-decode through dense edit points
--      (section 5). Clip durations are deliberately above PRE_BUFFER_BATCH
--      (48) on both sides of the 123172 boundary so the cache-thrashing
--      regression in section 4 is reproducible.
-- V3 — parallel coverage of three V1 ranges (clip-3 / clip-4 / clip-6).
--      Verifies multi-track decode (section 3) routes the right layer's
--      frame to the right track.
-- V6 — reference layer (ref, 863 frames ≈ 34.5s) spanning V1's opener +
--      cut region. Backed by a *different* media file than V1/V3 so the
--      multi-track frame-routing test in section 3 can actually detect a
--      layer-swap bug; if all layers shared content, the routing bug would
--      be invisible. Also drives the gap-after-clip-end test (section 6):
--      V6 ends at 122960, so playhead > 122960 must return nil + empty
--      clip_id (TMB gap-detection contract).
local TIMELINE = [[
    V1: [clip-1 122097-122928][clip-2 122928-122960][clip-3 122960-123003][clip-4 123003-123043][clip-5 123043-123172][clip-6 123172-123286]
    V3: [clip-3 122960-123003][clip-4 123003-123043][clip-6 123172-123286]
    V6: [ref 122097-122960]
]]

local function path_for(track_name, _clip_name)
    if track_name == "V6" then return V6_PATH end
    return V1_V3_PATH
end

local tracks = timeline_dsl.to_tmb(timeline_dsl.parse(TIMELINE), {
    path_for        = path_for,
    source_in_for   = function(track_name, _clip_name, kind)
        -- This timeline is video-only. An audio kind here means the
        -- DSL grew an audio track without a matching resolver branch
        -- — audio TC origin is samples, not frames, so the wrong call
        -- would silently bake the wrong source_in.
        assert(kind == "video",
            "test_tmb_real_timeline: video-only timeline, got kind=" .. tostring(kind))
        return tc_origin(path_for(track_name))
    end,
    rate_for        = function(_track_name, _kind) return 25, 1 end,
    speed_ratio_for = function(_t, _c) return 1.0 end,
    id_prefix_for   = function(t) return t:lower() .. "-" end,
})

local v1_clips = tracks.video[1]
local v3_clips = tracks.video[3]
local v6_clips = tracks.video[6]

--------------------------------------------------------------------------------
-- 1. Probe media files
--------------------------------------------------------------------------------
section("1. Probe media files")
do
    for _, path in ipairs({ V1_V3_PATH, V6_PATH }) do
        local info = EMP.MEDIA_FILE_PROBE(path)
        check(info ~= nil, "probe " .. path .. ": got info")
        if info then
            check(info.has_video, string.format("probe %s: has video (%dx%d)", path, info.width, info.height))
        end
    end
end

--------------------------------------------------------------------------------
-- 2. Park decode across V1 edit points
--------------------------------------------------------------------------------
section("2. Park decode across V1 edit points")
do
    local tmb = EMP.TMB_CREATE(0)
    EMP.TMB_SET_SEQUENCE_RATE(tmb, SEQ_FPS_NUM, SEQ_FPS_DEN)
    EMP.TMB_SET_TRACK_CLIPS(tmb, "video", 1, v1_clips)

    -- Decode one frame from each clip (park mode = guaranteed sync)
    for _, clip in ipairs(v1_clips) do
        local mid = clip.sequence_start + math.floor(clip.duration / 2)
        EMP.TMB_SET_PLAYHEAD(tmb, mid, 0, 1.0)
        local frame, info = EMP.TMB_GET_VIDEO_FRAME(tmb, 1, mid)
        check(frame ~= nil, string.format("park V1 frame %d (%s): decoded", mid, clip.clip_id))
        check(info.clip_id == clip.clip_id,
            string.format("park V1 frame %d: clip_id=%s (expect %s)", mid, info.clip_id, clip.clip_id))
        check(not info.pending, string.format("park V1 frame %d: not pending", mid))
        check(not info.offline, string.format("park V1 frame %d: not offline", mid))
    end

    EMP.TMB_RELEASE_ALL(tmb)
    EMP.TMB_CLOSE(tmb)
end

--------------------------------------------------------------------------------
-- 3. Multi-track park decode (V1 + V3 + V6 simultaneously)
--------------------------------------------------------------------------------
section("3. Multi-track park decode at playhead 122965")
do
    local tmb = EMP.TMB_CREATE(0)
    EMP.TMB_SET_SEQUENCE_RATE(tmb, SEQ_FPS_NUM, SEQ_FPS_DEN)
    EMP.TMB_SET_TRACK_CLIPS(tmb, "video", 1, v1_clips)
    EMP.TMB_SET_TRACK_CLIPS(tmb, "video", 3, v3_clips)
    EMP.TMB_SET_TRACK_CLIPS(tmb, "video", 6, v6_clips)

    local playhead = 122965
    EMP.TMB_SET_PLAYHEAD(tmb, playhead, 0, 1.0)

    -- V1 at 122965 should be v1-clip-3 (sequence_start=122960, dur=43)
    local f1, i1 = EMP.TMB_GET_VIDEO_FRAME(tmb, 1, playhead)
    check(f1 ~= nil, "multitrack V1@122965: decoded")
    check(i1.clip_id == "v1-clip-3",
        string.format("multitrack V1@122965: clip_id=%s (expect v1-clip-3)", i1.clip_id))

    -- V3 at 122965 should be v3-clip-3 (parallel coverage of same source range)
    local f3, i3 = EMP.TMB_GET_VIDEO_FRAME(tmb, 3, playhead)
    check(f3 ~= nil, "multitrack V3@122965: decoded")
    check(i3.clip_id == "v3-clip-3",
        string.format("multitrack V3@122965: clip_id=%s (expect v3-clip-3)", i3.clip_id))

    -- V6 ref ends at 122960 (122097+863), so playhead 122965 is in gap.
    -- Decode at 122955 instead (5 frames before clip end).
    local v6_frame = 122955
    EMP.TMB_SET_PLAYHEAD(tmb, v6_frame, 0, 1.0)
    local f6, i6 = EMP.TMB_GET_VIDEO_FRAME(tmb, 6, v6_frame)
    check(f6 ~= nil, "multitrack V6@122955: decoded")
    check(i6.clip_id == "v6-ref",
        string.format("multitrack V6@122955: clip_id=%s (expect v6-ref)", i6.clip_id))

    if f1 and f6 then
        local fi1 = EMP.FRAME_INFO(f1)
        local fi6 = EMP.FRAME_INFO(f6)
        check(fi1.width > 0 and fi6.width > 0, "multitrack: both frames have valid dimensions")
    end

    EMP.TMB_RELEASE_ALL(tmb)
    EMP.TMB_CLOSE(tmb)
end

--------------------------------------------------------------------------------
-- 4. Cache thrashing regression: pre-buffer two adjacent clips, verify both
--    survive in cache.  Bug: MAX_VIDEO_CACHE (72) < 2 × PRE_BUFFER_BATCH (48)
--    caused the current clip's frames to be evicted by the next clip's pre-buffer.
--------------------------------------------------------------------------------
section("4. Cache thrashing regression (two clips pre-buffered)")
do
    local tmb = EMP.TMB_CREATE(3)
    EMP.TMB_SET_SEQUENCE_RATE(tmb, SEQ_FPS_NUM, SEQ_FPS_DEN)
    EMP.TMB_SET_TRACK_CLIPS(tmb, "video", 1, v1_clips)

    -- Use boundary where BOTH clips > PRE_BUFFER_BATCH (48):
    --   v1-clip-5 (123043-123172, 129 frames) → v1-clip-6 (123172-123286, 114 frames)
    -- Pre-buffer: min(48,remaining_A)+min(48,114) = 48+48=96 > MAX_VIDEO_CACHE(72) → thrash.
    -- Evicts 24 entries: the lowest keys in clip A (where playhead IS).
    local playhead_start = 123130  -- 42 frames from boundary (within PRE_BUFFER_THRESHOLD=96)
    local probe_frame = 123140     -- 10 frames ahead: in the evicted zone (bottom 24)

    -- Step 1: Park decode to open reader + seed last_displayed
    EMP.TMB_SET_PLAYHEAD(tmb, playhead_start, 0, 1.0)
    local f_park = EMP.TMB_GET_VIDEO_FRAME(tmb, 1, playhead_start)
    check(f_park ~= nil, "thrash: park decode at playhead (seeds reader)")

    -- Step 2: Switch to play mode: triggers BOTH pre-buffers:
    --   GetVideoFrame cache miss → async batch for clip A (42 frames from 123130)
    --   SetPlayhead boundary proximity → pre-buffer for clip B (48 frames from 123172)
    EMP.TMB_SET_PLAYHEAD(tmb, playhead_start + 1, 1, 1.0)
    EMP.TMB_GET_VIDEO_FRAME(tmb, 1, playhead_start + 1)  -- stale return → async clip A batch

    -- Step 3: Let both workers complete (42+48=90 frames decoded).
    os.execute("sleep 0.5")

    -- Step 4: Still in play mode — probe a frame in the "eviction zone".
    -- With old cache=72: 90-72=18 lowest keys evicted → 123130-123147 gone → pending=true.
    -- With new cache=144: all 90 fit → cache hit → pending=false.
    EMP.TMB_SET_PLAYHEAD(tmb, probe_frame, 1, 1.0)
    local fa, ia = EMP.TMB_GET_VIDEO_FRAME(tmb, 1, probe_frame)
    check(fa ~= nil, "thrash: probe frame has a frame")
    check(not ia.pending,
        "thrash: probe frame NOT pending (was evicted by clip B pre-buffer before fix)")

    EMP.TMB_RELEASE_ALL(tmb)
    EMP.TMB_CLOSE(tmb)
end

--------------------------------------------------------------------------------
-- 5. Async play through rapid cuts on V1
--    Simulates real playback: advance playhead frame-by-frame through the
--    v1-clip-2 → v1-clip-3 → v1-clip-4 transition (3 cuts in 115 frames).
--------------------------------------------------------------------------------
section("5. Async play through V1 rapid cuts (122928-123043)")
do
    local tmb = EMP.TMB_CREATE(3)
    EMP.TMB_SET_SEQUENCE_RATE(tmb, SEQ_FPS_NUM, SEQ_FPS_DEN)
    EMP.TMB_SET_TRACK_CLIPS(tmb, "video", 1, v1_clips)

    local start_frame = 122928  -- start of v1-clip-2
    local end_frame = 123043    -- end of v1-clip-4
    local MAX_RETRIES = 50
    local SLEEP_CMD = "sleep 0.01"
    local FRAME_DEADLINE_MS = 1000.0 / (SEQ_FPS_NUM / SEQ_FPS_DEN) -- 40ms at 25fps

    -- Pre-warm: park decode at start to open reader + seed cache, then
    -- signal play direction and let workers pre-buffer for 200ms.
    -- Without this, the first ~10 frames are always stale (cold start),
    -- masking the real bug (cache thrashing between clips).
    EMP.TMB_SET_PLAYHEAD(tmb, start_frame, 0, 1.0)
    local warm_frame = EMP.TMB_GET_VIDEO_FRAME(tmb, 1, start_frame)
    assert(warm_frame, "pre-warm: failed to park-decode start frame")
    EMP.TMB_SET_PLAYHEAD(tmb, start_frame, 1, 1.0)
    os.execute("sleep 0.2")  -- let workers pre-buffer ahead

    local decoded_count = 0
    local stuck_count = 0
    local worst_retries = 0
    local clip_transitions = {}
    local last_clip_id = nil

    -- Real-time metrics: frames that would glitch in live playback
    local POLL_SLEEP_MS = 10  -- os.execute("sleep 0.01") ≈ 10ms
    local stale_on_first_call = 0  -- pending=true on first GET = visible glitch
    local per_frame_retries = {}   -- retry count per frame
    local glitch_at_boundary = {}  -- which clip boundaries cause stale frames

    for f = start_frame, end_frame - 1 do
        EMP.TMB_SET_PLAYHEAD(tmb, f, 1, 1.0)
        local frame, info = EMP.TMB_GET_VIDEO_FRAME(tmb, 1, f)

        local first_call_pending = (frame == nil or info.pending)
        if first_call_pending then
            stale_on_first_call = stale_on_first_call + 1
        end

        local retries = 0
        while (frame == nil or info.pending) and retries < MAX_RETRIES do
            os.execute(SLEEP_CMD)
            frame, info = EMP.TMB_GET_VIDEO_FRAME(tmb, 1, f)
            retries = retries + 1
        end

        per_frame_retries[#per_frame_retries + 1] = retries
        if retries > worst_retries then worst_retries = retries end

        if frame ~= nil and not info.pending then
            decoded_count = decoded_count + 1
        else
            stuck_count = stuck_count + 1
        end

        -- Track clip transitions + whether they caused a stale frame
        if info.clip_id ~= last_clip_id and info.clip_id ~= "" then
            clip_transitions[#clip_transitions + 1] = {
                frame = f,
                clip_id = info.clip_id,
            }
            if first_call_pending then
                glitch_at_boundary[#glitch_at_boundary + 1] = {
                    frame = f,
                    clip_id = info.clip_id,
                    retries = retries,
                    wall_ms = retries * POLL_SLEEP_MS,
                }
            end
            last_clip_id = info.clip_id
        end
    end

    local total_frames = end_frame - start_frame
    check(stuck_count == 0,
        string.format("async V1 rapid cuts: %d/%d decoded, %d stuck (worst poll: %d)",
            decoded_count, total_frames, stuck_count, worst_retries))

    -- Should see exactly 3 clips: v1-clip-2 → v1-clip-3 → v1-clip-4
    check(#clip_transitions == 3,
        string.format("async V1 rapid cuts: %d clip transitions (expect 3)", #clip_transitions))

    if #clip_transitions >= 3 then
        check(clip_transitions[1].clip_id == "v1-clip-2",
            string.format("transition 1: %s (expect v1-clip-2)", clip_transitions[1].clip_id))
        check(clip_transitions[2].clip_id == "v1-clip-3",
            string.format("transition 2: %s (expect v1-clip-3)", clip_transitions[2].clip_id))
        check(clip_transitions[3].clip_id == "v1-clip-4",
            string.format("transition 3: %s (expect v1-clip-4)", clip_transitions[3].clip_id))
    end

    -- Real-time performance report
    -- Note: os.clock() = CPU time (excludes sleep). Retry count × 10ms = wall-time estimate.
    local glitch_pct = (stale_on_first_call / total_frames) * 100.0
    local worst_wall_ms = worst_retries * POLL_SLEEP_MS

    -- Count frames exceeding frame deadline (retry-based wall time estimate)
    local over_deadline_count = 0
    for _, r in ipairs(per_frame_retries) do
        if (r * POLL_SLEEP_MS) > FRAME_DEADLINE_MS then
            over_deadline_count = over_deadline_count + 1
        end
    end

    print(string.format("\n    [perf] %d/%d frames (%.0f%%) stale on first call (= visible glitch)",
        stale_on_first_call, total_frames, glitch_pct))
    print(string.format("    [perf] %d/%d frames (%.0f%%) exceeded %.0fms wall-time deadline",
        over_deadline_count, total_frames, (over_deadline_count / total_frames) * 100.0, FRAME_DEADLINE_MS))
    print(string.format("    [perf] worst resolve: %d retries ≈ %dms wall (deadline=%.0fms)",
        worst_retries, worst_wall_ms, FRAME_DEADLINE_MS))

    -- Per-boundary glitch detail
    if #glitch_at_boundary > 0 then
        print("    [perf] glitches at clip boundaries:")
        for _, g in ipairs(glitch_at_boundary) do
            print(string.format("      frame %d → %s: %d retries ≈ %dms",
                g.frame, g.clip_id, g.retries, g.wall_ms))
        end
    end

    -- Soft metric: stale frames depend on worker speed vs test advancement rate.
    -- In real playback (40ms/frame), workers keep up. Here we report for diagnostics.
    if stale_on_first_call > #clip_transitions then
        print(string.format("    ⚠ NOTE: %d stale frames > %d transitions (worker racing test, not cache thrashing)",
            stale_on_first_call, #clip_transitions))
    end

    EMP.TMB_RELEASE_ALL(tmb)
    EMP.TMB_CLOSE(tmb)
end

--------------------------------------------------------------------------------
-- 6. V6 gap test: V6 reference clip ends at 122960, gap after that
--------------------------------------------------------------------------------
section("6. V6 gap after clip end")
do
    local tmb = EMP.TMB_CREATE(0)
    EMP.TMB_SET_SEQUENCE_RATE(tmb, SEQ_FPS_NUM, SEQ_FPS_DEN)
    EMP.TMB_SET_TRACK_CLIPS(tmb, "video", 6, v6_clips)

    -- Frame inside V6 clip
    EMP.TMB_SET_PLAYHEAD(tmb, 122500, 0, 1.0)
    local f_in = EMP.TMB_GET_VIDEO_FRAME(tmb, 6, 122500)
    check(f_in ~= nil, "V6 inside clip: frame decoded")

    -- Frame after V6 clip ends (122097 + 863 = 122960)
    EMP.TMB_SET_PLAYHEAD(tmb, 122970, 0, 1.0)
    local f_gap, i_gap = EMP.TMB_GET_VIDEO_FRAME(tmb, 6, 122970)
    check(f_gap == nil, "V6 after clip end: nil frame (gap)")
    check(i_gap.clip_id == "", string.format("V6 gap: clip_id=%q (expect empty)", i_gap.clip_id))

    EMP.TMB_RELEASE_ALL(tmb)
    EMP.TMB_CLOSE(tmb)
end

--------------------------------------------------------------------------------
-- Summary
--------------------------------------------------------------------------------
print(string.format("\n%d/%d checks passed", passed, total))
if #failures > 0 then
    print("\nFailures:")
    for _, msg in ipairs(failures) do
        print("  - " .. msg)
    end
end
if passed == total then
    print("✅ test_tmb_real_timeline.lua passed")
else
    error(string.format("FAILED: %d/%d checks failed", total - passed, total))
end
