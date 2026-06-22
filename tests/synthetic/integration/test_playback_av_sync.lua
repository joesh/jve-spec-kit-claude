-- Integration test: End-to-end A/V sync through real C++ PlaybackController.
--
-- Exercises the full playback pipeline: TMB decode → PlaybackController tick →
-- GPU surface delivery → audio output. Measures A/V drift, seek latency,
-- and monotonic frame advancement through rapid cuts.
--
-- Uses the Anamnesis gold master V1 rapid-cut sequence (real media, real edits).
-- Audio assertions gracefully degrade if no audio device is available (CI/headless).
--
-- Must run via: JVEEditor --test tests/synthetic/integration/test_playback_av_sync.lua

local ienv = require("synthetic.integration.integration_test_env")
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

--- Assert playback cadence quality from diag ring summary.
-- Call after PLAYBACK.STOP — rings survive until next Play().
-- @param fps_num, fps_den: sequence frame rate (cadence threshold floor)
-- @param wall_ms: wall duration of the play loop (microseconds-to-ms scale OK).
--   Used to derive the OBSERVED tick interval (wall_ms / tick_count). When
--   CVDisplayLink succeeds, ticks come at ~60Hz and frame_period dominates the
--   gate; when it falls back to manual TICK (--test mode without a window),
--   tick interval is ~50ms and dominates instead. Without this, the gate
--   measures the test driver's sleep jitter rather than engine cadence and
--   false-positives in headless fallback.
local function assert_diag_quality(pc_handle, label, has_audio_flag, fps_num, fps_den, wall_ms)
    local diag = PLAYBACK.GET_DIAG_SUMMARY(pc_handle)
    if diag.tick_count == 0 then
        print("    [diag] " .. label .. ": no ticks recorded (skip assertions)")
        return
    end

    local frame_period_ms = 1000.0 / (fps_num / fps_den)
    assert(wall_ms and wall_ms > 0, "assert_diag_quality: wall_ms required")
    local tick_interval_ms = wall_ms / diag.tick_count
    local cadence_floor_ms = math.max(frame_period_ms, tick_interval_ms)

    -- Allow ≤2 under CI/headless: manual TICK under heavy CPU load can briefly
    -- starve the audio pump (buf=0 → audio-master), causing transient backward
    -- steps when audio clock lags video. The pathological drift false-trigger
    -- caused dozens per second — this threshold catches that while tolerating
    -- transient stalls from CPU contention.
    check(diag.backward_jumps <= 2,
        string.format("%s: backward jumps ≤ 2 (got %d)", label, diag.backward_jumps))

    check(diag.skip_count == 0,
        string.format("%s: no emergency skips (got %d)", label, diag.skip_count))

    check(diag.hold_count == 0,
        string.format("%s: no emergency holds (got %d)", label, diag.hold_count))

    check(diag.cadence_p95_ms < 2 * cadence_floor_ms,
        string.format("%s: cadence p95 %.1fms < %.0fms (2x max(frame_period=%.0fms, tick_interval=%.0fms))",
            label, diag.cadence_p95_ms, 2 * cadence_floor_ms,
            frame_period_ms, tick_interval_ms))

    if has_audio_flag then
        check(diag.drift_p95_s < 0.15,
            string.format("%s: drift p95 %.3fs < 0.15s", label, diag.drift_p95_s))
    end

    check(not diag.audio_master_engaged,
        string.format("%s: audio-master not engaged at stop", label))

    print(string.format("    [diag] %s: %d ticks, cadence p50/p95=%.1f/%.1fms, "
        .. "drift p50/p95=%.3f/%.3fs, skips=%d holds=%d backward=%d",
        label, diag.tick_count,
        diag.cadence_p50_ms, diag.cadence_p95_ms,
        diag.drift_p50_s, diag.drift_p95_s,
        diag.skip_count, diag.hold_count, diag.backward_jumps))
end

