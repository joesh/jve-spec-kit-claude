#!/usr/bin/env luajit
-- Regression test: DRP retimed clips must convert in_value and duration_raw
-- from retimed timebase to actual source frames.
--
-- DRP <In> for retimed clips: "frame_number|hex_speed" where both the integer
-- AND duration_raw are in RETIMED timebase (not actual source frames).
-- The speed ratio converts retimed → source: source_frame = retimed_frame * speed.
--
-- Ground truth from FCP XML (same clip, same project):
--   File: A004_05201551_C030 VFX_01.mxf — 182 actual frames at 25fps
--   Clipitem duration: 216 (retimed total)
--   In: 34 (retimed), Out: 215 (retimed)
--   Time Remap filter: speed = 84%
--   Keyframes: retimed 34 → source 28.56, retimed 216 → source 182.16
--   Actual speed: 182/216 = 0.8426
--
-- DRP hex speed: 19/21 = 0.9048 (NOT the actual speed — empirically wrong)

require("test_env")

print("=== test_drp_retimed_clip_speed.lua ===")

local drp_importer = require("importers.drp_importer")

local function elem(tag, text, children)
    return {
        tag = tag,
        attrs = {},
        children = children or {},
        text = text or "",
    }
end

local function wrap_clips(...)
    local elements = {}
    for _, clip in ipairs({...}) do
        table.insert(elements, elem("Element", "", {clip}))
    end
    return elem("Items", "", elements)
end

--------------------------------------------------------------------------------
-- Test 1: Clip with no MTBA → non-retimed (hex suffix in <In> is ignored)
-- The hex after the pipe is flags/metadata, not a speed value.
--------------------------------------------------------------------------------

print("\n--- Test 1: No MTBA → non-retimed (hex suffix ignored) ---")

local seq = elem("Sequence", "", {
    elem("Sm2TiTrack", "", {
        elem("Type", "0"),
        wrap_clips(
            elem("Sm2TiVideoClip", "", {
                elem("Name", "non_retimed_clip"),
                elem("Start", "15880"),
                elem("Duration", "181"),
                elem("MediaStartTime", "0"),
                elem("In", "34|007aeb3ccff3ec3f"),  -- hex suffix = flags, not speed
                elem("MediaFilePath", "/nonexistent/retimed.mxf"),
                elem("MediaFrameRate", "0000000000003940"),  -- 25fps LE double
                -- No MediaTimemapBA → not retimed
            })
        ),
    }),
})

local video_tracks = drp_importer.parse_resolve_tracks(seq, 25)
local clip = video_tracks[1].clips[1]

-- No MTBA = not retimed. source_in = raw in_value (34)
assert(clip.source_in == 34, string.format(
    "No MTBA: source_in should be raw in_value 34, got %d", clip.source_in))
print(string.format("  ✓ source_in = %d (not retimed, hex suffix ignored)", clip.source_in))

-- source_duration = raw duration (181)
local actual_dur = clip.source_out - clip.source_in
assert(actual_dur == 181, string.format(
    "No MTBA: source_duration should be raw 181, got %d", actual_dur))
print(string.format("  ✓ source_duration = %d (not retimed)", actual_dur))

-- Timeline duration unchanged
assert(clip.duration == 181, "Timeline duration should be 181, got " .. clip.duration)
print("  ✓ timeline duration = 181 (unchanged)")

--------------------------------------------------------------------------------
-- Test 2: Non-retimed clip (no hex) is NOT affected by retiming logic
--------------------------------------------------------------------------------

print("\n--- Test 2: Non-retimed clip preserves raw in_value ---")

local seq_normal = elem("Sequence", "", {
    elem("Sm2TiTrack", "", {
        elem("Type", "0"),
        wrap_clips(
            elem("Sm2TiVideoClip", "", {
                elem("Name", "normal_clip"),
                elem("Start", "0"),
                elem("Duration", "200"),
                elem("MediaStartTime", "0"),
                elem("In", "50"),
                elem("MediaFilePath", "/nonexistent/normal.mxf"),
                elem("MediaFrameRate", "0000000000003940"),  -- 25fps LE double
            })
        ),
    }),
})

local v_normal = drp_importer.parse_resolve_tracks(seq_normal, 25)
local normal = v_normal[1].clips[1]

