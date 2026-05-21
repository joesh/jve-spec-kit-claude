#!/usr/bin/env luajit
--- Clip.compute_trim_duration — canonical owner-timebase duration math
--- for edge-trim commands. Pinned in isolation because three call sites
--- (OverwriteTrimEdge.compute_trim, SetMarkAndTrimIfClip.dispatch_live_bound
--- precheck, batch_ripple_edit.compute_{in,out}_edge_trim) all derive
--- their new-duration value here. Drift between the precheck and the
--- mutation arithmetic would produce a class of "SetMark accepts, trim
--- rejects" bugs.

package.path = package.path .. ";src/lua/?.lua;tests/?.lua"
require("test_env")

print("=== test_clip_compute_trim_duration.lua ===")

local Clip = require("models.clip")

-- Fixtures: forward and reverse clips at 1:1 mapping. The helper reads
-- direction from clip.source_in vs clip.source_out.
local function forward(d) return { source_in=100, source_out=200, duration=d or 100 } end
local function reverse(d) return { source_in=200, source_out=100, duration=d or 100 } end

-- Forward clip, left/in edge: head moves → new_duration = current - delta.
do
    assert(Clip.compute_trim_duration(forward(), "left", 25) == 75,
        "fwd left shrink: 100 - 25 = 75")
    assert(Clip.compute_trim_duration(forward(), "in", 25) == 75,
        "in edge synonym matches left edge")
    assert(Clip.compute_trim_duration(forward(), "left", -25) == 125,
        "fwd left grow (negative delta): 100 - (-25) = 125")
    print("  ✓ forward + left/in: duration - delta")
end

-- Forward clip, right/out edge: tail moves → new_duration = current + delta.
do
    assert(Clip.compute_trim_duration(forward(), "right", 25) == 125,
        "fwd right grow: 100 + 25 = 125")
    assert(Clip.compute_trim_duration(forward(), "out", 25) == 125,
        "out edge synonym matches right edge")
    assert(Clip.compute_trim_duration(forward(), "right", -25) == 75,
        "fwd right shrink: 100 + (-25) = 75")
    print("  ✓ forward + right/out: duration + delta")
end

-- Reverse clip (source_in > source_out): the trim direction inverts
-- because pushing source_in HIGHER means more source content ahead of
-- the playback head, growing the clip. Symmetric for source_out.
do
    -- Reverse left edge: pressing IN at a HIGHER source frame extends head.
    assert(Clip.compute_trim_duration(reverse(), "left", 25) == 125, string.format(
        "rev left delta=+25: expected 125 (clip grows when src_in pushed higher); got %s",
        tostring(Clip.compute_trim_duration(reverse(), "left", 25))))
    assert(Clip.compute_trim_duration(reverse(), "in", 25) == 125,
        "rev in synonym matches rev left")
    assert(Clip.compute_trim_duration(reverse(), "left", -25) == 75,
        "rev left delta=-25 shrinks (75)")
    print("  ✓ reverse + left/in: duration + delta (inverted sign)")
end

do
    -- Reverse right edge: pressing OUT at a HIGHER source frame shrinks
    -- (less source between the new tail and the unchanged head).
    assert(Clip.compute_trim_duration(reverse(), "right", 25) == 75, string.format(
        "rev right delta=+25: expected 75 (tail moves toward head); got %s",
        tostring(Clip.compute_trim_duration(reverse(), "right", 25))))
    assert(Clip.compute_trim_duration(reverse(), "right", -25) == 125,
        "rev right delta=-25 grows tail (125)")
    print("  ✓ reverse + right/out: duration - delta (inverted sign)")
end

-- Direction comes from source_in vs source_out. Same delta, different
-- direction → different result.
do
    local fwd_result = Clip.compute_trim_duration(forward(), "left", 25)
    local rev_result = Clip.compute_trim_duration(reverse(), "left", 25)
    assert(fwd_result ~= rev_result, string.format(
        "direction must influence the result; forward=%d reverse=%d",
        fwd_result, rev_result))
    assert(fwd_result + rev_result == 2 * forward().duration, string.format(
        "forward and reverse results are mirror-symmetric around current_duration; "
        .. "got fwd+rev=%d expected 2*duration=%d",
        fwd_result + rev_result, 2 * forward().duration))
    print("  ✓ direction-sensitive: forward and reverse mirror around current_duration")
end

-- The collapse / invert cases are NOT clamped here — the helper returns
-- the raw arithmetic so callers can decide what to do (precheck-reject
-- vs. model-assert backstop).
do
    assert(Clip.compute_trim_duration(forward(), "left", 100) == 0,
        "fwd left delta == duration yields 0 (collapse — caller decides)")
    assert(Clip.compute_trim_duration(forward(), "left", 150) == -50,
        "fwd left delta > duration yields negative (caller decides)")
    assert(Clip.compute_trim_duration(reverse(), "left", -100) == 0,
        "rev left delta == -duration yields 0 (collapse)")
    print("  ✓ helper returns raw arithmetic; collapse/invert is caller's call")
end

-- Unknown edges fail loudly (1.14 fail-fast).
do
    local ok = pcall(Clip.compute_trim_duration, forward(), "bogus", 10)
    assert(not ok, "unknown edge must assert")
    ok = pcall(Clip.compute_trim_duration, forward(), nil, 10)
    assert(not ok, "nil edge must assert")
    ok = pcall(Clip.compute_trim_duration, forward(), "", 10)
    assert(not ok, "empty-string edge must assert")
    print("  ✓ unknown / nil / empty edge values reject loudly")
end

-- Type-check args.
do
    local ok = pcall(Clip.compute_trim_duration, { source_in=0, source_out=10, duration="100" }, "left", 10)
    assert(not ok, "non-number clip.duration must assert")
    ok = pcall(Clip.compute_trim_duration, forward(), "left", "10")
    assert(not ok, "non-number delta must assert")
    ok = pcall(Clip.compute_trim_duration, { source_in=0, source_out=0, duration=100 }, "left", 10)
    assert(not ok, "source_in == source_out (zero-direction) must assert")
    -- Mismatched nil: only one of source_in/out is nil — undefined state.
    ok = pcall(Clip.compute_trim_duration, { source_in=0, source_out=nil, duration=100 }, "left", 10)
    assert(not ok, "source_out nil but source_in non-nil must assert (gap-state ambiguity)")
    print("  ✓ non-number args + zero-direction + half-nil reject loudly")
end

-- Gap clips: source_in and source_out are both nil (synthesized
-- in-memory gap from gap_lifecycle.lua). No source direction; trims as
-- pure timeline arithmetic with forward sign. The ripple commands hit
-- this path when computing trim on a selected gap edge.
do
    local gap = { source_in = nil, source_out = nil, duration = 80, is_gap = true }
    assert(Clip.compute_trim_duration(gap, "left", 25) == 55,
        "gap left: 80 - 25 = 55 (forward arithmetic)")
    assert(Clip.compute_trim_duration(gap, "right", 25) == 105,
        "gap right: 80 + 25 = 105 (forward arithmetic)")
    print("  ✓ gap clip (both source bounds nil): forward arithmetic")
end

print("\n✅ test_clip_compute_trim_duration.lua passed")
