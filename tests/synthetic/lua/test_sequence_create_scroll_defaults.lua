#!/usr/bin/env luajit
--- Newly-created sequences must default both scroll offsets to 0 in
--- the anchored coordinate system (single-owner scroll redesign,
--- 2026-06-09): video offset = pixels from the content BOTTOM, audio
--- offset = pixels from the TOP. So 0/0 means "V1 and A1 fully
--- visible" — the first-open framing every NLE shows.
---
--- Domain symptom this guards (reported 2026-06-07): "When first
--- opened in a timeline, the sequence should be vert scrolled so V1
--- and A1 are fully visible." Bottom-anchored video coordinates make
--- that the structural meaning of the default — no sentinel
--- translation step to get wrong.
---
--- Contract: when the caller doesn't supply offsets, Sequence.create
--- stores 0; explicit caller-supplied values pass through verbatim.

require("test_env")

print("=== test_sequence_create_scroll_defaults.lua ===")

local Sequence = require("models.sequence")

local function make(opts)
    opts = opts or {}
    opts.kind = opts.kind or "sequence"
    if opts.kind == "sequence" and opts.audio_sample_rate == nil then
        opts.audio_sample_rate = 48000
    end
    return Sequence.create("S", "p", { fps_numerator = 24, fps_denominator = 1 },
        1920, 1080, opts)
end

-- (1) No caller-supplied scroll → anchored home position (V1/A1 visible).
local s = make()
assert(s.video_scroll_offset == 0, string.format(
    "Sequence.create with no video_scroll_offset must default to 0 "
    .. "(bottom-anchored: V1 fully visible on first open); got %s.",
    tostring(s.video_scroll_offset)))
assert(s.audio_scroll_offset == 0, string.format(
    "Sequence.create with no audio_scroll_offset must default to 0 "
    .. "(top-anchored: A1 fully visible on first open); got %s.",
    tostring(s.audio_scroll_offset)))
print("  ✓ unsupplied → 0/0 (V1 and A1 visible)")

-- (2) Explicit non-zero values pass through unchanged.
local s_mid = make({ video_scroll_offset = 250, audio_scroll_offset = 80 })
assert(s_mid.video_scroll_offset == 250, string.format(
    "Sequence.create with explicit video_scroll_offset=250 must store "
    .. "250 verbatim; got %s.", tostring(s_mid.video_scroll_offset)))
assert(s_mid.audio_scroll_offset == 80, string.format(
    "Sequence.create with explicit audio_scroll_offset=80 must store "
    .. "80 verbatim; got %s.", tostring(s_mid.audio_scroll_offset)))
print("  ✓ explicit values preserved")

print("\n✅ test_sequence_create_scroll_defaults.lua passed")
