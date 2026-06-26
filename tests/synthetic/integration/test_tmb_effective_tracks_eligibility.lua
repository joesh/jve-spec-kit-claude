-- Integration test: TMB eligibility is driven by the compositor-pushed
-- effective-video-tracks set, NOT by topology (i.e. "any higher track has
-- a clip → skip lower track decode").
--
-- Regression for 2026-06-24 stutter bug: V1 video froze (1 frame every few
-- seconds) on Anamnesis timeline when a higher track (e.g. V4) carried a
-- muted clip overlapping V1. Pre-fix TMB's is_video_obscured inferred
-- occlusion from raw m_tracks topology and skipped V1's REFILL decode.
-- Post-fix the compositor pushes the effective set via
-- SetEffectiveVideoTracks; track_is_eligible reads from that set only.
--
-- Invariant: with effective=[V1], V1 must decode regardless of clips on
-- excluded tracks above it.

local ienv = require("synthetic.integration.integration_test_env")

print("=== test_tmb_effective_tracks_eligibility.lua ===")

local EMP = ienv.require_emp()
local media_path = ienv.test_media_path(ienv.STANDARD_MEDIA)

local FPS_NUM = 24000
local FPS_DEN = 1001

local passed, failed = 0, 0
local function check(cond, label)
    if cond then
        passed = passed + 1
        print("  PASS: " .. label)
    else
        failed = failed + 1
        print("  FAIL: " .. label)
    end
end

local function make_clip(id, sequence_start, duration)
    return {
        clip_id = id,
        media_path = media_path,
        sequence_start = sequence_start,
        duration = duration,
        source_in = 0,
        rate_num = FPS_NUM,
        rate_den = FPS_DEN,
        speed_ratio = 1.0,
    }
end

-- ═══════════════════════════════════════════════════════════════
-- 1. V1 decodes when an excluded V2 has an overlapping clip
-- ═══════════════════════════════════════════════════════════════
-- This is the exact bug shape: muted upper track has a clip, lower
-- track must still produce frames. Pre-fix is_video_obscured(V1)
-- would return true (because V2 has a clip at the same frame in
-- m_tracks) and REFILL would skip V1. Post-fix V1 is in the
-- effective set → eligible → decodes.
print("\n--- 1: V1 decodes when V2 has overlapping clip but is excluded ---")

local tmb = EMP.TMB_CREATE(3)  -- pool_threads=2 → REFILL path exercised
EMP.TMB_SET_SEQUENCE_RATE(tmb, FPS_NUM, FPS_DEN)
EMP.TMB_SET_SEQUENCE_RESOLUTION(tmb, 640, 360)

-- Both tracks carry a clip at timeline 0..50 (overlap = bug trigger)
EMP.TMB_SET_TRACK_CLIPS(tmb, "video", 1, { make_clip("v1-clip", 0, 50) })
EMP.TMB_SET_TRACK_CLIPS(tmb, "video", 2, { make_clip("v2-clip", 0, 50) })

-- Compositor reports V2 muted → effective set = {1}
EMP.TMB_SET_EFFECTIVE_VIDEO_TRACKS(tmb, { 1 })

-- Drive the playhead so REFILL workers prefetch around frame 10
EMP.TMB_SET_PLAYHEAD(tmb, 10, 1, 1.0)

-- Poll for V1 frame (REFILL is async; allow some time).
-- os.time() (wall-clock, 1s resolution) — os.clock() returns CPU time
-- which can diverge from wall time when REFILL workers monopolise CPU.
local v1_frame
local deadline_sec = 2
local start = os.time()
while os.time() - start < deadline_sec do
    v1_frame = EMP.TMB_GET_VIDEO_FRAME(tmb, 1, 10)
    if v1_frame then break end
end

check(v1_frame ~= nil,
    "V1 frame decoded (effective=[1], V2 has overlapping clip)")

-- V2 must be reported ineligible — REFILL skips it.
-- We probe cache-only to avoid sync decode masking the eligibility gate.
-- Poll for the full deadline: a single nil could mean "not cached yet"
-- (REFILL still spinning up). Ineligibility means V2 stays empty
-- indefinitely, so the strong assertion is "no V2 frame appears even
-- after V1 has been ready for the entire window."
local v2_frame
local v2_start = os.time()
while os.time() - v2_start < deadline_sec do
    v2_frame = EMP.TMB_GET_VIDEO_FRAME(tmb, 2, 10, true)
    if v2_frame then break end
end
check(v2_frame == nil,
    "V2 cache-only stays nil across full poll window (ineligible — REFILL skipped it)")

EMP.TMB_CLOSE(tmb)

-- ═══════════════════════════════════════════════════════════════
-- 2. Default (no effective set pushed) → all tracks eligible
-- ═══════════════════════════════════════════════════════════════
-- Safety: if the compositor never pushes a set (e.g. test harness or
-- early-init path), every track must decode. m_effective_video_tracks_valid
-- defaults false → track_is_eligible returns true for all.
print("\n--- 2: Default-no-push → all tracks decode ---")

local tmb2 = EMP.TMB_CREATE(3)
EMP.TMB_SET_SEQUENCE_RATE(tmb2, FPS_NUM, FPS_DEN)
EMP.TMB_SET_SEQUENCE_RESOLUTION(tmb2, 640, 360)

EMP.TMB_SET_TRACK_CLIPS(tmb2, "video", 1, { make_clip("v1-only", 0, 50) })
EMP.TMB_SET_TRACK_CLIPS(tmb2, "video", 2, { make_clip("v2-only", 0, 50) })

-- NOTE: no TMB_SET_EFFECTIVE_VIDEO_TRACKS call

EMP.TMB_SET_PLAYHEAD(tmb2, 10, 1, 1.0)

local v1f, v2f
local start2 = os.time()
while os.time() - start2 < deadline_sec do
    v1f = v1f or EMP.TMB_GET_VIDEO_FRAME(tmb2, 1, 10)
    v2f = v2f or EMP.TMB_GET_VIDEO_FRAME(tmb2, 2, 10)
    if v1f and v2f then break end
end

check(v1f ~= nil, "V1 decodes when no effective set is pushed")
check(v2f ~= nil, "V2 decodes when no effective set is pushed")

EMP.TMB_CLOSE(tmb2)

-- ═══════════════════════════════════════════════════════════════
-- 3. Effective set update → previously-ineligible track becomes eligible
-- ═══════════════════════════════════════════════════════════════
-- Unmuting V2 (push effective=[1,2]) must make V2 frames decodable.
print("\n--- 3: Pushing updated effective set unblocks decode ---")

local tmb3 = EMP.TMB_CREATE(3)
EMP.TMB_SET_SEQUENCE_RATE(tmb3, FPS_NUM, FPS_DEN)
EMP.TMB_SET_SEQUENCE_RESOLUTION(tmb3, 640, 360)

EMP.TMB_SET_TRACK_CLIPS(tmb3, "video", 1, { make_clip("v1c", 0, 50) })
EMP.TMB_SET_TRACK_CLIPS(tmb3, "video", 2, { make_clip("v2c", 0, 50) })

EMP.TMB_SET_EFFECTIVE_VIDEO_TRACKS(tmb3, { 1 })  -- V2 muted
EMP.TMB_SET_PLAYHEAD(tmb3, 10, 1, 1.0)

-- Now unmute V2. SetEffectiveVideoTracks intentionally does not wake
-- REFILL (mute/solo flips are common; spinning on every flip is wasteful);
-- the playhead nudge triggers a fresh prefetch cycle that re-evaluates V2.
EMP.TMB_SET_EFFECTIVE_VIDEO_TRACKS(tmb3, { 1, 2 })
EMP.TMB_SET_PLAYHEAD(tmb3, 11, 1, 1.0)

local v2_after
local start3 = os.time()
while os.time() - start3 < deadline_sec do
    v2_after = EMP.TMB_GET_VIDEO_FRAME(tmb3, 2, 11)
    if v2_after then break end
end
check(v2_after ~= nil, "V2 decodes after being added to effective set")

EMP.TMB_CLOSE(tmb3)

print(string.format("\n%d passed, %d failed", passed, failed))
assert(failed == 0, string.format("%d check(s) failed", failed))
print("✅ test_tmb_effective_tracks_eligibility.lua passed")
