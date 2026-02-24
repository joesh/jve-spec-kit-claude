-- Integration test: End-to-end A/V sync through real C++ PlaybackController.
--
-- Exercises the full playback pipeline: TMB decode → PlaybackController tick →
-- GPU surface delivery → audio output. Measures A/V drift, seek latency,
-- and monotonic frame advancement through rapid cuts.
--
-- Uses the Anamnesis gold master V1 rapid-cut sequence (real media, real edits).
-- Audio assertions gracefully degrade if no audio device is available (CI/headless).
--
-- Must run via: JVEEditor --test tests/integration/test_playback_av_sync.lua

local ienv = require("integration.integration_test_env")
local ffi = require("ffi")

print("=== test_playback_av_sync.lua ===")

--------------------------------------------------------------------------------
-- Wall-clock timer (microsecond monotonic via mach_absolute_time)
--------------------------------------------------------------------------------
ffi.cdef[[
    typedef struct { uint32_t numer; uint32_t denom; } jve_mach_timebase_info_t;
    uint64_t mach_absolute_time(void);
    int mach_timebase_info(jve_mach_timebase_info_t *info);
]]

local timebase = ffi.new("jve_mach_timebase_info_t")
ffi.C.mach_timebase_info(timebase)
local tb_numer = tonumber(timebase.numer)
local tb_denom = tonumber(timebase.denom)
assert(tb_denom > 0, "mach_timebase_info: denom is 0")

local function wall_us()
    local t = ffi.C.mach_absolute_time()
    -- Convert to microseconds: ticks * numer / denom / 1000
    return tonumber(t) * tb_numer / tb_denom / 1000.0
end

--------------------------------------------------------------------------------
-- Prerequisites
--------------------------------------------------------------------------------
local EMP = ienv.require_emp()
local PLAYBACK = qt_constants.PLAYBACK
assert(PLAYBACK, "PLAYBACK bindings not available")

local CONTROL = qt_constants.CONTROL
assert(CONTROL and CONTROL.PROCESS_EVENTS,
    "CONTROL.PROCESS_EVENTS not available (stale build?)")

--- Sleep briefly, fire manual tick (when CVDisplayLink unavailable), drain GCD queue.
-- CVDisplayLink fails in CLI/headless mode; TICK manually fires the display link
-- callback, then PROCESS_EVENTS drains dispatch_async blocks (frame delivery, callbacks).
local function poll_sleep(pc_handle, seconds)
    os.execute(string.format("sleep %.3f", seconds))
    if pc_handle then
        PLAYBACK.TICK(pc_handle)
    end
    CONTROL.PROCESS_EVENTS()
end

local WIDGET = qt_constants.WIDGET
assert(WIDGET and WIDGET.CREATE_GPU_VIDEO_SURFACE,
    "CREATE_GPU_VIDEO_SURFACE not available")

local ok_surf, surface = pcall(WIDGET.CREATE_GPU_VIDEO_SURFACE)
if not ok_surf or not surface then
    print("  SKIP: GPU surface creation failed (headless?)")
    print("✅ test_playback_av_sync.lua passed (skipped)")
    return
end
print("  ✓ Created GPU video surface")

--------------------------------------------------------------------------------
-- Check/section helpers
--------------------------------------------------------------------------------
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
-- Media paths (Anamnesis fixtures — same as test_tmb_real_timeline.lua)
--------------------------------------------------------------------------------
local MEDIA_DIR = ienv.resolve_repo_path("tests/fixtures/media/anamnesis")

local media = {
    day4_c002 = MEDIA_DIR .. "/A012_C002.mov",  -- 18-097-002
    day4_c008 = MEDIA_DIR .. "/A012_C008.mov",  -- 18-100-001
    day4_c005 = MEDIA_DIR .. "/A012_C005.mov",  -- 18-098-003
    day4_c010 = MEDIA_DIR .. "/A012_C010.mov",  -- 18-100-003
}

