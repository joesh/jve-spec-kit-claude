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
-- Test 1: Retimed video clip with hex speed (probe unavailable — hex fallback)
-- Verifies that speed is applied to BOTH in_value and duration_raw
--------------------------------------------------------------------------------

print("\n--- Test 1: Retimed clip hex fallback applies speed to both in and duration ---")

-- Hex for 19/21 = 0.904761... (LE IEEE 754)
local hex_speed = "007aeb3ccff3ec3f"

local seq = elem("Sequence", "", {
    elem("Sm2TiTrack", "", {
        elem("Type", "0"),
        wrap_clips(
            elem("Sm2TiVideoClip", "", {
                elem("Name", "retimed_clip"),
                elem("Start", "15880"),
                elem("Duration", "181"),
                elem("MediaStartTime", "0"),
                elem("In", "34|" .. hex_speed),
                elem("MediaFilePath", "/nonexistent/retimed.mxf"),
            })
        ),
    }),
})

local video_tracks = drp_importer._parse_resolve_tracks(seq, 25)
local clip = video_tracks[1].clips[1]

-- source_in must NOT be raw 34 — it must be scaled by speed
-- With hex speed 0.9048: source_in = floor(34 * 0.9048 + 0.5) = 31
-- (Correct value from probe would be ~29, but hex is fallback)
assert(clip.source_in ~= 34, string.format(
    "REGRESSION: retimed source_in must not be raw in_value (got %d, expected ~31 not 34)",
    clip.source_in))
local expected_in = math.floor(34 * (19/21) + 0.5)
assert(clip.source_in == expected_in, string.format(
    "Retimed source_in should be %d (hex fallback), got %d", expected_in, clip.source_in))
print(string.format("  ✓ source_in = %d (scaled by hex speed, not raw 34)", clip.source_in))

-- source_duration must also be scaled
local expected_dur = math.floor(181 * (19/21) + 0.5)
local actual_dur = clip.source_out - clip.source_in
assert(actual_dur == expected_dur, string.format(
    "Retimed source_duration should be %d, got %d", expected_dur, actual_dur))
print(string.format("  ✓ source_duration = %d (scaled)", actual_dur))

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
            })
        ),
    }),
})

local v_normal = drp_importer._parse_resolve_tracks(seq_normal, 25)
local normal = v_normal[1].clips[1]

assert(normal.source_in == 50, "Non-retimed source_in should be 50, got " .. normal.source_in)
assert(normal.source_out == 250, "Non-retimed source_out should be 250, got " .. normal.source_out)
assert(normal.duration == 200, "Non-retimed duration should be 200")
print("  ✓ source_in = 50, source_out = 250 (non-retimed, raw values)")

--------------------------------------------------------------------------------
-- Test 3: Speed ratio derivable from clip fields
-- The playback engine computes speed = (source_out - source_in) / duration.
-- For a retimed clip, this should be < 1.0 (slow motion).
--------------------------------------------------------------------------------

print("\n--- Test 3: Derived speed ratio is < 1.0 for slow-motion clip ---")

local derived_speed = (clip.source_out - clip.source_in) / clip.duration
assert(derived_speed < 1.0, string.format(
    "Derived speed should be < 1.0 for slow-mo, got %.4f", derived_speed))
assert(derived_speed > 0.5, string.format(
    "Derived speed should be > 0.5 (not too far from 0.84), got %.4f", derived_speed))
print(string.format("  ✓ derived speed = %.4f (< 1.0, slow-mo)", derived_speed))

--------------------------------------------------------------------------------
-- Test 4: Fast-forward clip (speed > 1.0)
--------------------------------------------------------------------------------

print("\n--- Test 4: Fast-forward clip (hex speed > 1.0) ---")

-- Hex for 2.0 (LE IEEE 754): 0000000000000040
local hex_fast = "0000000000000040"

local seq_fast = elem("Sequence", "", {
    elem("Sm2TiTrack", "", {
        elem("Type", "0"),
        wrap_clips(
            elem("Sm2TiVideoClip", "", {
                elem("Name", "fast_clip"),
                elem("Start", "0"),
                elem("Duration", "100"),
                elem("MediaStartTime", "0"),
                elem("In", "20|" .. hex_fast),
                elem("MediaFilePath", "/nonexistent/fast.mxf"),
            })
        ),
    }),
})

