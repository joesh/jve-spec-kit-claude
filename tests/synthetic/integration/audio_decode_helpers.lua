-- Shared helpers for the audio-decode regression battery (--test mode, real EMP).
--
-- Black-box only: callers derive EXPECTED values from the synthetic fixtures'
-- known per-channel tone content (gen_synthetic_tone_wavs.sh), never from decoder
-- internals. These helpers just drive decode and reduce PCM to measurable scalars
-- (frequency power via Goertzel, sample-array diffs).

local ienv = require("synthetic.integration.integration_test_env")
local ffi = require("ffi")
local EMP = ienv.require_emp()

local M = {}
M.EMP = EMP

-- Decode a single audio clip's [t0_us, t1_us) range to an interleaved float table.
-- @param opts table: { path, t0_us, t1_us, out_sr, out_ch, source_channel? }
--   source_channel omitted => field absent from the clip table (composite/default).
-- @return samples (1-based interleaved float table) | nil, info table {frames, channels, sample_rate}
function M.decode(opts)
    assert(opts.path and opts.t0_us and opts.t1_us and opts.out_sr and opts.out_ch,
        "decode: path/t0_us/t1_us/out_sr/out_ch all required")
    local tmb = EMP.TMB_CREATE(0)  -- sync, deterministic
    EMP.TMB_SET_SEQUENCE_RATE(tmb, 25, 1)
    EMP.TMB_SET_AUDIO_FORMAT(tmb, opts.out_sr, opts.out_ch)
    local clip = {
        clip_id = opts.clip_id or "c",
        media_path = opts.path,
        sequence_start = 0,
        duration = opts.duration or 200,
        source_in = opts.source_in or 0,
        rate_num = 25, rate_den = 1, speed_ratio = 1.0,
    }
    if opts.source_channel ~= nil then clip.source_channel = opts.source_channel end
    EMP.TMB_SET_TRACK_CLIPS(tmb, "audio", opts.track or 1, { clip })
    local pcm = EMP.TMB_GET_TRACK_AUDIO(tmb, opts.track or 1, opts.t0_us, opts.t1_us,
        opts.out_sr, opts.out_ch)
    local samples, info = nil, nil
    if pcm then
        info = EMP.PCM_INFO(pcm)
        if info.frames > 0 then
            local ptr = ffi.cast("float*", EMP.PCM_DATA_PTR(pcm))
            samples = {}
            for i = 0, info.frames * info.channels - 1 do
                samples[i + 1] = tonumber(ptr[i])
            end
        end
        EMP.PCM_RELEASE(pcm)
    end
    EMP.TMB_CLOSE(tmb)
    return samples, info
end

-- Max abs and RMS difference between two interleaved sample tables (over min length).
-- @return maxdiff, rmsdiff, compared_count
function M.diff(a, b)
    assert(a and b, "diff: both arrays required")
    local n = math.min(#a, #b)
    local mx, sum = 0, 0
    for i = 1, n do
        local d = math.abs(a[i] - b[i])
        if d > mx then mx = d end
        sum = sum + d * d
    end
    return mx, math.sqrt(sum / math.max(n, 1)), n
end

-- Goertzel power at frequency f for one channel of an interleaved buffer.
-- @param arr interleaved float table, nch channels, ch 0-based, sr sample rate, f Hz
-- @return normalized power (∝ amplitude²); ~0 when the tone is absent.
function M.goertzel(arr, nch, ch, sr, f)
    assert(arr and nch >= 1 and ch >= 0 and ch < nch, "goertzel: bad channel args")
    local n = math.floor(#arr / nch)
    local w = 2 * math.pi * f / sr
    local coeff = 2 * math.cos(w)
    local s1, s2 = 0, 0
    for i = 0, n - 1 do
        local s0 = arr[i * nch + ch + 1] + coeff * s1 - s2
        s2 = s1; s1 = s0
    end
    return (s1 * s1 + s2 * s2 - coeff * s1 * s2) / (n * n)
end

-- The fixture set, with known content baked by gen_synthetic_tone_wavs.sh.
M.FX8 = ienv.test_media_path("synthetic_8ch_tones_48k.wav")   -- 8ch@48k, ch k = (k+1)*400 Hz
M.FX2 = ienv.test_media_path("synthetic_2ch_tones_44k.wav")   -- stereo@44.1k, L=300 R=2100
M.FX1 = ienv.test_media_path("synthetic_1ch_tone_48k.wav")    -- mono@48k, 660 Hz

-- Channel k of FX8 carries this frequency (0-based).
function M.ch_freq(k) return (k + 1) * 400 end

return M
