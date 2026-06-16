-- Per-channel audio extraction (Approach A target). RED until A lands.
--
-- A synced/Adaptive master expands to one track per file channel; each track
-- must decode ONLY its own channel (source_channel selector), so soloing a track
-- plays that channel's content — not a downmix of all of them. Pre-A the C++
-- decode path drops source_channel and downmixes, so every track sounds the same;
-- that bug is exactly what these assertions fail on until A is implemented.
--
-- Expected frequencies are the synthetic fixture's known per-channel tones
-- (channel k of FX8 = (k+1)*400 Hz) — domain facts, not decoder internals.
-- The downmix carries only even-indexed channels in out-ch0, so the
-- odd-indexed channels (1,3,5,7 = 800/1600/2400/3200 Hz) are the cleanest
-- RED->GREEN discriminators: absent pre-A, dominant post-A.

local H = require("synthetic.integration.audio_decode_helpers")

print("=== test_audio_per_channel_extraction.lua ===")

local PRESENT = 1e-3   -- a full-scale extracted tone's Goertzel power ~3.9e-3
local RATIO   = 100    -- the channel's own tone must dominate any other by >=100x

-- Strongest tone (by Goertzel) among the 8 candidate channel frequencies,
-- measured on output channel `out_ch` of an extracted buffer.
local function dominant_channel(samples, out_ch)
    local best_k, best_p = -1, -1
    for k = 0, 7 do
        local p = H.goertzel(samples, 2, out_ch, 48000, H.ch_freq(k))
        if p > best_p then best_p, best_k = p, k end
    end
    return best_k, best_p
end

-- ───────────────────────────────────────────────────────────────────
-- P1. Each of the 8 channels extracts to ITS OWN tone, dominant over
--     all others. This is the core requirement.
-- ───────────────────────────────────────────────────────────────────
print("\n--- P1: every channel extracts its own tone ---")
for k = 0, 7 do
    local s = H.decode{ path = H.FX8, t0_us = 0, t1_us = 500000, out_sr = 48000, out_ch = 2,
                        source_channel = k }
    assert(s, string.format("P1 ch%d: empty decode", k))
    local own = H.goertzel(s, 2, 0, 48000, H.ch_freq(k))
    local best_k, best_p = dominant_channel(s, 0)
    print(string.format("  ch%d (%dHz): own=%.4g dominant=ch%d(%.4g)",
        k, H.ch_freq(k), own, best_k, best_p))
    assert(own > PRESENT,
        string.format("ch%d: own tone %dHz missing (power=%.6g) — source_channel ignored?",
            k, H.ch_freq(k), own))
    assert(best_k == k,
        string.format("ch%d: dominant tone is ch%d's (%dHz), not ch%d's — wrong channel extracted",
            k, best_k, H.ch_freq(best_k), k))
    -- dominate the nearest other channels by a wide margin
    for j = 0, 7 do
        if j ~= k then
            local other = H.goertzel(s, 2, 0, 48000, H.ch_freq(j))
            assert(own > other * RATIO,
                string.format("ch%d: leak from ch%d (%dHz): own=%.4g other=%.4g",
                    k, j, H.ch_freq(j), own, other))
        end
    end
end
print("  PASS: all 8 channels extract distinctly")

