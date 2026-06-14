#!/usr/bin/env luajit

-- Reverse clip must cover the SAME source region as its forward twin.
--
-- Ground-truth fixture authored in DaVinci Resolve ("test audio, reverse
-- audio.drp"): one A/V clip placed twice on the timeline with an identical
-- trim — once forward (1x), once reversed (-100%). Because the trim is
-- identical and the reverse is exactly -100%, the reversed clip plays the
-- EXACT same source samples as the forward clip, last-sample-first.
--
-- This test takes the forward clip as the reference and derives what the
-- reverse clip MUST be — the expected reverse values are never hand-written,
-- they come from the forward clip's actual source range. This is the domain
-- truth ("reverse plays the same region backward"), not a re-derivation of
-- the importer's arithmetic.
--
-- Convention (mirrors forward's inclusive-low / exclusive-high):
--   forward: source_in = first played sample (low, inclusive)
--            source_out = last played + 1 sample (high, exclusive)
--   reverse: source_in = highest played sample (inclusive, = playback entry)
--                      = forward.source_out - 1
--            source_out = lowest played - 1 sample (exclusive lower bound)
--                      = forward.source_in - 1
--   |reverse span| == |forward span|  (a -100% reverse covers the same width)
--
-- Regression: the importer's retime-curve branch computed the reverse source
-- span one frame short (out_frame is the inclusive high for reverse, but was
-- counted as if exclusive), so the reverse clip dropped its first played
-- frame. Forward span here is 66000 samples (33 frames @ 48k/24fps); the bug
-- produced a 64000-sample (32-frame) reverse span.

require("test_env")

local drp = require("importers.drp_importer")

print("=== integration_test_drp_reverse_audio_pair.lua ===")

-- Fixture lives at tests/fixtures/resolve/, two dirs up from this script
-- (tests/synthetic/lua/). Compute from the script location so cwd doesn't
-- matter (the start_timecode test's script-relative path was wrong).
local script_dir = debug.getinfo(1, "S").source:match("@(.*/)")
assert(script_dir, "could not determine script dir")
local DRP_PATH = script_dir .. "../../fixtures/resolve/test audio, reverse audio.drp"

local result = drp.parse_drp_file(DRP_PATH)
assert(result, "parse_drp_file should succeed for " .. DRP_PATH)

-- Collect every clip across all timelines/tracks, split by direction.
local forward, reverse
for _, tl in ipairs(result.timelines or {}) do
    for _, tr in ipairs(tl.tracks or {}) do
        for _, c in ipairs(tr.clips or {}) do
            assert(c.source_in and c.source_out and c.clip_speed,
                "clip missing source_in/source_out/clip_speed")
            if c.clip_speed > 0 then
                assert(not forward, "expected exactly one forward clip")
                forward = c
            elseif c.clip_speed < 0 then
                assert(not reverse, "expected exactly one reverse clip")
                reverse = c
            end
        end
    end
end
assert(forward, "no forward clip (clip_speed > 0) found in fixture")
assert(reverse, "no reverse clip (clip_speed < 0) found in fixture")

print(string.format("  forward: source_in=%d source_out=%d span=%d speed=%.3f",
    forward.source_in, forward.source_out,
    forward.source_out - forward.source_in, forward.clip_speed))
print(string.format("  reverse: source_in=%d source_out=%d span=%d speed=%.3f",
    reverse.source_in, reverse.source_out,
    reverse.source_in - reverse.source_out, reverse.clip_speed))

-- ── Forward sanity: it is a normal forward clip ──────────────────────────
assert(forward.source_in < forward.source_out, string.format(
    "forward clip must have source_in < source_out, got %d / %d",
    forward.source_in, forward.source_out))
local forward_span = forward.source_out - forward.source_in
assert(forward_span > 0, "forward span must be positive")

-- ── Reverse direction marked ─────────────────────────────────────────────
assert(reverse.source_in > reverse.source_out, string.format(
    "reverse clip must have source_in > source_out (reverse convention), got %d / %d",
    reverse.source_in, reverse.source_out))

-- ── Reverse covers the SAME region as forward, backward ──────────────────
-- Expected values DERIVED from the forward clip, not hand-written.
local expected_rev_source_in  = forward.source_out - 1  -- highest played sample (inclusive)
local expected_rev_source_out = forward.source_in  - 1  -- exclusive lower bound

assert(reverse.source_in == expected_rev_source_in, string.format(
    "reverse source_in must be forward.source_out-1 (%d) = highest played sample; got %d "
    .. "(off-by-one: reverse dropped its first played frame)",
    expected_rev_source_in, reverse.source_in))
assert(reverse.source_out == expected_rev_source_out, string.format(
    "reverse source_out must be forward.source_in-1 (%d) = exclusive lower bound; got %d",
    expected_rev_source_out, reverse.source_out))

-- ── Span equality: a -100% reverse spans the same width as forward ───────
local reverse_span = reverse.source_in - reverse.source_out
assert(reverse_span == forward_span, string.format(
    "reverse span (%d) must equal forward span (%d) for a -100%% reverse",
    reverse_span, forward_span))

print(string.format(
    "  ✓ reverse covers same region backward: [%d..%d] (%d samples), matching forward",
    reverse.source_out + 1, reverse.source_in, reverse_span))

print("\n✅ integration_test_drp_reverse_audio_pair.lua passed")
