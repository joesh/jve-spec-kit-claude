-- Per-channel peak generation (Phase 3 of per-channel audio).
--
-- An audio clip plays ONE source-file channel (media_refs.source_channel);
-- its waveform must reflect THAT channel, not a composite fold of all
-- channels. This test drives the C++ peak generator directly with a
-- source_channel selector and asserts each channel's envelope magnitude
-- matches what we synthesized for that channel.
--
-- Fixture: synthetic_8ch_amp_ramp_48k.wav — channel k (0-based) is a 1 kHz
-- sine whose amplitude is PROPORTIONAL to (k+1). So the per-channel peak
-- envelopes form a strict ramp: max[k] ≈ (k+1) * max[0]. The composite
-- downmix (source_channel = -1) folds min/max across all channels, so its
-- peak equals the LOUDEST channel (max[7]). A correct per-channel generator
-- yields eight DISTINCT envelopes obeying the (k+1) ratio; a composite-only
-- generator (the pre-Phase-3 behavior) yields max[7] for EVERY channel, so
-- the ratio collapses to 1 and this test fails.
--
-- The test asserts the (k+1) RATIO, not absolute levels, so it is
-- independent of ffmpeg's sine-source amplitude convention (~0.125 full
-- scale — see gen_synthetic_tone_wavs.sh).
--
-- Run via: ./build/bin/jve --test tests/synthetic/integration/test_peak_per_channel.lua

local env = require("synthetic.integration.integration_test_env")
local EMP = env.require_emp()
local ffi = require("ffi")

print("--- test_peak_per_channel.lua ---")

local MEDIA = env.test_media_path("synthetic_8ch_amp_ramp_48k.wav")
local OUT_DIR = "/tmp/jve/test_peak_per_channel"
os.execute(string.format("rm -rf %q && mkdir -p %q", OUT_DIR, OUT_DIR))

local N_CHANNELS = 8
local SR = 48000
-- Query a 256-sample (one level-0 bin) window well inside the file so the
-- 1 kHz sine is at full amplitude (avoid the very first/last bins).
local Q_START = SR        -- 1.0 s in
local Q_END = Q_START + 256
local RATIO_TOL = 0.04    -- fractional tolerance on the (k+1) ratio

-- Generate + load a peak file for one source channel, return its bin max.
local function channel_peak_max(ch)
    local job_id = string.format("ramp_ch%d", ch)
    local out = string.format("%s/%s.peaks", OUT_DIR, job_id)
    EMP.PEAK_REQUEST(job_id, MEDIA, out, ch)  -- 4th arg: source_channel

    local deadline = os.time() + 30
    while true do
        local status = EMP.PEAK_STATUS(job_id)
        if status and status.state == "complete" then break end
        if status and status.state == "failed" then
            error(string.format("peak generation failed for channel %d", ch))
        end
        assert(os.time() <= deadline,
            string.format("peak gen timed out for channel %d", ch))
        for _ = 1, 1000000 do end
    end

    local handle = assert(EMP.PEAK_LOAD(out),
        string.format("PEAK_LOAD failed for channel %d", ch))
    local peaks, count = EMP.PEAK_QUERY(handle, Q_START, Q_END, 1)
    assert(peaks and count == 1,
        string.format("PEAK_QUERY failed for channel %d", ch))
    local pd = ffi.cast("float*", peaks)
    local mx = math.max(math.abs(pd[0]), math.abs(pd[1]))
    EMP.PEAK_RELEASE(handle)
    return mx
end

-- Measure each channel's extracted envelope.
local maxes = {}
for ch = 0, N_CHANNELS - 1 do
    maxes[ch] = channel_peak_max(ch)
end

-- Channel 0 is the unit. Every other channel must obey the synthesized
-- (k+1) ratio: max[k] ≈ (k+1) * max[0]. This is the discriminator — a
-- composite-only generator returns max[7] for every channel, so the
-- ratio would be ~8 for channel 0 and ~1 for channel 7, failing here.
assert(maxes[0] > 0.001, string.format(
    "channel 0 envelope is silent (max=%.5f) — extraction produced nothing", maxes[0]))
for ch = 0, N_CHANNELS - 1 do
    local ratio = maxes[ch] / maxes[0]
    local want_ratio = ch + 1
    print(string.format("  channel %d: peak max=%.5f  ratio=%.3f (expected %d)",
        ch, maxes[ch], ratio, want_ratio))
    assert(math.abs(ratio - want_ratio) <= want_ratio * RATIO_TOL, string.format(
        "channel %d ratio=%.3f, expected %d (±%.0f%%) — per-channel extraction "
        .. "wrong (composite fold collapses the ramp)",
        ch, ratio, want_ratio, RATIO_TOL * 100))
end

-- Strictly increasing (mutually distinct envelopes).
for ch = 1, N_CHANNELS - 1 do
    assert(maxes[ch] > maxes[ch - 1], string.format(
        "channel %d (%.5f) must be louder than channel %d (%.5f)",
        ch, maxes[ch], ch - 1, maxes[ch - 1]))
end

-- Composite (-1) is the resampler's DOWNMIX of all channels to stereo (not a
-- max-fold). With eight in-phase channels it sums to more than any single
-- channel, and it must clearly differ from the channel-0 extraction — that's
-- the proof the source_channel selector actually changes the decode.
local comp_out = OUT_DIR .. "/ramp_composite.peaks"
EMP.PEAK_REQUEST("ramp_composite", MEDIA, comp_out, -1)
local deadline = os.time() + 30
while true do
    local status = EMP.PEAK_STATUS("ramp_composite")
    if status and status.state == "complete" then break end
    if status and status.state == "failed" then error("composite peak gen failed") end
    assert(os.time() <= deadline, "composite peak gen timed out")
    for _ = 1, 1000000 do end
end
local comp_handle = assert(EMP.PEAK_LOAD(comp_out))
local cp, cc = EMP.PEAK_QUERY(comp_handle, Q_START, Q_END, 1)
assert(cp and cc == 1, "composite PEAK_QUERY failed")
local cpd = ffi.cast("float*", cp)
local comp_max = math.max(math.abs(cpd[0]), math.abs(cpd[1]))
EMP.PEAK_RELEASE(comp_handle)
print(string.format("  composite: peak max=%.5f (ch0=%.5f, ch7=%.5f)",
    comp_max, maxes[0], maxes[N_CHANNELS - 1]))
assert(comp_max > 0.001, string.format(
    "composite envelope is silent (max=%.5f) — composite decode broken", comp_max))
assert(comp_max > maxes[0], string.format(
    "composite (%.5f) must exceed the quietest channel (%.5f) — it sums "
    .. "in-phase channels", comp_max, maxes[0]))
assert(math.abs(comp_max - maxes[0]) > maxes[0] * 0.5, string.format(
    "composite (%.5f) too close to channel-0 extraction (%.5f) — the "
    .. "source_channel selector isn't changing the decode", comp_max, maxes[0]))

os.execute(string.format("rm -rf %q", OUT_DIR))
print("✅ test_peak_per_channel.lua passed")
