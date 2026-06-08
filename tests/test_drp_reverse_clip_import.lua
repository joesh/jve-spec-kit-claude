#!/usr/bin/env luajit
-- Regression test: a timeline clip with a reverse retime curve imports
-- correctly when the clip's timeline duration reaches the curve's domain
-- boundary.
--
-- Domain: A reverse clip plays source frames from a HIGH frame down to a
-- LOW frame. After import, the model convention is that `source_in` holds
-- the clip's playback-start (high) frame and `source_out` the playback-end
-- (low) frame, with `clip_speed` negative to mark the reverse direction.
--
-- For extreme retimes (e.g. 493× reverse) the curve's valid domain (XMax
-- playback seconds) can be shorter than the clip's timeline duration. When
-- the curve is evaluated past XMax the source position is clamped to the
-- curve's final Y value (the file's first frame, Y=0 for a reverse curve
-- that spans the whole master clip). The clip's playable source range then
-- stops at source frame 0 — never below — and the importer must:
--   - produce non-negative source-frame offsets
--   - report `source_in > source_out` (reverse convention)
--   - mark `clip_speed < 0`
--
-- The MTBA blob here is copied from a real production clip
-- ('timetravel-back-to-hospital-shes-gone' in the anamnesis gold master):
-- YMax=927.584s, XMax=1.88s (= 47 timeline frames), speed = YMax/XMax ≈ 493,
-- keyframes (X=0, Y=YMax) → (X=XMax, Y=0).

require("test_env")

local drp_importer = require("importers.drp_importer")

print("=== test_drp_reverse_clip_import.lua ===")

-- ---------------------------------------------------------------------------
-- Test-element helpers.
-- ---------------------------------------------------------------------------

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
-- Reverse MTBA curve from a real production clip. 493× reverse.
-- Keyframes: (X=0s, Y=927.584s) → (X=1.88s, Y=0s).
-- Evaluating past X=1.88s clamps Y to 0 (the file's first source frame).
-- ---------------------------------------------------------------------------

local MTBA_REVERSE =
    "0000000100000006000000080059004d006100780000000600408cfcac5f92c5fa00000008005800" ..
    "4d0061007800000006003ffe147ae147ae16000000100055006e0069007100750065004900640000" ..
    "000a000000004800650063003800310033003000610036002d0033003900630065002d0034003900" ..
    "620065002d0061003100370038002d00610064006200390033006100610061003600620064003900" ..
    "000020004c00610073007400560061006c006900640059004f006600660073006500740000000600" ..
    "408d9a3d70a3d70b00000016004b00650079006600720061006d00650073004200410000000c0000" ..
    "00017400000001000000020000000200310000000c00000000a700000001000000070000000c0069" ..
    "006e0074006500720070000000020000000000000000080059004f00750074000000060000000000" ..
    "000000000000000600590049006e0000000600000000000000000000000002005900000006000000" ..
    "000000000000000000080058004f0075007400000006000000000000000000000000060058004900" ..
    "6e0000000600000000000000000000000002005800000006003ffe147ae147ae1600000002003000" ..
    "00000c00000000a700000001000000070000000c0069006e00740065007200700000000200000000" ..
    "00000000080059004f00750074000000060000000000000000000000000600590049006e00000006" ..
    "0000000000000000000000000200590000000600408cfcac5f92c5fa000000080058004f00750074" ..
    "000000060000000000000000000000000600580049006e0000000600000000000000000000000002" ..
    "0058000000060000000000000000000000000c0044006200540079007000650000000a0000000014" ..
    "0053006d003200540069006d0065004d00610070"

local MEDIA_FRAME_RATE_25 = "00000000000039400000000000000000"

-- ---------------------------------------------------------------------------
-- Inputs — clip duration (48 frames at 25fps = 1.92s) exceeds the curve's
-- XMax (1.88s). The curve evaluator clamps past its domain; the importer
-- must still produce a valid (in, out, speed<0) triple.
-- ---------------------------------------------------------------------------

local SEQ_FPS = 25
local MEDIA_FPS = 25
local MEDIA_START_SEC = 3600.0   -- 01:00:00:00
local MEDIA_TC_ORIGIN = math.floor(MEDIA_START_SEC * MEDIA_FPS + 0.5)
local TIMELINE_DURATION = 48

-- ---------------------------------------------------------------------------
-- Build a synthetic DRP timeline clip and run the importer.
-- ---------------------------------------------------------------------------

local seq_elem = elem("Sequence", "", {
    elem("Sm2TiTrack", "", {
        elem("Type", "0"),  -- 0 = VIDEO
        wrap(
            elem("Sm2TiVideoClip", { DbId = "v1" }, {
                elem("Name", "reverse_clamped"),
                elem("Start", "0"),
                elem("Duration", tostring(TIMELINE_DURATION)),
                elem("MediaStartTime", tostring(MEDIA_START_SEC)),
                elem("In", ""),
                elem("MediaFilePath", "/test/reverse.mov"),
                elem("MediaFrameRate", MEDIA_FRAME_RATE_25),
                elem("MediaTimemapBA", MTBA_REVERSE),
            })
        ),
    }),
})

local video_tracks = drp_importer.parse_resolve_tracks(seq_elem, { frame_rate = SEQ_FPS })
assert(#video_tracks == 1 and #video_tracks[1].clips == 1, "expected 1 clip")
local clip = video_tracks[1].clips[1]

print(string.format("Imported: source_in=%d source_out=%d clip_speed=%.3f",
    clip.source_in, clip.source_out, clip.clip_speed))

-- ---------------------------------------------------------------------------
-- Assertion 1: reverse direction is detected and marked.
-- ---------------------------------------------------------------------------
assert(clip.clip_speed < 0,
    string.format("reverse curve must produce negative clip_speed, got %f",
        clip.clip_speed))

-- ---------------------------------------------------------------------------
-- Assertion 2: source_in > source_out (reverse-clip model convention:
-- playback starts at the high source frame and ends at the low one).
-- ---------------------------------------------------------------------------
assert(clip.source_in > clip.source_out,
    string.format("reverse clip must have source_in > source_out, got %d vs %d",
        clip.source_in, clip.source_out))

-- ---------------------------------------------------------------------------
-- Assertion 3: both endpoints are inside the source file (source frame
-- indices must be at or after the file's TC origin, i.e. non-negative
-- relative to MEDIA_TC_ORIGIN).
-- ---------------------------------------------------------------------------
assert(clip.source_out >= MEDIA_TC_ORIGIN,
    string.format("source_out must be at or after file TC origin %d, got %d",
        MEDIA_TC_ORIGIN, clip.source_out))
assert(clip.source_in >= MEDIA_TC_ORIGIN,
    string.format("source_in must be at or after file TC origin %d, got %d",
        MEDIA_TC_ORIGIN, clip.source_in))

print("\n✅ test_drp_reverse_clip_import.lua passed")
