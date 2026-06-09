-- Integration test: A/V sync with non-zero source_in.
--
-- test_playback_av_sync.lua uses source_in=0 for all clips. This test
-- verifies A/V sync holds when clips have trimmed source positions,
-- which exercises the source_in→seek conversion path under real playback.
--
-- Uses anamnesis media at 25fps with non-zero source_in values.
-- A broken source_in conversion would cause audio to play from the wrong
-- position, producing measurable A/V drift.

local ienv = require("synthetic.integration.integration_test_env")
local ffi = require("ffi")

print("=== test_playback_av_sync_offset.lua ===")

local EMP = ienv.require_emp()
local PLAYBACK = qt_constants.PLAYBACK
assert(PLAYBACK, "PLAYBACK bindings not available")
local CONTROL = qt_constants.CONTROL
assert(CONTROL and CONTROL.PROCESS_EVENTS, "CONTROL.PROCESS_EVENTS not available")

--------------------------------------------------------------------------------
-- Wall clock
--------------------------------------------------------------------------------
ffi.cdef[[
    typedef struct { uint32_t numer; uint32_t denom; } jve_mach_timebase_info2_t;
    uint64_t mach_absolute_time(void);
    int mach_timebase_info(jve_mach_timebase_info2_t *info);
]]

local timebase = ffi.new("jve_mach_timebase_info2_t")
ffi.C.mach_timebase_info(timebase)
local tb_numer = tonumber(timebase.numer)
local tb_denom = tonumber(timebase.denom)

local function wall_us()
    return tonumber(ffi.C.mach_absolute_time()) * tb_numer / tb_denom / 1000.0
end

local function poll_sleep(pc, seconds)
    PLAYBACK.TICK(pc)
    CONTROL.PROCESS_EVENTS()
    local t0 = wall_us()
    while (wall_us() - t0) < seconds * 1e6 do end
end

--------------------------------------------------------------------------------
-- Test tracking
--------------------------------------------------------------------------------
local passed, failed = 0, 0
local function check(condition, label)
    if condition then
        passed = passed + 1
        print("  PASS: " .. label)
    else
        failed = failed + 1
        print("  FAIL: " .. label)
    end
end

--------------------------------------------------------------------------------
-- Media + clips with NON-ZERO source_in
--
-- A single 64s Anamnesis source backs both V1 video and A1 audio; A/V drift
-- assertions read identical content via different TC origins (video
-- first_frame_tc vs audio first_sample_tc) plus a per-clip frame offset.
-- The OFFSETS (10, 15, 5, 20 frames) are the whole point of this test: they
-- exercise the source_in→seek conversion that test_playback_av_sync skips
-- (that test uses source_in=0 everywhere).
--------------------------------------------------------------------------------
local MEDIA_DIR = ienv.resolve_repo_path("tests/fixtures/media/anamnesis-untrimmed")
local MEDIA_PATH = MEDIA_DIR .. "/A007_05202055_C007.mov"

do
    local f = io.open(MEDIA_PATH, "r")
    assert(f, "Missing fixture: " .. MEDIA_PATH)
    f:close()
end

local SEQ_FPS_NUM = 25
local SEQ_FPS_DEN = 1
local TL_START = 1000  -- non-zero timeline start (not 0!)

-- Probe must populate first_frame_tc / first_sample_tc. A nil here is a
-- broken container or stale binding, not "default to 0" — the offset
-- assertions further down would then drift uniformly across clips and
-- look like a sync bug instead of a probe bug.
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

-- Per-clip source_in offset in TIMELINE FRAMES (converted to samples for
-- audio inside resolve_source_in below). Different offsets per clip mean
-- a broken source_in→seek conversion will drift differently for each cut.
local FRAME_OFFSETS = {
    ["clip-1"] = 10,
    ["clip-2"] = 15,
    ["clip-3"] = 5,
    ["clip-4"] = 20,
}

local TIMELINE = string.format([[
    V1: [clip-1 %d-%d][clip-2 %d-%d][clip-3 %d-%d][clip-4 %d-%d]
    A1: [clip-1 %d-%d][clip-2 %d-%d][clip-3 %d-%d][clip-4 %d-%d]
]],
    TL_START,        TL_START + 30,
    TL_START + 30,   TL_START + 55,
    TL_START + 55,   TL_START + 135,
    TL_START + 135,  TL_START + 185,
    TL_START,        TL_START + 30,
    TL_START + 30,   TL_START + 55,
    TL_START + 55,   TL_START + 135,
    TL_START + 135,  TL_START + 185)

