#!/usr/bin/env luajit
-- Regression test: a FREEZE-FRAME retimed clip must import with its source
-- in-point at the HELD source frame, reading exactly one source frame.
--
-- Real fixture data: the freeze clip on A023_10251352_C026.mov in
-- tests/fixtures/resolve/anamnesis-gold-timeline.drp (take "56,59-197-002",
-- two stacked V1/V4 clips at timeline 193818, Sm2Ti DbId 1222af80…).
--
-- DRP ground truth for that clip:
--   <In>             = 89975        (playback-timeline frames, NOT source frames)
--   <Duration>       = 87           (timeline frames the freeze is held)
--   <MediaStartTime> = 49934.48 s   → master TC origin 49934.48 × 25 = 1248362
--   <MediaTimemapBA> = a FLAT curve: YMin = YMax = 14.8 s = source frame 370.
--                      A freeze holds ONE source frame (370) for the whole clip.
--
-- Domain ground truth (independent of the code):
--   The media-managed trim of C026 starts at TC 1248732 — i.e. Resolve cut the
--   trimmed file at the freeze's held frame, 0-handle. So the held source frame
--   is 370 and source_in MUST be 1248362 + 370 = 1248732. (The relink "short at
--   head 347 f" is exactly 1248732 − 1248385, the gap the OLD importer produced.)
--
-- Freeze source-span model (Joe's decision): a freeze reads ONE source frame and
-- holds it → source_out = source_in + 1.
--
-- The OLD importer discarded the flat curve in decode_media_timemap (it only
-- accepted forward 0→YMax or reverse YMax→0 curves), then synthesized a
-- from-ORIGIN ramp and evaluated <In>=89975 on it → source frame 23 →
-- source_in 1248385, source_out 1248384 (negative-duration, malformed clip).

require("test_env")

print("=== test_drp_freeze_frame_source_in.lua ===")

local drp_importer = require("importers.drp_importer")
local _xml_helpers = require("drp_test_helpers")
local elem = _xml_helpers.elem
local wrap_clips = _xml_helpers.wrap_clips

-- Verbatim MediaTimemapBA from the A023_C026 freeze clip (YMin=YMax=14.8s).
local mtba_freeze = "0000000100000007000000080059004d0069006e0000000600402d99999999a000000000080059004d006100780000000600402d99999999a000000000080058004d00610078000000060040ed4c0000000000000000100055006e0069007100750065004900640000000a000000004800350031003100320030003300610061002d0032006300610032002d0034003500350062002d0062006600390037002d00370035006400630064006500370064003400660031006600000020004c00610073007400560061006c006900640059004f006600660073006500740000000600405d1eb851eb843d00000016004b00650079006600720061006d00650073004200410000000c000000017400000001000000020000000200310000000c00000000a700000001000000070000000c0069006e0074006500720070000000020000000000000000080059004f00750074000000060000000000000000000000000600590049006e000000060000000000000000000000000200590000000600402d99999999a000000000080058004f00750074000000060000000000000000000000000600580049006e00000006000000000000000000000000020058000000060040ed4c00000000000000000200300000000c00000000a700000001000000070000000c0069006e0074006500720070000000020000000000000000080059004f00750074000000060000000000000000000000000600590049006e000000060000000000000000000000000200590000000600402d99999999a000000000080058004f00750074000000060000000000000000000000000600580049006e00000006000000000000000000000000020058000000060000000000000000000000000c0044006200540079007000650000000a00000000140053006d003200540069006d0065004d00610070"

local seq = elem("Sequence", "", {
    elem("Sm2TiTrack", "", {
        elem("Type", "0"),
        wrap_clips(
            elem("Sm2TiVideoClip", { DbId = "freeze1" }, {
                elem("Name", "56,59-197-002 freeze"),
                elem("Start", "193818"),
                elem("Duration", "87"),
                elem("MediaStartTime", "49934.48"),
                elem("In", "89975"),
                elem("MediaFilePath", "/Volumes/AnamBack4 Joe/Footage/Day 8/A023/A023_10251352_C026.mov"),
                elem("MediaTimemapBA", mtba_freeze),
                elem("MediaFrameRate", "0000000000003940"),  -- 25fps LE double
            })
        ),
    }),
})

local video_tracks = drp_importer.parse_resolve_tracks(seq, {frame_rate = 25})
assert(#video_tracks == 1, "expected 1 video track")
assert(#video_tracks[1].clips == 1, string.format(
    "expected 1 clip, got %d", #video_tracks[1].clips))

local clip = video_tracks[1].clips[1]

local EXPECTED_SOURCE_IN  = 1248732   -- 1248362 origin + 370 held frame (= trim start)
local EXPECTED_SOURCE_OUT = 1248733   -- source_in + 1 (read one frame, hold)

print("\n--- Freeze source_in must land on the held frame (= trim start) ---")
print(string.format("  source_in = %d (expected %d, diff %+d)",
    clip.source_in, EXPECTED_SOURCE_IN, clip.source_in - EXPECTED_SOURCE_IN))
assert(clip.source_in == EXPECTED_SOURCE_IN, string.format(
    "Freeze source_in must be %d (master origin 1248362 + held source frame 370, "
    .. "= the media-managed trim start). Got %d. The importer discarded the flat "
    .. "freeze curve and synthesized a from-origin ramp, landing source frame 23.",
    EXPECTED_SOURCE_IN, clip.source_in))
print("  ✓ source_in correct")

print("\n--- A freeze reads exactly ONE source frame (source_out = source_in + 1) ---")
print(string.format("  source_out = %d (expected %d)", clip.source_out, EXPECTED_SOURCE_OUT))
assert(clip.source_out == EXPECTED_SOURCE_OUT, string.format(
    "Freeze source_out must be source_in + 1 = %d (one held frame). Got %d "
    .. "(source length %d). The old importer produced a negative source span.",
    EXPECTED_SOURCE_OUT, clip.source_out, clip.source_out - clip.source_in))
print("  ✓ source_out correct (1 held frame)")

print("\n--- Timeline duration is unchanged (the freeze is held 87 frames) ---")
assert(clip.duration == 87, string.format(
    "Freeze timeline duration should be 87, got %d", clip.duration))
print("  ✓ timeline duration = 87")

print("\n✅ test_drp_freeze_frame_source_in.lua passed")
