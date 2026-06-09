#!/usr/bin/env luajit
--- Newly-created sequences must default video_scroll_offset to the
--- UNINITIALIZED sentinel so the first-open viewport positions V1 (the
--- bottom-anchored video track) fully visible at the bottom — not V_n
--- at the top.
---
--- Domain symptom (reported 2026-06-07): "When first opened in a
--- timeline, the sequence should be vert scrolled so V1 and A1 are
--- fully visible. Right now V1 isn't."
---
--- Root cause: Sequence.create wrote `video_scroll_offset = 0` (a
--- fallback `or 0` on the opts value), bypassing the schema's `-1`
--- sentinel that compute_initial_scroll_target translates into
--- SCROLL_PAST_MAX → Qt clamps to viewport-bottom → V1 visible.
---
--- Contract: when the caller doesn't supply video_scroll_offset,
--- Sequence.create must store the UNINITIALIZED sentinel; explicit
--- caller-supplied values (including 0 — meaning "user scrolled to the
--- top") still pass through unchanged.

require("test_env")

print("=== test_sequence_create_video_scroll_sentinel.lua ===")

local Sequence = require("models.sequence")
local metrics  = require("ui.timeline.timeline_panel_metrics")

local function make(opts)
    opts = opts or {}
    opts.kind = opts.kind or "sequence"
    if opts.kind == "sequence" and opts.audio_sample_rate == nil then
        opts.audio_sample_rate = 48000
    end
    return Sequence.create("S", "p", { fps_numerator = 24, fps_denominator = 1 },
        1920, 1080, opts)
end

-- (1) No caller-supplied scroll → sentinel default.
local s = make()
assert(s.video_scroll_offset == metrics.UNINITIALIZED_SCROLL_OFFSET, string.format(
    "Sequence.create with no video_scroll_offset must default to the "
    .. "UNINITIALIZED sentinel (%d) so first-open positions V1 at the "
    .. "bottom of the viewport; got %s.",
    metrics.UNINITIALIZED_SCROLL_OFFSET, tostring(s.video_scroll_offset)))
print("  ✓ unsupplied → sentinel")

-- (2) Explicit 0 ("user scrolled to top") passes through unchanged.
local s_top = make({ video_scroll_offset = 0 })
assert(s_top.video_scroll_offset == 0, string.format(
    "Sequence.create with explicit video_scroll_offset=0 (user scrolled "
    .. "to top) must store 0, not the sentinel; got %s.",
    tostring(s_top.video_scroll_offset)))
print("  ✓ explicit 0 preserved")

-- (3) Explicit non-zero passes through unchanged.
local s_mid = make({ video_scroll_offset = 250 })
assert(s_mid.video_scroll_offset == 250, string.format(
    "Sequence.create with explicit video_scroll_offset=250 must store "
    .. "250 verbatim; got %s.", tostring(s_mid.video_scroll_offset)))
print("  ✓ explicit non-zero preserved")

print("\n✅ test_sequence_create_video_scroll_sentinel.lua passed")
