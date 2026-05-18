-- T021 (018, FR-022): the importer's audio sample → (master.fps frame,
-- master_clock_hz tick) conversion.
--
-- Domain behaviour: when an importer (DRP/FCP7/...) hands a clip with audio
-- source_in expressed in file-natural samples, the importer must store the
-- position as (frame, subframe) in the master sequence's fps timebase and
-- the project's master_clock_hz tick space. After 018 the resolver reads
-- (frame, subframe) and reconstructs the file-natural sample via the inverse
-- math (data-model.md "Resolution to file-natural sample"). The two halves
-- must round-trip to within ≤0.5 sample (≤1 tick at the project clock).
--
-- This test pins the helper that performs that conversion. Initially fails
-- because importer_core.compute_audio_clip_source does not yet exist.

require("test_env")

local importer_core = require("importers.importer_core")
local subframe_math = require("core.subframe_math")

local function approx_eq(a, b, eps)
    return math.abs(a - b) <= eps
end

-- ── Scenario A: 48000 Hz file under 24/1 master at 192000 Hz clock ──────
-- 48000 samples = 1 second = 24 master frames. Tpf = 192000/24 = 8000.
-- Expected: frame = 24, subframe = 0 (exact divisor).
local f, s = importer_core.compute_audio_clip_source(48000, 48000, 24, 1, 192000)
assert(f == 24 and s == 0,
    string.format("scenario A: expected (24, 0), got (%s, %s)", tostring(f), tostring(s)))

-- Sub-frame sample. 48000 Hz file, S = 100 samples.
--   total_ticks = 100 * 192000 / 48000 = 400.
--   frame = 400 / 8000 = 0, subframe = 400.
f, s = importer_core.compute_audio_clip_source(100, 48000, 24, 1, 192000)
assert(f == 0 and s == 400,
    string.format("scenario A sub-frame: expected (0, 400), got (%s, %s)", tostring(f), tostring(s)))

-- Round-trip exact: pack(f,s,tpf) → ticks → ticks_to_samples ≡ 100.
local tpf = subframe_math.ticks_per_frame(192000, 24, 1)
local back = subframe_math.ticks_to_samples(
    subframe_math.pack(f, s, tpf), 48000, 192000)
assert(back == 100,
    string.format("scenario A round-trip: 100 → (%d, %d) → %d (expected 100)",
        f, s, back))

-- ── Scenario B: 44100 Hz file (non-divisor) ──────────────────────────────
-- 44100 samples = 1 second = 24 master frames. Exact second IS divisor.
f, s = importer_core.compute_audio_clip_source(44100, 44100, 24, 1, 192000)
assert(f == 24 and s == 0,
    string.format("scenario B exact-second: expected (24, 0), got (%s, %s)", tostring(f), tostring(s)))

-- 100 samples at 44100. total_ticks = round(100 * 192000 / 44100) = round(435.37) = 435.
-- tpf = 8000. frame = 0, subframe = 435.
f, s = importer_core.compute_audio_clip_source(100, 44100, 24, 1, 192000)
assert(f == 0 and s == 435,
    string.format("scenario B non-divisor: expected (0, 435), got (%s, %s)", tostring(f), tostring(s)))

-- Round-trip bound: ≤1 sample (non-divisor rounding picks up ≤0.5 each way).
back = subframe_math.ticks_to_samples(
    subframe_math.pack(f, s, tpf), 44100, 192000)
assert(approx_eq(back, 100, 1),
    string.format("scenario B round-trip: 100 → (%d, %d) → %d (expected ≈100, ±1)",
        f, s, back))

-- ── Scenario C: 96000 Hz file at 23.976 (24000/1001) master ─────────────
-- tpf = 192000 * 1001 / 24000 = 8008 ticks per frame.
-- S = 96000 → total_ticks = 96000 * 192000 / 96000 = 192000.
-- frame = floor(192000 / 8008) = 23. subframe = 192000 - 23*8008 = 7816.
f, s = importer_core.compute_audio_clip_source(96000, 96000, 24000, 1001, 192000)
local tpf_c = subframe_math.ticks_per_frame(192000, 24000, 1001)
assert(tpf_c == 8008, "test design: tpf at 23.976 / 192k clock = 8008")
local expected_f = math.floor(192000 / 8008)
local expected_s = 192000 - expected_f * 8008
assert(f == expected_f and s == expected_s, string.format(
    "scenario C: expected (%d, %d), got (%s, %s)",
    expected_f, expected_s, tostring(f), tostring(s)))

-- ── NSF: invalid inputs assert ──────────────────────────────────────────
local function expect_assert(fn, expected)
    local ok, err = pcall(fn)
    assert(not ok, "expected assert, got success")
    assert(type(err) == "string" and err:find(expected, 1, true),
        string.format("expected error containing %q, got %q", expected, tostring(err)))
end

expect_assert(function() importer_core.compute_audio_clip_source(-1, 48000, 24, 1, 192000) end, "samples")
expect_assert(function() importer_core.compute_audio_clip_source(0, 0, 24, 1, 192000) end, "file_rate")
expect_assert(function() importer_core.compute_audio_clip_source(0, 48000, 0, 1, 192000) end, "fps_num")
expect_assert(function() importer_core.compute_audio_clip_source(0, 48000, 24, 0, 192000) end, "fps_den")
expect_assert(function() importer_core.compute_audio_clip_source(0, 48000, 24, 1, 0) end, "master_clock_hz")

print("✅ test_drp_importer_subframe.lua passed")
