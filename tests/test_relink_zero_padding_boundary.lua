#!/usr/bin/env luajit
-- Regression test: a retimed clip whose source range exactly fills the
-- Resolve Media-Manager output must pass the relinker's containment check.
--
-- Domain: Resolve's Media Manager default is ZERO handles. The output file's
-- TC range covers EXACTLY the source frames the timeline clip consumes — no
-- slack on either side. For a clip that plays at non-integer speed, the
-- number of source frames consumed is `floor(timeline_dur × speed)` (last
-- partial frame is not a whole frame and cannot be a file frame of its own).
--
-- If the importer over-counts source frames by 1, the imported clip's source
-- range sits 1 frame past the end of any zero-padding trim of that content —
-- and the relinker's containment check rejects it.
--
-- Concrete scenario: 125 timeline frames at 1.5× speed → 187 whole source
-- frames consumed. A trimmed file sized to exactly 187 frames must contain
-- the imported clip's source range.

require("test_env")

local drp_importer = require("importers.drp_importer")
local M = require("core.media_relinker")

print("=== test_relink_zero_padding_boundary.lua ===")

-- ---------------------------------------------------------------------------
-- Test-element helpers.
-- ---------------------------------------------------------------------------

local function elem(tag, text, children)
    return { tag = tag, attrs = {}, children = children or {}, text = text or "" }
end

local function wrap(...)
    local out = {}
    for _, c in ipairs({...}) do
        table.insert(out, elem("Element", "", {c}))
    end
    return elem("Items", "", out)
end

-- ---------------------------------------------------------------------------
-- MTBA blob: 1.5× constant-speed retime curve.
-- Extracted from retime_matrix_test.drp — Resolve-authored from a hand-written
-- EDL, so this is the exact binary shape Resolve emits for a constant 150%
-- speed clip. Keyframes span (X=0, Y=0) → (X=23.333s, Y=35s).
-- ---------------------------------------------------------------------------

local MTBA_150_PERCENT =
    "0000000100000006000000080059004d006100780000000600404180000000007b00000008005800" ..
    "4d00610078000000060040375555555555f9000000100055006e0069007100750065004900640000" ..
    "000a000000004800650032003200610039006600390063002d0035003300300031002d0034006300" ..
    "300066002d0038003300380038002d00340039003500370062003400380065006300300038003400" ..
    "000020004c00610073007400560061006c006900640059004f006600660073006500740000000600" ..
    "404180000000007b00000016004b00650079006600720061006d00650073004200410000000c0000" ..
    "00017400000001000000020000000200310000000c00000000a700000001000000070000000c0069" ..
    "006e0074006500720070000000020000000000000000080059004f00750074000000060000000000" ..
    "000000000000000600590049006e0000000600000000000000000000000002005900000006004041" ..
    "80000000007b000000080058004f0075007400000006000000000000000000000000060058004900" ..
    "6e00000006000000000000000000000000020058000000060040375555555555f900000002003000" ..
    "00000c00000000a700000001000000070000000c0069006e00740065007200700000000200000000" ..
    "00000000080059004f00750074000000060000000000000000000000000600590049006e00000006" ..
    "00000000000000000000000002005900000006000000000000000000000000080058004f00750074" ..
    "000000060000000000000000000000000600580049006e0000000600000000000000000000000002" ..
    "0058000000060000000000000000000000000c0044006200540079007000650000000a0000000014" ..
    "0053006d003200540069006d0065004d00610070"

-- 25.0 as IEEE-754 little-endian double, padded to 32 hex chars:
local MEDIA_FRAME_RATE_25 = "00000000000039400000000000000000"

-- ---------------------------------------------------------------------------
-- Inputs — chosen so timeline_dur × speed is non-integer (where rounding
-- matters; for integer results ceil/floor agree and no bug can manifest).
-- ---------------------------------------------------------------------------

