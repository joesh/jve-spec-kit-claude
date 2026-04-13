#!/usr/bin/env luajit
-- Regression test: DRP importer must use each media file's NATIVE rate
-- (video fps or audio sample rate) when computing source-unit values, NOT
-- the sequence's frame rate.
--
-- Domain rule: source_in is an absolute timecode that addresses a specific
-- file frame. Decoding reads files at their native rate (C++ uses
-- file_info.video_rate()), so source_in must be expressed in the file's
-- native units. A 24fps clip on a 25fps sequence must have source_in
-- computed as TC_seconds * 24, not TC_seconds * 25 — otherwise every source
-- query lands on the wrong file frame and playback runs 4% fast.
--
-- The DRP <MediaFrameRate> element carries the file's native fps as a
-- little-endian IEEE-754 double. 24.0 → "0000000000003840".

require("test_env")

print("=== test_drp_media_rate_conform.lua ===")

local drp_importer = require("importers.drp_importer")

local function elem(tag, text, children)
    return { tag = tag, attrs = {}, children = children or {}, text = text or "" }
end

local function wrap_clips(...)
    local elements = {}
    for _, clip in ipairs({...}) do
        table.insert(elements, elem("Element", "", {clip}))
    end
    return elem("Items", "", elements)
end

-- IEEE-754 LE hex for common video rates. The DRP <MediaFrameRate> field is
-- padded to 32 hex chars (two doubles); parse_resolve_tracks only reads the
-- first 16. Verified against the comment at drp_importer.lua:227.
local HEX_24 = "00000000000038400000000000000000"
local HEX_25 = "00000000000039400000000000000000"
local HEX_30 = "0000000000003E400000000000000000"

--------------------------------------------------------------------------------
-- Test 1: 24fps media on 25fps sequence — untrimmed
--------------------------------------------------------------------------------
-- MediaStartTime 3600 sec = 01:00:00:00. File is 24fps, so that TC addresses
-- file frame 3600 * 24 = 86400. Sequence is 25fps. A user watching this clip
-- expects the file to play at natural speed; source_in must be the file's
-- frame count of the TC origin, which is 86400, not 3600 * 25 = 90000.

print("\n--- Test 1: 24fps media on 25fps sequence, untrimmed ---")

local seq1 = elem("Sequence", "", {
    elem("Sm2TiTrack", "", {
        elem("Type", "0"),  -- VIDEO
        wrap_clips(
            elem("Sm2TiVideoClip", "", {
                elem("Name", "OldFashionedCountdown"),
                elem("Start", "90000"),         -- timeline pos = 1hr at 25fps
                elem("Duration", "100"),        -- 100 timeline frames = 4s
                elem("MediaStartTime", "3600"), -- file TC origin = 01:00:00
                elem("In", ""),                  -- untrimmed
                elem("MediaFilePath", "/test/OldFashionedFilmLeaderCountdownVidevo.mov"),
                elem("MediaFrameRate", HEX_24), -- 24fps file
            })
        ),
    }),
})

