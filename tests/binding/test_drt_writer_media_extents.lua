require("test_env")

-- =============================================================================
-- DRT writer — Sm2Sequence/MediaExtents must reflect payload content, not
-- leak the empty-reference template value (3600.0, 0.0).
--
-- DOMAIN contract (phase0-findings.md §K3b, anamnesis-gold dissection):
--   MediaExtents = two LE doubles
--     [earliest_clip_real_sec, latest_clip_real_sec]
--   in absolute project-epoch seconds. clip.sequence_start is already
--   absolute in JVE (sequence.lua:1007); no add of seq origin.
-- =============================================================================

local writer  = require("exporters.drt_writer")
local fixture = require("helpers.drt_spike_fixture")

local function check(cond, msg)
    assert(cond, "MediaExtents substitution FAILED: " .. tostring(msg))
end

-- Distinguishing value per finding #9: clip.sequence_start chosen such that
-- it's NOT equal to seq.start_tc_frame (which would have hidden a writer
-- bug that swapped them). Picking an arbitrary mid-hour timestamp:
-- 01:00:20.833... at 24 fps = TC_1H + 500 frames.
local SEQ_START_OFFSET_FRAMES = 500
local CLIP_DURATION           = 60   -- arbitrary, < media frames

local payload = fixture.build_a005_payload()
local seq  = payload.sequence
-- Mutate every clip on every track. The fixture has both video and audio
-- tracks; compute_seq_extents_frames spans both, so a mutation applied to
-- only one would let the un-mutated track set the latest-extent and break
-- the assertion.
for _, track in ipairs(seq.tracks) do
    for _, c in ipairs(track.clips) do
        c.sequence_start = fixture.TC_1H + SEQ_START_OFFSET_FRAMES
        c.duration       = CLIP_DURATION
    end
end
local clip = seq.tracks[1].clips[1]

local OUT = fixture.out_path("test_drt_writer_media_extents")
os.remove(OUT)
writer.author(OUT, payload)

local xml = fixture.unzip_member(OUT, "MediaPool/Master/MpFolder.xml")

local extents_hex = xml:match("<MediaExtents>([^<]+)</MediaExtents>")
check(extents_hex, "no <MediaExtents> element found in MpFolder.xml")
check(#extents_hex == 32, string.format(
    "MediaExtents must be 32 hex chars (two LE doubles), got %d", #extents_hex))

local earliest = fixture.le_hex_to_double(extents_hex:sub(1, 16))
local latest   = fixture.le_hex_to_double(extents_hex:sub(17, 32))

-- Domain expectations derived from the absolute-TC convention:
--   earliest = clip.sequence_start / seq.fps
--   latest   = (clip.sequence_start + clip.duration) / seq.fps
local want_early = clip.sequence_start / seq.fps
local want_late  = (clip.sequence_start + clip.duration) / seq.fps

local function near(a, b) return math.abs(a - b) < 1e-9 end

check(near(earliest, want_early), string.format(
    "MediaExtents[0] = %.6f, expected %.6f = clip.sequence_start %d / "
    .. "seq.fps %d",
    earliest, want_early, clip.sequence_start, seq.fps))

check(near(latest, want_late), string.format(
    "MediaExtents[1] = %.6f, expected %.6f = (clip.sequence_start %d + "
    .. "clip.duration %d) / seq.fps %d. If this is 0.0, the empty-reference "
    .. "template's empty-content extent is leaking.",
    latest, want_late, clip.sequence_start, clip.duration, seq.fps))

os.remove(OUT)

print("✅ test_drt_writer_media_extents.lua passed")