--------------------------------------------------------------------------------
-- Media path — single 64s ProRes/PCM Anamnesis source backs both V1 video
-- and A1 audio. A/V sync verification doesn't require distinct content; the
-- timing assertions read the same source via different TC origins (video
-- first_frame_tc vs audio first_sample_tc).
--------------------------------------------------------------------------------
local MEDIA_DIR = ienv.resolve_repo_path("tests/fixtures/media/anamnesis-untrimmed")
local MEDIA_PATH = MEDIA_DIR .. "/A007_05202055_C007.mov"

do
    local f = io.open(MEDIA_PATH, "r")
    assert(f, "Missing fixture: " .. MEDIA_PATH)
    f:close()
end

--------------------------------------------------------------------------------
-- Timeline layout: V1 rapid-cut sequence + parallel A1 audio.
-- 4 video clips covering frames 122960..123286 (~326 frames ≈ 13s at 25fps);
-- A1 mirrors V1's layout so each video cut has a matched audio cut at the
-- same sequence frame. A/V drift is measured against playback-pipeline
-- timing across these cuts.
--------------------------------------------------------------------------------
local SEQ_FPS_NUM = 25
local SEQ_FPS_DEN = 1
local WINDOW_HI = 123286

-- Probe file's TC origin via EMP binding.
-- source_in must be absolute TC: first_frame_tc for video, first_sample_tc
-- for audio. The probe MUST populate the field — a nil here means a broken
-- container or stale binding, not "default to 0"; A/V drift assertions
-- would then pass against the wrong origin on both streams.
local function tc_origin(path)
    local probe = EMP.MEDIA_FILE_PROBE(path)
    assert(probe, "MEDIA_FILE_PROBE failed: " .. path)
    return assert(probe.first_frame_tc,
        "MEDIA_FILE_PROBE: first_frame_tc nil for " .. path)
end

local function audio_tc_origin(path)
    local probe = EMP.MEDIA_FILE_PROBE(path)
    assert(probe, "MEDIA_FILE_PROBE failed: " .. path)
    return assert(probe.first_sample_tc,
        "MEDIA_FILE_PROBE: first_sample_tc nil for " .. path)
end

local timeline_dsl = require("synthetic.helpers.timeline_dsl")

local TIMELINE = [[
    V1: [clip-1 122960-123003][clip-2 123003-123043][clip-3 123043-123172][clip-4 123172-123286]
    A1: [clip-1 122960-123003][clip-2 123003-123043][clip-3 123043-123172][clip-4 123172-123286]
]]

local tracks = timeline_dsl.to_tmb(timeline_dsl.parse(TIMELINE), {
    path_for        = function(_t, _c) return MEDIA_PATH end,
    source_in_for   = function(_t, _c, kind)
        if kind == "audio" then return audio_tc_origin(MEDIA_PATH) end
        return tc_origin(MEDIA_PATH)
    end,
    rate_for        = function(_t, kind)
        if kind == "audio" then return 48000, 1 end
        return 25, 1
    end,
    speed_ratio_for = function(_t, _c) return 1.0 end,
    id_prefix_for   = function(t) return t:lower() .. "-" end,
})

local v1_clips = tracks.video[1]
local a1_clips = tracks.audio[1]

--------------------------------------------------------------------------------
-- TMB setup (2 pool threads for async decode)
--------------------------------------------------------------------------------
local tmb = EMP.TMB_CREATE(3)
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
PLAYBACK.SET_BOUNDS(pc, 0, WINDOW_HI, SEQ_FPS_NUM, SEQ_FPS_DEN)
PLAYBACK.SET_SURFACE(pc, surface)

-- Clip provider: clips already loaded via TMB_SET_TRACK_CLIPS above.
-- Provider is a no-op — TMB already has all clips for this test.
PLAYBACK.SET_CLIP_PROVIDER(pc, function(from, to, track_type) end)

-- Capture frame history via position callback
local position_history = {}
PLAYBACK.SET_POSITION_CALLBACK(pc, function(frame, stopped)
    position_history[#position_history + 1] = {
        frame = frame, stopped = stopped, wall_us = wall_us(),
    }
end)

