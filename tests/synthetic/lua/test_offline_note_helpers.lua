#!/usr/bin/env luajit
-- Pure-helper tests for core.media.offline_note. Covers the compact
-- inline shortfall suffix used by the timeline clip label AND the
-- shortfall math used by the offline-frame composer. No Qt, no IO.
package.path = package.path .. ";../src/lua/?.lua;../src/lua/?/init.lua;./?.lua;./?/init.lua"
require("test_env")

local on = require("core.media.offline_note")
local json = require("dkjson")

print("=== offline_note helpers ===")

-- ---------------------------------------------------------------------------
-- parse: rejects garbage, accepts valid, nil-safe.
-- ---------------------------------------------------------------------------
assert(on.parse(nil) == nil, "parse(nil) should return nil")
assert(on.parse("") == nil, "parse('') should return nil")
assert(on.parse("not json") == nil, "parse(garbage) should return nil")
do
    local p = on.parse(json.encode({ kind = "partial_coverage", rate = 25 }))
    assert(p and p.kind == "partial_coverage",
        "parse(valid) returns table with kind")
end

-- ---------------------------------------------------------------------------
-- shortfall: tail-only, head-only, both, covered.
-- ---------------------------------------------------------------------------
local note = {
    kind = "partial_coverage",
    candidate_path = "/x/A035.mov",
    covered_start_tc = 100000,
    covered_end_tc   = 100100,
    rate = 25,
}

-- Tail-only: clip extends past covered_end by 3.
do
    local sf = on.shortfall(note, 100000, 100103)
    assert(sf, "expected shortfall table for tail-only")
    assert(sf.head_missing == 0 and sf.tail_missing == 3,
        string.format("tail-only: head=%d tail=%d (want 0, 3)",
            sf.head_missing, sf.tail_missing))
    assert(sf.rate == 25, "rate propagates")
end

-- Head-only: clip starts before covered_start.
do
    local sf = on.shortfall(note, 99990, 100100)
    assert(sf.head_missing == 10 and sf.tail_missing == 0,
        "head-only: head=10, tail=0")
end

-- Both ends missing.
do
    local sf = on.shortfall(note, 99990, 100110)
    assert(sf.head_missing == 10 and sf.tail_missing == 10,
        "both: head=10, tail=10")
end

-- Clip fully inside — no shortfall.
do
    local sf = on.shortfall(note, 100020, 100080)
    assert(sf == nil, "fully-covered clip returns nil shortfall")
end

-- Non-partial-coverage note → nil (no fabricated shortfall).
do
    local sf = on.shortfall({ kind = "other" }, 100000, 100100)
    assert(sf == nil, "other-kind note returns nil")
end

-- nil inputs → nil (no crash).
assert(on.shortfall(nil, 0, 100) == nil, "nil note → nil")
assert(on.shortfall(note, nil, 100) == nil, "nil source_in → nil")

-- ---------------------------------------------------------------------------
-- short_suffix: timeline-label-sized, accepts raw JSON too.
-- ---------------------------------------------------------------------------
-- No note → empty string (no space wasted on the label).
assert(on.short_suffix(nil, 100, 200) == "", "nil note → empty string")
assert(on.short_suffix("", 100, 200) == "", "empty string note → empty string")

-- Tail-only: compact " (short 3f)"
do
    local s = on.short_suffix(note, 100000, 100103)
    assert(s:find(" %(short "), "tail-only suffix has parenthetical: " .. s)
    assert(s:find("3f"), "tail-only suffix mentions 3f: " .. s)
    assert(not s:find("head"), "tail-only must not mention head: " .. s)
end

-- Head-only: explicit head: prefix because order matters ("head:45f")
do
    local s = on.short_suffix(note, 99955, 100100)
    assert(s:find("head"), "head-only suffix mentions head: " .. s)
    assert(s:find("45f"), "head-only suffix includes 45f: " .. s)
end

-- Both: "45f+3f"
do
    local s = on.short_suffix(note, 99955, 100103)
    assert(s:find("45f%+3f"), "both-ends suffix uses `NfN+Mf`: " .. s)
end

-- Accepts a raw JSON string too (clip renderer path).
do
    local raw = json.encode(note)
    local s = on.short_suffix(raw, 100000, 100103)
    assert(s:find("3f"), "JSON-string input produces same suffix: " .. s)
end

-- Audio: stored rate is 48000 (sample rate). Timeline display at 25fps
-- should rescale the sample-count shortfall into frames so users read
-- a meaningful number instead of "short 1524f" on an audio clip.
do
    local audio_note = {
        kind = "partial_coverage",
        candidate_path = "/x/sound.wav",
        covered_start_tc = 1000000,
        covered_end_tc   = 1048000,   -- 1 second of audio samples
        rate = 48000,
    }
    -- Clip wants 1524 samples past the end → ~0.8 video frames @ 25fps
    -- → rescales to 1f (rounded) or 0f (subframe → empty suffix).
    -- Quick check: rescale preserves non-trivial deltas.
    local s = on.short_suffix(audio_note, 1000000, 1048000 + 48000 * 3, 25)
    -- 48000 * 3 samples = 3 seconds = 75 frames @25fps
    assert(s:find("75f"), string.format(
        "audio shortfall must rescale samples→frames at display_rate: %s", s))
    -- No display_rate → suffix keeps raw samples (and confusingly says 'f').
    local s_raw = on.short_suffix(audio_note, 1000000, 1048000 + 48000 * 3)
    assert(s_raw:find("144000f"),
        "without display_rate, delta stays in source units (samples).")
    -- Sub-frame delta → empty suffix (nothing interesting to say).
    local s_tiny = on.short_suffix(audio_note, 1000000, 1048000 + 100, 25)
    assert(s_tiny == "", string.format(
        "sub-frame audio delta rescales to 0 → empty suffix, got %q", s_tiny))
end

-- ---------------------------------------------------------------------------
-- format_frame_delta: sub-second, mid-range, long.
-- ---------------------------------------------------------------------------
assert(on.format_frame_delta(3, 25):find("3f"), "3f at 25fps")
assert(on.format_frame_delta(50, 25):find("~2%."), "50f @25fps → seconds hint")
assert(on.format_frame_delta(25 * 65, 25):find("~65s"), "long → seconds only")

print("✅ test_offline_note_helpers.lua passed")