local v_fast = drp_importer._parse_resolve_tracks(seq_fast, 25)
local fast = v_fast[1].clips[1]

-- source_in = floor(20 * 2.0 + 0.5) = 40
assert(fast.source_in == 40, "Fast source_in should be 40, got " .. fast.source_in)
-- source_duration = floor(100 * 2.0 + 0.5) = 200
local fast_dur = fast.source_out - fast.source_in
assert(fast_dur == 200, "Fast source_duration should be 200, got " .. fast_dur)
-- Derived speed > 1.0
local fast_speed = fast_dur / fast.duration
assert(fast_speed > 1.0, string.format("Fast speed should be > 1.0, got %.4f", fast_speed))
print(string.format("  ✓ source_in=%d, source_dur=%d, speed=%.1f", fast.source_in, fast_dur, fast_speed))

--------------------------------------------------------------------------------
-- Test 5: REAL DATA — clip 40-335.3-1 from fixture DRP
-- Fixture: tests/fixtures/resolve/2026-03-01-anamnesis joe edit.drp
-- Sequence: 3890091e-19cd-415c-935d-3d4a8c28647e
--
-- This clip has <In>2327|000000000000ac3d</In> where the hex decodes to
-- ≈1.27e-11 (garbage, not a real speed). The 660-byte MediaTimemapBA confirms
-- speed=1.0 (YMax=XMax=118.64). Without the fix, source_in=0 (wrong).
-- With the fix, source_in=2327 (correct non-retimed source offset).
--------------------------------------------------------------------------------

print("\n--- Test 5: Real DRP clip 40-335.3-1 — garbage hex speed must not zero source_in ---")

-- Real MTBA hex from the DRP clip (660-byte version 1 blob)
local real_mtba_hex = "0000000100000006000000080059004d006100780000000600405da8f5c28f5c3d000000080058004d006100780000000600405da8f5c28f5c3d000000100055006e0069007100750065004900640000000a000000004800650062006300380039003600650065002d0033006600650064002d0034003700380039002d0039003000650064002d00610039003200340031003600390038006400300036003300000020004c00610073007400560061006c006900640059004f006600660073006500740000000600405da8f5c28f5c3d00000016004b00650079006600720061006d00650073004200410000000c000000017400000001000000020000000200310000000c00000000a700000001000000070000000c0069006e0074006500720070000000020000000000000000080059004f00750074000000060000000000000000000000000600590049006e0000000600000000000000000000000002005900000006000000000000000000000000080058004f00750074000000060000000000000000000000000600580049006e000000060000000000000000000000000200580000000600405da8f5c28f5c3d0000000200300000000c00000000a700000001000000070000000c0069006e0074006500720070000000020000000000000000080059004f00750074000000060000000000000000000000000600590049006e000000060000000000000000000000000200590000000600405da8f5c28f5c3d000000080058004f00750074000000060000000000000000000000000600580049006e00000006000000000000000000000000020058000000060000000000000000000000000c0044006200540079007000650000000a00000000140053006d003200540069006d0065004d00610070"

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
            })
        ),
    }),
})

local v_real = drp_importer._parse_resolve_tracks(seq_real, 25)
local real_clip = v_real[1].clips[1]

-- Before fix: garbage speed 1.27e-11 accepted → source_in = floor(2327 * 1.27e-11) = 0
-- After fix: garbage rejected, MTBA confirms speed=1.0 → source_in = 2327
assert(real_clip.source_in == 2327, string.format(
    "REGRESSION: clip 40-335.3-1 source_in must be 2327 (not 0 from garbage speed), got %d",
    real_clip.source_in))
assert(real_clip.source_out == 2327 + 109, string.format(
    "source_out should be %d, got %d", 2327 + 109, real_clip.source_out))
assert(real_clip.duration == 109, "timeline duration should be 109, got " .. real_clip.duration)
assert(math.abs(real_clip.clip_speed - 1.0) < 0.001, string.format(
    "clip_speed should be 1.0 (MTBA YMax=XMax), got %.4f", real_clip.clip_speed))
print(string.format("  ✓ source_in=%d source_out=%d duration=%d speed=%.1f",
    real_clip.source_in, real_clip.source_out, real_clip.duration, real_clip.clip_speed))