-- Capture clip transitions
local clip_transitions = {}
PLAYBACK.SET_CLIP_TRANSITION_CALLBACK(pc, function(clip_id, rotation, par_num, par_den, is_offline, media_path, frame) -- luacheck: no unused
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
    local baseline_audio_us = has_audio and qt_constants.AOP.AUDIBLE_US(aop) or 0

    -- Clear state for this run
    position_history = {}
    clip_transitions = {}

    -- Start playback.
    -- Warm-up: first ~500ms has cold-buffer underruns (expected — AAC decode from
    -- seek point + SSE fill + AOP buffer). Clear flag after audio pipeline stabilizes.
    PLAYBACK.PLAY(pc, 1, 1.0)
    for _ = 1, 30 do poll_sleep(pc, 0.016) end  -- ~500ms at ~60Hz tick rate
    if has_audio then
        -- Headless --test mode on macOS: CVDisplayLink creation fails (see
        -- WARN at startup) and QAudioSink may open but never get pulled by
        -- the OS audio device. Detect by probing PLAYHEAD_US — if it's
        -- still 0 after 500ms of warmup ticks, audio isn't actually
        -- running and AUDIBLE_US assertions would compare against a
        -- frozen clock. Downgrade has_audio for this run.
        if not ienv.audio_is_live(aop) then
            print("  ⚠ Audio device opened but PLAYHEAD_US stays at 0 — "
                .. "headless audio backend not ticking; downgrading to video-only")
            has_audio = false
        else
            qt_constants.AOP.CLEAR_UNDERRUN(aop)
        end
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
                s.audio_playhead_us = qt_constants.AOP.AUDIBLE_US(aop)
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

    -- (d2) Clip-routing: forward playback across cuts at 123003/123043/
    -- 123172 (START_FRAME=122965, last_frame well past 123043 under any
    -- reasonable rate) must fire transitions tagged with the matching
    -- v1-clip-N ids. Decoder mis-routing (wrong clip's frame served) is
    -- invisible to the rate/monotonic checks but shows up here.
    check(#clip_transitions >= 2,
        string.format("forward playback fired ≥2 clip transitions (got %d)",
            #clip_transitions))
    local v1_id_pattern = "^v1%-clip%-%d+$"
    for i, t in ipairs(clip_transitions) do
        check(t.clip_id and t.clip_id:match(v1_id_pattern),
            string.format("transition[%d] tagged with v1-clip-N (got %s)",
                i, tostring(t.clip_id)))
    end

    -- (e) [Audio] Playhead advanced
    if has_audio then
        local last_audio_us = samples[#samples].audio_playhead_us
        check(last_audio_us > baseline_audio_us,
            string.format("audio playhead advanced: %d → %d us",
                baseline_audio_us, last_audio_us))

        -- (f) [Audio] No underruns
        local had_underrun = qt_constants.AOP.HAD_UNDERRUN(aop)
        check(not had_underrun, "no audio underruns during playback")

        -- (g) [A/V sync] Drift measurement — RELATIVE to first sample.
        --
        -- AUDIBLE_US subtracts the QAudioSink internal buffer, but Qt does
        -- not expose CoreAudio HAL latency, so an irreducible offset between
        -- audio and video remains. What matters for sync is whether that
        -- offset stays STABLE over playback, not its absolute size.
        --
        -- baseline_offset = (audio - video) at first sample post-warmup.
        -- relative_drift = (audio - video) at sample N, minus baseline_offset.
        -- A perfectly synced pipeline keeps relative_drift ≈ 0.
        local baseline_offset
        local max_drift_us = 0
        local max_drift_idx = 0
        local drift_samples = {}
        local per_tick = {}
        for i, s in ipairs(samples) do
            if s.audio_playhead_us and s.audio_playhead_us > 0 then
                local video_time_us = (s.video_frame - START_FRAME) * 1000000.0 / target_fps
                local raw_offset = s.audio_playhead_us - video_time_us
                if not baseline_offset then baseline_offset = raw_offset end
                local drift = math.abs(raw_offset - baseline_offset)
                if drift > max_drift_us then
                    max_drift_us = drift
                    max_drift_idx = i
                end
                drift_samples[#drift_samples + 1] = {
                    wall_us = s.wall_us, drift = drift,
                }
                per_tick[i] = {
                    wall_us = s.wall_us, video_frame = s.video_frame,
                    video_time_us = video_time_us,
                    audio_us = s.audio_playhead_us, drift = drift,
                }
            end
        end
        assert(baseline_offset ~= nil,
            "drift loop: no audio samples — has_audio was true but " ..
            "AUDIBLE_US never returned > 0; check AOP startup path")

        -- Diagnostic dump: window around peak drift to reveal jump structure.
        if max_drift_us > 0 and per_tick[max_drift_idx] then
            local lo = math.max(1, max_drift_idx - 5)
            local hi = math.min(#samples, max_drift_idx + 5)
            local t0 = per_tick[lo] and per_tick[lo].wall_us or 0
            print(string.format("    [drift-dump] peak idx=%d max=%.1fms baseline_offset=%.1fms — window:",
                max_drift_idx, max_drift_us / 1000.0, baseline_offset / 1000.0))
            for i = lo, hi do
                local pt = per_tick[i]
                if pt then
                    local marker = (i == max_drift_idx) and " ◄ peak" or ""
                    print(string.format(
                        "      t+%6.3fs vf=%d vt=%8.1fms au=%8.1fms reldrift=%6.1fms%s",
                        (pt.wall_us - t0) / 1e6, pt.video_frame,
                        pt.video_time_us / 1000.0, pt.audio_us / 1000.0,
                        pt.drift / 1000.0, marker))
                end
            end
        end

        -- Relative-drift peak ceiling. Under manual TICK (no CVDisplayLink),
        -- the integer frame counter quantizes ~88% of wall, so peak relative
        -- drift = slope × window + frame-quantization noise. With slope
        -- limit 25ms/s and ~2s sample window, peak ≈ 50ms accumulated +
        -- ~one frame period quantization. 150ms catches real one-shot
        -- jumps (offline transitions, audio reseek glitches) without
        -- false-flagging the harness. Production with CVDisplayLink hits
        -- ~10-30ms peak.
        local MAX_DRIFT_US = 150000
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
                -- Manual TICK runs the controller at ~22fps wall vs target 25fps,
                -- so the integer frame counter quantizes BEHIND wall time while
                -- audio plays at hardware rate. Result: a steady ~15-20ms/s
                -- harness-induced drift. CVDisplayLink in production hits much
                -- tighter numbers. 25ms/s catches real divergence (decoder lag,
                -- clock drift bugs) without flagging the harness limit.
                check(slope < 25.0,
                    string.format("A/V drift slope: %.2f ms/s (limit 25.0 ms/s)", slope))
                if slope >= 5.0 then
                    print(string.format("    [info] drift slope %.2f ms/s (manual-TICK harness)", slope))
                end
            end
        end
    end

    -- Report clip transitions observed
    print(string.format("    [info] %d clip transitions, %d position callbacks",
        #clip_transitions, #position_history))
    print(string.format("    [info] %d frames in %.1fs = %.1f fps",
        frames_advanced, wall_seconds, measured_fps))

    -- Diag ring quality assertions (the exact symptom this fix addresses)
    assert_diag_quality(pc, "Test 1 forward", has_audio, SEQ_FPS_NUM, SEQ_FPS_DEN,
        wall_seconds * 1000.0)
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
    -- Time the measured window only (exclude warm-up — warm-up cadence is
    -- cold-start noise, not steady-state. assert_diag_quality divides this
    -- by diag.tick_count to derive the observed tick interval).
    -- Tick at ~60Hz (16ms) for ~1s — 60+ samples for stable p95. The earlier
    -- 18×50ms gave only ~19 ticks total (incl warm-up), making p95 the 18th-
    -- largest of 19, which natural sleep jitter blows past in headless mode.
    local measured_wall_start = wall_us()
    for _ = 1, 60 do
        poll_sleep(pc, 0.016)
    end
    local measured_wall_ms = (wall_us() - measured_wall_start) / 1000.0
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

    -- Diag ring quality assertions
    assert_diag_quality(pc, "Test 3 seek+resume", has_audio, SEQ_FPS_NUM, SEQ_FPS_DEN,
        measured_wall_ms)
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
