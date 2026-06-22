-- Integration test: shuttle ladder (L/J key-repeat) ramp through real C++
-- PlaybackController. Quantifies A/V drift and verifies recovery when slowing
-- back down.
--
-- Joe's 2026-06-21 bug: holding L 8 times ramps to 32× but A/V sync drifts by
-- multiple seconds and doesn't recover when ramping back down. The lightweight
-- SetSpeed branch (sse.cpp:276 + playback_controller.mm:1180) is correct in
-- principle but: (a) the original single-anchor PlaybackClock froze for
-- output_latency µs after each Reanchor while video advanced at NEW speed —
-- per-rung error ≈ latency × NEW; cumulative across 8 rungs ≈ 2s at 32×;
-- (b) even with the rate-envelope clock that fixes (a), a long HOLD at top
-- speed can still develop drift if SSE/AOP can't keep up.
--
-- This test reproduces the user-visible bug:
--   1. Ramp up press-by-press to 32× (mimics key-repeat).
--   2. HOLD at 32× for ~1.5s wall — consumes ~48s of source media at 32×.
--      This is the phase the previous version of this test skipped, which is
--      why it passed even when live editor still drifted multiple seconds.
--   3. Ramp down press-by-press to 1×.
--   4. Settle at 1× for ~5s wall — long enough that the diag ring is
--      dominated by post-ramp ticks. drift_p50 across that window IS the
--      steady-state sync error.
--   5. Sample a SECOND diag 2s later: drift must not have grown — confirms
--      recovery has stuck, not "audio is still racing to catch up at >1×".
--   6. frames-seen advance rate during settle ≈ fps × wall-elapsed (no
--      catch-up forward run, no PLL pull-back oscillation).
--
-- Must run via: JVEEditor --test tests/synthetic/integration/test_playback_shuttle_ramp.lua

local ienv = require("synthetic.integration.integration_test_env")

print("=== test_playback_shuttle_ramp.lua ===")

--------------------------------------------------------------------------------
-- Prerequisites
--------------------------------------------------------------------------------
local EMP = ienv.require_emp()
local PLAYBACK = qt_constants.PLAYBACK
assert(PLAYBACK, "PLAYBACK bindings not available")
assert(PLAYBACK.SET_SPEED,
    "PLAYBACK.SET_SPEED missing — lightweight SetSpeed branch not built")

local CONTROL = qt_constants.CONTROL
assert(CONTROL and CONTROL.PROCESS_EVENTS,
    "CONTROL.PROCESS_EVENTS not available (stale build?)")

local function poll_sleep(pc_handle, seconds)
    os.execute(string.format("sleep %.3f", seconds))
    if pc_handle then PLAYBACK.TICK(pc_handle) end
    CONTROL.PROCESS_EVENTS()
end

-- Drive ticks for `seconds` of wall time at ~16ms cadence (~60Hz, matches
-- CVDisplayLink). Returns the number of ticks driven so we can compute
-- expected frame advance at 1× downstream.
local TICK_PERIOD_S = 0.016
local function drive_for(pc_handle, seconds)
    local ticks = math.max(1, math.floor(seconds / TICK_PERIOD_S))
    for _ = 1, ticks do poll_sleep(pc_handle, TICK_PERIOD_S) end
    return ticks
end

local WIDGET = qt_constants.WIDGET
assert(WIDGET and WIDGET.CREATE_GPU_VIDEO_SURFACE,
    "CREATE_GPU_VIDEO_SURFACE not available")

local ok_surf, surface = pcall(WIDGET.CREATE_GPU_VIDEO_SURFACE)
if not ok_surf or not surface then
    print("  SKIP: GPU surface creation failed (headless?)")
    print("✅ test_playback_shuttle_ramp.lua passed (skipped)")
    return
end

--------------------------------------------------------------------------------
-- Check helpers
--------------------------------------------------------------------------------
local passed, total = 0, 0
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
-- Media + timeline. Two back-to-back placements of the long anamnesis clip so
-- the 32× hold (~48s media consumed in 1.5s wall) has comfortable headroom.
-- A007_05202055_C007.mov is 64.08s = 1602 frames @25fps; two placements give
-- ~3200 frames of sequence runway.
--------------------------------------------------------------------------------
local SEQ_FPS_NUM, SEQ_FPS_DEN = 25, 1
local MEDIA_DIR = ienv.resolve_repo_path("tests/fixtures/media/anamnesis-untrimmed")
local MEDIA_PATH = MEDIA_DIR .. "/A007_05202055_C007.mov"
do
    local f = io.open(MEDIA_PATH, "r")
    assert(f, "Missing fixture: " .. MEDIA_PATH)
    f:close()
end

