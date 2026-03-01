-- Integration test: Async playback through gap clears frame and recovers
--
-- Tests the ASYNC (playback) code path — display link callback → main queue.
-- The sync test (test_seek_gap_clears_frame.lua) only covers seeks, which
-- run on the calling thread. This test exercises real playback.
--
-- Two scenarios:
--   1. Clean clip boundary → gap → next clip (no source EOF)
--   2. Source EOF within clip → gap → next clip
--
-- Observable: SURFACE_FRAME_SIZE returns 0,0 during gap, >0,>0 during clip.
--
-- Must run via: JVEEditor --test tests/integration/test_playback_gap_clears_and_recovers.lua

require('test_env')

local env = require("integration.integration_test_env")
local EMP = env.require_emp()
local PLAYBACK = qt_constants.PLAYBACK
local WIDGET = qt_constants.WIDGET
local CONTROL = qt_constants.CONTROL

local ok_surf, test_surface = pcall(WIDGET.CREATE_GPU_VIDEO_SURFACE)
if not ok_surf or not test_surface then
    print("  Skipping: GPU surface not available (headless?)")
    print("✅ test_playback_gap_clears_and_recovers.lua passed (skipped)")
    return
end

local function poll_sleep(pc_handle, seconds)
    os.execute(string.format("sleep %.3f", seconds))
    if pc_handle then
        PLAYBACK.TICK(pc_handle)
    end
    CONTROL.PROCESS_EVENTS()
end

print("Testing async playback through gap — clear and recover...")

local media_path = env.test_media_path(env.STANDARD_MEDIA)
local RATE_NUM = 24000
local RATE_DEN = 1001

--- Create TMB with two clips separated by a gap on the same track.
local function create_gap_tmb(opts)
    local tmb = EMP.TMB_CREATE(opts.pool_threads or 2)
    assert(tmb, "create_gap_tmb: TMB_CREATE returned nil")
    EMP.TMB_SET_SEQUENCE_RATE(tmb, RATE_NUM, RATE_DEN)

    local clip_a = {
        clip_id = "clip-A",
        media_path = media_path,
        timeline_start = opts.clip_a_start,
        duration = opts.clip_a_duration,
        source_in = opts.clip_a_source_in or 0,
        rate_num = RATE_NUM,
        rate_den = RATE_DEN,
        speed_ratio = 1.0,
    }
    local clip_b = {
        clip_id = "clip-B",
        media_path = media_path,
        timeline_start = opts.clip_b_start,
        duration = opts.clip_b_duration,
        source_in = opts.clip_b_source_in or 0,
        rate_num = RATE_NUM,
        rate_den = RATE_DEN,
        speed_ratio = 1.0,
    }

    EMP.TMB_SET_TRACK_CLIPS(tmb, "video", 1, { clip_a, clip_b })
    return tmb
end

--- Run a single playback-through-gap scenario.
-- Seeks near end of clip A, plays through the gap into clip B.
-- Asserts: surface clears during gap AND recovers during clip B.
local function run_scenario(label, tmb, seek_frame, bounds)
    print(string.format("  Scenario: %s", label))

    local pc = PLAYBACK.CREATE()
    assert(pc, "run_scenario: CREATE failed for " .. label)

    PLAYBACK.SET_TMB(pc, tmb)
    PLAYBACK.SET_BOUNDS(pc, bounds, RATE_NUM, RATE_DEN)
    PLAYBACK.SET_VIDEO_TRACKS(pc, {1})
    PLAYBACK.SET_SURFACE(pc, test_surface)
    PLAYBACK.SET_NEED_CLIPS_CALLBACK(pc, function(_, _, track_type)
        PLAYBACK.SET_CLIP_WINDOW(pc, track_type, 0, bounds)
    end)
    PLAYBACK.SET_CLIP_WINDOW(pc, "video", 0, bounds)
    PLAYBACK.SET_CLIP_WINDOW(pc, "audio", 0, bounds)

    -- Seek inside clip A — verify content displayed
    PLAYBACK.SEEK(pc, seek_frame)
    local w, h = EMP.SURFACE_FRAME_SIZE(test_surface)
    assert(w > 0 and h > 0,
        string.format("%s: seek to frame %d: %dx%d (expected >0x>0)", label, seek_frame, w, h))
    print(string.format("    PASS: Seek to frame %d: %dx%d", seek_frame, w, h))

    -- Start playback
    PLAYBACK.PLAY(pc, 1, 1.0)

    -- Phase 1: wait for gap — surface must clear (frameSize 0x0)
    local gap_detected = false
    for i = 1, 200 do  -- 200 × 16ms = 3.2s max
        poll_sleep(pc, 0.016)
        w, h = EMP.SURFACE_FRAME_SIZE(test_surface)
        if w == 0 and h == 0 then
            gap_detected = true
            print(string.format("    PASS: Gap detected (black) after %d polls", i))
            break
        end
    end
    assert(gap_detected,
        string.format("%s: surface never cleared during gap (still %dx%d after 3.2s)",
            label, w, h))

    -- Phase 2: wait for clip B — surface must recover (frameSize >0x>0)
    local recovered = false
    for i = 1, 200 do  -- 200 × 16ms = 3.2s max
        poll_sleep(pc, 0.016)
        w, h = EMP.SURFACE_FRAME_SIZE(test_surface)
        if w > 0 and h > 0 then
            recovered = true
            print(string.format("    PASS: Clip B recovered (%dx%d) after %d polls", w, h, i))
            break
        end
    end
    assert(recovered,
        string.format("%s: surface never recovered after gap (still %dx%d after 3.2s)",
            label, w, h))

    PLAYBACK.STOP(pc)
    PLAYBACK.CLOSE(pc)
end

------------------------------------------------------------------------
-- Scenario 1: Clean boundary (no EOF)
-- Clip A: frames 0-29 (source_in=0, 30 frames from 108-frame source)
-- Gap:    frames 30-49
-- Clip B: frames 50-79 (source_in=30)
------------------------------------------------------------------------
local tmb1 = create_gap_tmb({
    pool_threads = 2,
    clip_a_start = 0,
    clip_a_duration = 30,
    clip_a_source_in = 0,
    clip_b_start = 50,
    clip_b_duration = 30,
    clip_b_source_in = 30,
})
run_scenario("Clean boundary (no EOF)", tmb1, 25, 100)
EMP.TMB_CLOSE(tmb1)

------------------------------------------------------------------------
-- Scenario 2: EOF boundary
-- Clip A: frames 0-29 (source_in=95 → source 95-124, file has 108 →
--         EOF at source 108 = timeline frame ~13. Remaining frames
--         hold last decoded frame via REFILL EOF handler.)
-- Gap:    frames 30-49
-- Clip B: frames 50-79 (source_in=0, fresh start)
------------------------------------------------------------------------
local tmb2 = create_gap_tmb({
    pool_threads = 2,
    clip_a_start = 0,
    clip_a_duration = 30,
    clip_a_source_in = 95,
    clip_b_start = 50,
    clip_b_duration = 30,
    clip_b_source_in = 0,
})
run_scenario("EOF boundary", tmb2, 10, 100)
EMP.TMB_CLOSE(tmb2)

print("✅ test_playback_gap_clears_and_recovers.lua passed")
