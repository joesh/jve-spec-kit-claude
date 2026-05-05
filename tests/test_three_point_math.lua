#!/usr/bin/env luajit

-- T023 (015) — FR-036, FR-037, FR-038: 3-point edit math + ghost mark.
--
-- Domain: given any 3 of (src_in, src_out, rec_in, rec_out), the 4th is computed.
-- The computed mark appears as a dashed "ghost" mark labeled "(computed)" on the
-- appropriate ruler. Rate mismatch is handled via the sequence fps fields.
--
-- Pure-Lua coverage: math correctness for all 4 combos, rate-mismatch case.
-- UI coverage (ghost-mark rendering, "(computed)" label in inspector/status bar,
-- mark persistence across SourceTab switch) requires --test mode: see T044.
--
-- Rate fixture: source=25fps, record=24fps.
--   src duration 150 frames at 25fps = 6.0 s → 144 frames at 24fps.
--   Non-trivial src_in=100 avoids the trivial zero case.
--
-- Expected FAIL today: core.three_point_math module not found (T044 not applied).

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require("test_env")

print("=== test_three_point_math.lua ===")

-- FAIL here if T044 not applied.
local tpm = require("core.three_point_math")

-- ── Rate helpers ──────────────────────────────────────────────────────────────
-- Convert src_frames (at 25fps) to rec_frames (at 24fps) without sub-frame error.
-- 25fps → 24fps: multiply by 24, divide by 25 (exact for multiples of 25).
local SRC_NUM, SRC_DEN = 25, 1
local REC_NUM, REC_DEN = 24, 1

-- The function under test: tpm.compute(marks, src_fps, rec_fps) → computed_mark_table.
-- marks = { src_in, src_out, rec_in, rec_out } with exactly one nil value.
-- Returns { src_in, src_out, rec_in, rec_out, computed_key } where computed_key names
-- the field that was computed (so the UI can render it as the ghost mark).

local function compute(marks)
    return tpm.compute(marks, {SRC_NUM, SRC_DEN}, {REC_NUM, REC_DEN})
end

-- ── Case A: src_in, src_out, rec_in given → compute rec_out ──────────────────
print("-- Case A: compute rec_out --")
do
    local src_in, src_out, rec_in = 100, 250, 480
    -- Duration: 150 src frames = 6.0 s. At 24fps: 6.0 * 24 = 144 frames.
    local expected_rec_out = rec_in + 144   -- 624

    local result = compute({ src_in=src_in, src_out=src_out, rec_in=rec_in })
    assert(result, "tpm.compute returned nil for Case A")
    assert(result.computed_key == "rec_out", string.format(
        "Case A: computed_key='%s', expected 'rec_out'", tostring(result.computed_key)))
    assert(result.rec_out == expected_rec_out, string.format(
        "Case A: rec_out=%s, expected %d (src_in=%d src_out=%d rec_in=%d)",
        tostring(result.rec_out), expected_rec_out, src_in, src_out, rec_in))
    print(string.format("  rec_out=%d (expected %d) — OK", result.rec_out, expected_rec_out))
end

-- ── Case B: src_in, src_out, rec_out given → compute rec_in ──────────────────
print("-- Case B: compute rec_in --")
do
    local src_in, src_out, rec_out = 100, 250, 624
    local expected_rec_in = rec_out - 144   -- 480

    local result = compute({ src_in=src_in, src_out=src_out, rec_out=rec_out })
    assert(result, "tpm.compute returned nil for Case B")
    assert(result.computed_key == "rec_in", string.format(
        "Case B: computed_key='%s', expected 'rec_in'", tostring(result.computed_key)))
    assert(result.rec_in == expected_rec_in, string.format(
        "Case B: rec_in=%s, expected %d", tostring(result.rec_in), expected_rec_in))
    print(string.format("  rec_in=%d (expected %d) — OK", result.rec_in, expected_rec_in))
end

-- ── Case C: rec_in, rec_out, src_in given → compute src_out ──────────────────
print("-- Case C: compute src_out --")
do
    local rec_in, rec_out, src_in = 480, 624, 100
    -- Duration: 144 rec frames = 6.0 s. At 25fps: 6.0 * 25 = 150 frames.
    local expected_src_out = src_in + 150   -- 250

    local result = compute({ rec_in=rec_in, rec_out=rec_out, src_in=src_in })
    assert(result, "tpm.compute returned nil for Case C")
    assert(result.computed_key == "src_out", string.format(
        "Case C: computed_key='%s', expected 'src_out'", tostring(result.computed_key)))
    assert(result.src_out == expected_src_out, string.format(
        "Case C: src_out=%s, expected %d", tostring(result.src_out), expected_src_out))
    print(string.format("  src_out=%d (expected %d) — OK", result.src_out, expected_src_out))
end

-- ── Case D: rec_in, rec_out, src_out given → compute src_in ──────────────────
print("-- Case D: compute src_in --")
do
    local rec_in, rec_out, src_out = 480, 624, 250
    local expected_src_in = src_out - 150   -- 100

    local result = compute({ rec_in=rec_in, rec_out=rec_out, src_out=src_out })
    assert(result, "tpm.compute returned nil for Case D")
    assert(result.computed_key == "src_in", string.format(
        "Case D: computed_key='%s', expected 'src_in'", tostring(result.computed_key)))
    assert(result.src_in == expected_src_in, string.format(
        "Case D: src_in=%s, expected %d", tostring(result.src_in), expected_src_in))
    print(string.format("  src_in=%d (expected %d) — OK", result.src_in, expected_src_in))
end

-- ── Round-trip consistency: A then C must be inverses ────────────────────────
print("-- Round-trip A→C --")
do
    local a = compute({ src_in=100, src_out=250, rec_in=480 })
    local c = compute({ rec_in=480, rec_out=a.rec_out, src_in=100 })
    assert(c.src_out == 250, string.format(
        "Round-trip: A→C src_out=%d, expected 250", tostring(c.src_out)))
    print(string.format("  round-trip A→C: src_out=%d — OK", c.src_out))
end

-- ── Reject zero-duration source range ────────────────────────────────────────
print("-- zero-duration source rejected --")
do
    local ok, err = pcall(compute, { src_in=100, src_out=100, rec_in=480 })
    assert(not ok, "FAIL: zero-duration src range must be rejected")
    print("  zero-duration rejected — OK")
end

-- ── Reject zero-duration record range ────────────────────────────────────────
print("-- zero-duration record rejected --")
do
    local ok = pcall(compute, { rec_in=480, rec_out=480, src_in=100 })
    assert(not ok, "FAIL: zero-duration rec range must be rejected")
    print("  zero-duration rejected — OK")
end

-- ── Reject all-four-marks-given (no computation needed) ──────────────────────
print("-- all four marks given (no nil) rejected --")
do
    local ok = pcall(compute, { src_in=100, src_out=250, rec_in=480, rec_out=624 })
    assert(not ok, "FAIL: all-four-marks case must be rejected (no ghost mark needed)")
    print("  all-four-marks rejected — OK")
end

-- ── Reject fewer-than-three marks ────────────────────────────────────────────
print("-- fewer than three marks rejected --")
do
    local ok = pcall(compute, { src_in=100, rec_in=480 })
    assert(not ok, "FAIL: two-marks case must be rejected")
    print("  two-marks rejected — OK")
end

-- NOTE: ghost-mark rendering ("(computed)" label, dashed style, sequence-ruler
-- placement) and mark persistence across SourceTab switch require --test mode.
-- Those assertions live in the T044 implementation test.

print("\n✅ test_three_point_math.lua passed")
