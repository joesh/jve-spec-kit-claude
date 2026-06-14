require("test_env")

-- =============================================================================
-- Reverse-clip DRT file round-trip through the REAL DRP importer (spec 023).
--
-- A reverse clip authored by exporters.drt_writer must parse back via
-- importers.drp_importer with its reverse identity intact: source_in (highest
-- played source frame, inclusive) > source_out (lowest played minus one,
-- exclusive). The exporter emits the full keyframe-curve MediaTimemapBA with
-- <In>=0; the importer walks that curve to recover the source range. This is
-- the offline gate before the live Resolve VM round-trip.
--
-- The payload carries a FORWARD selection and its REVERSE twin playing the
-- EXACT SAME source content backward, so the test proves (a) the forward path
-- is unchanged and (b) the reverse path is the mirror of it — not a separate
-- broken shape.
--
-- DOMAIN-derived values (never traced from the writer/importer):
--   • NTSC 23.976 = 24000/1001; media TC origin 01:00:00:00 = 86400 frames.
--   • The selection plays source frames 86520..86639 inclusive (120 frames,
--     5 s @ 23.976) — a non-zero, mid-file window so "write 0/read 0" can't
--     pass.
--   • FORWARD convention (NLE): source_in = first played frame (86520),
--     source_out = one past the last played frame (86640, exclusive).
--   • REVERSE convention (this codebase): source_in = highest played frame,
--     inclusive (86639); source_out = lowest played frame minus one, exclusive
--     (86519). source_in - source_out = duration (120) for unity-speed reverse.
-- =============================================================================

local writer = require("exporters.drt_writer")
local importer = require("importers.drp_importer")

local function check(cond, msg)
    assert(cond, "reverse round-trip FAILED: " .. tostring(msg))
end

local FR_23976 = 24000 / 1001
local TC_1H = 24 * 3600                       -- 86400 frames @ 23.976 = 01:00:00:00

-- Played source window (inclusive frames) and its length.
local PLAY_LO = TC_1H + 120                    -- 86520, lowest played frame
local PLAY_HI = TC_1H + 239                    -- 86639, highest played frame
local PLAY_LEN = PLAY_HI - PLAY_LO + 1         -- 120 frames

local MEDIA = {
    {
        file_uuid       = "11111111-1111-4111-8111-111111111111",
        file_path       = "/Volumes/Media/A_take03.mov",
        duration_frames = 7200,
        start_tc_frame  = TC_1H,               -- file TC origin 01:00:00:00
        native_rate     = FR_23976,
    },
}

-- FORWARD selection: source_in = first played, source_out = one-past-last.
local FWD = {
    id              = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
    media_uuid      = MEDIA[1].file_uuid,
    sequence_start  = 0,
    duration        = PLAY_LEN,
    source_in       = PLAY_LO,                 -- 86520
    source_out      = PLAY_HI + 1,             -- 86640 (exclusive)
    name            = "A fwd sel",
    enabled         = true,
}

-- REVERSE twin: same 120 source frames, played backward.
local REV = {
    id              = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
    media_uuid      = MEDIA[1].file_uuid,
    sequence_start  = PLAY_LEN,                -- butts up after the forward clip
    duration        = PLAY_LEN,
    source_in       = PLAY_HI,                 -- 86639 (highest played, inclusive)
    source_out      = PLAY_LO - 1,             -- 86519 (lowest played minus 1, exclusive)
    name            = "A rev sel",
    enabled         = true,
}

local PAYLOAD = {
    project = { name = "reverse round-trip", fps = FR_23976 },
    media_refs = MEDIA,
    sequence = {
        name = "Seq1", fps = FR_23976, width = 1920, height = 1080,
        tracks = { { type = "video", clips = { FWD, REV } } },
    },
}

local OUT = "/tmp/jve/reverse_clip_roundtrip.drt"
os.execute("mkdir -p /tmp/jve")
os.remove(OUT)

writer.author_a005_compatible(OUT, PAYLOAD)

local parsed = importer.parse_drp_file(OUT)
check(parsed.success, ("parse_drp_file refused the writer's .drt: %s")
    :format(tostring(parsed.error)))
check(#parsed.timelines == 1,
    ("expected 1 sequence, got %d"):format(#parsed.timelines))

local got_by_id = {}
for _, t in ipairs(parsed.timelines[1].tracks) do
    for _, c in ipairs(t.clips or {}) do
        got_by_id[c.clip_id] = c
    end
end

-- ── Forward clip: unchanged shape (source_in < source_out). ────────────────
local gf = got_by_id[FWD.id]
check(gf, "forward clip.id did not survive the round-trip")
check(gf.source_in == FWD.source_in,
    ("forward source_in %d → %s"):format(FWD.source_in, tostring(gf.source_in)))
check(gf.source_out == FWD.source_out,
    ("forward source_out %d → %s"):format(FWD.source_out, tostring(gf.source_out)))
check(gf.source_in < gf.source_out,
    "forward clip must read back as forward (source_in < source_out)")
check(gf.duration == FWD.duration,
    ("forward duration %d → %s"):format(FWD.duration, tostring(gf.duration)))

-- ── Reverse clip: mirror shape (source_in > source_out), exact values. ─────
local gr = got_by_id[REV.id]
check(gr, "reverse clip.id did not survive the round-trip")
check(gr.source_in > gr.source_out,
    ("reverse clip must read back reversed (source_in > source_out); "
    .. "got source_in=%s source_out=%s — a forward/curve-direction bug "
    .. "shows here"):format(tostring(gr.source_in), tostring(gr.source_out)))
check(gr.source_in == REV.source_in,
    ("reverse source_in %d (highest played, inclusive) → %s"):format(
        REV.source_in, tostring(gr.source_in)))
check(gr.source_out == REV.source_out,
    ("reverse source_out %d (lowest played minus 1, exclusive) → %s"):format(
        REV.source_out, tostring(gr.source_out)))
check(gr.duration == REV.duration,
    ("reverse duration %d → %s"):format(REV.duration, tostring(gr.duration)))

-- The reverse twin must cover the SAME source content as the forward clip:
-- highest played frame identical, lowest played frame identical.
check(gr.source_in == gf.source_out - 1,
    "reverse highest-played frame must equal forward's last played frame")
check(gr.source_out + 1 == gf.source_in,
    "reverse lowest-played frame must equal forward's first played frame")

os.remove(OUT)

print("✅ test_drt_reverse_clip_roundtrip.lua passed")
