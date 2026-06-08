require("test_env")

-- =============================================================================
-- DRT writer — MpFolder.xml MediaVec must contain one Sm2MpVideoClip per
-- payload media_ref, and timeline-clip MediaRefs must cross-link.
--
-- DOMAIN contract: every <MediaRef>UUID</MediaRef> emitted on timeline
-- clips inside SeqContainer/*.xml must resolve to a media-pool item
-- (Sm2MpVideoClip / Sm2MpAudioClip) inside MpFolder.xml's <MediaVec>
-- whose @DbId equals that UUID. Resolve's project importer drops any
-- timeline clip whose MediaRef has no media-pool target — silently —
-- producing an empty timeline despite the project archive being accepted.
--
-- Phase-0 evidence (specs/023/phase0-findings.md §K): JVE-authored DRP
-- without source-media items = empty timeline on import.
-- =============================================================================

local writer  = require("exporters.drt_writer")
local fixture = require("helpers.drt_spike_fixture")

local function check(cond, msg)
    assert(cond, "MediaVec population FAILED: " .. tostring(msg))
end

-- Distinguishing values per finding #15: media.start_tc_frame ≠ 0 and
-- clip.source_in ≠ media.start_tc_frame make `in_offset = source_in -
-- start_tc_frame` non-zero so a writer that emitted either source
-- directly (instead of the difference) would fail. Clip duration is
-- shrunk below media duration so source_in + clip.duration fits inside
-- the file (60 + 30 = 90 < 108 file frames).
local CLIP_DURATION         = 60
local CLIP_SOURCE_IN_OFFSET = 30
local IN_OFFSET_EXPECTED    = CLIP_SOURCE_IN_OFFSET

local payload = fixture.build_a005_payload()
payload.media_refs[1].start_tc_frame = fixture.TC_1H
-- Apply mutation to every clip on every track — the fixture has both video
-- and audio tracks sharing the same media; mutating only one would leave the
-- other's source_in below the file's TC origin and trip the writer's assert.
for _, track in ipairs(payload.sequence.tracks) do
    for _, c in ipairs(track.clips) do
        c.duration  = CLIP_DURATION
        c.source_in = fixture.TC_1H + CLIP_SOURCE_IN_OFFSET
    end
end

local clip  = payload.sequence.tracks[1].clips[1]
local media = payload.media_refs[1]

local OUT = fixture.out_path("test_drt_writer_media_pool_population")
os.remove(OUT)
writer.author_a005_compatible(OUT, payload)

local mp_folder_xml = fixture.unzip_member(OUT, "MediaPool/Master/MpFolder.xml")

-- (1) Media-pool item exists for the payload's media_ref.
local mp_item_needle = string.format(
    '<Sm2MpVideoClip DbId="%s">', media.file_uuid)
check(fixture.plain_count(mp_folder_xml, mp_item_needle) == 1, string.format(
    "expected exactly one %s in MpFolder.xml — without it the timeline "
    .. "clip's <MediaRef> dangles and Resolve drops the clip silently",
    mp_item_needle))

local seq_xml = fixture.unzip_member(OUT, "SeqContainer/*.xml")

-- Number of clip-bearing tracks in the payload (one MediaRef per clip; both
-- video + audio reference the same media file).
local CLIP_COUNT = 0
for _, track in ipairs(payload.sequence.tracks) do
    CLIP_COUNT = CLIP_COUNT + #track.clips
end

-- (2) Timeline clip's MediaRef uses the same UUID (cross-link). One per clip.
local mref_needle = string.format("<MediaRef>%s</MediaRef>", media.file_uuid)
check(fixture.plain_count(seq_xml, mref_needle) == CLIP_COUNT, string.format(
    "expected %d %s in SeqContainer/*.xml (one per clip); cross-link from "
    .. "every timeline clip to the media-pool item must use the payload "
    .. "media_uuid", CLIP_COUNT, mref_needle))

-- (3) <Start> is absolute project-epoch frames = clip.sequence_start
--     (sequence.lua:1007). Both sides absolute — no transformation.
--     All clips share the same sequence_start in this fixture, so one
--     <Start> needle should appear once per clip.
local start_needle = string.format("<Start>%d</Start>", clip.sequence_start)
check(fixture.plain_count(seq_xml, start_needle) == CLIP_COUNT, string.format(
    "expected %d %s; <Start> must equal clip.sequence_start since both JVE "
    .. "and Resolve use absolute project-epoch frames",
    CLIP_COUNT, start_needle))

-- (4) <In> is source_in − media.start_tc_frame (file-relative offset).
--     A writer that emitted clip.source_in directly would produce
--     <In>%d</In> with the absolute frame number — caught here.
local in_needle = string.format("<In>%d</In>", IN_OFFSET_EXPECTED)
check(fixture.plain_count(seq_xml, in_needle) == CLIP_COUNT, string.format(
    "expected %d %s (= clip.source_in %d − media.start_tc_frame %d, "
    .. "once per clip). A writer emitting clip.source_in directly would "
    .. "emit <In>%d</In> and fail this assertion.",
    CLIP_COUNT, in_needle, clip.source_in, media.start_tc_frame,
    clip.source_in))

os.remove(OUT)

print("✅ test_drt_writer_media_pool_population.lua passed")
