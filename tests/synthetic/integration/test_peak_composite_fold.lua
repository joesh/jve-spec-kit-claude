-- Composite (Adaptive) waveform fold — 023 Feature A.
--
-- A synced/Adaptive clip is ONE timeline audio clip standing for a whole
-- multi-channel master (N channels, possibly across files). It has no single
-- per-channel source window, so the renderer FOLDS the per-channel envelopes
-- into one downmix waveform on demand via EMP.PEAK_QUERY_COMPOSITE. The fold is
-- per-pixel min-of-mins / max-of-maxes across the channels' loaded peaks.
--
-- Domain expectation (independent of implementation): the composite waveform
-- shows the LOUDEST channel's excursion at each instant. Fixture
-- synthetic_8ch_amp_ramp_48k.wav: channel k is the same 1 kHz sine scaled by
-- (k+1), so channel 7 dominates everywhere → the composite envelope must equal
-- channel 7's envelope at every pixel, and must clearly exceed channel 0's.
--
-- Run via: ./build/bin/jve --test tests/synthetic/integration/test_peak_composite_fold.lua

local env = require("synthetic.integration.integration_test_env")
local EMP = env.require_emp()
local ffi = require("ffi")

print("--- test_peak_composite_fold.lua ---")

local MEDIA = env.test_media_path("synthetic_8ch_amp_ramp_48k.wav")
local OUT_DIR = "/tmp/jve/test_peak_composite_fold"
os.execute(string.format("rm -rf %q && mkdir -p %q", OUT_DIR, OUT_DIR))

local N_CHANNELS = 8
local SR = 48000
local Q_START = SR              -- 1.0 s in (steady-state sine)
local Q_END = Q_START + 4096    -- multi-bin window
local PX = 8                    -- exercise the per-pixel fold

-- Generate + load one channel's peak file; return its handle.
local function generate_channel(ch)
    local job_id = string.format("cfold_ch%d", ch)
    local out = string.format("%s/%s.peaks", OUT_DIR, job_id)
    EMP.PEAK_REQUEST(job_id, MEDIA, out, ch)

    local deadline = os.time() + 30
    while true do
        local status = EMP.PEAK_STATUS(job_id)
        if status and status.state == "complete" then break end
        if status and status.state == "failed" then
            error(string.format("peak gen failed for channel %d", ch))
        end
        assert(os.time() <= deadline,
            string.format("peak gen timed out for channel %d", ch))
        for _ = 1, 1000000 do end
    end
    return assert(EMP.PEAK_LOAD(out),
        string.format("PEAK_LOAD failed for channel %d", ch))
end

-- Read a query result (lightuserdata of [min0,max0,min1,max1,...]) into
-- parallel Lua arrays so we can compare independently of the C buffer.
local function read_pairs(peaks, count)
    local pd = ffi.cast("float*", peaks)
    local mins, maxs = {}, {}
    for i = 0, count - 1 do
        mins[i] = pd[2 * i]
        maxs[i] = pd[2 * i + 1]
    end
    return mins, maxs
end

-- Per-channel envelopes + handles (kept alive for the composite call).
local handles = {}
local ch_mins, ch_maxs = {}, {}
local ref_count = nil
for ch = 0, N_CHANNELS - 1 do
    local h = generate_channel(ch)
    handles[ch] = h
    local peaks, count = EMP.PEAK_QUERY(h, Q_START, Q_END, PX)
    assert(peaks and count > 0,
        string.format("PEAK_QUERY returned nothing for channel %d", ch))
    ref_count = ref_count or count
    assert(count == ref_count, string.format(
        "channel %d count %d != %d — per-channel windows misaligned",
        ch, count, ref_count))
    ch_mins[ch], ch_maxs[ch] = read_pairs(peaks, count)
end

-- Expected composite: per-pixel max-of-maxes / min-of-mins across channels.
local exp_min, exp_max = {}, {}
for i = 0, ref_count - 1 do
    local mn, mx = math.huge, -math.huge
    for ch = 0, N_CHANNELS - 1 do
        if ch_mins[ch][i] < mn then mn = ch_mins[ch][i] end
        if ch_maxs[ch][i] > mx then mx = ch_maxs[ch][i] end
    end
    exp_min[i], exp_max[i] = mn, mx
end

-- Drive the fold under test.
local refs = {}
for ch = 0, N_CHANNELS - 1 do
    refs[ch + 1] = { handle = handles[ch], start = Q_START, ["end"] = Q_END }
end
local comp_peaks, comp_count = EMP.PEAK_QUERY_COMPOSITE(refs, PX)
assert(comp_peaks and comp_count == ref_count, string.format(
    "PEAK_QUERY_COMPOSITE count %s != %d", tostring(comp_count), ref_count))
local comp_min, comp_max = read_pairs(comp_peaks, comp_count)

-- Fold is exact min/max selection of the same float values — assert equality.
for i = 0, ref_count - 1 do
    assert(comp_max[i] == exp_max[i], string.format(
        "pixel %d composite max %.6f != expected max-of-maxes %.6f",
        i, comp_max[i], exp_max[i]))
    assert(comp_min[i] == exp_min[i], string.format(
        "pixel %d composite min %.6f != expected min-of-mins %.6f",
        i, comp_min[i], exp_min[i]))
    -- Loudest channel (ch7) dominates the amp ramp, so the composite must
    -- equal it and clearly exceed the quietest channel (ch0).
    assert(comp_max[i] == ch_maxs[N_CHANNELS - 1][i], string.format(
        "pixel %d composite max %.6f != loudest channel max %.6f",
        i, comp_max[i], ch_maxs[N_CHANNELS - 1][i]))
    assert(comp_max[i] > ch_maxs[0][i], string.format(
        "pixel %d composite max %.6f must exceed channel-0 max %.6f "
        .. "(fold did nothing)", i, comp_max[i], ch_maxs[0][i]))
end
print(string.format("  %d pixels: composite == loudest-channel fold, > ch0", ref_count))

-- Empty / pixel_width <= 0 guards return nil, 0.
local none_p, none_c = EMP.PEAK_QUERY_COMPOSITE({}, PX)
assert(none_p == nil and none_c == 0, "empty refs must return nil, 0")
local zp, zc = EMP.PEAK_QUERY_COMPOSITE(refs, 0)
assert(zp == nil and zc == 0, "pixel_width 0 must return nil, 0")

for ch = 0, N_CHANNELS - 1 do EMP.PEAK_RELEASE(handles[ch]) end
os.execute(string.format("rm -rf %q", OUT_DIR))
print("✅ test_peak_composite_fold.lua passed")
