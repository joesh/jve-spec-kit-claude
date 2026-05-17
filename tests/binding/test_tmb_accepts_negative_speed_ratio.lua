-- Test: TMB_ADD_CLIPS / TMB_SET_TRACK_CLIPS accept negative speed_ratio.
--
-- Requires --test mode (real C++ bindings).
--
-- Regression for: playback_engine errors observed in TSO 2026-04-16 at
--   20:45:10–11:
--     "TMB_ADD_CLIPS: element 1 speed_ratio must be > 0"
-- fired 4× when a reverse clip (source_in > source_out) was provided to
-- the playback engine.
--
-- Design: commit 40b663c ("feat: reverse clip playback (negative
-- speed_ratio)") made speed_ratio signed across the playback pipeline
-- (direction encoded in sign; magnitude is the conform ratio). The
-- commit message states: "Asserts relaxed from speed>0 to speed!=0."
-- The C++ internals (decode_into_cache, GetTrackAudio, etc.) were
-- updated, but the two Lua-facing binding gates at emp_bindings.cpp
-- (TMB_SET_TRACK_CLIPS and TMB_ADD_CLIPS) were missed — they still
-- rejected speed_ratio <= 0.
--
-- This test exercises the real bindings with a reverse-clip payload and
-- asserts that both entry points accept it without error.

local EMP = qt_constants and qt_constants.EMP
assert(EMP, "EMP bindings not available — run via: ./build/bin/JVEEditor --test this_script.lua")

print("=== test_tmb_accepts_negative_speed_ratio.lua ===")

local tmb = EMP.TMB_CREATE(0)  -- sync pool, no worker threads
assert(tmb, "TMB_CREATE failed")

EMP.TMB_SET_SEQUENCE_RATE(tmb, 25, 1)
EMP.TMB_SET_AUDIO_FORMAT(tmb, 48000, 2)

-- A reverse clip: source_in (200) > source_out (100), speed_ratio = -1.0
-- (100 frames played backwards over 100 timeline frames = 1x reverse).
local reverse_clip = {
    clip_id        = "reverse-clip-001",
    media_path     = "/nonexistent/fixture.mov",  -- offline ok for this test
    sequence_start = 0,
    duration       = 100,
    source_in      = 200,
    rate_num       = 25,
    rate_den       = 1,
    speed_ratio    = -1.0,
    offline        = true,
    volume         = 1.0,
}

-- ─── Test 1: TMB_ADD_CLIPS accepts negative speed_ratio ───
print("\n--- TMB_ADD_CLIPS accepts negative speed_ratio ---")

local ok, err = pcall(EMP.TMB_ADD_CLIPS, tmb, "video", 1, { reverse_clip })
assert(ok, string.format(
    "TMB_ADD_CLIPS must accept signed speed_ratio (reverse clip); got error: %s",
    tostring(err)))
print("  ✓ TMB_ADD_CLIPS accepted reverse clip (speed_ratio=-1.0)")

-- ─── Test 2: TMB_SET_TRACK_CLIPS accepts negative speed_ratio ───
print("\n--- TMB_SET_TRACK_CLIPS accepts negative speed_ratio ---")

ok, err = pcall(EMP.TMB_SET_TRACK_CLIPS, tmb, "audio", 1, { reverse_clip })
assert(ok, string.format(
    "TMB_SET_TRACK_CLIPS must accept signed speed_ratio (reverse clip); got error: %s",
    tostring(err)))
print("  ✓ TMB_SET_TRACK_CLIPS accepted reverse clip (speed_ratio=-1.0)")

-- ─── Test 3: Zero is still rejected (invariant unchanged) ───
print("\n--- TMB_ADD_CLIPS still rejects speed_ratio == 0 ---")

local zero_clip = {}
for k, v in pairs(reverse_clip) do zero_clip[k] = v end
zero_clip.speed_ratio = 0.0
zero_clip.clip_id = "zero-clip-001"

ok, err = pcall(EMP.TMB_ADD_CLIPS, tmb, "video", 1, { zero_clip })
assert(not ok, "TMB_ADD_CLIPS must reject zero speed_ratio, but it accepted")
assert(tostring(err):find("speed_ratio", 1, true),
    "Rejection error should mention speed_ratio; got: " .. tostring(err))
print("  ✓ TMB_ADD_CLIPS rejected zero speed_ratio: " .. tostring(err):match("[^\n]+"))

EMP.TMB_CLOSE(tmb)

print("\n✅ test_tmb_accepts_negative_speed_ratio.lua passed")
