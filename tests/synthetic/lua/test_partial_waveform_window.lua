#!/usr/bin/env luajit
--- partial_waveform_window: maps a clamped peak-query result to the
--- on-screen sub-rectangle the waveform should occupy. The unwritten
--- tail of an in-progress peak file must NOT be filled by stretching;
--- it must remain blank and reveal left-to-right (forward clips) or
--- right-to-left (reverse clips) as peak generation advances.
---
--- Domain symptom (reported 2026-06-07): "Peak generator displays
--- wrong when the peaks are being written. Seems to stretch the peaks
--- to fit so they march along as the file gets added to. Should just
--- not show the end and it should reveal as writes continue."

require("test_env")

print("=== test_partial_waveform_window.lua ===")

local wu = require("core.media.waveform_utils")

-- (1) Full coverage: actual range == requested range → window unchanged.
do
    local x, w = wu.partial_waveform_window(
        1000, 2000,    -- requested source range
        1000, 2000,    -- actual covered (full)
        50, 400,       -- visible_x, draw_width
        false)
    assert(x == 50 and w == 400, string.format(
        "Full coverage must return the input window unchanged; got x=%d w=%d", x, w))
    print("  ✓ full coverage → window unchanged")
end

-- (2) Forward clip, 30% generated: waveform fills leftmost 30% of pixels.
do
    -- requested 1000..2000 (1000 samples); actual 1000..1300 (300 samples = 30%).
    local x, w = wu.partial_waveform_window(
        1000, 2000,
        1000, 1300,
        50, 400,
        false)
    -- 30% of 400 = 120 pixels.
    assert(x == 50, string.format(
        "Forward partial: x must anchor at visible_x (left edge), reveal "
        .. "extends right as generation advances; got x=%d", x))
    assert(w == 120, string.format(
        "Forward partial 30%% of 400-wide window must be 120 px; got w=%d", w))
    print("  ✓ forward 30% → leftmost 120 px")
end

-- (3) Reverse clip, 30% generated: waveform fills rightmost 30% of pixels.
do
    local x, w = wu.partial_waveform_window(
        1000, 2000,    -- normalized forward range (caller already swapped)
        1000, 1300,
        50, 400,
        true)
    -- Rightmost 120 px: x = 50 + (400 - 120) = 330.
    assert(x == 330, string.format(
        "Reverse partial: x must anchor at the right side of the visible "
        .. "window so the partial waveform appears at the right edge; got x=%d", x))
    assert(w == 120, string.format(
        "Reverse partial width must be 120 px (30%% of 400); got w=%d", w))
    print("  ✓ reverse 30% → rightmost 120 px")
end

-- (4) Tiny coverage clamps to >= 1 px so the waveform is at least visible.
do
    local x, w = wu.partial_waveform_window(
        1000, 2000,
        1000, 1001,    -- 0.1% — would round to 0 px
        50, 400,
        false)
    assert(w >= 1, string.format(
        "Sub-pixel partial must clamp width to >= 1 px (visible reveal); got w=%d", w))
    assert(x == 50, string.format(
        "Sub-pixel forward partial must anchor at visible_x (50); got %d", x))
    print("  ✓ sub-pixel coverage clamped to >= 1 px")
end

-- (5) Near-full coverage that rounds to draw_width returns the full window.
-- (Otherwise the partial path would clip the final pixel of an otherwise-
-- complete waveform — visually identical to a 1-pixel gap on completion.)
do
    local x, w = wu.partial_waveform_window(
        1000, 2000,
        1000, 1999,    -- 99.9%
        50, 400,
        false)
    -- 99.9% of 400 = 399.6 → rounds to 400, which equals draw_width: return full.
    assert(x == 50 and w == 400, string.format(
        "Rounded-up near-full coverage must collapse to the full window so "
        .. "there's no 1-pixel gap at completion; got x=%d w=%d", x, w))
    print("  ✓ near-full coverage → full window (no edge gap)")
end

print("\n✅ test_partial_waveform_window.lua passed")