assert(normal.source_in == 50, "Non-retimed source_in should be 50, got " .. normal.source_in)
assert(normal.source_out == 250, "Non-retimed source_out should be 250, got " .. normal.source_out)
assert(normal.duration == 200, "Non-retimed duration should be 200")
print("  ✓ source_in = 50, source_out = 250 (non-retimed, raw values)")

-- Test 3 removed: derived speed test moved to Test 8 which uses real MTBA data

--------------------------------------------------------------------------------
-- Test 4: Clip with hex suffix but no MTBA — also non-retimed
--------------------------------------------------------------------------------

print("\n--- Test 4: Another no-MTBA clip (hex suffix ignored) ---")

local seq_fast = elem("Sequence", "", {
    elem("Sm2TiTrack", "", {
        elem("Type", "0"),
        wrap_clips(
            elem("Sm2TiVideoClip", "", {
                elem("Name", "fast_clip"),
                elem("Start", "0"),
                elem("Duration", "100"),
                elem("MediaStartTime", "0"),
                elem("In", "20|0000000000000040"),  -- hex suffix = flags
                elem("MediaFilePath", "/nonexistent/fast.mxf"),
                elem("MediaFrameRate", "0000000000003940"),  -- 25fps LE double
                -- No MediaTimemapBA → not retimed
            })
        ),
    }),
})

local v_fast = drp_importer.parse_resolve_tracks(seq_fast, 25)
local fast = v_fast[1].clips[1]

-- No MTBA = not retimed. source_in = raw in_value (20)
assert(fast.source_in == 20, "No MTBA: source_in should be 20, got " .. fast.source_in)
local fast_dur = fast.source_out - fast.source_in
assert(fast_dur == 100, "No MTBA: source_duration should be 100, got " .. fast_dur)
print(string.format("  ✓ source_in=%d, source_dur=%d (non-retimed)", fast.source_in, fast_dur))

--------------------------------------------------------------------------------
-- Test 5: REAL DATA — clip 40-335.3-1 from fixture DRP
-- Fixture: tests/fixtures/resolve/anamnesis joe edit.drp
-- Sequence: 3890091e-19cd-415c-935d-3d4a8c28647e
--
-- This clip has <In>2327|000000000000ac3d</In> where the hex decodes to
-- ≈1.27e-11 (garbage, not a real speed). The 660-byte MediaTimemapBA confirms
-- speed=1.0 (YMax=XMax=118.64). Without the fix, source_in=0 (wrong).
-- With the fix, source_in=2327 (correct non-retimed source offset).
--------------------------------------------------------------------------------

print("\n--- Test 5: Real DRP clip 40-335.3-1 — garbage hex speed must not zero source_in ---")

-- 9-byte short MTBA from the non-retimed version of this clip.
-- The 660-byte v1 blob has KeyframesBA whose X/Y values are degenerate
-- (YMax=XMax=118.64, keyframes appear reversed). Use the short form which
-- correctly signals "no retime" — the garbage hex speed is then rejected
-- by the < 0.05 guard and clip_speed stays 1.0.
local real_mtba_hex = "02405da8f5c28f5c29"

local seq_real = elem("Sequence", "", {
    elem("Sm2TiTrack", "", {
        elem("Type", "0"),
        wrap_clips(
            elem("Sm2TiVideoClip", "", {
                elem("Name", "40-335.3-1"),
                elem("Start", "91606"),
                elem("Duration", "109"),
                elem("MediaStartTime", "14481.12"),
                elem("In", "2327|000000000000ac3d"),
                elem("MediaFilePath", "/Volumes/AnamBack4 Joe/Day 12/A036/A036_11200401_C002.mov"),
                elem("MediaTimemapBA", real_mtba_hex),
                elem("MediaFrameRate", "0000000000003940"),  -- 25fps LE double
            })
        ),
    }),
})

local v_real = drp_importer.parse_resolve_tracks(seq_real, 25)
local real_clip = v_real[1].clips[1]

-- Before fix: garbage speed 1.27e-11 accepted → source_in = floor(2327 * 1.27e-11) = 0
-- After fix: garbage rejected, MTBA confirms speed=1.0 → source_in = media_tc_origin + 2327
-- media_tc_origin = floor(14481.12 * 25 + 0.5) = 362028
local mst5_origin = math.floor(14481.12 * 25 + 0.5)  -- 362028
assert(real_clip.source_in == mst5_origin + 2327, string.format(
    "REGRESSION: clip 40-335.3-1 source_in must be %d (abs TC), got %d",
    mst5_origin + 2327, real_clip.source_in))
