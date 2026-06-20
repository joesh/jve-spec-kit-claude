#!/usr/bin/env luajit
-- Regression test: the forward-retime IN-point must FLOOR the sub-frame-accurate
-- source position, not CEIL it.
--
-- The source frame *displayed* at a clip's first timeline frame is the frame
-- whose half-open interval [n, n+1) contains the playhead's sub-frame-accurate
-- source position — i.e. floor(curve(In + sub_frame)). Resolve's media-managed
-- trim cuts the source from that displayed frame, so JVE's source_in must equal
-- the floored frame to relink against the trimmed file.
--
-- Fixture: 00.5G-1 (DbId 84fe694c-…) from "anamnesis joe edit.drp", a VARIABLE-
-- speed clip (4 keyframes). Its in-point falls in the curve's first segment
-- (0,0)→(22.367,22.367), which is slope 1.0 (an un-retimed region), so the <In>
-- sub-frame (0.0433 timeline frames) passes straight through to a source
-- sub-frame:
--   <In> 517|009f6f243e30a63f  (whole=517, sub-frame ≈ 0.0433)
--   MediaStartTime 4966.6  → 4966.6 × 25 = 124165 = master clip TC origin
--   eval_curve(517.0433/25) × 25 = 517.0433
-- The displayed source frame is floor(517.0433) = 517, so:
--   source_in = 124165 + 517 = 124682  (= 01:23:07:07, Resolve's trim first-frame
--   TC, verified by the e2e relink in test_e2e_retime_relink.lua).
--
-- The bug: snap_ceil(517.0433) = 518 → source_in 124683 (1 frame PAST Resolve's
-- cut → false "partial coverage" on relink). snap_ceil only ever agreed with the
-- truth back when the sub-frame was dropped (517.0 → ceil 517); once the curve is
-- sampled sub-frame-accurately (the A030_C012 fix), ceil double-rounds-up.
--
-- Cross-fixture safety: A030_C012 (430.00) and A035 (394.00) and the C026 freeze
-- (370.0) all land on whole source frames, where floor == ceil — so this change
-- does not regress test_drp_retime_subframe_inclusion / _curve_walk / freeze.

require("test_env")

print("=== test_drp_retime_inpoint_floor.lua ===")

local drp_importer = require("importers.drp_importer")
local _h = require("drp_test_helpers")
local elem, wrap_clips = _h.elem, _h.wrap_clips

-- 00.5G-1 MediaTimemapBA (forward, variable speed, 4 keyframes), from the DRP.
local mtba_05g = "0000000100000006000000080059004d0061007800000006004042d16872b020ee000000080058004d0061007800000006004041db126827e147000000100055006e0069007100750065004900640000000a000000004800610031003900630066003300370036002d0037003900610031002d0034003500310031002d0062003400640035002d00300030003000620031003100380032003400640061006300000020004c00610073007400560061006c006900640059004f0066006600730065007400000006004042d1eb851eb87b00000016004b00650079006600720061006d00650073004200410000000c00000002e000000001000000040000000200330000000c00000000a700000001000000070000000c0069006e0074006500720070000000020000000000000000080059004f00750074000000060000000000000000000000000600590049006e0000000600000000000000000000000002005900000006004042d16872b020ee000000080058004f00750074000000060000000000000000000000000600580049006e0000000600000000000000000000000002005800000006004041db126827e1470000000200320000000c00000000a700000001000000070000000c0069006e0074006500720070000000020000000000000000080059004f00750074000000060000000000000000000000000600590049006e0000000600000000000000000000000002005900000006004038b851eb851eb8000000080058004f00750074000000060000000000000000000000000600580049006e0000000600000000000000000000000002005800000006004037f83d047145850000000200310000000c00000000a700000001000000070000000c0069006e0074006500720070000000020000000000000000080059004f00750074000000060000000000000000000000000600590049006e00000006000000000000000000000000020059000000060040365df89e7f6e13000000080058004f00750074000000060000000000000000000000000600580049006e00000006000000000000000000000000020058000000060040365df89e7f6e130000000200300000000c00000000a700000001000000070000000c0069006e0074006500720070000000020000000000000000080059004f00750074000000060000000000000000000000000600590049006e0000000600000000000000000000000002005900000006000000000000000000000000080058004f00750074000000060000000000000000000000000600580049006e00000006000000000000000000000000020058000000060000000000000000000000000c0044006200540079007000650000000a00000000140053006d003200540069006d0065004d00610070"

local seq = elem("Sequence", "", {
    elem("Sm2TiTrack", "", {
        elem("Type", "0"),
        wrap_clips(
            elem("Sm2TiVideoClip", { DbId = "84fe694c-b36f-4345-bdb7-90aa871072ff" }, {
                elem("Name", "00.5G-1"),
                elem("Start", "91344"),
                elem("Duration", "204"),
                elem("MediaStartTime", "4966.6"),
                elem("In", "517|009f6f243e30a63f"),
                elem("MediaFilePath", "/Volumes/AnamBack4 Joe/Footage/00.5G-1.mov"),
                elem("MediaTimemapBA", mtba_05g),
                elem("MediaFrameRate", "00000000000039400000000000000000"),  -- 25fps LE double
            })
        ),
    }),
})

local tracks = drp_importer.parse_resolve_tracks(seq, { frame_rate = 25 })
assert(#tracks == 1, "expected 1 video track")
assert(#tracks[1].clips == 1, "expected 1 clip")
local clip = tracks[1].clips[1]

-- Domain ground truth: Resolve's media-managed trim first-frame TC = 01:23:07:07
-- = frame 124682 (0 handles — Resolve cuts the source at the clip's displayed
-- in-point). Verified end-to-end by test_e2e_retime_relink.lua.
local EXPECTED_SOURCE_IN = 124682

print(string.format("  source_in = %d (expected %d, diff %+d)",
    clip.source_in, EXPECTED_SOURCE_IN, clip.source_in - EXPECTED_SOURCE_IN))
assert(clip.source_in == EXPECTED_SOURCE_IN, string.format(
    "forward-retime in-point must FLOOR the sub-frame-accurate source position. " ..
    "00.5G-1's in-point sits in a slope-1.0 curve segment so the <In> sub-frame " ..
    "(0.0433) passes through to source 517.0433; the displayed source frame is " ..
    "floor = 517 → source_in %d (= Resolve trim TC 01:23:07:07). Got %d. " ..
    "snap_ceil double-rounds-up to 518 → 124683.",
    EXPECTED_SOURCE_IN, clip.source_in))

print("✅ test_drp_retime_inpoint_floor.lua passed")