local v1 = drp_importer.parse_resolve_tracks(seq1, 25)  -- SEQUENCE is 25fps
assert(#v1 == 1 and #v1[1].clips == 1, "expected 1 video clip")
local clip1 = v1[1].clips[1]

local expected_mst_file = 3600 * 24  -- 86400: file's native TC origin
assert(clip1.source_in == expected_mst_file, string.format(
    "24-on-25 untrimmed: source_in should be %d (media-native TC), got %d. " ..
    "If this is %d, the parser used the sequence rate instead of the file rate.",
    expected_mst_file, clip1.source_in, 3600 * 25))
print(string.format("  ✓ source_in = %d (file's 24fps TC, not sequence's 25fps)",
    clip1.source_in))

-- Duration on the timeline is 100 frames = 4.0 seconds (at 25fps).
-- At natural speed, the file supplies 4.0 * 24 = 96 file frames during those
-- 4 seconds. source_out - source_in must equal 96 — NOT 100 (which would be
-- sequence-rate math) and NOT duration*25/24 (reverse mistake).
local expected_source_range = 96
local actual_source_range = clip1.source_out - clip1.source_in
assert(actual_source_range == expected_source_range, string.format(
    "24-on-25 source range should be %d file frames (duration_sec * media_fps), got %d",
    expected_source_range, actual_source_range))
print(string.format("  ✓ source_out - source_in = %d file frames (4s × 24fps)",
    actual_source_range))

--------------------------------------------------------------------------------
-- Test 2: 24fps media on 25fps sequence — trimmed
--------------------------------------------------------------------------------
-- <In>N</In> is expressed by DRP in master-playback-timeline frames at the
-- SEQUENCE rate. For an un-retimed 24fps clip on a 25fps sequence, In=48
-- means "start 48/25 = 1.92 sec into the file" = floor(1.92 * 24 + 0.5) = 46
-- file frames. Expected source_in:
--   media_tc_origin_frames + 46 = 86400 + 46 = 86446.

print("\n--- Test 2: 24fps media on 25fps sequence, In=48 ---")

local seq2 = elem("Sequence", "", {
    elem("Sm2TiTrack", "", {
        elem("Type", "0"),
        wrap_clips(
            elem("Sm2TiVideoClip", "", {
                elem("Name", "trimmed_24_on_25"),
                elem("Start", "90050"),
                elem("Duration", "50"),  -- 50 timeline frames = 2s at 25fps
                elem("MediaStartTime", "3600"),
                elem("In", "48"),         -- 48 file frames into the file
                elem("MediaFilePath", "/test/b.mov"),
                elem("MediaFrameRate", HEX_24),
            })
        ),
    }),
})

local v2 = drp_importer.parse_resolve_tracks(seq2, 25)
local clip2 = v2[1].clips[1]

-- In=48 at 25fps seq → 48*24/25 = 46.08 → floor(46.08+0.5) = 46 file frames
local expected_in_offset = math.floor(48 * 24 / 25 + 0.5)  -- 46
assert(clip2.source_in == 86400 + expected_in_offset, string.format(
    "trimmed source_in should be %d (media-native TC + In converted to file rate), got %d",
    86400 + expected_in_offset, clip2.source_in))
print(string.format("  ✓ source_in = %d (TC origin 86400 + In→%d file frames)", clip2.source_in, expected_in_offset))

-- 50 timeline frames at 25fps = 2.0s. Source duration = floor(50*24/25+0.5) = 48 file frames
local expected_src_dur2 = math.floor(50 * 24 / 25 + 0.5)  -- 48
assert(clip2.source_out - clip2.source_in == expected_src_dur2, string.format(
    "trimmed source range should be %d file frames, got %d",
    expected_src_dur2, clip2.source_out - clip2.source_in))
print(string.format("  ✓ source range = %d file frames (2s × 24fps)", expected_src_dur2))

--------------------------------------------------------------------------------
-- Test 3: 30fps media on 25fps sequence — untrimmed
--------------------------------------------------------------------------------
-- Reverse direction: media faster than sequence. 100 timeline frames = 4s,
-- so the file supplies 4 * 30 = 120 file frames of natural-speed content.
-- source_in for TC origin 3600s at 30fps = 108000.

print("\n--- Test 3: 30fps media on 25fps sequence ---")

local seq3 = elem("Sequence", "", {
    elem("Sm2TiTrack", "", {
        elem("Type", "0"),
        wrap_clips(
            elem("Sm2TiVideoClip", "", {
                elem("Name", "thirty_on_25"),
                elem("Start", "90000"),
                elem("Duration", "100"),
                elem("MediaStartTime", "3600"),
                elem("In", ""),
                elem("MediaFilePath", "/test/c.mov"),
                elem("MediaFrameRate", HEX_30),
            })
        ),
    }),
})

local v3 = drp_importer.parse_resolve_tracks(seq3, 25)
local clip3 = v3[1].clips[1]

assert(clip3.source_in == 3600 * 30, string.format(
    "30-on-25 untrimmed source_in should be %d, got %d",
    3600 * 30, clip3.source_in))
print(string.format("  ✓ source_in = %d (30fps TC origin)", clip3.source_in))

assert(clip3.source_out - clip3.source_in == 120, string.format(
    "30-on-25 source range should be 120 file frames (4s × 30fps), got %d",
    clip3.source_out - clip3.source_in))
print(string.format("  ✓ source range = 120 file frames"))

--------------------------------------------------------------------------------
-- Test 4: Matched rates (25fps media on 25fps sequence) — regression guard
--------------------------------------------------------------------------------
-- Sanity check: when media.rate == sequence.rate the fix must not disturb
-- existing behavior. source_in should still be TC_seconds × 25.

print("\n--- Test 4: 25fps media on 25fps sequence (regression guard) ---")

local seq4 = elem("Sequence", "", {
    elem("Sm2TiTrack", "", {
        elem("Type", "0"),
        wrap_clips(
            elem("Sm2TiVideoClip", "", {
                elem("Name", "matched_rates"),
                elem("Start", "90000"),
                elem("Duration", "100"),
                elem("MediaStartTime", "3600"),
                elem("In", ""),
                elem("MediaFilePath", "/test/d.mov"),
                elem("MediaFrameRate", HEX_25),
            })
        ),
    }),
})

local v4 = drp_importer.parse_resolve_tracks(seq4, 25)
local clip4 = v4[1].clips[1]

assert(clip4.source_in == 3600 * 25, string.format(
    "matched-rate untrimmed source_in should be %d, got %d",
    3600 * 25, clip4.source_in))
assert(clip4.source_out - clip4.source_in == 100, string.format(
    "matched-rate source range should equal duration (100), got %d",
    clip4.source_out - clip4.source_in))
print("  ✓ Matched-rate case unchanged")

--------------------------------------------------------------------------------
-- Test 5: clip.rate stamp on the timeline-level clip (post-import)
--------------------------------------------------------------------------------
-- At the parse_resolve_tracks layer clips carry two rate fields:
--   frame_rate  = sequence rate (for timeline position math)
--   native_rate = media's native fps (source coords are in this rate)
-- For downstream consumers that need the file's actual fps (inspector,
-- match-frame, retime math, audio conform speed_ratio), native_rate is used.

print("\n--- Test 5: clip native_rate field = media's native rate ---")

assert(clip1.native_rate == 24, string.format(
    "24-on-25 clip.native_rate should be 24 (media-native), got %s",
    tostring(clip1.native_rate)))
print(string.format("  ✓ 24-on-25 clip.native_rate = %s", tostring(clip1.native_rate)))

assert(clip3.native_rate == 30,
    "30-on-25 clip.native_rate should be 30")
print(string.format("  ✓ 30-on-25 clip.native_rate = %s", tostring(clip3.native_rate)))

assert(clip4.native_rate == 25,
    "25-on-25 clip.native_rate should be 25")
print(string.format("  ✓ 25-on-25 clip.native_rate = %s", tostring(clip4.native_rate)))

print("\n✅ test_drp_media_rate_conform.lua passed")