--------------------------------------------------------------------------------
-- Test 6: REAL DATA — decode_media_timemap on the real 660-byte MTBA blob
-- Verifies YMax=118.64, XMax=118.64, speed_ratio=1.0, forward
--------------------------------------------------------------------------------

print("\n--- Test 6: Real MTBA blob decode → YMax=XMax=118.64, speed=1.0 ---")

local result_real = drp_importer._decode_media_timemap(real_mtba_hex)
assert(result_real, "decode_media_timemap must succeed on real MTBA blob")
assert(math.abs(result_real.y_max - 118.64) < 0.01, string.format(
    "YMax should be ~118.64, got %.4f", result_real.y_max))
assert(math.abs(result_real.x_max - 118.64) < 0.01, string.format(
    "XMax should be ~118.64, got %.4f", result_real.x_max))
assert(math.abs(result_real.speed_ratio - 1.0) < 0.001, string.format(
    "speed_ratio should be 1.0 (YMax=XMax), got %.4f", result_real.speed_ratio))
assert(result_real.is_reverse == false, "Real clip should not be reverse")
print(string.format("  ✓ YMax=%.2f XMax=%.2f speed_ratio=%.1f is_reverse=%s",
    result_real.y_max, result_real.x_max, result_real.speed_ratio,
    tostring(result_real.is_reverse)))

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
            })
        ),
    }),
})

local v_nohex = drp_importer._parse_resolve_tracks(seq_nohex, 25)
local nohex_clip = v_nohex[1].clips[1]

assert(nohex_clip.source_in == 1163, string.format(
    "Non-hex clip source_in should be 1163, got %d", nohex_clip.source_in))
assert(nohex_clip.source_out == 1163 + 117, string.format(
    "source_out should be %d, got %d", 1163 + 117, nohex_clip.source_out))
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
-- Bug: importer used hex magnitude (0.7273) instead of MTBA magnitude (0.88)
-- Result: source_in = floor(447 * 0.7273) = 325 (wrong)
-- Expected: source_in = floor(447 * 0.88) = 393 (correct, matches Resolve TC)
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
            })
        ),
    }),
})

local v_333 = drp_importer._parse_resolve_tracks(seq_333, 25)
local clip_333 = v_333[1].clips[1]

-- MTBA speed = YMax/XMax = 73.28/83.28 ≈ 0.8799 (88%)
-- source_in = floor(447 * 0.8799 + 0.5) = 393
-- Resolve source TC 01:14:36:16 = media_start(01:14:20:22) + 394 frames (≈393-394 depending on rounding)
local mtba_speed = 73.28 / 83.28  -- ≈ 0.8799
local expected_in_333 = math.floor(447 * mtba_speed + 0.5)
assert(clip_333.source_in == expected_in_333, string.format(
    "REGRESSION: clip 01-333-2 source_in must use MTBA speed (expected %d, got %d). "..
    "Hex speed 0.7273 is wrong; MTBA 0.88 is correct.",
    expected_in_333, clip_333.source_in))
print(string.format("  ✓ source_in = %d (MTBA speed, not hex 0.7273 → %d)",
    clip_333.source_in, math.floor(447 * 0.7273 + 0.5)))

-- source_duration must also use MTBA speed
local expected_dur_333 = math.floor(132 * mtba_speed + 0.5)
local actual_dur_333 = clip_333.source_out - clip_333.source_in
assert(actual_dur_333 == expected_dur_333, string.format(
    "source_duration should be %d (MTBA), got %d", expected_dur_333, actual_dur_333))
print(string.format("  ✓ source_duration = %d (MTBA speed)", actual_dur_333))

-- clip_speed must reflect MTBA magnitude
assert(math.abs(clip_333.clip_speed - mtba_speed) < 0.01, string.format(
    "clip_speed should be ~%.4f (MTBA), got %.4f", mtba_speed, clip_333.clip_speed))
print(string.format("  ✓ clip_speed = %.4f (matches MTBA, not hex 0.7273)", clip_333.clip_speed))

-- Timeline duration unchanged
assert(clip_333.duration == 132, "Timeline duration should be 132, got " .. clip_333.duration)
print("  ✓ timeline duration = 132 (unchanged)")

print("\n✅ test_drp_retimed_clip_speed.lua passed")
