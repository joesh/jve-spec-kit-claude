-- T009 (018): canonical sub-frame math primitive (FR-006, FR-007, FR-008, FR-019).
-- Tests pack/unpack, normalize, samples<->ticks, ticks_per_frame, validation.
-- Initially fails because src/lua/core/subframe_math.lua does not yet exist.

require("test_env")
local M = require("core.subframe_math")

local function approx_eq(a, b, eps)
    eps = eps or 0.5
    return math.abs(a - b) <= eps
end

-- ---------------------------------------------------------------------------
-- ticks_per_frame
-- ---------------------------------------------------------------------------

assert(M.ticks_per_frame(192000, 24, 1) == 8000,
    "tpf(192000,24/1) should be 8000")
assert(M.ticks_per_frame(192000, 24000, 1001) == 8008,
    "tpf(192000,24000/1001) should be 8008")
assert(M.ticks_per_frame(48000, 24, 1) == 2000,
    "tpf(48000,24/1) should be 2000")
assert(M.ticks_per_frame(192000, 60, 1) == 3200,
    "tpf(192000,60/1) should be 3200")

-- Invalid inputs: every NSF rule fires.
local function expect_assert(fn, expected_msg)
    local ok, err = pcall(fn)
    assert(not ok, "expected assert, got success")
    assert(type(err) == "string" and err:match(expected_msg),
        string.format("expected error to match %q, got %q", expected_msg, tostring(err)))
end

expect_assert(function() M.ticks_per_frame(0, 24, 1) end, "master_clock_hz")
expect_assert(function() M.ticks_per_frame(192000, 0, 1) end, "fps_num")
expect_assert(function() M.ticks_per_frame(192000, 24, 0) end, "fps_den")
expect_assert(function() M.ticks_per_frame(-1, 24, 1) end, "master_clock_hz")

-- ---------------------------------------------------------------------------
-- pack / unpack round-trip
-- ---------------------------------------------------------------------------

for _, tpf in ipairs({8000, 8008, 2000, 3200, 1}) do
    for _, frame in ipairs({0, 1, 100, 1000000}) do
        for _, sub in ipairs({0, 1, tpf - 1, math.floor(tpf / 2)}) do
            if sub >= 0 and sub < tpf then
                local total = M.pack(frame, sub, tpf)
                local rf, rs = M.unpack(total, tpf)
                assert(rf == frame and rs == sub, string.format(
                    "pack/unpack round-trip failed: (frame=%d, sub=%d, tpf=%d) → packed=%s → unpacked=(%s,%s)",
                    frame, sub, tpf, tostring(total), tostring(rf), tostring(rs)))
            end
        end
    end
end

-- pack rejects out-of-range subframe.
expect_assert(function() M.pack(5, 8000, 8000) end, "subframe")
expect_assert(function() M.pack(5, -1, 8000) end, "subframe")
expect_assert(function() M.pack(-1, 0, 8000) end, "frame")

-- ---------------------------------------------------------------------------
-- normalize: carries forward and backward correctly
-- ---------------------------------------------------------------------------

-- Forward carry: subframe == tpf should normalize to (frame+1, 0).
local f, s = M.normalize(5, 8000, 8000)
assert(f == 6 and s == 0,
    string.format("normalize(5, 8000, 8000) expected (6, 0), got (%d, %d)", f, s))

-- Forward carry: subframe == 2*tpf - 1 should normalize to (frame+1, tpf-1).
f, s = M.normalize(5, 15999, 8000)
assert(f == 6 and s == 7999,
    string.format("normalize(5, 15999, 8000) expected (6, 7999), got (%d, %d)", f, s))

-- Backward carry: subframe == -1 should normalize to (frame-1, tpf-1).
f, s = M.normalize(5, -1, 8000)
assert(f == 4 and s == 7999,
    string.format("normalize(5, -1, 8000) expected (4, 7999), got (%d, %d)", f, s))

-- Already canonical: passthrough.
f, s = M.normalize(5, 100, 8000)
assert(f == 5 and s == 100,
    string.format("normalize(5, 100, 8000) expected (5, 100), got (%d, %d)", f, s))

-- ---------------------------------------------------------------------------
-- samples_to_ticks / ticks_to_samples — divisor case is exact
-- ---------------------------------------------------------------------------

local divisor_grid = {
    {file_rate = 48000,  mch = 192000, factor = 4},   -- ticks = samples * 4
    {file_rate = 96000,  mch = 192000, factor = 2},
    {file_rate = 192000, mch = 192000, factor = 1},
    {file_rate = 24000,  mch = 192000, factor = 8},
}
for _, cell in ipairs(divisor_grid) do
    for _, samples in ipairs({0, 1, 100, 10000, 999999}) do
        local ticks = M.samples_to_ticks(samples, cell.file_rate, cell.mch)
        assert(ticks == samples * cell.factor, string.format(
            "samples_to_ticks(%d, %d, %d) expected %d, got %s",
            samples, cell.file_rate, cell.mch, samples * cell.factor, tostring(ticks)))
        local samples_back = M.ticks_to_samples(ticks, cell.file_rate, cell.mch)
        assert(samples_back == samples, string.format(
            "samples_to_ticks round-trip lost data: %d → %d → %d",
            samples, ticks, samples_back))
    end
end

-- Non-divisor case: bounded error.
-- 44100 / 192000 = 0.2296875 ticks per sample.
local s_in = 12345
local t = M.samples_to_ticks(s_in, 44100, 192000)
local s_out = M.ticks_to_samples(t, 44100, 192000)
assert(approx_eq(s_out, s_in, 1),
    string.format("44.1k round-trip should be within 1 sample: in=%d out=%d", s_in, s_out))

-- Invalid inputs.
expect_assert(function() M.samples_to_ticks(0, 0, 192000) end, "file_rate")
expect_assert(function() M.samples_to_ticks(0, 48000, 0) end, "master_clock_hz")
expect_assert(function() M.samples_to_ticks(-1, 48000, 192000) end, "samples")
expect_assert(function() M.ticks_to_samples(0, 0, 192000) end, "file_rate")
expect_assert(function() M.ticks_to_samples(-1, 48000, 192000) end, "ticks")

-- ---------------------------------------------------------------------------
-- is_canonical / assert_canonical
-- ---------------------------------------------------------------------------

assert(M.is_canonical(5, 0, 8000), "5,0,8000 should be canonical")
assert(M.is_canonical(5, 7999, 8000), "5,7999,8000 should be canonical")
assert(not M.is_canonical(5, -1, 8000), "5,-1,8000 should NOT be canonical")
assert(not M.is_canonical(5, 8000, 8000), "5,8000,8000 should NOT be canonical")

expect_assert(function() M.assert_canonical(5, -1, 8000, "test") end, "canonical")
expect_assert(function() M.assert_canonical(5, 8000, 8000, "test") end, "canonical")

-- Round-half-away-from-zero: enforce the FR-008 rule explicitly.
-- 1 sample @ 44.1k → 1 * 192000 / 44100 = 4.3537... → rounds to 4 (closer to 4).
-- 2 samples @ 44.1k → 2 * 192000 / 44100 = 8.7075... → rounds to 9.
local t1 = M.samples_to_ticks(1, 44100, 192000)
local t2 = M.samples_to_ticks(2, 44100, 192000)
assert(t1 == 4, "samples_to_ticks(1, 44100, 192000) expected 4, got " .. tostring(t1))
assert(t2 == 9, "samples_to_ticks(2, 44100, 192000) expected 9, got " .. tostring(t2))

print("✅ test_subframe_math.lua passed")