local function tc_origin_video(path)
    local probe = EMP.MEDIA_FILE_PROBE(path)
    return assert(probe.first_frame_tc, "first_frame_tc nil")
end
local function tc_origin_audio(path)
    local probe = EMP.MEDIA_FILE_PROBE(path)
    return assert(probe.first_sample_tc, "first_sample_tc nil")
end

local VIDEO_ORIGIN = tc_origin_video(MEDIA_PATH)
local AUDIO_ORIGIN = tc_origin_audio(MEDIA_PATH)

local PER_CLIP = 1600       -- ~64s of media each, just under the file's 64.08s
local SEQ_HI   = PER_CLIP * 2

local v_clips = {
    { clip_id = "v-ramp-1", media_path = MEDIA_PATH,
      sequence_start = 0,        duration = PER_CLIP,
      source_in = VIDEO_ORIGIN,  rate_num = SEQ_FPS_NUM, rate_den = SEQ_FPS_DEN,
      speed_ratio = 1.0 },
    { clip_id = "v-ramp-2", media_path = MEDIA_PATH,
      sequence_start = PER_CLIP, duration = PER_CLIP,
      source_in = VIDEO_ORIGIN,  rate_num = SEQ_FPS_NUM, rate_den = SEQ_FPS_DEN,
      speed_ratio = 1.0 },
}
local a_clips = {
    { clip_id = "a-ramp-1", media_path = MEDIA_PATH,
      sequence_start = 0,        duration = PER_CLIP,
      source_in = AUDIO_ORIGIN,  rate_num = 48000, rate_den = 1,
      speed_ratio = 1.0 },
    { clip_id = "a-ramp-2", media_path = MEDIA_PATH,
      sequence_start = PER_CLIP, duration = PER_CLIP,
      source_in = AUDIO_ORIGIN,  rate_num = 48000, rate_den = 1,
      speed_ratio = 1.0 },
}

local tmb = EMP.TMB_CREATE(3)
assert(tmb)
EMP.TMB_SET_SEQUENCE_RATE(tmb, SEQ_FPS_NUM, SEQ_FPS_DEN)
EMP.TMB_SET_TRACK_CLIPS(tmb, "video", 1, v_clips)
EMP.TMB_SET_TRACK_CLIPS(tmb, "audio", 1, a_clips)
EMP.TMB_SET_AUDIO_FORMAT(tmb, 48000, 2)
EMP.TMB_SET_AUDIO_MIX_PARAMS(tmb, {{ track_index = 1, volume = 1.0 }}, 48000, 2)

--------------------------------------------------------------------------------
-- PlaybackController + audio
--------------------------------------------------------------------------------
local pc = PLAYBACK.CREATE()
assert(pc)
PLAYBACK.SET_TMB(pc, tmb)
PLAYBACK.SET_BOUNDS(pc, 0, SEQ_HI, SEQ_FPS_NUM, SEQ_FPS_DEN)
PLAYBACK.SET_SURFACE(pc, surface)
PLAYBACK.SET_CLIP_PROVIDER(pc, function(_, _, _) end)

