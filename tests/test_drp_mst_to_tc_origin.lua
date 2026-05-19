-- Helen 44.1k drift fix: DRP MediaStartTime (decimal-seconds string,
-- parsed as float64) converted to media TC origin (integer at native_rate
-- units) must match Resolve EDL semantics.
--
-- The pre-fix path used `math.floor(mst * native_rate + 0.5)` (round-half-
-- away-from-zero). That works for camera files where MST*native_rate is
-- within float64-epsilon of an integer (those files start TC at sample/
-- frame boundaries) but breaks for BWF files like Helen's where MST is a
-- genuinely fractional frame count (BWF's sample-precise time_reference
-- falls between video frames).
--
-- Helen's actual case: MST = 109.2736507936508 (= 4818968 / 44100 samples).
--   * At native_rate=44100 (audio): 4818968 exactly — both methods agree.
--   * At native_rate=25 (video):    2731.84 — Resolve EDL takes 2731 (floor).
--     Pre-fix round-half-away gave 2732 → 1484-sample drift downstream.
--
-- The right discriminator: if (mst*rate) is within float64-roundoff of an
-- integer (camera case), round to nearest; otherwise floor (genuine sub-
-- frame TC, Helen case). Camera-clip example from the original TODO:
--   MST = 74276.76 → MST*25 = 1856918.999… (float64 noise from 25-multiply
--   on an integer-valued seconds count) → snap to 1856919.

require("test_env")
local drp = require("importers.drp_importer")

print("\n=== drp_importer.mst_to_tc_origin Resolve EDL parity ===")

-- ─────────────────────────────────────────────────────────────────────
-- Case 1: Helen BWF — genuinely fractional video frame count.
-- ─────────────────────────────────────────────────────────────────────
-- MST = 4818968/44100 exactly. At 25fps video, that's 2731.84 frames —
-- Resolve EDL floors to 2731.
do
    local mst = 4818968 / 44100
    local tc  = drp.mst_to_tc_origin(mst, 25)
    assert(tc == 2731, string.format(
        "Helen 44.1k @ 25fps: expected EDL-floor=2731, got %d", tc))
    -- Audio side: same MST at 44100 sample_rate is exact integer.
    local tc_a = drp.mst_to_tc_origin(mst, 44100)
    assert(tc_a == 4818968, string.format(
        "Helen 44.1k @ 44100: expected exact 4818968 samples, got %d", tc_a))
    print(string.format("  ok Helen: V=%d (floor of 2731.84), A=%d", tc, tc_a))
end

-- ─────────────────────────────────────────────────────────────────────
-- Case 2: Camera clip — MST*native_rate close-to-integer (float64 noise).
-- ─────────────────────────────────────────────────────────────────────
-- 74276.76 seconds at 25fps. The arithmetic 74276.76 * 25 in float64 is
-- 1856918.9999… not 1856919 exactly. Resolve treats this as frame 1856919
-- (the TC origin IS on a frame boundary; the .9999 is purely float64
-- noise from the decimal MST representation).
do
    local mst = 74276.76
    -- Sanity that we picked an example that actually trips: confirm the
    -- naive multiplication is below the integer, not above. If the
    -- assertion below fails on a future float64 revision, swap example.
    assert(mst * 25 < 1856919 and mst * 25 > 1856918.9, string.format(
        "test setup: expected MST*25 in (1856918.9, 1856919); got %.10f",
        mst * 25))
    local tc = drp.mst_to_tc_origin(mst, 25)
    assert(tc == 1856919, string.format(
        "Camera 25fps with float64 noise: expected snap-to-nearest=1856919, " ..
        "got %d. Falling through to floor here would cause a 1-frame off-by-one " ..
        "for every camera clip with a fractional-seconds MST.", tc))
    print(string.format("  ok Camera: snap to %d (float64 noise rejected)", tc))
end

-- ─────────────────────────────────────────────────────────────────────
-- Case 3: Exact integer MST (TC origin = 00:00:00:00 family).
-- ─────────────────────────────────────────────────────────────────────
-- MST = 0 or any whole-number seconds. Both methods agree.
do
    assert(drp.mst_to_tc_origin(0, 24) == 0, "MST=0 must give tc=0")
    assert(drp.mst_to_tc_origin(60, 24) == 1440, "MST=60s at 24fps = 1440 frames")
    assert(drp.mst_to_tc_origin(1, 48000) == 48000, "MST=1s at 48kHz = 48000 samples")
    print("  ok Exact-integer MST cases")
end

-- ─────────────────────────────────────────────────────────────────────
-- Case 4: Genuinely sub-frame fractional (synthetic, not just float
-- noise). E.g. half-frame TC offset at 24fps.
-- ─────────────────────────────────────────────────────────────────────
-- MST = 0.5/24 = 0.020833... seconds. MST*24 = 0.5 — exactly halfway.
-- Resolve EDL floors (= 0). Pre-fix round-half-away gave 1 (wrong).
do
    local mst = 0.5 / 24
    local tc = drp.mst_to_tc_origin(mst, 24)
    assert(tc == 0, string.format(
        "half-frame sub-TC at 24fps: expected EDL-floor=0, got %d", tc))
    print(string.format("  ok Half-frame sub-TC: floor to %d", tc))
end

-- ─────────────────────────────────────────────────────────────────────
-- Case 5: Input validation — negative MST, zero/negative rate.
-- ─────────────────────────────────────────────────────────────────────
do
    local ok1 = pcall(drp.mst_to_tc_origin, -1, 24)
    assert(not ok1, "negative MST must assert")
    local ok2 = pcall(drp.mst_to_tc_origin, 1, 0)
    assert(not ok2, "rate=0 must assert")
    local ok3 = pcall(drp.mst_to_tc_origin, 1, -24)
    assert(not ok3, "negative rate must assert")
    print("  ok Input validation (negative MST, zero/negative rate)")
end

print("✅ test_drp_mst_to_tc_origin.lua passed")
