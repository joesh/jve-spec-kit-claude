-- Integration Test: Real Timeline Section from Anamnesis Gold Master
-- Reconstructs the actual clip layout around playhead 122965 in
-- "2026-01-21-anamnesis-GOLD-MASTER-CANDIDATE" and decodes through it.
--
-- Tests: multi-track video decode, clip boundary transitions, rapid cuts,
-- async pending resolution across real edit points with real media.
--
-- Must run via: JVEEditor --test tests/integration/test_tmb_real_timeline.lua

local ienv = require("integration.integration_test_env")
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
-- Media paths (extracted fixtures — source_in is zero-based)
--------------------------------------------------------------------------------
local MEDIA_DIR = ienv.resolve_repo_path("tests/fixtures/media/anamnesis")

local media = {
    vfx_01    = MEDIA_DIR .. "/A016_C003_VFX_01.mov",  -- Helen VHS VFX
    day5_c003 = MEDIA_DIR .. "/A016_C003.mov",          -- 30-124-001
    day4_c002 = MEDIA_DIR .. "/A012_C002.mov",          -- 18-097-002
    day4_c008 = MEDIA_DIR .. "/A012_C008.mov",          -- 18-100-001
    day4_c005 = MEDIA_DIR .. "/A012_C005.mov",          -- 18-098-003
    day4_c010 = MEDIA_DIR .. "/A012_C010.mov",          -- 18-100-003
    gold      = MEDIA_DIR .. "/GOLD_MASTER.mov",        -- prev gold master on V6
}

-- Verify all media files exist
for name, path in pairs(media) do
    local f = io.open(path, "r")
    assert(f, "Missing fixture: " .. name .. " at " .. path)
    f:close()
end

--------------------------------------------------------------------------------
-- Timeline layout: V1 clips around playhead 122965
-- Original source_in values adjusted to zero-based (fixtures start at original src_in)
--------------------------------------------------------------------------------
local SEQ_FPS_NUM = 25
local SEQ_FPS_DEN = 1

-- V1: rapid cut sequence — Helen VHS → 30-124-001 → 18-097-002 → 18-100-001 → 18-098-003 → 18-100-003
local v1_clips = {
    { clip_id = "v1-helen-vhs",  media_path = media.vfx_01,    timeline_start = 122097, duration = 831, source_in = 0, rate_num = 25, rate_den = 1, speed_ratio = 1.0 },
    { clip_id = "v1-30-124-001", media_path = media.day5_c003,  timeline_start = 122928, duration = 32,  source_in = 0, rate_num = 25, rate_den = 1, speed_ratio = 1.0 },
    { clip_id = "v1-18-097-002", media_path = media.day4_c002,  timeline_start = 122960, duration = 43,  source_in = 0, rate_num = 25, rate_den = 1, speed_ratio = 1.0 },
    { clip_id = "v1-18-100-001", media_path = media.day4_c008,  timeline_start = 123003, duration = 40,  source_in = 0, rate_num = 25, rate_den = 1, speed_ratio = 1.0 },
    { clip_id = "v1-18-098-003", media_path = media.day4_c005,  timeline_start = 123043, duration = 129, source_in = 0, rate_num = 25, rate_den = 1, speed_ratio = 1.0 },
    { clip_id = "v1-18-100-003", media_path = media.day4_c010,  timeline_start = 123172, duration = 114, source_in = 0, rate_num = 25, rate_den = 1, speed_ratio = 1.0 },
}

-- V3: parallel coverage clips (same source ranges, different camera files)
local v3_clips = {
    { clip_id = "v3-18-097-002", media_path = media.day4_c002,  timeline_start = 122960, duration = 43,  source_in = 0, rate_num = 25, rate_den = 1, speed_ratio = 1.0 },
    { clip_id = "v3-18-100-001", media_path = media.day4_c008,  timeline_start = 123003, duration = 40,  source_in = 0, rate_num = 25, rate_den = 1, speed_ratio = 1.0 },
    { clip_id = "v3-18-100-003", media_path = media.day4_c010,  timeline_start = 123172, duration = 114, source_in = 0, rate_num = 25, rate_den = 1, speed_ratio = 1.0 },
}

