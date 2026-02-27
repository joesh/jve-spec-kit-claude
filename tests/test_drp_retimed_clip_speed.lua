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

print("\n✅ test_drp_retimed_clip_speed.lua passed")
