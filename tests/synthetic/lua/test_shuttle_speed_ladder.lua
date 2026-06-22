-- Unit: FR-003 JKL shuttle speed ladder (spec 025).
--
-- DOMAIN RULE (FR-003): the shuttle speed ladder steps in 0.25 increments
-- from 1.0x to 2.0x, then in successive powers of two CAPPED at 32x (FCP7
-- convention). Above ~32x the decoder + clip prefetch cannot service the
-- playhead, so video starves (freezes/gaps) while audio and the position
-- counter keep running on their own threads — the cap keeps every reachable
-- rung playable:
--
--     1.0 → 1.25 → 1.5 → 1.75 → 2.0 → 4.0 → 8.0 → 16.0 → 32.0 (max)
--
-- Stepping DOWN reverses that ladder and, at 1.0x, signals STOP (the
-- opposite-direction key at 1x stops playback — it does not reverse).
--
-- The 0.5x slow-play (K+J / K+L) is OUTSIDE this ladder. Pressing a
-- same-direction shuttle key from 0.5x rejoins the ladder at its base
-- (1.0x); an opposite-direction key from 0.5x stops. Both preserve the
-- pre-025 slow-play exit behavior.
--
-- Expected values are derived from the FR-003 spec ladder, NOT from the
-- implementation. Pure module — no DB, no engine, no C++ controller.

require("test_env")
local ladder = require("core.playback.shuttle_ladder")

local function approx(a, b)
    return a ~= nil and b ~= nil and math.abs(a - b) < 1e-9
end

local function expect_assert(fn, label)
    local ok, err = pcall(fn)
    assert(not ok, label .. ": expected an assert, got success")
    err = tostring(err)
    assert(err:find("step_up") or err:find("step_down"),
        label .. ": error must name the function, got: " .. err)
end

print("=== test_shuttle_speed_ladder.lua ===")

-- ── Step UP across the whole ladder, then plateau at the 32x cap ─────────
do
    local seq = { 1.0, 1.25, 1.5, 1.75, 2.0, 4.0, 8.0, 16.0, 32.0 }
    for i = 1, #seq - 1 do
        local got = ladder.step_up(seq[i])
        assert(approx(got, seq[i + 1]), string.format(
            "step_up(%.2f) → expected %.2f, got %s",
            seq[i], seq[i + 1], tostring(got)))
    end
    print("  PASS: up ladder 1.0→1.25→1.5→1.75→2.0→4.0→8.0→16→32")
end

-- ── 32x is the ceiling: holding the shuttle key STAYS at 32x ─────────────
-- This is the regression for the freeze: an uncapped ladder climbed into
-- 64/128x where decode+prefetch starve and video locks up.
do
    assert(approx(ladder.step_up(16.0), 32.0), "step_up(16)→32 (last real rung)")
    assert(approx(ladder.step_up(32.0), 32.0), "step_up(32) must STAY 32 (ceiling)")
    print("  PASS: ladder caps at 32x — no climb past the playable ceiling")
end

-- ── Step DOWN reverses the ladder; 1.0 → stop (nil) ──────────────────────
do
    local seq = { 32.0, 16.0, 8.0, 4.0, 2.0, 1.75, 1.5, 1.25, 1.0 }
    for i = 1, #seq - 1 do
        local got = ladder.step_down(seq[i])
        assert(approx(got, seq[i + 1]), string.format(
            "step_down(%.2f) → expected %.2f, got %s",
            seq[i], seq[i + 1], tostring(got)))
    end
    assert(ladder.step_down(1.0) == nil,
        "step_down(1.0) must signal STOP (nil)")
    print("  PASS: down ladder 32→…→1.0→stop")
end

-- ── Non-trivial starting speeds (not just sequential walks) ──────────────
do
    assert(approx(ladder.step_up(1.5), 1.75), "step_up(1.5)→1.75")
    assert(approx(ladder.step_up(4.0), 8.0), "step_up(4.0)→8.0")
    assert(approx(ladder.step_up(2.0), 4.0), "step_up(2.0): 2.0→4.0 power-of-2 transition")
    assert(approx(ladder.step_down(8.0), 4.0), "step_down(8.0)→4.0")
    assert(approx(ladder.step_down(1.25), 1.0), "step_down(1.25)→1.0")
    assert(approx(ladder.step_down(2.0), 1.75), "step_down(2.0): power-of-2→quarter transition")
    print("  PASS: non-trivial 1.5 / 4.0 / 8.0 / 2.0 boundary transitions")
end

-- ── 0.5x slow-play exit rejoins ladder base / stops ──────────────────────
do
    assert(approx(ladder.step_up(0.5), 1.0),
        "step_up(0.5): same-direction from slow-play rejoins ladder at 1.0")
    assert(ladder.step_down(0.5) == nil,
        "step_down(0.5): opposite-direction from slow-play stops")
    print("  PASS: 0.5x slow-play exit → 1.0 (up) / stop (down)")
end

-- ── Assert paths: non-positive speed is an invariant violation ───────────
do
    expect_assert(function() ladder.step_up(0) end, "step_up(0)")
    expect_assert(function() ladder.step_up(-1) end, "step_up(-1)")
    expect_assert(function() ladder.step_down(0) end, "step_down(0)")
    expect_assert(function() ladder.step_down(-2) end, "step_down(-2)")
    print("  PASS: non-positive speed asserts with function name")
end

print("✅ test_shuttle_speed_ladder.lua passed")