local tracks = timeline_dsl.to_tmb(timeline_dsl.parse(TIMELINE), {
    path_for        = function(_t, _c) return MEDIA_PATH end,
    source_in_for   = function(_t, clip_name, kind)
        local frame_offset = FRAME_OFFSETS[clip_name]
        assert(frame_offset, "No frame offset configured for " .. clip_name)
        if kind == "audio" then
            local samples = math.floor(frame_offset * 48000 / SEQ_FPS_NUM + 0.5)
            return audio_tc_origin(MEDIA_PATH) + samples
        end
        return tc_origin(MEDIA_PATH) + frame_offset
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

local WINDOW_HI = TL_START + 185  -- total timeline extent

--------------------------------------------------------------------------------
-- TMB + PlaybackController setup
--------------------------------------------------------------------------------
local tmb = EMP.TMB_CREATE(3)
EMP.TMB_SET_SEQUENCE_RATE(tmb, SEQ_FPS_NUM, SEQ_FPS_DEN)
EMP.TMB_SET_TRACK_CLIPS(tmb, "video", 1, v1_clips)
EMP.TMB_SET_TRACK_CLIPS(tmb, "audio", 1, a1_clips)
EMP.TMB_SET_AUDIO_FORMAT(tmb, 48000, 2)
EMP.TMB_SET_AUDIO_MIX_PARAMS(tmb, {{ track_index = 1, volume = 1.0 }}, 48000, 2)

local WIDGET = qt_constants.WIDGET
assert(WIDGET and WIDGET.CREATE_GPU_VIDEO_SURFACE,
    "CREATE_GPU_VIDEO_SURFACE not available")
local ok_surf, surface = pcall(WIDGET.CREATE_GPU_VIDEO_SURFACE)
if not ok_surf or not surface then
    print("  SKIP: GPU surface creation failed (headless?)")
    print("✅ test_playback_av_sync_offset.lua passed (skipped)")
    return
end

local pc = PLAYBACK.CREATE()
PLAYBACK.SET_TMB(pc, tmb)
PLAYBACK.SET_BOUNDS(pc, 0, WINDOW_HI, SEQ_FPS_NUM, SEQ_FPS_DEN)
PLAYBACK.SET_SURFACE(pc, surface)
PLAYBACK.SET_CLIP_PROVIDER(pc, function() end)

local position_history = {}
PLAYBACK.SET_POSITION_CALLBACK(pc, function(frame, stopped)
    position_history[#position_history + 1] = { frame = frame, stopped = stopped }
end)
PLAYBACK.SET_CLIP_TRANSITION_CALLBACK(pc, function() end)

print("  TMB: 4 clips with source_in={10,15,5,20}, timeline starting at " .. TL_START)

--------------------------------------------------------------------------------
-- Audio setup
--------------------------------------------------------------------------------
local aop, sse = ienv.try_open_audio(48000, 2)
local has_audio = (aop ~= nil)
if has_audio then
    PLAYBACK.ACTIVATE_AUDIO(pc, aop, sse, 48000, 2)
    print("  Audio activated")
else
    print("  No audio device — video-only assertions")
end

--------------------------------------------------------------------------------
-- Test: Forward playback through offset clips (~2.5 seconds)
--------------------------------------------------------------------------------
print("\n--- Forward playback with source_in offsets ---")

local START_FRAME = TL_START
PLAYBACK.SEEK(pc, START_FRAME)
check(PLAYBACK.CURRENT_FRAME(pc) == START_FRAME,
    string.format("parked at frame %d", START_FRAME))

local baseline_surface = EMP.SURFACE_FRAME_COUNT(surface)
local baseline_audio = has_audio and qt_constants.AOP.AUDIBLE_US(aop) or 0

position_history = {}
PLAYBACK.PLAY(pc, 1, 1.0)

-- Warm up (500ms)
for _ = 1, 30 do poll_sleep(pc, 0.016) end
if has_audio then
    -- See note in test_playback_av_sync.lua: headless --test mode may
    -- open the audio device but never tick it (CVDisplayLink absent).
    -- Downgrade rather than asserting against a frozen audio clock.
    if not ienv.audio_is_live(aop) then
        print("  ⚠ Audio device opened but PLAYHEAD_US stays at 0 — "
            .. "headless audio backend not ticking; downgrading to video-only")
        has_audio = false
    else
        qt_constants.AOP.CLEAR_UNDERRUN(aop)
    end
end

-- Collect samples for ~2 seconds
local samples = {}
local target_fps = SEQ_FPS_NUM / SEQ_FPS_DEN
for _ = 1, 120 do
    poll_sleep(pc, 0.016)
    local entry = {
        video_frame = PLAYBACK.CURRENT_FRAME(pc),
        wall_us = wall_us(),
    }
    if has_audio then
        entry.audio_playhead_us = qt_constants.AOP.AUDIBLE_US(aop)
    end
    samples[#samples + 1] = entry
end

-- Capture audio playhead BEFORE stop (stop resets AOP playhead to 0)
local pre_stop_audio = has_audio and qt_constants.AOP.AUDIBLE_US(aop) or 0

PLAYBACK.STOP(pc)

-- Video advanced
local end_frame = PLAYBACK.CURRENT_FRAME(pc)
check(end_frame > START_FRAME + 20,
    string.format("video advanced: %d → %d", START_FRAME, end_frame))

-- Surface delivered frames
local surface_count = EMP.SURFACE_FRAME_COUNT(surface) - baseline_surface
check(surface_count > 20, string.format("surface delivered %d frames", surface_count))

-- Monotonic — START_FRAME (not 0) so a seek-to-0 / seek-rewind regression
-- would surface as a backward jump rather than slipping under a zero floor.
local monotonic = true
local prev_frame = START_FRAME
for _, s in ipairs(samples) do
    if s.video_frame < prev_frame then monotonic = false; break end
    prev_frame = s.video_frame
end
check(monotonic, "video frames monotonically non-decreasing")

-- A/V drift (if audio available)
if has_audio then
    check(pre_stop_audio > baseline_audio,
        string.format("audio advanced: %d → %d us", baseline_audio, pre_stop_audio))

    local had_underrun = qt_constants.AOP.HAD_UNDERRUN(aop)
    check(not had_underrun, "no audio underruns during playback")

    -- Measure drift RELATIVE to first sample.
    -- AUDIBLE_US subtracts the QAudioSink internal buffer, but Qt does not
    -- expose CoreAudio HAL latency. The irreducible offset doesn't matter
    -- for sync — only divergence from baseline does.
    local baseline_offset
    local max_drift_us = 0
    for _, s in ipairs(samples) do
        if s.audio_playhead_us and s.audio_playhead_us > 0 then
            local video_time_us = (s.video_frame - START_FRAME) * 1000000.0 / target_fps
            local raw_offset = s.audio_playhead_us - video_time_us
            if not baseline_offset then baseline_offset = raw_offset end
            local drift = math.abs(raw_offset - baseline_offset)
            if drift > max_drift_us then max_drift_us = drift end
        end
    end
    assert(baseline_offset ~= nil,
        "drift loop: no audio samples — has_audio was true but " ..
        "AUDIBLE_US never returned > 0; check AOP startup path")

    -- 150ms peak ceiling: under manual TICK (no CVDisplayLink) the integer
    -- frame counter quantizes behind wall, so peak relative drift is
    -- slope×window + frame-quantization noise (~150ms total). Catches real
    -- one-shot jumps from misapplied source_in offsets without false-
    -- flagging the harness. Production hits ~10-30ms.
    check(max_drift_us < 150000,
        string.format("A/V drift max %.1fms (limit 150ms) with source_in offsets",
            max_drift_us / 1000.0))

    -- Diag summary
    local diag = PLAYBACK.GET_DIAG_SUMMARY(pc)
    if diag then
        check(diag.backward_jumps <= 2,
            string.format("backward jumps ≤ 2 (got %d)", diag.backward_jumps))
        if diag.drift_p95_s then
            check(diag.drift_p95_s < 0.15,
                string.format("drift p95 %.3fs < 0.15s", diag.drift_p95_s))
        end
    end
end

-- Cleanup
PLAYBACK.CLOSE(pc)
EMP.TMB_CLOSE(tmb)

print(string.format("\n%d passed, %d failed", passed, failed))
assert(failed == 0, string.format("%d check(s) failed", failed))
print("✅ test_playback_av_sync_offset.lua passed")