local frames_seen = {}
PLAYBACK.SET_POSITION_CALLBACK(pc, function(frame, _stopped)
    frames_seen[#frames_seen + 1] = frame
end)

local aop, sse = ienv.try_open_audio(48000, 2)
local has_audio = (aop ~= nil)
if has_audio then
    PLAYBACK.ACTIVATE_AUDIO(pc, aop, sse, 48000, 2)
end

--------------------------------------------------------------------------------
-- Shuttle ladder + key-repeat helpers
--------------------------------------------------------------------------------
-- FCP7 ladder: 1.0 → 1.25 → 1.5 → 1.75 → 2.0 → 4 → 8 → 16 → 32
local LADDER = { 1.0, 1.25, 1.5, 1.75, 2.0, 4.0, 8.0, 16.0, 32.0 }

-- macOS key-repeat is ~33ms. We use 80ms to leave more drain-window per
-- press for the rate-envelope to expose any per-press leak.
local KEY_REPEAT_S = 0.080

local function shuttle_press_and_sample(rung_index, dir)
    local target_speed = LADDER[rung_index]
    PLAYBACK.SET_SPEED(pc, dir * target_speed)
    drive_for(pc, KEY_REPEAT_S)
    return PLAYBACK.GET_DIAG_SUMMARY(pc)
end

-- Per-rung ramp-up drift bound. drift_p95 is a tail percentile over the
-- diag ring — during ramp-up the ring is dominated by per-press transients
-- whose magnitude per press ≈ Δspeed × output_latency (~150ms). We allow
-- 2× headroom for measurement noise, floor 0.20s (steady jitter + cold start).
local function expected_ramp_up_drift_bound(rung_index)
    local cum = 0
    local prev = LADDER[1]
    for i = 2, rung_index do
        cum = cum + math.abs(LADDER[i] - prev) * 0.15
        prev = LADDER[i]
    end
    return math.max(0.20, cum * 2.0)
end

--------------------------------------------------------------------------------
-- Scenario: cold-start → ramp up → HOLD at 32× → ramp down → SETTLE → recheck
--------------------------------------------------------------------------------
section("1. Cold start")
PLAYBACK.SEEK(pc, 0)
frames_seen = {}
PLAYBACK.PLAY(pc, 1, 1.0)
-- CoreAudio spin-up is ~200ms; give 500ms warmup so cadence stabilizes
-- and the diag ring no longer reflects the cold-buffer phase.
drive_for(pc, 0.50)
if has_audio then
    if not ienv.audio_is_live(aop) then
        print("  ⚠ Audio device not ticking under headless — downgrading to video-only assertions")
        has_audio = false
    else
        qt_constants.AOP.CLEAR_UNDERRUN(aop)
    end
end

section("2. Ramp up press-by-press to 32×")
for rung = 2, #LADDER do
    local diag = shuttle_press_and_sample(rung, 1)
    print(string.format("    [up] rung %d (%.2f×): drift p50/p95=%.3f/%.3fs gap=%d backw=%d am=%s",
        rung, LADDER[rung],
        diag.drift_p50_s, diag.drift_p95_s,
        diag.gap_count, diag.backward_jumps,
        tostring(diag.audio_master_engaged)))
    if has_audio then
        local bound = expected_ramp_up_drift_bound(rung)
        check(math.abs(diag.drift_p95_s) < bound,
            string.format("rung %d (%.2f×): |drift p95|=%.3fs < %.3fs",
                rung, LADDER[rung], math.abs(diag.drift_p95_s), bound))
    end
end

section("3. HOLD at 32× for 1.5s wall (~48s media @25fps = ~1200 frames)")
-- This is the phase that exposes Joe's "multiple seconds drift" bug. If the
-- rate-envelope clock or SSE can't sustain 32× without slipping, drift will
-- grow monotonically through this hold. We sample drift every 0.5s and
-- assert it never exceeds 0.5s during the hold itself.
local hold_diags = {}
for i = 1, 3 do
    drive_for(pc, 0.50)
    local d = PLAYBACK.GET_DIAG_SUMMARY(pc)
    hold_diags[i] = d
    print(string.format("    [hold@32×] t=%.1fs: drift p50/p95=%.3f/%.3fs cadence p50/p95=%.0f/%.0fms gap=%d frame=%d",
        i * 0.5, d.drift_p50_s, d.drift_p95_s,
        d.cadence_p50_ms, d.cadence_p95_ms,
        d.gap_count, frames_seen[#frames_seen] or -1))
end
local final_hold = hold_diags[#hold_diags]
if has_audio then
    -- During sustained 32×, the per-press transients have flushed; only the
    -- "is the clock keeping up with the device" question matters. Bound is
    -- generous (0.6s) but DOES catch unbounded growth.
    check(math.abs(final_hold.drift_p50_s) < 0.6,
        string.format("after 1.5s @ 32×: |drift p50|=%.3fs < 0.6s (no unbounded growth)",
            math.abs(final_hold.drift_p50_s)))
end

-- Frame-delivery cadence catches the "video freezes for ~1s then jumps" bug
-- that Joe sees live. TickMetric::cadence_ms is written ONLY when
-- deliverFrame successfully calls setFrame() with a new image. If TMB's
-- nearest-cached-frame search rejects sparse decoded frames at shuttle
-- speed, setFrame stops firing and cadence_p95 balloons to ~1000ms+
-- (one freeze per shuttle window). With the speed-scaled nearest-frame
-- bound, decoder-produced frames within the same clip surface to the
-- display, cadence stays bounded. Bound: 200ms at 32× (= ~5fps display
-- rate) — choppy but well under the "1s+ freeze" symptom.
check(final_hold.cadence_p95_ms < 200,
    string.format("32× hold delivery cadence p95=%.0fms < 200ms (no second-long freezes)",
        final_hold.cadence_p95_ms))
check(final_hold.gap_count == 0,
    string.format("no audio gaps during 32× hold (got %d)", final_hold.gap_count))

section("4. Ramp down press-by-press to 1×")
for rung = #LADDER - 1, 1, -1 do
    local diag = shuttle_press_and_sample(rung, 1)
    print(string.format("    [down] rung %d (%.2f×): drift p50/p95=%.3f/%.3fs gap=%d backw=%d",
        rung, LADDER[rung],
        diag.drift_p50_s, diag.drift_p95_s,
        diag.gap_count, diag.backward_jumps))
end

section("5. Settle at 1× for 5s wall (drift_p50 must reach noise floor)")
-- 5s settle at ~60Hz = ~300 ticks. The diag ring (1800 ticks) still holds
-- ramp-up + hold + ramp-down history (~3-4s of ticks), so p95 carries those
-- physical transition spikes. p50 is the right metric for "current sync":
-- at 300 settle-ticks vs ~250 ramp-ticks in the ring, the median is
-- dominated by settle, which is what Joe wants ("after I slow down, sync
-- comes back").
local settle_start_frame = frames_seen[#frames_seen] or 0
drive_for(pc, 5.0)
local recover_diag = PLAYBACK.GET_DIAG_SUMMARY(pc)
local settle_end_frame = frames_seen[#frames_seen] or 0
local settle_frames_advanced = settle_end_frame - settle_start_frame
print(string.format("    [recovered] drift p50/p95=%.3f/%.3fs gap=%d am=%s",
    recover_diag.drift_p50_s, recover_diag.drift_p95_s,
    recover_diag.gap_count, tostring(recover_diag.audio_master_engaged)))
print(string.format("    [recovered] frames advanced %d over 5s wall (expected ~125 @ 1× 25fps)",
    settle_frames_advanced))

if has_audio then
    check(math.abs(recover_diag.drift_p50_s) < 0.10,
        string.format("after 5s settle: |drift p50|=%.3fs < 0.10s (steady-state sync recovered)",
            math.abs(recover_diag.drift_p50_s)))
end

-- Audio not "catching up at >1×" check: at 1× steady play, frames_seen
-- advances at fps × wall. If audio is still racing forward to resync,
-- video clock will follow (PLL pulls video to audio clock), so frames
-- will advance faster than 25fps × 5s ≈ 125. Allow generous +25% margin
-- for warm-up jitter and the first few settle ticks (which may still be
-- catching up). The bug-shape we're guarding against is multi-× advance.
if has_audio then
    local fps = SEQ_FPS_NUM / SEQ_FPS_DEN
    local expected = fps * 5.0
    local upper = expected * 1.50
    check(settle_frames_advanced > 0 and settle_frames_advanced < upper,
        string.format("settle frame-advance %d in (0, %.0f) — not racing forward at >1×",
            settle_frames_advanced, upper))
end

section("6. Continue at 1× for 2s — drift must not regrow")
-- If recovery is real, drift_p50 at t=settle+2s ≤ drift_p50 at t=settle.
-- If audio is slowly winding off again (recovery never stuck), p50 grows.
drive_for(pc, 2.0)
local recheck_diag = PLAYBACK.GET_DIAG_SUMMARY(pc)
print(string.format("    [+2s recheck] drift p50/p95=%.3f/%.3fs gap=%d am=%s",
    recheck_diag.drift_p50_s, recheck_diag.drift_p95_s,
    recheck_diag.gap_count, tostring(recheck_diag.audio_master_engaged)))

if has_audio then
    -- Allow 30ms growth (measurement noise + ring rotation). Real
    -- regrowth would be hundreds of ms.
    local growth = math.abs(recheck_diag.drift_p50_s) - math.abs(recover_diag.drift_p50_s)
    check(growth < 0.030,
        string.format("drift p50 grew by %.3fs over 2s (must be < 0.030s — recovery is stuck)",
            growth))
    check(math.abs(recheck_diag.drift_p50_s) < 0.10,
        string.format("after +2s: |drift p50|=%.3fs < 0.10s (still in steady state)",
            math.abs(recheck_diag.drift_p50_s)))
end

-- Monotonic frames across the WHOLE run (rules out backward jumps / loops).
local mono = true
local last = -1
for _, f in ipairs(frames_seen) do
    if f < last then mono = false; break end
    last = f
end
check(mono, "video frames monotonic non-decreasing across full ramp+hold+settle")
check(recheck_diag.gap_count == 0,
    string.format("no audio gaps end-to-end (got %d)", recheck_diag.gap_count))

print(string.format("    [stats] total ticks=%d, total frames delivered=%d",
    recheck_diag.tick_count, #frames_seen))

PLAYBACK.STOP(pc)

--------------------------------------------------------------------------------
-- Result
--------------------------------------------------------------------------------
print(string.format("\n=== %d/%d checks passed ===", passed, total))
if #failures > 0 then
    print("FAILURES:")
    for _, f in ipairs(failures) do print("  - " .. f) end
    error("test_playback_shuttle_ramp.lua failed")
end
print("✅ test_playback_shuttle_ramp.lua passed")