assert(real_clip.source_out == mst5_origin + 2327 + 109, string.format(
    "source_out should be %d, got %d", mst5_origin + 2327 + 109, real_clip.source_out))
assert(real_clip.duration == 109, "timeline duration should be 109, got " .. real_clip.duration)
assert(math.abs(real_clip.clip_speed - 1.0) < 0.001, string.format(
    "clip_speed should be 1.0 (MTBA YMax=XMax), got %.4f", real_clip.clip_speed))
print(string.format("  ✓ source_in=%d source_out=%d duration=%d speed=%.1f",
    real_clip.source_in, real_clip.source_out, real_clip.duration, real_clip.clip_speed))

--------------------------------------------------------------------------------
-- Test 6: 9-byte MTBA returns nil (short form has no speed/direction data)
--------------------------------------------------------------------------------

print("\n--- Test 6: 9-byte MTBA → nil (no speed/direction data) ---")

local result_real = drp_importer.decode_media_timemap(real_mtba_hex)
assert(result_real == nil, "9-byte MTBA should return nil from decode_media_timemap")
print("  ✓ 9-byte MTBA correctly returns nil")

--------------------------------------------------------------------------------
-- Test 7: REAL DATA — same clip in different sequence (no hex, 9-byte MTBA)
-- Sequence dcefce24: In=1163, Duration=117, MTBA=02405da8f5c28f5c29 (9 bytes)
-- This version was never affected by the bug — validates non-retimed path.
--------------------------------------------------------------------------------

print("\n--- Test 7: Real clip in non-retimed sequence (no hex speed) ---")

local seq_nohex = elem("Sequence", "", {
    elem("Sm2TiTrack", "", {
        elem("Type", "0"),
        wrap_clips(
            elem("Sm2TiVideoClip", "", {
                elem("Name", "40-335.3-1"),
                elem("Start", "90904"),
                elem("Duration", "117"),
                elem("MediaStartTime", "14481.12"),
                elem("In", "1163"),
                elem("MediaFilePath", "/Users/joe/Movies/ProxyMedia/Day 12/AO36/A036_11200401_C002.mov"),
                elem("MediaTimemapBA", "02405da8f5c28f5c29"),
                elem("MediaFrameRate", "0000000000003940"),  -- 25fps LE double
            })
        ),
    }),
})

local v_nohex = drp_importer.parse_resolve_tracks(seq_nohex, 25)
local nohex_clip = v_nohex[1].clips[1]

-- media_tc_origin = floor(14481.12 * 25 + 0.5) = 362028
local mst7_origin = math.floor(14481.12 * 25 + 0.5)
assert(nohex_clip.source_in == mst7_origin + 1163, string.format(
    "Non-hex clip source_in should be %d (abs TC), got %d", mst7_origin + 1163, nohex_clip.source_in))
assert(nohex_clip.source_out == mst7_origin + 1163 + 117, string.format(
    "source_out should be %d, got %d", mst7_origin + 1163 + 117, nohex_clip.source_out))
assert(math.abs(nohex_clip.clip_speed - 1.0) < 0.001, string.format(
    "clip_speed should be 1.0, got %.4f", nohex_clip.clip_speed))
print(string.format("  ✓ source_in=%d source_out=%d (different trim, same media)",
    nohex_clip.source_in, nohex_clip.source_out))

--------------------------------------------------------------------------------
-- Test 8: REAL DATA — clip 01-333-2 from fixture DRP
-- Resolve shows: Speed 88.00%, FPS 22.000, Duration 00:00:05:07
-- Source TC: 01:14:36:16 (media start TC 01:14:20:22 → offset 394 frames)
--
-- DRP data:
--   <In>447|00f05d74d145e73f</In>  — hex speed decodes to 0.7273 (WRONG)
--   <MediaTimemapBA> blob: YMax=73.28s, XMax=83.28s → speed=0.8799 (CORRECT, 88%)
--   <Duration>132</Duration>
--
-- The importer walks the curve: in_seconds = 447/25 = 17.88s,
-- y_in = 17.88 × (73.28/83.28) ≈ 15.7322 source seconds
-- in_offset = ceil(15.7322 × 25) = ceil(393.305) = 394 frames
-- source_in = 111522 + 394 = 111916, matching Resolve's 01:14:36:16.
--------------------------------------------------------------------------------

print("\n--- Test 8: Real clip 01-333-2 — MTBA speed must override hex speed magnitude ---")

