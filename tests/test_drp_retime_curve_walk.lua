#!/usr/bin/env luajit
-- Regression test: DRP retimed-clip <In> is in master-clip-playback-timeline
-- frames, NOT source frames. To convert to source frames, the importer must
-- walk the MediaTimemapBA curve at X = In and read the Y value.
--
-- Test fixture: tests/fixtures/resolve/retime-test.drt
--
-- The fixture contains two timeline clips that reference the SAME source
-- content of A035_11200114_C056.mov:
--
--   Clip 1 (retimed):    <In>447|hex_speed</In>  <Duration>132</Duration>
--                        <MediaTimemapBA> = full v1 curve, constant 0.88 slope
--
--   Clip 2 (un-retimed): <In>394</In>             <Duration>132</Duration>
--                        <MediaTimemapBA> = 9-byte short form (no curve)
--
-- Both clips reference media that starts at TC 01:14:20:22 = frame 111522
-- (MediaStartTime = 4460.88s @ 25fps).
--
-- Resolve's source viewer shows the in-point of BOTH clips at TC 01:14:36:16
-- = frame 111916. So both clips MUST produce source_in_frame = 111916.
--
-- Currently:
--   Clip 1 → 111915 (off by 1: floor(447 × 0.88 + 0.5) = 393 + 111522 = 111915)
--   Clip 2 → 111916 (correct: 394 + 111522 = 111916)
--
-- After the fix (curve walking instead of × scalar speed):
--   Clip 1 → 111916 (curve.Y(447) at slope 0.88, rounded up to 394)
--   Clip 2 → 111916 (identity curve, In = source frames)
--
-- This is the cleanest cross-check: SAME source content, two ways of expressing
-- it, and the importer is correct iff both forms produce the same source_in.

require("test_env")

print("=== test_drp_retime_curve_walk.lua ===")

local drp_importer = require("importers.drp_importer")

-- Hex of the full v1 MediaTimemapBA from clip 1 (constant 0.88 slope, 660 bytes)
local mtba_retimed = "0000000100000006000000080059004d006100780000000600405251eb851eb83d000000080058004d0061007800000006004054d1cdbb1cdb9b000000100055006e0069007100750065004900640000000a000000004800390038003000300033006300620063002d0063006500640064002d0034003300340063002d0039003100640063002d00350031006100310030003100350036006100300066006200000020004c00610073007400560061006c006900640059004f006600660073006500740000000600405251eb851eb83d00000016004b00650079006600720061006d00650073004200410000000c000000017400000001000000020000000200310000000c00000000a700000001000000070000000c0069006e0074006500720070000000020000000000000000080059004f00750074000000060000000000000000000000000600590049006e0000000600000000000000000000000002005900000006004052523a29c77993000000080058004f00750074000000060000000000000000000000000600580049006e0000000600000000000000000000000002005800000006004054d1cdbb1cdb9b0000000200300000000c00000000a700000001000000070000000c0069006e0074006500720070000000020000000000000000080059004f00750074000000060000000000000000000000000600590049006e0000000600000000000000000000000002005900000006000000000000000000000000080058004f00750074000000060000000000000000000000000600580049006e00000006000000000000000000000000020058000000060000000000000000000000000c0044006200540079007000650000000a00000000140053006d003200540069006d0065004d00610070"

-- Hex of the 9-byte short MediaTimemapBA from clip 2 (no curve, no retime)
local mtba_no_retime = "02405251eb851eb851"

-- Build a synthetic Sequence XML element wrapping both clips on a single
-- video track. Pattern matches tests/test_drp_retimed_clip_speed.lua.
local function elem(tag, text_or_attrs, children)
    local text = type(text_or_attrs) == "string" and text_or_attrs or ""
    local attrs = type(text_or_attrs) == "table" and text_or_attrs or {}
    return {
        tag = tag,
        attrs = attrs,
        children = children or {},
        text = text,
    }
end

local function wrap_clips(...)
    local elements = {}
    for _, clip in ipairs({...}) do
        table.insert(elements, elem("Element", "", {clip}))
    end
    return elem("Items", "", elements)
end

local seq = elem("Sequence", "", {
    elem("Sm2TiTrack", "", {
        elem("Type", "0"),
        wrap_clips(
            -- Clip 1: retimed
            elem("Sm2TiVideoClip", { DbId = "v1" }, {
                elem("Name", "01-333-2 retimed"),
                elem("Start", "90000"),
                elem("Duration", "132"),
                elem("MediaStartTime", "4460.88"),
                elem("In", "447|00f05d74d145e73f"),
                elem("MediaFilePath", "/Volumes/AnamBack4 Joe/Footage/Day 12/A035/A035_11200114_C056.mov"),
                elem("MediaTimemapBA", mtba_retimed),
                elem("MediaFrameRate", "0000000000003940"),  -- 25fps LE double
            }),
            -- Clip 2: same content, retiming removed
            elem("Sm2TiVideoClip", { DbId = "v1" }, {
                elem("Name", "01-333-2 unretimed"),
                elem("Start", "90132"),
                elem("Duration", "132"),
                elem("MediaStartTime", "4460.88"),
                elem("In", "394"),
                elem("MediaFilePath", "/Volumes/AnamBack4 Joe/Footage/Day 12/A035/A035_11200114_C056.mov"),
                elem("MediaTimemapBA", mtba_no_retime),
                elem("MediaFrameRate", "0000000000003940"),  -- 25fps LE double
            })
        ),
    }),
})