-- V6: previous gold master export (reference layer)
local v6_clips = {
    { clip_id = "v6-gold-ref",   media_path = media.gold,       timeline_start = 122097, duration = 863, source_in = 0, rate_num = 25, rate_den = 1, speed_ratio = 1.0 },
}

--------------------------------------------------------------------------------
-- 1. Probe all media files
--------------------------------------------------------------------------------
section("1. Probe media files")
do
    for name, path in pairs(media) do
        local info = EMP.MEDIA_FILE_PROBE(path)
        check(info ~= nil, string.format("probe %s: got info", name))
        if info then
            check(info.has_video, string.format("probe %s: has video (%dx%d)", name, info.width, info.height))
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
        local mid = clip.timeline_start + math.floor(clip.duration / 2)
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

    -- V1 at 122965 should be clip v1-18-097-002 (timeline_start=122960, dur=43)
    local f1, i1 = EMP.TMB_GET_VIDEO_FRAME(tmb, 1, playhead)
    check(f1 ~= nil, "multitrack V1@122965: decoded")
    check(i1.clip_id == "v1-18-097-002",
        string.format("multitrack V1@122965: clip_id=%s (expect v1-18-097-002)", i1.clip_id))

    -- V3 at 122965 should be clip v3-18-097-002
    local f3, i3 = EMP.TMB_GET_VIDEO_FRAME(tmb, 3, playhead)
    check(f3 ~= nil, "multitrack V3@122965: decoded")
    check(i3.clip_id == "v3-18-097-002",
        string.format("multitrack V3@122965: clip_id=%s (expect v3-18-097-002)", i3.clip_id))

    -- V6 gold ref ends at 122960 (122097+863), so playhead 122965 is in gap.
    -- Decode at 122955 instead (5 frames before clip end).
    local v6_frame = 122955
    EMP.TMB_SET_PLAYHEAD(tmb, v6_frame, 0, 1.0)
    local f6, i6 = EMP.TMB_GET_VIDEO_FRAME(tmb, 6, v6_frame)
    check(f6 ~= nil, "multitrack V6@122955: decoded")
    check(i6.clip_id == "v6-gold-ref",
        string.format("multitrack V6@122955: clip_id=%s (expect v6-gold-ref)", i6.clip_id))

    -- Verify different frames (different media files = different pixel data)
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
    local tmb = EMP.TMB_CREATE(2)
    EMP.TMB_SET_SEQUENCE_RATE(tmb, SEQ_FPS_NUM, SEQ_FPS_DEN)
    EMP.TMB_SET_TRACK_CLIPS(tmb, "video", 1, v1_clips)

    -- Use boundary where BOTH clips > PRE_BUFFER_BATCH (48):
    --   v1-18-098-003 (123043-123172, 129 frames) → v1-18-100-003 (123172-123286, 114 frames)
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
--    30-124-001 → 18-097-002 → 18-100-001 transition (3 cuts in 115 frames).
--------------------------------------------------------------------------------
section("5. Async play through V1 rapid cuts (122928-123043)")
do
    local tmb = EMP.TMB_CREATE(2)
    EMP.TMB_SET_SEQUENCE_RATE(tmb, SEQ_FPS_NUM, SEQ_FPS_DEN)
    EMP.TMB_SET_TRACK_CLIPS(tmb, "video", 1, v1_clips)

    local start_frame = 122928  -- start of 30-124-001
    local end_frame = 123043    -- end of 18-100-001
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

    -- Should see exactly 3 clips: 30-124-001 → 18-097-002 → 18-100-001
    check(#clip_transitions == 3,
        string.format("async V1 rapid cuts: %d clip transitions (expect 3)", #clip_transitions))

    if #clip_transitions >= 3 then
        check(clip_transitions[1].clip_id == "v1-30-124-001",
            string.format("transition 1: %s (expect v1-30-124-001)", clip_transitions[1].clip_id))
        check(clip_transitions[2].clip_id == "v1-18-097-002",
            string.format("transition 2: %s (expect v1-18-097-002)", clip_transitions[2].clip_id))
        check(clip_transitions[3].clip_id == "v1-18-100-001",
            string.format("transition 3: %s (expect v1-18-100-001)", clip_transitions[3].clip_id))
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
-- 6. V6 gap test: V6 gold master ends at 122960, gap after that
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
