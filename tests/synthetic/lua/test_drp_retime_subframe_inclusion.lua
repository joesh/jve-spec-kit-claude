#!/usr/bin/env luajit
-- Regression test: a RETIMED DRP clip whose <In> carries a sub-frame fraction
-- must sample the MediaTimemapBA curve at the sub-frame-accurate timeline
-- position. Dropping the fraction (sampling at the floored whole frame) loses
-- up to one source frame when speed > 1.
--
-- Fixture: A030_11130255_C012 from anamnesis-gold-timeline.drp.
--   <In>330|00609ad8899de83f  (whole=330, sub-frame ≈ 0.769 timeline frames)
--   <Duration>224
--   <MediaStartTime>10515.6  → 10515.6 × 25 = 262890 = master clip TC origin
--   MediaTimemapBA: forward retime, constant 1.30× speed (YMax 45.868s,
--                   XMax 35.283s; slope 1.30), keyframes (0,0)→(35.283,45.868)
--
-- Resolve media-managed this clip to a trim whose embedded timecode is
-- 02:55:32:20 = frame 263320 (0 handles — Resolve cuts the source at exactly
-- the clip's in-point). So Resolve's source in-point for this clip is frame
-- 263320, and JVE MUST produce source_in = 263320.
--
-- The bug: the importer's retime branch computed in_sec = in_value / fps,
-- dropping the <In> sub-frame, giving:
--   eval_curve(330/25) × 25 = 429.00 (exact integer) → snap_ceil → 429
--   → source_in = 262890 + 429 = 263319  (1 frame BEFORE the trim → relink
--     reports false "partial coverage")
-- With the sub-frame:
--   eval_curve(330.769/25) × 25 = 430.00 → snap_ceil → 430
--   → source_in = 262890 + 430 = 263320  (= Resolve's cut). Correct.
--
-- Cross-fixture safety: test_drp_retime_curve_walk.lua's clip 1 (A035, <In>
-- 447|sub-frame, slope 0.88) yields 394 BOTH with and without the sub-frame
-- (393.36 and 394.00 both ceil to 394), so this fix does not regress it.

require("test_env")

print("=== test_drp_retime_subframe_inclusion.lua ===")

local drp_importer = require("importers.drp_importer")
local _h = require("drp_test_helpers")
local elem, wrap_clips = _h.elem, _h.wrap_clips

-- A030_C012 MediaTimemapBA (forward, 1.30× constant), from the gold DRP.
local mtba_a030 = "0000000100000006000000080059004d0061007800000006004046ef1a9fbe76d2000000080058004d0061007800000006004041a43bdd576cec000000100055006e0069007100750065004900640000000a000000004800610038003300350034006100340033002d0034003500630032002d0034003100390035002d0038003300330061002d00620034006500350061006200390032006600310035003700000020004c00610073007400560061006c006900640059004f0066006600730065007400000006004046f0a3d70a3d7b00000016004b00650079006600720061006d00650073004200410000000c000000017400000001000000020000000200310000000c00000000a700000001000000070000000c0069006e0074006500720070000000020000000000000000080059004f00750074000000060000000000000000000000000600590049006e0000000600000000000000000000000002005900000006004046ef1a9fbe76d2000000080058004f00750074000000060000000000000000000000000600580049006e0000000600000000000000000000000002005800000006004041a43bdd576cec0000000200300000000c00000000a700000001000000070000000c0069006e0074006500720070000000020000000000000000080059004f00750074000000060000000000000000000000000600590049006e0000000600000000000000000000000002005900000006000000000000000000000000080058004f00750074000000060000000000000000000000000600580049006e00000006000000000000000000000000020058000000060000000000000000000000000c0044006200540079007000650000000a00000000140053006d003200540069006d0065004d00610070"

local seq = elem("Sequence", "", {
    elem("Sm2TiTrack", "", {
        elem("Type", "0"),
        wrap_clips(
            elem("Sm2TiVideoClip", { DbId = "v1" }, {
                elem("Name", "34-262-1"),
                elem("Start", "148280"),
                elem("Duration", "224"),
                elem("MediaStartTime", "10515.6"),
                elem("In", "330|00609ad8899de83f"),
                elem("MediaFilePath", "/Volumes/AnamBack4 Joe/Footage/Day 10/A030/A030_11130255_C012.mov"),
                elem("MediaTimemapBA", mtba_a030),
                elem("MediaFrameRate", "0000000000003940"),  -- 25fps LE double
            })
        ),
    }),
})

local tracks = drp_importer.parse_resolve_tracks(seq, { frame_rate = 25 })
assert(#tracks == 1, "expected 1 video track")
assert(#tracks[1].clips == 1, "expected 1 clip")
local clip = tracks[1].clips[1]

-- Domain ground truth: Resolve's media-managed trim TC = 02:55:32:20 = 263320.
local EXPECTED_SOURCE_IN = 263320

print(string.format("  source_in = %d (expected %d, diff %+d)",
    clip.source_in, EXPECTED_SOURCE_IN, clip.source_in - EXPECTED_SOURCE_IN))
assert(clip.source_in == EXPECTED_SOURCE_IN, string.format(
    "retimed clip with sub-frame <In> must sample the curve at the sub-frame-" ..
    "accurate position. Expected source_in %d (= Resolve trim TC 02:55:32:20). " ..
    "Got %d. The retime branch is dropping the <In> sub-frame (0.769 timeline " ..
    "frames × 1.30 speed = 1.0 source frame).",
    EXPECTED_SOURCE_IN, clip.source_in))

print("✅ test_drp_retime_subframe_inclusion.lua passed")