local video_tracks = drp_importer.parse_resolve_tracks(seq, {frame_rate = 25})
assert(#video_tracks == 1, "expected 1 video track")
assert(#video_tracks[1].clips == 2, string.format(
    "expected 2 clips, got %d", #video_tracks[1].clips))

local clip_retimed = video_tracks[1].clips[1]
local clip_unretimed = video_tracks[1].clips[2]

-- Domain ground truth: master clip starts at TC 01:14:20:22 = frame 111522 @ 25fps.
-- Both clips' source content begins at the same source frame, which Resolve's
-- source viewer shows as TC 01:14:36:16 = frame 111916.
local EXPECTED_SOURCE_IN = 111916  -- 01:14:36:16

print("\n--- Clip 1 (retimed): source_in must equal Resolve's display ---")
print(string.format("  source_in = %d (expected %d, diff %+d)",
    clip_retimed.source_in, EXPECTED_SOURCE_IN,
    clip_retimed.source_in - EXPECTED_SOURCE_IN))
assert(clip_retimed.source_in == EXPECTED_SOURCE_IN, string.format(
    "Clip 1 (retimed) source_in must be %d (= 01:14:36:16, what Resolve shows). " ..
    "Got %d. The importer must walk the MediaTimemapBA curve at X=447 to get " ..
    "Y=394 source frames, NOT compute floor(447 × YMax/XMax) which produces 393.",
    EXPECTED_SOURCE_IN, clip_retimed.source_in))
print("  ✓ Clip 1 source_in correct")

print("\n--- Clip 2 (un-retimed): source_in must equal the same value ---")
print(string.format("  source_in = %d (expected %d, diff %+d)",
    clip_unretimed.source_in, EXPECTED_SOURCE_IN,
    clip_unretimed.source_in - EXPECTED_SOURCE_IN))
assert(clip_unretimed.source_in == EXPECTED_SOURCE_IN, string.format(
    "Clip 2 (un-retimed) source_in must be %d (= 01:14:36:16). Got %d. " ..
    "An un-retimed clip with <In>394</In> is source-frame-indexed; the " ..
    "importer should add 394 to the master clip's TC origin (111522) " ..
    "and produce 111916.",
    EXPECTED_SOURCE_IN, clip_unretimed.source_in))
print("  ✓ Clip 2 source_in correct")

print("\n--- Cross-check: BOTH clips must produce the same source_in ---")
assert(clip_retimed.source_in == clip_unretimed.source_in, string.format(
    "Cross-check failed: clip 1 (retimed) source_in = %d, clip 2 (un-retimed) " ..
    "source_in = %d. Both clips reference the same source content and Resolve " ..
    "shows the same in-point for both, so JVE must produce the same source_in_frame.",
    clip_retimed.source_in, clip_unretimed.source_in))
print(string.format("  ✓ both source_in = %d", clip_retimed.source_in))

print("\n--- Timeline durations are unchanged by the fix ---")
assert(clip_retimed.duration == 132, string.format(
    "Clip 1 timeline duration should be 132, got %d", clip_retimed.duration))
assert(clip_unretimed.duration == 132, string.format(
    "Clip 2 timeline duration should be 132, got %d", clip_unretimed.duration))
print("  ✓ both timeline durations = 132")

-- Sanity check on source_out: a retimed clip at constant 0.88 slope reads ~116
-- source frames over 132 timeline frames (132 × 0.88 ≈ 116). An un-retimed
-- clip reads 132 source frames over the same timeline duration. So the
-- retimed clip's source_out should land 116 frames past source_in, and the
-- un-retimed clip's should land 132 frames past.
print("\n--- source_out lengths reflect retime (sanity check, not pinned to 1 frame) ---")
local len_retimed = clip_retimed.source_out - clip_retimed.source_in
local len_unretimed = clip_unretimed.source_out - clip_unretimed.source_in
print(string.format("  retimed source length   = %d frames (~116 expected)", len_retimed))
print(string.format("  unretimed source length = %d frames (132 expected)", len_unretimed))
assert(len_unretimed == 132, string.format(
    "Un-retimed source length must equal timeline duration (132), got %d", len_unretimed))
assert(len_retimed >= 115 and len_retimed <= 117, string.format(
    "Retimed source length should be ~116 frames (132 × 0.88), got %d", len_retimed))
print("  ✓ retime semantics correct")

print("\n✅ test_drp_retime_curve_walk.lua passed")
