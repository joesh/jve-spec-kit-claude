require("test_env")

-- =============================================================================
-- T004 — DRT file round-trip through the REAL DRP importer
--
-- Black-box contract: a .drt authored by exporters.drt_writer for a 3-clip
-- sequence must parse back via importers.drp_importer.parse_drp_file with
-- per-clip TC, duration, MediaRef (file_uuid), and the identity field
-- (clip.id, carried as the timeline-clip Sm2Ti DbId per spec 023 FR-011b)
-- byte-equal to what the writer was given.
--
-- DOMAIN-derived values (never traced from the writer):
--   • NTSC 23.976 = 24000/1001 — canonical fractional frame rate.
--   • Sequence start TC 01:00:00:00 @ 23.976 = 86400 frames (24·3600).
--   • Clip A starts at sequence_start 0, clip B at A's end, clip C with a
--     non-zero gap to exercise non-contiguous placement.
--   • Source-in offsets are non-zero so a "write 0 / read 0" bug can't
--     pass: each clip enters its source asset mid-file.
--   • Three distinct media file_uuids — round-trip must NOT cross-link.
-- =============================================================================

local writer = require("exporters.drt_writer")
local importer = require("importers.drp_importer")

local function check(cond, msg)
    assert(cond, "T004 round-trip FAILED: " .. tostring(msg))
end

local FR_23976 = 24000 / 1001
local TC_1H_AT_23976 = 24 * 3600                  -- 86400 frames

-- ---------------------------------------------------------------------------
-- Build the payload. Three clips with non-trivial, distinct values for every
-- property that must survive the round-trip.
-- ---------------------------------------------------------------------------

local MEDIA = {
    {
        file_uuid       = "11111111-1111-4111-8111-111111111111",
        file_path       = "/Volumes/Media/A_take03.mov",
        duration_frames = 7200,                   -- 5min @ 23.976
        start_tc_frame  = TC_1H_AT_23976,         -- file TC origin 01:00:00:00
        native_rate     = FR_23976,
        kind            = "video",
        file_mtime_us   = 1471909574000000,  -- Clip-blob date/f13 derive from it
    },
    {
        file_uuid       = "22222222-2222-4222-8222-222222222222",
        file_path       = "/Volumes/Media/B_take01.mov",
        duration_frames = 4800,
        start_tc_frame  = 0,                      -- tc=0 (most files)
        native_rate     = FR_23976,
        kind            = "video",
        file_mtime_us   = 1471909574000000,  -- Clip-blob date/f13 derive from it
    },
    {
        file_uuid       = "33333333-3333-4333-8333-333333333333",
        file_path       = "/Volumes/Media/C_take07.mov",
        duration_frames = 9600,
        start_tc_frame  = 2 * TC_1H_AT_23976,     -- 02:00:00:00
        native_rate     = FR_23976,
        kind            = "video",
        file_mtime_us   = 1471909574000000,  -- Clip-blob date/f13 derive from it
    },
}

local CLIPS = {
    {
        id              = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
        media_uuid      = MEDIA[1].file_uuid,
        sequence_start  = 0,
        duration        = 240,                    -- 10 sec
        source_in       = TC_1H_AT_23976 + 120,   -- 5 sec into media (offset from file TC origin)
        source_out      = TC_1H_AT_23976 + 120 + 240,  -- forward: source_in + duration
        name            = "A_take03 sel",
        enabled         = true,
    },
    {
        id              = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
        media_uuid      = MEDIA[2].file_uuid,
        sequence_start  = 240,                    -- butts up against A
        duration        = 360,
        source_in       = 60,                     -- 2.5 sec into media (tc=0 file)
        source_out      = 60 + 360,               -- forward: source_in + duration
        name            = "B_take01 sel",
        enabled         = true,
    },
    {
        id              = "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
        media_uuid      = MEDIA[3].file_uuid,
        sequence_start  = 720,                    -- 5-sec gap after B (240+360+120 gap)
        duration        = 480,
        source_in       = 2 * TC_1H_AT_23976 + 300, -- 12.5 sec into media (tc=02:00:00:00 origin)
        source_out      = 2 * TC_1H_AT_23976 + 300 + 480,  -- forward: source_in + duration
        name            = "C_take07 sel",
        enabled         = true,
    },
}

local PAYLOAD = {
    project = {
        name = "T004 round-trip",
        fps  = FR_23976,
    },
    media_refs = MEDIA,
    sequence = {
        name  = "Seq1",
        fps   = FR_23976,
        width = 1920, height = 1080,
        tracks = {
            { type = "video", clips = CLIPS },
        },
    },
}

-- ---------------------------------------------------------------------------
-- Author + parse.
-- ---------------------------------------------------------------------------

local OUT = "/tmp/jve/t004_roundtrip.drt"
os.execute("mkdir -p /tmp/jve")
os.remove(OUT)

writer.author_a005_compatible(OUT, PAYLOAD)

local parsed = importer.parse_drp_file(OUT)
check(parsed.success, ("parse_drp_file refused the writer's .drt: %s")
    :format(tostring(parsed.error)))

-- ---------------------------------------------------------------------------
-- Per-clip assertions. The contract is: writer-input ↔ parser-output equal
-- on (clip_id, file_uuid, start_value, duration). The parser names differ
-- from the writer's (clip.id → parsed.clip_id, etc.) — that's the import
-- DTO, not the round-trip violation.
-- ---------------------------------------------------------------------------

check(#parsed.timelines == 1,
    ("expected 1 sequence, got %d"):format(#parsed.timelines))
local tl = parsed.timelines[1]

-- Collect every clip across all tracks. The parser writes a single
-- `timeline.tracks` array (parse_sequence at drp_importer.lua:1697); we
-- compare as a set keyed by clip_id since order across tracks isn't part
-- of the contract.
local got_by_id = {}
check(type(tl.tracks) == "table", "timeline.tracks missing from parse output")
for _, t in ipairs(tl.tracks) do
    for _, c in ipairs(t.clips or {}) do
        check(c.clip_id, "parsed clip missing clip_id (identity field "
            .. "DbId on Sm2Ti{Video,Audio}Clip per FR-011b)")
        check(not got_by_id[c.clip_id],
            ("duplicate clip_id in parse output: %s"):format(c.clip_id))
        got_by_id[c.clip_id] = c
    end
end

for _, want in ipairs(CLIPS) do
    local got = got_by_id[want.id]
    check(got, ("clip.id %s did not survive the round-trip (writer set it "
        .. "on the timeline-item element; parser reads it from "
        .. "Sm2Ti*.attrs.DbId)"):format(want.id))

    check(got.start_value == want.sequence_start,
        ("clip %s: sequence_start %d → %s"):format(
            want.id, want.sequence_start, tostring(got.start_value)))

    check(got.duration == want.duration,
        ("clip %s: duration %d → %s"):format(
            want.id, want.duration, tostring(got.duration)))

    check(got.file_uuid == want.media_uuid,
        ("clip %s: media file_uuid %s → %s — MediaRef link lost or "
        .. "cross-wired"):format(want.id, want.media_uuid, tostring(got.file_uuid)))

    -- source_in is in native units (frames for video) and must include the
    -- file TC origin per `feedback_timecode_is_truth` — JVE source_in stores
    -- absolute timecode, not file-relative offset.
    check(got.source_in == want.source_in,
        ("clip %s: source_in %d → %s (absolute TC; file-relative bug "
        .. "would show as want - media.start_tc_frame)"):format(
            want.id, want.source_in, tostring(got.source_in)))
end

os.remove(OUT)

print("✅ test_drt_writer_file_roundtrip.lua passed")
