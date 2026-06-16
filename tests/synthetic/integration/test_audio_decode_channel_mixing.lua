-- Regression-lock: the DEFAULT (composite / "Adaptive") audio decode path —
-- the one with NO per-channel source_channel selection — keeps working through
-- Approach A. A adds per-channel extraction; it must NOT change how an
-- unselected (composite) clip downmixes, nor how mono/stereo sources map to
-- the stereo output.
--
-- Expected values are domain facts about the synthetic fixtures' known tones.

local H = require("synthetic.integration.audio_decode_helpers")

print("=== test_audio_decode_channel_mixing.lua ===")

local PRESENT = 1e-3       -- a full-scale tone's Goertzel power lands ~3.9e-3
local RATIO   = 100        -- present tone must dominate an absent one by >=100x

-- ───────────────────────────────────────────────────────────────────
-- M1. Mono source -> stereo output is dual-mono (L == R, exactly).
-- ───────────────────────────────────────────────────────────────────
print("\n--- M1: mono -> stereo dual-mono ---")
do
    local s, info = H.decode{ path = H.FX1, t0_us = 0, t1_us = 300000, out_sr = 48000, out_ch = 2 }
    assert(s and info.channels == 2, "M1: expected 2-channel output")
    local lr_max = 0
    for i = 1, math.floor(#s / 2) do
        local d = math.abs(s[(i - 1) * 2 + 1] - s[(i - 1) * 2 + 2])
        if d > lr_max then lr_max = d end
    end
    print(string.format("  L vs R maxdiff = %.6g (expect 0)", lr_max))
    assert(lr_max < 1e-6, string.format("mono not dual-mono: L/R maxdiff=%.6g", lr_max))
    -- and it actually carries the 660 Hz tone, not silence
    local p = H.goertzel(s, 2, 0, 48000, 660)
    assert(p > PRESENT, string.format("mono 660Hz tone missing (power=%.6g)", p))
end
print("  PASS: mono decodes to dual-mono 660Hz")

-- ───────────────────────────────────────────────────────────────────
-- M2. Stereo source preserves L/R separation: out-ch0 carries L's tone
--     (300 Hz) and not R's (2100 Hz); out-ch1 the reverse.
-- ───────────────────────────────────────────────────────────────────
print("\n--- M2: stereo L/R separation preserved ---")
do
    local s = H.decode{ path = H.FX2, t0_us = 0, t1_us = 500000, out_sr = 48000, out_ch = 2 }
    assert(s, "M2: empty")
    local l300 = H.goertzel(s, 2, 0, 48000, 300)
    local l2100 = H.goertzel(s, 2, 0, 48000, 2100)
    local r300 = H.goertzel(s, 2, 1, 48000, 300)
    local r2100 = H.goertzel(s, 2, 1, 48000, 2100)
    print(string.format("  out-ch0: 300Hz=%.4g 2100Hz=%.4g | out-ch1: 300Hz=%.4g 2100Hz=%.4g",
        l300, l2100, r300, r2100))
    assert(l300 > PRESENT and l300 > l2100 * RATIO, "M2: out-ch0 lost 300Hz dominance")
    assert(r2100 > PRESENT and r2100 > r300 * RATIO, "M2: out-ch1 lost 2100Hz dominance")
end
print("  PASS: stereo separation preserved")

-- ───────────────────────────────────────────────────────────────────
-- M3. Composite default is invariant to how it's expressed: omitting
--     source_channel == passing source_channel = -1. Both are the
--     "Adaptive"/composite downmix. This guards that A's per-channel
--     work leaves the default path identical and treats -1 as composite.
-- ───────────────────────────────────────────────────────────────────
print("\n--- M3: omitted source_channel == explicit -1 (composite) ---")
do
    local omitted   = H.decode{ path = H.FX8, t0_us = 0, t1_us = 500000, out_sr = 48000, out_ch = 2 }
    local explicit  = H.decode{ path = H.FX8, t0_us = 0, t1_us = 500000, out_sr = 48000, out_ch = 2,
                                source_channel = -1 }
    assert(omitted and explicit, "M3: empty decode")
    local mx = H.diff(omitted, explicit)
    print(string.format("  omitted vs -1 maxdiff = %.6g (expect 0)", mx))
    assert(mx < 1e-6, string.format("composite default differs from explicit -1: maxdiff=%.6g", mx))
    -- composite is non-silent and is NOT identical to any single extracted channel
    -- (it's a mix) — sanity that "composite" really means "more than one channel".
    local single = H.decode{ path = H.FX8, t0_us = 0, t1_us = 500000, out_sr = 48000, out_ch = 2,
                             source_channel = 0 }
    if single then
        -- Pre-A this is a no-op (single==composite); post-A they must differ.
        -- We do NOT assert difference here (that's the per-channel test's job) —
        -- only that composite itself is non-silent.
        local _ = single
    end
    local rms = 0
    for _, v in ipairs(omitted) do rms = rms + v * v end
    rms = math.sqrt(rms / #omitted)
    assert(rms > 1e-3, string.format("composite downmix is silent (rms=%.6g)", rms))
end
print("  PASS: composite default invariant + non-silent")

print("\n✅ test_audio_decode_channel_mixing.lua passed")