-- ───────────────────────────────────────────────────────────────────
-- P2. Cache non-collision: two tracks on the SAME file, decoded through
--     ONE TMB, selecting different channels, must return different
--     content. A decode cache keyed without the channel returns the
--     first channel's PCM for both — this fails on that bug.
--     (track1=ch1 800Hz, track2=ch6 2800Hz; both absent from downmix L
--      so a downmix-fallback also fails.)
-- ───────────────────────────────────────────────────────────────────
print("\n--- P2: two channels on same file via one TMB don't collide ---")
do
    local EMP = H.EMP
    local tmb = EMP.TMB_CREATE(0)
    EMP.TMB_SET_SEQUENCE_RATE(tmb, 25, 1)
    EMP.TMB_SET_AUDIO_FORMAT(tmb, 48000, 2)
    local function clip(id, ch) return {
        clip_id = id, media_path = H.FX8, sequence_start = 0, duration = 200,
        source_in = 0, rate_num = 25, rate_den = 1, speed_ratio = 1.0, source_channel = ch,
    } end
    EMP.TMB_SET_TRACK_CLIPS(tmb, "audio", 1, { clip("t1", 1) })  -- 800 Hz
    EMP.TMB_SET_TRACK_CLIPS(tmb, "audio", 2, { clip("t2", 6) })  -- 2800 Hz
    local ffi = require("ffi")
    local function track_samples(track)
        local pcm = EMP.TMB_GET_TRACK_AUDIO(tmb, track, 0, 500000, 48000, 2)
        assert(pcm, "P2: nil pcm track " .. track)
        local info = EMP.PCM_INFO(pcm)
        local ptr = ffi.cast("float*", EMP.PCM_DATA_PTR(pcm))
        local t = {}
        for i = 0, info.frames * info.channels - 1 do t[i + 1] = tonumber(ptr[i]) end
        EMP.PCM_RELEASE(pcm)
        return t
    end
    local s1 = track_samples(1)
    local s2 = track_samples(2)
    EMP.TMB_CLOSE(tmb)
    local d1 = dominant_channel(s1, 0)
    local d2 = dominant_channel(s2, 0)
    print(string.format("  track1 dominant ch%d (want 1=800Hz), track2 ch%d (want 6=2800Hz)", d1, d2))
    assert(d1 == 1, string.format("P2: track1 should be ch1(800Hz), got ch%d", d1))
    assert(d2 == 6, string.format("P2: track2 should be ch6(2800Hz), got ch%d — cache collision", d2))
end
print("  PASS: per-channel decode does not collide in the cache")

-- ───────────────────────────────────────────────────────────────────
-- P3. Decode-order independence: decoding ch6 first then ch1 must still
--     give ch1 its own tone (the earlier decode must not poison it).
-- ───────────────────────────────────────────────────────────────────
print("\n--- P3: decode order independence ---")
do
    local first = H.decode{ path = H.FX8, t0_us = 0, t1_us = 500000, out_sr = 48000, out_ch = 2,
                            source_channel = 6 }
    assert(select(1, dominant_channel(first, 0)) == 6, "P3: ch6 decode wrong")
    local second = H.decode{ path = H.FX8, t0_us = 0, t1_us = 500000, out_sr = 48000, out_ch = 2,
                             source_channel = 1 }
    local k = dominant_channel(second, 0)
    print(string.format("  after ch6, ch1 decode dominant = ch%d (want 1)", k))
    assert(k == 1, string.format("P3: ch1 poisoned by prior ch6 decode (got ch%d)", k))
end
print("  PASS: decode order independent")

-- ───────────────────────────────────────────────────────────────────
-- P4. Extracted single channel is dual-mono (L == R): a mono source
--     channel is duplicated to both stereo outputs for monitoring.
-- ───────────────────────────────────────────────────────────────────
print("\n--- P4: extracted channel is dual-mono ---")
do
    local s = H.decode{ path = H.FX8, t0_us = 0, t1_us = 300000, out_sr = 48000, out_ch = 2,
                        source_channel = 3 }
    assert(s, "P4: empty")
    local lr_max = 0
    for i = 1, math.floor(#s / 2) do
        local d = math.abs(s[(i - 1) * 2 + 1] - s[(i - 1) * 2 + 2])
        if d > lr_max then lr_max = d end
    end
    print(string.format("  ch3 extracted L vs R maxdiff = %.6g (expect 0)", lr_max))
    assert(lr_max < 1e-6, string.format("extracted channel not dual-mono: maxdiff=%.6g", lr_max))
end
print("  PASS: extracted channel duplicated to both outputs")

print("\n✅ test_audio_per_channel_extraction.lua passed")
