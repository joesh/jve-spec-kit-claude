-- Regression-lock: audio decode is CLICK-FREE and rate conversion is stable.
--
-- Approach A (per-channel decode extraction) rewrites the shared decode/resample
-- path — blast radius is ALL audio. This battery locks the current click-free
-- behavior so A cannot silently introduce boundary glitches or break rate
-- conversion. Expected values are domain facts (contiguous decode must be
-- seamless; a known sample-rate ratio yields a known frame count), with the
-- one empirical tolerance (rate-convert chunk transient) measured on the
-- pre-A build and documented inline.
--
-- Fixtures: gen_synthetic_tone_wavs.sh — pure per-channel sine tones.

local H = require("synthetic.integration.audio_decode_helpers")

print("=== test_audio_decode_continuity.lua ===")

-- ───────────────────────────────────────────────────────────────────
-- C1. Same-rate decode is SEAMLESS: decoding a contiguous range in
--     chunks must equal decoding it whole, sample-for-sample. A click
--     at a chunk boundary is exactly the failure this catches.
--     (8ch@48k decoded at 48k => no resampling => must be bit-seamless.)
-- ───────────────────────────────────────────────────────────────────
print("\n--- C1: same-rate chunked == whole (seamless) ---")
local SEAMLESS_TOL = 1e-6  -- pre-A build measured EXACTLY 0 here

local function chunked_equals_whole(path, out_sr, splits, tol, label)
    local whole = H.decode{ path = path, t0_us = 0, t1_us = 1000000, out_sr = out_sr, out_ch = 2 }
    assert(whole and #whole > 0, label .. ": whole decode empty")
    -- Build the chunked concatenation from `splits` boundary list (us).
    local cat, prev = {}, 0
    for _, b in ipairs(splits) do
        local c = H.decode{ path = path, t0_us = prev, t1_us = b, out_sr = out_sr, out_ch = 2 }
        assert(c and #c > 0, label .. ": chunk decode empty")
        for _, v in ipairs(c) do cat[#cat + 1] = v end
        prev = b
    end
    local mx, rms, n = H.diff(whole, cat)
    print(string.format("  [%s] whole=%d cat=%d cmp=%d maxdiff=%.6g rmsdiff=%.6g",
        label, #whole, #cat, n, mx, rms))
    assert(math.abs(#whole - #cat) <= 2,
        string.format("%s: chunk total frames diverge from whole (%d vs %d)", label, #whole, #cat))
    assert(mx < tol, string.format("%s: CLICK — chunked decode diverges from whole (maxdiff=%.6g >= %.6g)",
        label, mx, tol))
end

-- 2-chunk and 3-chunk splits at non-trivial, non-aligned boundaries.
chunked_equals_whole(H.FX8, 48000, { 500000, 1000000 }, SEAMLESS_TOL, "8ch 2-chunk")
chunked_equals_whole(H.FX8, 48000, { 333000, 666000, 1000000 }, SEAMLESS_TOL, "8ch 3-chunk")
print("  PASS: same-rate decode seamless across chunk boundaries")

-- ───────────────────────────────────────────────────────────────────
-- C2. Rate-converted decode stays continuous within the measured
--     pre-A tolerance. 44.1k source decoded at 48k engages the
--     resampler; the only divergence is a small per-call warmup
--     transient at chunk starts. Pre-A build measured maxdiff=1.34e-3,
--     rmsdiff=8.8e-6 — lock at modest headroom so A can't worsen it.
-- ───────────────────────────────────────────────────────────────────
print("\n--- C2: rate-convert (44.1k->48k) chunk transient bounded ---")
local RC_MAXDIFF = 5e-3   -- observed 1.34e-3
local RC_RMSDIFF = 1e-4   -- observed 8.8e-6
do
    local whole = H.decode{ path = H.FX2, t0_us = 0, t1_us = 1000000, out_sr = 48000, out_ch = 2 }
    local c1 = H.decode{ path = H.FX2, t0_us = 0, t1_us = 500000, out_sr = 48000, out_ch = 2 }
    local c2 = H.decode{ path = H.FX2, t0_us = 500000, t1_us = 1000000, out_sr = 48000, out_ch = 2 }
    local cat = {}
    for _, v in ipairs(c1) do cat[#cat + 1] = v end
    for _, v in ipairs(c2) do cat[#cat + 1] = v end
    local mx, rms = H.diff(whole, cat)
    print(string.format("  maxdiff=%.6g (<%.0e)  rmsdiff=%.6g (<%.0e)", mx, RC_MAXDIFF, rms, RC_RMSDIFF))
    assert(mx < RC_MAXDIFF, string.format("rate-convert chunk transient grew: maxdiff=%.6g", mx))
    assert(rms < RC_RMSDIFF, string.format("rate-convert chunk rms grew: rmsdiff=%.6g", rms))
end
print("  PASS: rate-convert continuity within bound")

-- ───────────────────────────────────────────────────────────────────
-- C3. Rate conversion preserves duration: 1.0s of 44.1k source decoded
--     at 48k yields ~48000 frames. Derived from the sample-rate ratio,
--     not from code. Catches a broken resample ratio.
-- ───────────────────────────────────────────────────────────────────
print("\n--- C3: rate-convert frame count ---")
do
    local _, info = H.decode{ path = H.FX2, t0_us = 0, t1_us = 1000000, out_sr = 48000, out_ch = 2 }
    assert(info, "C3: nil info")
    print(string.format("  1.0s @ out 48k -> %d frames (expect ~48000)", info.frames))
    assert(math.abs(info.frames - 48000) <= 2,
        string.format("rate-convert frame count wrong: %d (expected 48000±2)", info.frames))
    assert(info.sample_rate == 48000, "C3: output sample_rate not 48000")
end
print("  PASS: rate-convert frame count correct")

-- ───────────────────────────────────────────────────────────────────
-- C4. Seek determinism: re-decoding the SAME range after seeking
--     elsewhere returns identical samples — no FIFO/resampler state
--     leaks across a seek. (decode A, decode far-away B, decode A again
--     => first == third, exactly.)
-- ───────────────────────────────────────────────────────────────────
print("\n--- C4: seek does not contaminate re-decode ---")
do
    local a1 = H.decode{ path = H.FX8, t0_us = 0, t1_us = 400000, out_sr = 48000, out_ch = 2 }
    local _b = H.decode{ path = H.FX8, t0_us = 1400000, t1_us = 1800000, out_sr = 48000, out_ch = 2 }
    local a2 = H.decode{ path = H.FX8, t0_us = 0, t1_us = 400000, out_sr = 48000, out_ch = 2 }
    assert(a1 and _b and a2, "C4: a decode returned empty")
    local mx = H.diff(a1, a2)
    print(string.format("  re-decode maxdiff after intervening seek = %.6g", mx))
    assert(mx < SEAMLESS_TOL, string.format("seek contaminated re-decode: maxdiff=%.6g", mx))
end
print("  PASS: re-decode after seek is deterministic")

print("\n✅ test_audio_decode_continuity.lua passed")
