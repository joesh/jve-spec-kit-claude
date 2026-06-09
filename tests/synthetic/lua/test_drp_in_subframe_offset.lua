#!/usr/bin/env luajit
-- Regression test: the hex suffix on <In>N|hex</In> is a sub-frame fractional
-- offset. For unretimed clips, the fraction is added to the integer in-point
-- and round-half-up to the nearest whole source frame; for retimed clips the
-- MTBA curve provides sub-frame precision and the <In> fraction is ignored.
--
-- Domain: Resolve stores In-points with sub-frame precision for clips that
-- start mid-frame (common for sample-accurate audio edits). The integer part
-- is the whole-frame offset; the hex part is a little-endian IEEE-754 double
-- in [0, 1) representing the fractional position within that frame.
--
-- Production case: A012_10201517_C005 and A027_11060530_C007 in the anamnesis
-- gold master. Both have <In>N|hex</In> where hex ≈ 0.9999, which rounds the
-- in-point up to frame N+1 — exactly where the Media-Managed trimmed file
-- starts. Without the sub-frame fold, source_in lands one frame early and
-- the relinker rejects the clip.

require("test_env")

local drp_importer = require("importers.drp_importer")

print("=== test_drp_in_subframe_offset.lua ===")

local _xml_helpers = require("drp_test_helpers")
local elem = _xml_helpers.elem

local function wrap(...)
    local out = {}
    for _, c in ipairs({...}) do
        table.insert(out, elem("Element", "", {c}))
    end
    return elem("Items", "", out)
end

-- ---------------------------------------------------------------------------
-- Shared inputs for an unretimed clip (no MTBA). Varying only the <In> text
-- across sub-tests keeps each case one-variable-different from the baseline.
-- ---------------------------------------------------------------------------

local SEQ_FPS = 25
local MEDIA_FPS = 25
local MEDIA_START_SEC = 40.0
local MEDIA_TC_ORIGIN = math.floor(MEDIA_START_SEC * MEDIA_FPS + 0.5)  -- 1000
local TIMELINE_DURATION = 50
local MEDIA_FRAME_RATE_25 = "00000000000039400000000000000000"

local function import_clip_with_in(in_text)
    local seq_elem = elem("Sequence", "", {
        elem("Sm2TiTrack", "", {
            elem("Type", "0"),  -- 0 = VIDEO
            wrap(
                elem("Sm2TiVideoClip", { DbId = "v1" }, {
                    elem("Name", "subframe_case"),
                    elem("Start", "0"),
                    elem("Duration", tostring(TIMELINE_DURATION)),
                    elem("MediaStartTime", tostring(MEDIA_START_SEC)),
                    elem("In", in_text),
                    elem("MediaFilePath", "/test/subframe.mov"),
                    elem("MediaFrameRate", MEDIA_FRAME_RATE_25),
                })
            ),
        }),
    })
    local video_tracks = drp_importer.parse_resolve_tracks(seq_elem, {frame_rate = SEQ_FPS})
    assert(#video_tracks == 1 and #video_tracks[1].clips == 1, "expected 1 clip")
    return video_tracks[1].clips[1]
end

local function assert_source_in(case_label, in_text, expected_offset)
    local clip = import_clip_with_in(in_text)
    local expected_source_in = MEDIA_TC_ORIGIN + expected_offset
    assert(clip.source_in == expected_source_in, string.format(
        "%s: source_in=%d, expected %d (In=%q, offset %d)",
        case_label, clip.source_in, expected_source_in, in_text, expected_offset))
    print(string.format("  ✓ %s: source_in=%d (In=%q)",
        case_label, clip.source_in, in_text))
end

-- Hex values below are all IEEE-754 little-endian doubles.
local HEX_0_0         = "0000000000000000"  -- exactly 0.0
local HEX_0_5         = "000000000000e03f"  -- exactly 0.5
local HEX_JUST_BELOW_1 = "f8ffffffffffef3f" -- 0.9999999999999991 (from A012 production)
local HEX_NEGATIVE    = "000000000000e0bf"  -- -0.5 (invalid sub-frame range)

-- ---------------------------------------------------------------------------
-- Case 1 — happy path: sub-frame ≈ 1.0 rounds to next whole frame.
-- Production case from A012_10201517_C005.
-- ---------------------------------------------------------------------------
assert_source_in("sub-frame ≈ 1.0 rounds up", "100|" .. HEX_JUST_BELOW_1, 101)

-- ---------------------------------------------------------------------------
-- Case 2 — boundary: sub-frame exactly 0.5 rounds up (round-half-up).
-- ---------------------------------------------------------------------------
assert_source_in("sub-frame 0.5 rounds up", "100|" .. HEX_0_5, 101)

-- ---------------------------------------------------------------------------
-- Case 3 — boundary: sub-frame exactly 0.0 does NOT round up.
-- ---------------------------------------------------------------------------
assert_source_in("sub-frame 0.0 stays put", "100|" .. HEX_0_0, 100)

-- ---------------------------------------------------------------------------
-- Case 4 — no hex suffix: in-point is the integer as-is.
-- ---------------------------------------------------------------------------
assert_source_in("no hex suffix", "100", 100)

-- ---------------------------------------------------------------------------
-- Case 5 — empty pipe (no hex after pipe): treated same as no suffix.
-- ---------------------------------------------------------------------------
assert_source_in("empty hex after pipe", "100|", 100)

-- ---------------------------------------------------------------------------
-- Case 6 — invalid input: hex fraction out of [0, 1) range (e.g. negative).
-- Must not mis-apply as sub-frame; silently ignored (these occur legitimately
-- as speed-ratio remnants on retimed clips and are handled by MTBA there).
-- ---------------------------------------------------------------------------
assert_source_in("out-of-range hex ignored", "100|" .. HEX_NEGATIVE, 100)

-- ---------------------------------------------------------------------------
-- Case 7 — invalid input: hex suffix shorter than 16 chars. Malformed; logs
-- a warning and falls through to the integer value. No crash on bad DRP data.
-- ---------------------------------------------------------------------------
assert_source_in("short hex suffix ignored", "100|deadbeef", 100)

print("\n✅ test_drp_in_subframe_offset.lua passed")