local SEQ_FPS = 25
local MEDIA_FPS = 25
local MEDIA_START_SEC = 40.0
local MEDIA_TC_ORIGIN = math.floor(MEDIA_START_SEC * MEDIA_FPS + 0.5)
local TIMELINE_DURATION = 125  -- frames
local CLIP_SPEED = 1.5

-- Whole source frames consumed (domain: last partial frame is not a whole
-- file frame and Resolve's zero-padding trim doesn't include it):
local EXPECTED_SOURCE_DURATION = math.floor(TIMELINE_DURATION * CLIP_SPEED)

-- ---------------------------------------------------------------------------
-- Build a synthetic DRP timeline clip and run the importer.
-- ---------------------------------------------------------------------------

local seq_elem = elem("Sequence", "", {
    elem("Sm2TiTrack", "", {
        elem("Type", "0"),  -- 0 = VIDEO
        wrap(
            elem("Sm2TiVideoClip", "", {
                elem("Name", "boundary_zero_padding"),
                elem("Start", "0"),
                elem("Duration", tostring(TIMELINE_DURATION)),
                elem("MediaStartTime", tostring(MEDIA_START_SEC)),
                elem("In", ""),                       -- offset 0 (untrimmed in-point)
                elem("MediaFilePath", "/test/boundary.mov"),
                elem("MediaFrameRate", MEDIA_FRAME_RATE_25),
                elem("MediaTimemapBA", MTBA_150_PERCENT),
            })
        ),
    }),
})

local video_tracks = drp_importer.parse_resolve_tracks(seq_elem, SEQ_FPS)
assert(#video_tracks == 1 and #video_tracks[1].clips == 1, "expected 1 clip")
local clip = video_tracks[1].clips[1]
local imported_source_duration = clip.source_out - clip.source_in

print(string.format("Imported: source_in=%d source_out=%d source_dur=%d",
    clip.source_in, clip.source_out, imported_source_duration))
print(string.format("Expected source_dur=%d (whole source frames consumed by %d timeline frames at %sx)",
    EXPECTED_SOURCE_DURATION, TIMELINE_DURATION, tostring(CLIP_SPEED)))

-- ---------------------------------------------------------------------------
-- Assertion 1: imported source duration matches the number of whole source
-- frames the clip consumes. Over-counting by 1 is the bug this test catches.
-- ---------------------------------------------------------------------------
assert(imported_source_duration == EXPECTED_SOURCE_DURATION, string.format(
    "source_duration over/undercount: imported=%d expected=%d (off by %d). " ..
    "At %sx speed for %d timeline frames, the clip consumes %d whole source frames.",
    imported_source_duration, EXPECTED_SOURCE_DURATION,
    imported_source_duration - EXPECTED_SOURCE_DURATION,
    tostring(CLIP_SPEED), TIMELINE_DURATION, EXPECTED_SOURCE_DURATION))

-- ---------------------------------------------------------------------------
-- Assertion 2: a zero-padding trimmed file sized exactly for the consumed
-- source range must contain the imported clip. This is the containment
-- question the relinker asks when matching candidate files.
-- ---------------------------------------------------------------------------
local probe_result = {
    start_tc_value = clip.source_in,           -- file's frame 0 = clip's first source frame
    start_tc_rate = MEDIA_FPS,
    duration_frames = EXPECTED_SOURCE_DURATION,
    fps_num = MEDIA_FPS,
    fps_den = 1,
}
local clip_for_check = { source_in = clip.source_in, source_out = clip.source_out }
local fits = M.check_clip_containment(clip_for_check, probe_result, MEDIA_FPS, nil)
local cand_end = probe_result.start_tc_value + probe_result.duration_frames
assert(fits, string.format(
    "zero-padding trimmed file should contain its own clip:\n" ..
    "  clip:  source_in=%d source_out=%d\n" ..
    "  file:  start_tc=%d duration=%d (end=%d)",
    clip.source_in, clip.source_out,
    probe_result.start_tc_value, probe_result.duration_frames, cand_end))

print("\n✅ test_relink_zero_padding_boundary.lua passed")