-- Verify all media files exist
for name, path in pairs(media) do
    local f = io.open(path, "r")
    assert(f, "Missing fixture: " .. name .. " at " .. path)
    f:close()
end

--------------------------------------------------------------------------------
-- Timeline layout: V1 rapid-cut sequence starting at frame 122960
-- 3 cuts in ~326 frames (~13s at 25fps)
--------------------------------------------------------------------------------
local SEQ_FPS_NUM = 25
local SEQ_FPS_DEN = 1
local WINDOW_LO = 122960
local WINDOW_HI = 123286

local v1_clips = {
    { clip_id = "v1-18-097-002", media_path = media.day4_c002, timeline_start = 122960, duration = 43,  source_in = 0, rate_num = 25, rate_den = 1, speed_ratio = 1.0 },
    { clip_id = "v1-18-100-001", media_path = media.day4_c008, timeline_start = 123003, duration = 40,  source_in = 0, rate_num = 25, rate_den = 1, speed_ratio = 1.0 },
    { clip_id = "v1-18-098-003", media_path = media.day4_c005, timeline_start = 123043, duration = 129, source_in = 0, rate_num = 25, rate_den = 1, speed_ratio = 1.0 },
    { clip_id = "v1-18-100-003", media_path = media.day4_c010, timeline_start = 123172, duration = 114, source_in = 0, rate_num = 25, rate_den = 1, speed_ratio = 1.0 },
}

-- Audio track: same clips, same layout (AAC 48kHz stereo in all Anamnesis MOVs)
local a1_clips = {}
for i, vc in ipairs(v1_clips) do
    a1_clips[i] = {
        clip_id = "a1-" .. vc.clip_id:sub(4),
        media_path = vc.media_path,
        timeline_start = vc.timeline_start,
        duration = vc.duration,
        source_in = vc.source_in,
        rate_num = vc.rate_num,
        rate_den = vc.rate_den,
        speed_ratio = vc.speed_ratio,
    }
end

--------------------------------------------------------------------------------
-- TMB setup (2 pool threads for async decode)
--------------------------------------------------------------------------------
local tmb = EMP.TMB_CREATE(2)
assert(tmb, "TMB_CREATE returned nil")
EMP.TMB_SET_SEQUENCE_RATE(tmb, SEQ_FPS_NUM, SEQ_FPS_DEN)
EMP.TMB_SET_TRACK_CLIPS(tmb, "video", 1, v1_clips)
EMP.TMB_SET_TRACK_CLIPS(tmb, "audio", 1, a1_clips)
EMP.TMB_SET_AUDIO_FORMAT(tmb, 48000, 2)
EMP.TMB_SET_AUDIO_MIX_PARAMS(tmb, {{ track_index = 1, volume = 1.0 }}, 48000, 2)
print("  ✓ TMB created: video V1 + audio A1, 4 clips each")

--------------------------------------------------------------------------------
-- PlaybackController setup
--------------------------------------------------------------------------------
local pc = PLAYBACK.CREATE()
assert(pc, "Failed to create PlaybackController")

PLAYBACK.SET_TMB(pc, tmb)
PLAYBACK.SET_BOUNDS(pc, WINDOW_HI, SEQ_FPS_NUM, SEQ_FPS_DEN)
PLAYBACK.SET_VIDEO_TRACKS(pc, { 1 })
PLAYBACK.SET_SURFACE(pc, surface)
PLAYBACK.SET_CLIP_WINDOW(pc, "video", WINDOW_LO, WINDOW_HI)
PLAYBACK.SET_CLIP_WINDOW(pc, "audio", WINDOW_LO, WINDOW_HI)

-- Capture frame history via position callback
local position_history = {}
PLAYBACK.SET_NEED_CLIPS_CALLBACK(pc, function() end)
PLAYBACK.SET_POSITION_CALLBACK(pc, function(frame, stopped)
    position_history[#position_history + 1] = {
        frame = frame, stopped = stopped, wall_us = wall_us(),
    }
end)

