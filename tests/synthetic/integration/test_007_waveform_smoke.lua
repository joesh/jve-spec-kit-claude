-- 007 smoke: visible_source_range maps clip on-screen pixels to source samples.
--
-- Acceptance: the waveform renderer maps a clip rectangle to a source-sample
-- range so the PEAK_QUERY can fill pixel columns aligned to the clip body.
-- The math is pure data; deeper rendering is covered by
-- tests/synthetic/integration/test_waveform_end_to_end.lua.

local ienv = require("synthetic.integration.integration_test_env")
ienv.require_emp()

print("=== test_007_waveform_smoke.lua ===")

require("test_env")
local waveform_utils = require("core.media.waveform_utils")

-- A 1-second audio clip at 48 kHz: source_in=0, source_out=48000.
-- Render it across a 200-pixel-wide clip rectangle. The leftmost pixel
-- maps to sample 0; rightmost to sample 48000.
local source_in, source_out = 0, 48000
local clip_width, draw_width = 200, 200

-- Full visible: x=0, visible_x=0, clip_width=200, draw_width=200.
-- Whole 1-second / 48k-sample clip visible.
local left_in, left_out =
    waveform_utils.visible_source_range(source_in, source_out, 0, 0, clip_width, draw_width)
assert(left_in == 0 and left_out == 48000, string.format(
    "fully visible clip must map to [0, 48000); got [%d, %d)", left_in, left_out))
print(string.format("  PASS: full visible → [%d, %d) samples", left_in, left_out))

-- Right half visible: clip starts at x=0 with clip_width=200, but only the
-- pixels [100, 200) are on-screen — visible_x=100, draw_width=100.
local right_in, right_out =
    waveform_utils.visible_source_range(source_in, source_out,
        0, 100, clip_width, 100)
assert(math.abs(right_in - 24000) < 100, string.format(
    "right-half left bound should be near sample 24000; got %d", right_in))
assert(math.abs(right_out - 48000) < 100, string.format(
    "right-half right bound should be near sample 48000; got %d", right_out))
print(string.format("  PASS: right half → [%d, %d) samples", right_in, right_out))

print("\n✅ test_007_waveform_smoke.lua passed")
