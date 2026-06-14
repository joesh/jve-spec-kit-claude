#!/usr/bin/env luajit
-- Regression test: a timeline clip with a reverse retime curve imports
-- correctly when the clip's timeline duration reaches the curve's domain
-- boundary.
--
-- Domain: A reverse clip plays the SAME source span a forward clip would,
-- but last-frame-first. The forward span is frames [S, S+dur). Reversed, the
-- playback entry is the last forward frame (S+dur-1, inclusive) and the
-- exclusive boundary going downward is S-1 — mirroring forward's inclusive
-- low / exclusive high. So the model convention is `source_in` = highest
-- forward frame (inclusive, = playback start), `source_out` = lowest frame
-- minus one (exclusive lower bound), with `clip_speed` negative to mark the
-- direction. (source_out - source_in) = -dur keeps speed_ratio = -1, and the
-- universal decode source_in + offset*speed walks the span down with no
-- reverse special-case anywhere downstream.
--
-- For extreme retimes (e.g. 493× reverse) the curve's valid domain (XMax
-- playback seconds) can be shorter than the clip's timeline duration. When
-- the curve is evaluated past XMax the source position is clamped to the
-- curve's final Y value (the file's first frame, Y=0 for a reverse curve
-- that spans the whole master clip). The clip's lowest played source frame
-- is the file's first frame (the TC origin); the exclusive lower bound
-- (source_out) then sits one below it (origin-1), exactly as a forward clip's
-- exclusive source_out can sit one past its last frame. The importer must:
--   - keep the lowest played frame (source_out + 1) at/after the TC origin
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
-- Assertion 3: EXACT endpoints. The fixture's forward source span is derived
-- from the curve: the highest source time it reaches is YMax=927.584s × 25fps
-- = 23189.6 frames, so the highest WHOLE source frame played is frame 23189
-- (relative), anchored at the file TC origin (90000) → absolute frame 113189.
-- The lowest is the file's first frame (90000). So the played source region is
-- {90000 .. 113189} (23190 frames). Reversed playback enters at the highest
-- frame (113189) and the exclusive lower bound sits one below the lowest
-- (90000 - 1 = 89999).
--
-- The exact convention here is anchored by the real Resolve A/B fixture
-- "test audio, reverse audio.drp" (see integration_test_drp_reverse_audio_pair):
-- a reverse clip covers the SAME source region as its forward twin, so its
-- span equals the forward span and source_in is the highest played frame.
--
-- Two off-by-one regressions this guards:
--   (a) old plain swap stored the exclusive upper bound as source_in (entry
--       one frame PAST the span) — fixed by the inclusive-high/exclusive-low
--       swap in the importer.
--   (b) the reverse curve branch counted out_frame as exclusive when, after
--       the y_first/y_last swap, it is the INCLUSIVE highest frame — dropping
--       the top (first-played) frame and making the reverse span one frame
--       short. Fixed by the reverse +1 in the importer's source_duration.
-- ---------------------------------------------------------------------------
local FORWARD_SPAN_LOW  = 90000    -- TC origin = file's first frame
local FORWARD_SPAN_HIGH = 113189   -- origin + 23190 - 1 (last forward frame)
assert(clip.source_in == FORWARD_SPAN_HIGH,
    string.format("reverse source_in must be the highest forward frame %d, got %d",
        FORWARD_SPAN_HIGH, clip.source_in))
assert(clip.source_out == FORWARD_SPAN_LOW - 1,
    string.format("reverse source_out must be lowest frame - 1 (exclusive) %d, got %d",
        FORWARD_SPAN_LOW - 1, clip.source_out))

-- The lowest PLAYED frame (source_out + 1) stays at/after the file TC origin;
-- the exclusive bound itself is allowed to sit one below.
assert(clip.source_out + 1 >= MEDIA_TC_ORIGIN,
    string.format("lowest played frame (source_out+1=%d) must be >= TC origin %d",
        clip.source_out + 1, MEDIA_TC_ORIGIN))

print("\n✅ test_drp_reverse_clip_import.lua passed")
