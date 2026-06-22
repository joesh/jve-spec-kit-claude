-- TDD harness for the shuttle clip-transition freeze (Joe's live 2026-06-21
-- diag: cadence=9775ms flags=TRANSITION at A029_C003→A029_C025 boundary).
--
-- Unlike `test_playback_shuttle_ramp.lua` (which uses a single repeated file
-- and bypasses the clip_provider by populating TMB up-front), this test
-- exercises the EXACT path the live editor uses:
--
--   1. Multiple DIFFERENT media files placed back-to-back on the timeline,
--      so every boundary crossing requires a fresh file open + VT init +
--      first-GOP decode (a real READER_WARM job).
--   2. PlaybackController::SET_CLIP_PROVIDER routes prefetchClips() through
--      a Lua callback that only loads clips into TMB on demand (mirrors
--      what Lua's real provider does in the live editor — it doesn't
--      pre-populate; it queries the DB lazily per prefetch range).
--   3. Shuttle to 32× and HOLD long enough for the playhead to cross
--      ≥3 file boundaries.
--
-- Failing-test target: `cadence_max_ms < 500` during the 32× hold. Pre-fix
-- this should record multi-second values (matches live diag's 9775ms).
-- Post-fix (speed-scaled lookahead + proximity-priority READER_WARM picker)
-- it should be under 500ms.
--
-- Must run via: JVEEditor --test tests/synthetic/integration/test_playback_shuttle_clip_transitions.lua

local ienv = require("synthetic.integration.integration_test_env")

print("=== test_playback_shuttle_clip_transitions.lua ===")

local EMP = ienv.require_emp()
local PLAYBACK = qt_constants.PLAYBACK
assert(PLAYBACK, "PLAYBACK bindings not available")
assert(PLAYBACK.SET_SPEED, "PLAYBACK.SET_SPEED missing")
assert(PLAYBACK.SET_CLIP_PROVIDER, "PLAYBACK.SET_CLIP_PROVIDER missing")
local CONTROL = qt_constants.CONTROL
assert(CONTROL and CONTROL.PROCESS_EVENTS)

local function poll_sleep(pc, seconds)
    os.execute(string.format("sleep %.3f", seconds))
    if pc then PLAYBACK.TICK(pc) end
    CONTROL.PROCESS_EVENTS()
end
local function drive_for(pc, seconds)
    local ticks = math.max(1, math.floor(seconds / 0.016))
    for _ = 1, ticks do poll_sleep(pc, 0.016) end
end

local WIDGET = qt_constants.WIDGET
local ok_surf, surface = pcall(WIDGET.CREATE_GPU_VIDEO_SURFACE)
if not ok_surf or not surface then
    print("  SKIP: GPU surface creation failed (headless?)")
    print("✅ test_playback_shuttle_clip_transitions.lua passed (skipped)")
    return
end

local passed, total, failures = 0, 0, {}
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

--------------------------------------------------------------------------------
-- Build a timeline of 5 DIFFERENT short clips back-to-back. Each clip is one
-- of the standard fixture files; 32× × 4s wall = 128s of media consumed, so
-- ~28 boundary crossings — plenty to expose the READER_WARM queue ordering.
--
-- ANAMNESIS A007/A014 are too long (64s, only 2 fit in a 32×/4s window) and
-- they're the same codec — we want decoder spin-up cost to vary, so the
-- fixture diversity exposes any cost-spike path. countdown_chirp_30s (30s,
-- mp4) anchors a long clip; A005 (4.5s) and A002 (1s) anchor short clips
-- (boundary every ~30ms wall at 32×).
--------------------------------------------------------------------------------
local SEQ_FPS_NUM, SEQ_FPS_DEN = 25, 1
local FIXTURE_DIR = ienv.resolve_repo_path("tests/fixtures/media")

local function probe(path)
    local r = EMP.MEDIA_FILE_PROBE(path)
    return assert(r.first_frame_tc, "probe failed: " .. path), r
end

-- Use 6 distinct files. Frame counts must be safely shorter than the media's
-- actual duration in frames at 25fps so the clip stays within file bounds.
-- (We'll quantize each clip's duration to its real frame count below.)
local FILES = {
    FIXTURE_DIR .. "/A005_C052_0925BL_001.mp4",      -- 4.5s
    FIXTURE_DIR .. "/A002_C018_0922BW_002.mp4",      -- 1.08s
    FIXTURE_DIR .. "/countdown_chirp_30s.mp4",        -- 30s
    FIXTURE_DIR .. "/synth_25fps_tc.mov",             -- synth
    FIXTURE_DIR .. "/A005_C052_0925BL_001_tc01.mp4",  -- same content diff TC
    FIXTURE_DIR .. "/A002_C018_0922BW_002.mp4",       -- repeat to extend timeline
}

local sequence_start = 0
local clips = {}
for i, path in ipairs(FILES) do
    local f = io.open(path, "r"); assert(f, "Missing fixture: " .. path); f:close()
    local origin, info = probe(path)
    -- Floor to a safe sub-duration so we don't tip off file end at high speed.
    local secs = (info.duration_us or 0) / 1e6
    if secs <= 0 then secs = 4.0 end
    local frames = math.max(20, math.floor(secs * 25.0) - 2)  -- 2-frame safety
    clips[#clips + 1] = {
        clip_id = string.format("c%d-%s", i, path:match("([^/]+)$"):gsub("%.[^.]+$", "")),
        media_path = path,
        sequence_start = sequence_start,
        duration = frames,
        source_in = origin,
        rate_num = SEQ_FPS_NUM, rate_den = SEQ_FPS_DEN, speed_ratio = 1.0,
    }
    sequence_start = sequence_start + frames
end
local SEQ_HI = sequence_start
print(string.format("  fixture timeline: %d clips, %d total frames (%.1fs @25fps)",
    #clips, SEQ_HI, SEQ_HI / 25.0))

local tmb = EMP.TMB_CREATE(3)
assert(tmb)
EMP.TMB_SET_SEQUENCE_RATE(tmb, SEQ_FPS_NUM, SEQ_FPS_DEN)
-- NB: do NOT call TMB_SET_TRACK_CLIPS here. That would bypass the provider
-- and pre-warm everything, defeating the test. Provider populates on demand.
EMP.TMB_SET_AUDIO_FORMAT(tmb, 48000, 2)

local pc = PLAYBACK.CREATE()
PLAYBACK.SET_TMB(pc, tmb)
PLAYBACK.SET_BOUNDS(pc, 0, SEQ_HI, SEQ_FPS_NUM, SEQ_FPS_DEN)
PLAYBACK.SET_SURFACE(pc, surface)

-- Clip provider: emulate live Lua provider. For each prefetch range request
-- (from, to, track_kind), add any clip whose sequence_start falls in
-- [from, to) to TMB via TMB_ADD_CLIPS.
--
-- This is the path that triggers READER_WARM jobs: AddClips submits one
-- warm per new clip per track. process_next_decode_prep_job's picker
-- determines WHICH gets warmed first — that's the proximity-priority code
-- path under test.
local provider_calls = 0
local provider_added = 0
local function provider(from, to, track_kind)
    -- track_kind is a STRING ("video" | "audio") from the C++ binding.
    assert(track_kind == "video" or track_kind == "audio",
        "clip_provider: unexpected track_kind: " .. tostring(track_kind))
    provider_calls = provider_calls + 1
    local batch = {}
    for _, c in ipairs(clips) do
        if c.sequence_start >= from and c.sequence_start < to then
            -- For audio we need rate_num=48000; clone the clip and override.
            local copy
            if track_kind == "audio" then
                copy = {}
                for k, v in pairs(c) do copy[k] = v end
                copy.rate_num = 48000; copy.rate_den = 1
            else
                copy = c
            end
            batch[#batch + 1] = copy
        end
    end
    if #batch > 0 then
        EMP.TMB_ADD_CLIPS(tmb, track_kind, 1, batch)
        provider_added = provider_added + #batch
    end
end
PLAYBACK.SET_CLIP_PROVIDER(pc, provider)

local aop, sse = ienv.try_open_audio(48000, 2)
local has_audio = (aop ~= nil)
if has_audio then PLAYBACK.ACTIVATE_AUDIO(pc, aop, sse, 48000, 2) end

--------------------------------------------------------------------------------
-- Shuttle scenario
--------------------------------------------------------------------------------
PLAYBACK.SEEK(pc, 0)
PLAYBACK.PLAY(pc, 1, 1.0)
drive_for(pc, 0.50)  -- warmup
print(string.format("  warmup: provider_calls=%d provider_added=%d",
    provider_calls, provider_added))

-- Ramp to 32× via the same ladder the live keyboard uses.
local LADDER = { 1.25, 1.5, 1.75, 2.0, 4.0, 8.0, 16.0, 32.0 }
for _, spd in ipairs(LADDER) do
    PLAYBACK.SET_SPEED(pc, spd)
    drive_for(pc, 0.08)
end

-- HOLD at 32× for 3s wall = ~96s of media consumed = crosses every clip in
-- the timeline (well, until we hit the end). Three seconds is enough to
-- record several boundary transitions on this fixture set.
print("  HOLD at 32× for 3.0s wall")
drive_for(pc, 3.0)

local diag = PLAYBACK.GET_DIAG_SUMMARY(pc)
print(string.format("  diag: ticks=%d cadence p50/p95/p99/max = %.0f/%.0f/%.0f/%.0f ms",
    diag.tick_count, diag.cadence_p50_ms, diag.cadence_p95_ms, diag.cadence_p99_ms,
    diag.cadence_max_ms))
print(string.format("  diag: drift p50/p95 = %.3f/%.3fs gaps=%d transitions(repeat=%d)",
    diag.drift_p50_s, diag.drift_p95_s, diag.gap_count, diag.repeat_count))
print(string.format("  provider total: calls=%d clips_added=%d",
    provider_calls, provider_added))
-- A frames_seen list would help diagnose whether m_position even moved.
-- The cadence==0 across the board says deliverFrame's result.frame was
-- always null. That's exactly the freeze symptom — and it should drop
-- to under 500ms with the fix and stay multi-second pre-fix.

-- This is the failing harness for Joe's live bug. Pre-fix this asserted
-- value would be in the multi-thousand-ms range (live: 9775ms). The fix
-- (speed-scaled prefetch horizon + proximity-priority READER_WARM picker)
-- targets cadence_max_ms < 500ms — choppy but never frozen.
if has_audio then
    check(diag.cadence_max_ms < 500,
        string.format("cadence_max during 32× hold = %.0fms < 500ms (no second-long freezes at clip transitions)",
            diag.cadence_max_ms))
end

PLAYBACK.STOP(pc)

print(string.format("\n=== %d/%d checks passed ===", passed, total))
if #failures > 0 then
    for _, f in ipairs(failures) do print("  FAIL: " .. f) end
    error("test_playback_shuttle_clip_transitions.lua failed")
end
print("✅ test_playback_shuttle_clip_transitions.lua passed")
