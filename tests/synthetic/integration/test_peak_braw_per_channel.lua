-- Per-channel peak generation for BRAW audio.
--
-- BRAW bypasses the FFmpeg/swr decode path (it reads natively from the SDK).
-- Per-channel waveform extraction (spec 023) must still work there: the
-- timeline issues one peak request per referenced source channel
-- (media_refs.source_channel), and each must yield THAT channel's envelope —
-- not a composite fold, not a flat/dead waveform.
--
-- Before the fix the BRAW path rejected every source_channel >= 0, so every
-- chunk failed and a FLAT peak file was written and reported "complete". On the
-- Anamnesis gold timeline that meant a dead waveform for every BRAW audio clip.
--
-- Two assertions:
--   (A) every valid source channel (0 .. N-1) generates a non-silent envelope
--       and reports "complete";
--   (B) an out-of-range channel must FAIL LOUDLY (status "failed", no peak
--       file) — never a silent flat envelope reported as "complete".
--
-- Skips cleanly when no BRAW file with audio is present (BRAW media is too
-- large to commit as a fixture; mirrors test_braw_decode.lua).
--
-- Run via: ./build/bin/jve --test tests/synthetic/integration/test_peak_braw_per_channel.lua

local env = require("synthetic.integration.integration_test_env")
local test_env = require("test_env")
local EMP = env.require_emp()
local ffi = require("ffi")

print("--- test_peak_braw_per_channel.lua ---")

local OUT_DIR = "/tmp/jve/test_peak_braw_per_channel"
os.execute(string.format("rm -rf %q && mkdir -p %q", OUT_DIR, OUT_DIR))

-- Probe a BRAW file's audio channel count, or nil if unopenable / no audio.
local function braw_audio_channels(path)
    local f = io.open(path, "r")
    if not f then return nil end
    f:close()
    local media = EMP.MEDIA_FILE_OPEN(path)
    if not media then return nil end
    local info = EMP.MEDIA_FILE_INFO(media)
    local channels = (info.has_audio and info.audio_channels > 0) and info.audio_channels or nil
    EMP.MEDIA_FILE_CLOSE(media)
    return channels
end

-- Drive one peak job to terminal state; returns ("complete"|"failed", max_abs).
-- max_abs is the loudest level-0 bin across the WHOLE file (camera BRAW
-- reference audio is very quiet and uneven, so a single bin is unreliable).
local SR = 48000
local WHOLE_FILE_SAMPLES = SR * 600  -- generous; the peak file clamps to actual
local function run_peak_job(job_id, path, channel)
    local out = string.format("%s/%s.peaks", OUT_DIR, job_id)
    os.remove(out)
    EMP.PEAK_REQUEST(job_id, path, out, channel)

    local deadline = os.time() + 60
    local state
    while true do
        local status = EMP.PEAK_STATUS(job_id)
        state = status and status.state
        if state == "complete" or state == "failed" then break end
        assert(os.time() <= deadline,
            string.format("peak gen timed out for %s ch=%d", job_id, channel))
        for _ = 1, 1000000 do end
    end

    if state ~= "complete" then return state, 0 end

    local handle = assert(EMP.PEAK_LOAD(out),
        string.format("PEAK_LOAD failed for %s", job_id))
    local peaks, count = EMP.PEAK_QUERY(handle, 0, WHOLE_FILE_SAMPLES, 256)
    local mx = 0
    if peaks and count and count > 0 then
        local pd = ffi.cast("float*", peaks)
        for i = 0, (count * 2) - 1 do
            local v = math.abs(pd[i])
            if v > mx then mx = v end
        end
    end
    EMP.PEAK_RELEASE(handle)
    return state, mx
end

-- Find a BRAW file with audio. The committed fixture first, then real footage
-- (present on Joe's machine, absent in CI / fresh clones).
local CANDIDATES = {
    test_env.resolve_repo_path("tests/fixtures/media/anamnesis-untrimmed/A001_07240010_C015.braw"),
    "/Applications/Blackmagic RAW/Blackmagic RAW SDK/Media/sample.braw",
}
local braw_path, n_channels
for _, p in ipairs(CANDIDATES) do
    local ch = braw_audio_channels(p)
    if ch then braw_path = p; n_channels = ch; break end
end

if not braw_path then
    print("  SKIP: no BRAW file with audio present")
    print("✅ test_peak_braw_per_channel.lua passed (skipped)")
    return
end

print(string.format("  BRAW: %s (%d audio channels)", braw_path, n_channels))

-- (A) Every valid source channel extracts a non-silent envelope.
local ch_max = {}
for ch = 0, n_channels - 1 do
    local state, mx = run_peak_job(string.format("braw_ch%d", ch), braw_path, ch)
    assert(state == "complete", string.format(
        "BRAW channel %d peak must complete (per-channel extraction is wired "
        .. "through the SDK path), got %q", ch, tostring(state)))
    assert(mx > 0.001, string.format(
        "BRAW channel %d envelope is silent (max=%.5f) — extraction produced a "
        .. "flat/dead waveform", ch, mx))
    ch_max[ch] = mx
    print(string.format("    channel %d: complete, peak max=%.5f", ch, mx))
end

-- Composite (-1) must also still work, and equal the LOUDEST channel: the
-- generator folds min/max across channels, so the composite peak is the
-- max-of-channels. This proves the source_channel selector genuinely changes
-- the decode (a flat/sentinel file would make every channel identical, and a
-- composite-only generator would return this same value for every channel).
local comp_state, comp_max = run_peak_job("braw_composite", braw_path, -1)
assert(comp_state == "complete" and comp_max > 0.001, string.format(
    "BRAW composite peak must complete non-silent, got state=%q max=%.5f",
    tostring(comp_state), comp_max))
print(string.format("    composite: complete, peak max=%.5f", comp_max))

local loudest = 0
for ch = 0, n_channels - 1 do loudest = math.max(loudest, ch_max[ch]) end
assert(math.abs(comp_max - loudest) <= loudest * 0.05, string.format(
    "composite (%.5f) must equal the loudest channel (%.5f) — the min/max fold",
    comp_max, loudest))

-- For a genuinely multichannel file the per-channel envelopes must DIFFER;
-- identical maxes would mean the selector isn't changing the decode.
if n_channels >= 2 then
    local distinct = false
    for ch = 1, n_channels - 1 do
        if math.abs(ch_max[ch] - ch_max[0]) > ch_max[0] * 0.05 then distinct = true end
    end
    assert(distinct, string.format(
        "all %d BRAW channels share the same envelope max (%.5f) — per-channel "
        .. "extraction isn't selecting distinct channels", n_channels, ch_max[0]))
end

-- (B) An out-of-range channel must fail loudly — not silently write a flat file.
local oor = n_channels + 2
local oor_state = run_peak_job("braw_oor", braw_path, oor)
assert(oor_state == "failed", string.format(
    "out-of-range channel %d on a %d-channel BRAW must FAIL the peak job (no "
    .. "silent flat envelope reported as complete), got %q",
    oor, n_channels, tostring(oor_state)))
print(string.format("    out-of-range channel %d: correctly failed", oor))

os.execute(string.format("rm -rf %q", OUT_DIR))
print("✅ test_peak_braw_per_channel.lua passed")