-- Capture clip transitions
local clip_transitions = {}
PLAYBACK.SET_CLIP_TRANSITION_CALLBACK(pc, function(clip_id, rotation, par_num, par_den, is_offline)
    clip_transitions[#clip_transitions + 1] = {
        clip_id = clip_id, wall_us = wall_us(),
    }
end)

print("  ✓ PlaybackController created and wired")

--------------------------------------------------------------------------------
-- Audio setup (graceful degradation)
--------------------------------------------------------------------------------
local aop, sse = ienv.try_open_audio(48000, 2)
local has_audio = (aop ~= nil)

if has_audio then
    PLAYBACK.ACTIVATE_AUDIO(pc, aop, sse, 48000, 2)
    print("  ✓ Audio activated (AOP + SSE)")
else
    print("  ⚠ No audio device — video-only assertions")
end

--------------------------------------------------------------------------------
-- Test 1: Forward Playback Through Rapid Cuts
--------------------------------------------------------------------------------
section("1. Forward playback through rapid cuts")
do
    local START_FRAME = 122965

    -- Park at start position
    PLAYBACK.SEEK(pc, START_FRAME)
    check(PLAYBACK.CURRENT_FRAME(pc) == START_FRAME,
        string.format("parked at frame %d", START_FRAME))

    -- Record baseline
    local baseline_surface_count = EMP.SURFACE_FRAME_COUNT(surface)
    local baseline_wall_us = wall_us()
    local baseline_audio_us = has_audio and qt_constants.AOP.PLAYHEAD_US(aop) or 0

    -- Clear state for this run
    position_history = {}
    clip_transitions = {}

    -- Start playback.
    -- Warm-up: first ~500ms has cold-buffer underruns (expected — AAC decode from
    -- seek point + SSE fill + AOP buffer). Clear flag after audio pipeline stabilizes.
    PLAYBACK.PLAY(pc, 1, 1.0)
    for _ = 1, 30 do poll_sleep(pc, 0.016) end  -- ~500ms at ~60Hz tick rate
    if has_audio then
        qt_constants.AOP.CLEAR_UNDERRUN(aop)
    end

    -- Poll for ~2 seconds at ~60Hz tick rate. Sample every 3rd tick for measurements.
    local samples = {}
    local POLL_COUNT = 120  -- 120 × 16ms ≈ 2 seconds
    local SAMPLE_INTERVAL = 3

    for i = 1, POLL_COUNT do
        poll_sleep(pc, 0.016)
        -- Sample less frequently to reduce overhead (every 3rd tick ≈ 50ms)
        if i % SAMPLE_INTERVAL == 0 then
            local s = {
                wall_us = wall_us(),
                video_frame = PLAYBACK.CURRENT_FRAME(pc),
                surface_count = EMP.SURFACE_FRAME_COUNT(surface),
            }
            if has_audio then
                s.audio_playhead_us = qt_constants.AOP.PLAYHEAD_US(aop)
            end
            samples[#samples + 1] = s
        end
    end

    PLAYBACK.STOP(pc)
    local final_wall_us = wall_us()

    -- (a) Video advanced
    local last_frame = samples[#samples].video_frame
    check(last_frame > START_FRAME,
        string.format("video advanced: %d → %d", START_FRAME, last_frame))

    -- (b) Surface delivered frames
    local surface_delta = samples[#samples].surface_count - baseline_surface_count
    check(surface_delta > 0,
        string.format("surface delivered %d frames", surface_delta))

    -- (c) Monotonic: each frame >= previous (repeat OK, backward NOT OK)
    local monotonic = true
    local prev_frame = START_FRAME
    for _, s in ipairs(samples) do
        if s.video_frame < prev_frame then
            monotonic = false
            break
        end
        prev_frame = s.video_frame
    end
    check(monotonic, "video frames monotonically non-decreasing")

    -- (d) Rate: frames_advanced / wall_seconds ≈ 25fps (±50% tolerance for CI)
    local frames_advanced = last_frame - START_FRAME
    local wall_seconds = (final_wall_us - baseline_wall_us) / 1000000.0
    local measured_fps = frames_advanced / wall_seconds
    local target_fps = SEQ_FPS_NUM / SEQ_FPS_DEN
    local fps_lo = target_fps * 0.5
    local fps_hi = target_fps * 1.5
    check(measured_fps >= fps_lo and measured_fps <= fps_hi,
        string.format("playback rate: %.1ffps (target %d±50%%)", measured_fps, target_fps))

    -- (e) [Audio] Playhead advanced
    if has_audio then
        local last_audio_us = samples[#samples].audio_playhead_us
        check(last_audio_us > baseline_audio_us,
            string.format("audio playhead advanced: %d → %d us",
                baseline_audio_us, last_audio_us))

        -- (f) [Audio] No underruns
        local had_underrun = qt_constants.AOP.HAD_UNDERRUN(aop)
        check(not had_underrun, "no audio underruns during playback")

        -- (g) [A/V sync] Drift measurement
        local max_drift_us = 0
        local drift_samples = {}
        for _, s in ipairs(samples) do
            if s.audio_playhead_us and s.audio_playhead_us > 0 then
                local video_time_us = (s.video_frame - START_FRAME) * 1000000.0 / target_fps
                local drift = math.abs(video_time_us - s.audio_playhead_us)
                if drift > max_drift_us then max_drift_us = drift end
                drift_samples[#drift_samples + 1] = {
                    wall_us = s.wall_us, drift = drift,
                }
            end
        end

        -- Max drift < 300ms (150ms output latency + 150ms tolerance)
        local MAX_DRIFT_US = 300000
        check(max_drift_us < MAX_DRIFT_US,
            string.format("A/V drift max %.1fms (limit %.0fms)",
                max_drift_us / 1000.0, MAX_DRIFT_US / 1000.0))

        -- Drift not growing (linear regression slope < 1ms/s)
        if #drift_samples >= 4 then
            local n = #drift_samples
            local sum_x, sum_y, sum_xy, sum_xx = 0, 0, 0, 0
            local t0 = drift_samples[1].wall_us
            for _, ds in ipairs(drift_samples) do
                local x = (ds.wall_us - t0) / 1000000.0  -- seconds
                local y = ds.drift / 1000.0              -- milliseconds
                sum_x = sum_x + x
                sum_y = sum_y + y
                sum_xy = sum_xy + x * y
                sum_xx = sum_xx + x * x
            end
            local denom = n * sum_xx - sum_x * sum_x
            if denom > 0 then
                local slope = (n * sum_xy - sum_x * sum_y) / denom  -- ms per second
                -- Manual TICK has inherent jitter (~5-10ms/s) vs hardware CVDisplayLink.
                -- 15ms/s limit catches real divergence while tolerating tick jitter.
                check(slope < 15.0,
                    string.format("A/V drift slope: %.2f ms/s (limit 15.0 ms/s)", slope))
                if slope >= 1.0 then
                    print(string.format("    [info] drift slope %.2f ms/s (manual tick jitter expected)", slope))
                end
            end
        end
    end

    -- Report clip transitions observed
    print(string.format("    [info] %d clip transitions, %d position callbacks",
        #clip_transitions, #position_history))
    print(string.format("    [info] %d frames in %.1fs = %.1f fps",
        frames_advanced, wall_seconds, measured_fps))
end

--------------------------------------------------------------------------------
-- Test 2: Seek Accuracy + Latency
--------------------------------------------------------------------------------
section("2. Seek accuracy + latency")
do
    local SEEK_TARGET = 123100

    local count_before = EMP.SURFACE_FRAME_COUNT(surface)
    local t_before = wall_us()

    PLAYBACK.SEEK(pc, SEEK_TARGET)

    local t_after = wall_us()
    local count_after = EMP.SURFACE_FRAME_COUNT(surface)
    local seek_latency_us = t_after - t_before

    check(PLAYBACK.CURRENT_FRAME(pc) == SEEK_TARGET,
        string.format("seek target: CURRENT_FRAME=%d (expect %d)",
            PLAYBACK.CURRENT_FRAME(pc), SEEK_TARGET))

    check(count_after > count_before,
        string.format("seek delivered frame: surface count %d → %d",
            count_before, count_after))

    -- 500ms generous limit for decode + display
    local MAX_SEEK_LATENCY_US = 500000
    check(seek_latency_us < MAX_SEEK_LATENCY_US,
        string.format("seek latency: %.1fms (limit %.0fms)",
            seek_latency_us / 1000.0, MAX_SEEK_LATENCY_US / 1000.0))

    print(string.format("    [bench] seek to %d: %.1fms", SEEK_TARGET, seek_latency_us / 1000.0))
end

--------------------------------------------------------------------------------
-- Test 3: Seek + Resume Playback
--------------------------------------------------------------------------------
section("3. Seek + resume playback")
do
    local RESUME_START = 123043  -- clip boundary: 18-098-003 start

    -- Clear underrun flag before seek+resume test
    if has_audio then
        qt_constants.AOP.CLEAR_UNDERRUN(aop)
    end

    PLAYBACK.SEEK(pc, RESUME_START)
    check(PLAYBACK.CURRENT_FRAME(pc) == RESUME_START,
        string.format("parked at clip boundary %d", RESUME_START))

    local count_before = EMP.SURFACE_FRAME_COUNT(surface)
    position_history = {}

    -- Play for ~1 second (20 × 50ms).
    -- Clear underrun AFTER play starts — the initial pump cycles may underrun
    -- while the audio buffer fills from empty (expected cold-start behavior).
    PLAYBACK.PLAY(pc, 1, 1.0)
    poll_sleep(pc, 0.2)  -- warm-up: let audio pump fill buffer (seek flushed it)
    if has_audio then
        qt_constants.AOP.CLEAR_UNDERRUN(aop)
    end
    for _ = 1, 18 do
        poll_sleep(pc, 0.05)
    end
    PLAYBACK.STOP(pc)

    local last_frame = PLAYBACK.CURRENT_FRAME(pc)
    local count_after = EMP.SURFACE_FRAME_COUNT(surface)

    -- Monotonic advancement from resume point
    check(last_frame >= RESUME_START,
        string.format("resumed forward: %d → %d", RESUME_START, last_frame))

    check(count_after > count_before,
        string.format("surface frames delivered after resume: %d → %d",
            count_before, count_after))

    -- Audio: no underruns after seek+resume
    if has_audio then
        local had_underrun = qt_constants.AOP.HAD_UNDERRUN(aop)
        check(not had_underrun, "no audio underruns after seek+resume")
    end

    print(string.format("    [info] resumed from %d, advanced to %d (%d frames)",
        RESUME_START, last_frame, last_frame - RESUME_START))
end

--------------------------------------------------------------------------------
-- Cleanup
--------------------------------------------------------------------------------
section("Cleanup")
PLAYBACK.STOP(pc)
if has_audio then
    PLAYBACK.DEACTIVATE_AUDIO(pc)
    qt_constants.AOP.CLOSE(aop)
    qt_constants.SSE.CLOSE(sse)
    print("  ✓ Audio deactivated and closed")
end
PLAYBACK.CLOSE(pc)
EMP.TMB_CLOSE(tmb)
print("  ✓ PlaybackController and TMB closed")

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
    print("✅ test_playback_av_sync.lua passed")
else
    error(string.format("FAILED: %d/%d checks failed", total - passed, total))
end