-- Real MTBA blob from the DRP (YMax=73.28s, XMax=83.28s → speed=0.8799)
local mtba_333_2 = "0000000100000006000000080059004d006100780000000600405251eb851eb83d000000080058004d0061007800000006004054d1cdbb1cdb9b000000100055006e0069007100750065004900640000000a000000004800390038003000300033006300620063002d0063006500640064002d0034003300340063002d0039003100640063002d00350031006100310030003100350036006100300066006200000020004c00610073007400560061006c006900640059004f006600660073006500740000000600405251eb851eb83d00000016004b00650079006600720061006d00650073004200410000000c000000017400000001000000020000000200310000000c00000000a700000001000000070000000c0069006e0074006500720070000000020000000000000000080059004f00750074000000060000000000000000000000000600590049006e0000000600000000000000000000000002005900000006004052523a29c77993000000080058004f00750074000000060000000000000000000000000600580049006e0000000600000000000000000000000002005800000006004054d1cdbb1cdb9b0000000200300000000c00000000a700000001000000070000000c0069006e0074006500720070000000020000000000000000080059004f00750074000000060000000000000000000000000600590049006e0000000600000000000000000000000002005900000006000000000000000000000000080058004f00750074000000060000000000000000000000000600580049006e00000006000000000000000000000000020058000000060000000000000000000000000c0044006200540079007000650000000a00000000140053006d003200540069006d0065004d00610070"

local seq_333 = elem("Sequence", "", {
    elem("Sm2TiTrack", "", {
        elem("Type", "0"),
        wrap_clips(
            elem("Sm2TiVideoClip", "", {
                elem("Name", "01-333-2"),
                elem("Start", "92770"),
                elem("Duration", "132"),
                elem("MediaStartTime", "4460.88"),
                elem("In", "447|00f05d74d145e73f"),
                elem("MediaFilePath", "/Volumes/AnamBack4 Joe/Footage/Day 12/A035/A035_11200114_C056.mov"),
                elem("MediaTimemapBA", mtba_333_2),
                elem("MediaFrameRate", "0000000000003940"),  -- 25fps LE double
            })
        ),
    }),
})

local v_333 = drp_importer.parse_resolve_tracks(seq_333, 25)
local clip_333 = v_333[1].clips[1]

-- Domain: MTBA speed = YMax/XMax = 73.28/83.28 ≈ 0.88 (88% speed).
-- Curve walk: in_offset = ceil(447/25 × 0.88 × 25) = ceil(393.305) = 394.
-- media_tc_origin = floor(4460.88 * 25 + 0.5) = 111522
-- source_in = media_tc_origin + in_offset = 111522 + 394 = 111916
-- This matches Resolve's source viewer (01:14:36:16 = frame 111916).
local mst8_origin = math.floor(4460.88 * 25 + 0.5)  -- 111522
assert(clip_333.source_in == mst8_origin + 394, string.format(
    "REGRESSION: clip 01-333-2 source_in must be %d (= 01:14:36:16, abs TC with "..
    "MTBA speed 0.88, ceiling rounded). Got %d.",
    mst8_origin + 394, clip_333.source_in))
print(string.format("  ✓ source_in = %d (curve walk through MTBA, not hex 0.7273 → 325)",
    clip_333.source_in))

-- source_duration: 132 DRP × 0.88 ≈ 116 source frames
local actual_dur_333 = clip_333.source_out - clip_333.source_in
assert(actual_dur_333 == 116, string.format(
    "source_duration: 132 DRP × MTBA 0.88 = 116, got %d", actual_dur_333))
print(string.format("  ✓ source_duration = %d (MTBA speed)", actual_dur_333))

-- clip_speed must reflect MTBA magnitude ≈ 0.88 (not hex 0.7273)
local mtba_speed = 73.28 / 83.28  -- from fixture YMax/XMax
assert(math.abs(clip_333.clip_speed - mtba_speed) < 0.01, string.format(
    "clip_speed should be ~0.88 (MTBA), got %.4f", clip_333.clip_speed))
print(string.format("  ✓ clip_speed = %.4f (matches MTBA, not hex 0.7273)", clip_333.clip_speed))

-- Timeline duration unchanged
assert(clip_333.duration == 132, "Timeline duration should be 132, got " .. clip_333.duration)
print("  ✓ timeline duration = 132 (unchanged)")

print("\n✅ test_drp_retimed_clip_speed.lua passed")
