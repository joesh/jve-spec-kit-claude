-- core/subframe_math.lua — feature 018
--
-- Canonical sub-frame math primitive (FR-006, FR-007, FR-008).
-- The single source of truth for (frame, subframe) arithmetic and sample
-- conversion. Pure Lua, zero dependencies. Every function asserts on every
-- invalid input per FR-007 (no silent fallback, no silent clamp, no default).
--
-- See specs/018-uniform-clip-source/contracts/subframe_math.md for the full
-- contract.

local M = {}

-- Round half away from zero. Matches `round_int` in models/sequence.lua and
-- the convention used by the resolver — FR-008 single-rounding-rule policy.
-- Subframes and sample positions are always non-negative per FR-002 and
-- domain, so a non-negative-input fast path is the common case.
local function round_half_away_from_zero(x)
    if x >= 0 then return math.floor(x + 0.5) end
    return -math.floor(-x + 0.5)
end
-- Exposed for callers that need the canonical FR-008 rounding rule outside
-- the sample/tick conversions (e.g. SetProjectMasterClock's per-clip rescale).
M.round_half_away_from_zero = round_half_away_from_zero

local function assert_int(name, v)
    assert(type(v) == "number" and v == math.floor(v),
        string.format("subframe_math: %s must be an integer, got %s", name, tostring(v)))
end

local function assert_pos_int(name, v)
    assert_int(name, v)
    assert(v > 0,
        string.format("subframe_math: %s must be > 0, got %s", name, tostring(v)))
end

local function assert_nonneg_int(name, v)
    assert_int(name, v)
    assert(v >= 0,
        string.format("subframe_math: %s must be >= 0, got %s", name, tostring(v)))
end

-- ticks_per_frame: number of master-clock ticks in one frame of a sequence
-- with the given fps. Integer when master_clock_hz is divisible by fps_num.
function M.ticks_per_frame(master_clock_hz, fps_num, fps_den)
    assert_pos_int("master_clock_hz", master_clock_hz)
    assert_pos_int("fps_num", fps_num)
    assert_pos_int("fps_den", fps_den)
    return math.floor(master_clock_hz * fps_den / fps_num)
end

-- pack: (frame, subframe) → single total_ticks integer.
function M.pack(frame, subframe, ticks_per_frame)
    assert_nonneg_int("frame", frame)
    assert_nonneg_int("subframe", subframe)
    assert_pos_int("ticks_per_frame", ticks_per_frame)
    assert(subframe < ticks_per_frame, string.format(
        "subframe_math.pack: subframe (%d) must be < ticks_per_frame (%d)",
        subframe, ticks_per_frame))
    return frame * ticks_per_frame + subframe
end

-- unpack: inverse of pack. total_ticks → (frame, subframe).
function M.unpack(total_ticks, ticks_per_frame)
    assert_nonneg_int("total_ticks", total_ticks)
    assert_pos_int("ticks_per_frame", ticks_per_frame)
    local frame = math.floor(total_ticks / ticks_per_frame)
    local subframe = total_ticks - frame * ticks_per_frame
    return frame, subframe
end

-- normalize: canonicalize a possibly-out-of-range (frame, subframe) pair into
-- (frame', subframe') where 0 <= subframe' < ticks_per_frame. Handles both
-- forward and backward carry.
function M.normalize(frame, subframe, ticks_per_frame)
    assert_int("frame", frame)
    assert_int("subframe", subframe)
    assert_pos_int("ticks_per_frame", ticks_per_frame)
    local carry = math.floor(subframe / ticks_per_frame)
    local rem = subframe - carry * ticks_per_frame
    return frame + carry, rem
end

-- samples_to_ticks: file-natural sample position → master-clock ticks.
function M.samples_to_ticks(samples, file_rate, master_clock_hz)
    assert_nonneg_int("samples", samples)
    assert_pos_int("file_rate", file_rate)
    assert_pos_int("master_clock_hz", master_clock_hz)
    return round_half_away_from_zero(samples * master_clock_hz / file_rate)
end

-- ticks_to_samples: master-clock ticks → file-natural sample position.
function M.ticks_to_samples(ticks, file_rate, master_clock_hz)
    assert_nonneg_int("ticks", ticks)
    assert_pos_int("file_rate", file_rate)
    assert_pos_int("master_clock_hz", master_clock_hz)
    return round_half_away_from_zero(ticks * file_rate / master_clock_hz)
end

-- is_canonical: predicate. Returns true iff (frame, subframe) satisfies the
-- canonical-form invariant for the given ticks_per_frame.
function M.is_canonical(frame, subframe, ticks_per_frame)
    assert_pos_int("ticks_per_frame", ticks_per_frame)
    if type(frame) ~= "number" or frame ~= math.floor(frame) then return false end
    if type(subframe) ~= "number" or subframe ~= math.floor(subframe) then return false end
    return subframe >= 0 and subframe < ticks_per_frame
end

-- assert_canonical: tripwire variant. Fails loudly on violation with context.
function M.assert_canonical(frame, subframe, ticks_per_frame, ctx)
    assert(M.is_canonical(frame, subframe, ticks_per_frame), string.format(
        "subframe_math.assert_canonical: (frame=%s, subframe=%s, tpf=%d) not canonical [%s]",
        tostring(frame), tostring(subframe), ticks_per_frame, tostring(ctx)))
end

return M
