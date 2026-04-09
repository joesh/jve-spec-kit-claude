require("test_env")
local waveform_utils = require("core.media.waveform_utils")

print("--- test_waveform_viewport_clipping.lua ---")

-- Tests for waveform_utils.visible_source_range — the function the renderer
-- uses to compute which source samples are visible when a clip is partially
-- clipped by the viewport edges.

-- ============================================================================
-- Test 1: Fully visible clip — no clipping, output equals input
-- ============================================================================
print("  test 1: fully visible clip")
local si, so = waveform_utils.visible_source_range(4608000, 5088000, 200, 200, 400, 400)
assert(si == 4608000, "fully visible: source_in unchanged, got " .. si)
assert(so == 5088000, "fully visible: source_out unchanged, got " .. so)
print("    OK")

-- ============================================================================
-- Test 2: Clip extends past LEFT edge
-- ============================================================================
print("  test 2: clip extends past left edge")
-- x=-300, visible_x=0, clip_width=1000, draw_width=700
-- 300px clipped left. spp = 480000/1000 = 480. left_clip = 300*480 = 144000
local si2, so2 = waveform_utils.visible_source_range(4608000, 5088000, -300, 0, 1000, 700)
assert(si2 == 4752000, "left clip: visible_source_in expected 4752000 got " .. si2)
assert(so2 == 5088000, "left clip: visible_source_out expected 5088000 got " .. so2)
print("    OK")

-- ============================================================================
-- Test 3: Clip extends past RIGHT edge
-- ============================================================================
print("  test 3: clip extends past right edge")
-- x=1500, visible_x=1500, clip_width=1000, draw_width=420
-- 580px clipped right. spp=480. right_clip=580*480=278400
local si3, so3 = waveform_utils.visible_source_range(4608000, 5088000, 1500, 1500, 1000, 420)
assert(si3 == 4608000, "right clip: source_in expected 4608000 got " .. si3)
assert(so3 == 4809600, "right clip: source_out expected 4809600 got " .. so3)
print("    OK")

-- ============================================================================
-- Test 4: Clip extends past BOTH edges (long clip scrolled)
-- ============================================================================
print("  test 4: clip extends past both edges")
-- x=-5000, visible_x=0, clip_width=12000, draw_width=1920
-- spp = 5760000/12000 = 480
-- left_clip=5000*480=2400000, right_clip=5080*480=2438400
local si4, so4 = waveform_utils.visible_source_range(0, 5760000, -5000, 0, 12000, 1920)
assert(si4 == 2400000, "both clip: source_in expected 2400000 got " .. si4)
assert(so4 == 3321600, "both clip: source_out expected 3321600 got " .. so4)
print("    OK")

-- ============================================================================
-- Test 5: Scroll right shifts visible range by exact pixel amount
-- ============================================================================
print("  test 5: scroll shifts visible range")
-- Same clip scrolled 500px right: x=-5500
local si5, so5 = waveform_utils.visible_source_range(0, 5760000, -5500, 0, 12000, 1920)
assert(si5 == 2640000, "scroll: source_in expected 2640000 got " .. si5)
assert(so5 == 3561600, "scroll: source_out expected 3561600 got " .. so5)
-- Shift must equal 500px * 480spp = 240000
assert(si5 - si4 == 240000, "scroll shift_in expected 240000 got " .. (si5 - si4))
assert(so5 - so4 == 240000, "scroll shift_out expected 240000 got " .. (so5 - so4))
print("    OK")

-- ============================================================================
-- Test 6: Non-trivial absolute TC source_in (01:00:00:00 at 48kHz)
-- ============================================================================
print("  test 6: absolute TC offset")
-- source_in=172800000. Clip at x=-100, clip_width=800, visible_x=0, draw_width=700
-- spp=480000/800=600. left_clip=100*600=60000
local si6, so6 = waveform_utils.visible_source_range(172800000, 173280000, -100, 0, 800, 700)
assert(si6 == 172860000, "TC: source_in expected 172860000 got " .. si6)
assert(so6 == 173280000, "TC: source_out expected 173280000 got " .. so6)
print("    OK")

-- ============================================================================
-- Test 7: 1px visible sliver
-- ============================================================================
print("  test 7: 1px visible sliver")
-- x=-999, clip_width=1000, visible_x=0, draw_width=1
-- spp=480000/1000=480. left_clip=999*480=479520
local si7, so7 = waveform_utils.visible_source_range(0, 480000, -999, 0, 1000, 1)
assert(si7 == 479520, "sliver: source_in expected 479520 got " .. si7)
assert(so7 == 480000, "sliver: source_out expected 480000 got " .. so7)
print("    OK")

-- ============================================================================
-- Test 8: Visible range is DIFFERENT from full range when clipped
-- This is the key invariant — if this passes with the naive (broken)
-- implementation that ignores clipping, the test suite is worthless.
-- ============================================================================
print("  test 8: clipped range differs from full range")
local full_si, full_so = waveform_utils.visible_source_range(0, 5760000, -5000, 0, 12000, 1920)
-- A naive implementation would return (0, 5760000) — the full source range
assert(full_si ~= 0, "CRITICAL: clipped source_in must differ from full source_in")
assert(full_so ~= 5760000, "CRITICAL: clipped source_out must differ from full source_out")
-- The visible range must be strictly smaller than the full range
assert(full_so - full_si < 5760000, "visible range must be smaller than full range")
print("    OK")

-- ============================================================================
-- Test 9: Input validation
-- ============================================================================
print("  test 9: input validation")
local ok1, _ = pcall(waveform_utils.visible_source_range, 100, 50, 0, 0, 100, 100)
assert(not ok1, "source_out <= source_in should fail")

local ok2, _ = pcall(waveform_utils.visible_source_range, 0, 100, 0, 0, 0, 100)
assert(not ok2, "clip_width=0 should fail")

local ok3, _ = pcall(waveform_utils.visible_source_range, 0, 100, 0, 0, 100, 0)
assert(not ok3, "draw_width=0 should fail")
print("    OK")

print("✅ test_waveform_viewport_clipping.lua passed")
