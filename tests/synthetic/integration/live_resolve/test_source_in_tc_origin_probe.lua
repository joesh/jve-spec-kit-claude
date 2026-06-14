-- PROBE — empirically pin the source_in coordinate space across the
-- bridge (spec 023, FR-011c position channel).
--
-- The question this answers (and that NO existing test could, because
-- every other test drives source_in == 0-origin values):
--   JVE stores clip.source_in as ABSOLUTE source TC in native frames
--   (drp_importer: source_in_native = media_tc_origin + in_offset;
--   payload_builder.lua:20-21 says the same; the media's TC origin is
--   media:get_start_tc()). Resolve's TimelineItem:GetSourceStartFrame()
--   — what read_timeline returns as item.source_in — is documented
--   "start frame in source media": a 0-based MEDIA-RELATIVE frame
--   INDEX. A frame index does not depend on the file's embedded TC tag
--   (embedded TC affects TC *display*, not frame numbering), so we do
--   NOT need a real embedded-TC file to exercise the divergence — we
--   set the media's TC origin in metadata and let the send path treat
--   source_in as absolute against it.
--   => Whenever a media's TC origin is non-zero the two diverge by
--      exactly media_tc_origin, and the position channel (which
--      compares them raw) can never content-match. This probe MEASURES
--      that delta on a live Resolve to confirm the transform before the
--      fix lands.
--
-- Media: the 23.976fps A005 fixture (the DRT writer is a quarantined
--   23.976 mp4/mov spike — drt_writer.lua:981). Its file TC tag is 0,
--   but we stamp a non-zero TC origin (TC_ORIGIN) into the media
--   METADATA — exactly what the DRP importer does for a camera file —
--   so get_start_tc() yields it and the send path subtracts it.
-- We place ONE clip trimmed IN_OFFSET frames into the media, so its
-- JVE absolute source_in = TC_ORIGIN + IN_OFFSET. After SendToResolve +
-- read_timeline we expect Resolve to report source_in == IN_OFFSET
-- (media-relative). If instead it reports the absolute value, the
-- diagnosis is wrong and NO normalization is needed — either way the
-- printed numbers are the ground truth.
--
-- ⚠ State-changing on the CURRENT Resolve project (imports + deletes a
-- fixture timeline): VM test environment only.
--
-- Run via:
--   scripts/run_live_resolve_test.sh test_source_in_tc_origin_probe

local test_env = require("test_env")
local database = require("core.database")
local Project = require("models.project")
local Sequence = require("models.sequence")
local Track = require("models.track")
local Media = require("models.media")
local Clip = require("models.clip")
local command_manager = require("core.command_manager")
local supervisor = require("core.resolve_bridge.helper_supervisor")
local driver = require(
    "synthetic.integration.live_resolve.command_driver")

-- 23.976fps mp4 with a REAL embedded TC of 01:00:00:00 (synthesized
-- from the A005 fixture, ffmpeg -timecode). Real embedded TC matters:
-- the DRT round-trip resolves a clip's source position as a TIMECODE
-- against the file's OWN embedded TC, so JVE's TC origin and the file's
-- must agree — we therefore let JVE EXTRACT the origin from the file
-- (no metadata injection) rather than assert a guessed value.
local MEDIA_PATH = test_env.resolve_repo_path(
    "tests/fixtures/media/A005_C052_0925BL_001_tc01.mp4")
local FPS_NUM, FPS_DEN = 24000, 1001      -- 23.976 (DRT writer quarantine)
local MEDIA_FRAMES = 108                   -- ffprobe nb_frames (video)
local IN_OFFSET = 30                       -- trim 30 frames into media
local DUR       = 24
local SEQ_START = 120

-- ── DB fixture ─────────────────────────────────────────────────────
local DB_PATH = "/tmp/jve/test_source_in_tc_origin_probe.db"
os.remove(DB_PATH)
os.execute("mkdir -p /tmp/jve")
assert(database.init(DB_PATH), "schema init failed")
local db = database.get_connection()
db:exec(require("import_schema"))

Project.create("p", {
    id = "p1", fps_mismatch_policy = "passthrough",
    settings = { master_clock_hz = 705600000,
                 default_fps = { num = FPS_NUM, den = FPS_DEN } },
}):save()
Sequence.create("m", "p1",
    { fps_numerator = FPS_NUM, fps_denominator = FPS_DEN },
    1920, 1080, { id = "m", kind = "master" }):save()
Sequence.create("probe-seq", "p1",
    { fps_numerator = FPS_NUM, fps_denominator = FPS_DEN },
    1920, 1080, { id = "e1", kind = "sequence",
                  audio_sample_rate = 48000 }):save()
Track.create_video("V1", "e1", { id = "e1-v1", index = 1 }):save()
Track.create_video("V1", "m", { id = "m-v1", index = 1 }):save()
db:exec("UPDATE sequences SET default_video_layer_track_id = 'm-v1' WHERE id = 'm'")

-- No start_tc in metadata — get_start_tc() extracts it from the file
-- via EMP (the file genuinely carries embedded TC 01:00:00:00), so the
-- origin JVE uses is byte-for-byte the one Resolve reads from the same
-- file. This is the whole point: file-TC and JVE-origin agree because
-- they come from the same source.
local media = Media.create({
    id = "med-tc01", project_id = "p1",
    name = "A005_C052_0925BL_001_tc01.mp4",
    file_path = MEDIA_PATH, duration_frames = MEDIA_FRAMES,
    fps_numerator = FPS_NUM, fps_denominator = FPS_DEN,
    audio_channels = 0, metadata = "{}",
})
media:save()
db:exec(string.format([[
    INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id,
        media_id, source_in_frame, source_out_frame,
        sequence_start_frame, duration_frames, audio_sample_rate,
        enabled, volume, playhead_frame, created_at, modified_at)
    VALUES ('mr-tc01', 'p1', 'm', 'm-v1', 'med-tc01', 0, %d, 0, %d,
        NULL, 1, 1.0, 0, 0, 0);
]], MEDIA_FRAMES, MEDIA_FRAMES))

-- Extract the file's embedded TC origin (native frames) — this is the
-- same value the send path passes as start_tc_frame and Resolve reads
-- off the file. A zero origin would make the test vacuous (no
-- absolute/relative divergence), so require it non-zero.
local TC_ORIGIN = media:get_start_tc()
assert(type(TC_ORIGIN) == "number" and TC_ORIGIN > 0, string.format(
    "probe: embedded TC origin must extract non-zero from %s; got %s",
    MEDIA_PATH, tostring(TC_ORIGIN)))
-- JVE's importer convention: source_in is ABSOLUTE = origin + offset.
local ABS_SOURCE_IN = TC_ORIGIN + IN_OFFSET

local sub_in, sub_out = Clip.subframe_defaults_for_track_type("VIDEO")
local CLIP_ID = "0b50c0de-7007-4aaa-8aaa-000000000001"
assert(Clip.create({
    id = CLIP_ID, project_id = "p1", owner_sequence_id = "e1",
    track_id = "e1-v1", sequence_id = "m",
    name = "A005_C052_0925BL_001_tc01.mp4",
    sequence_start_frame = SEQ_START, duration_frames = DUR,
    source_in_frame = ABS_SOURCE_IN,
    source_out_frame = ABS_SOURCE_IN + DUR,
    source_in_subframe = sub_in, source_out_subframe = sub_out,
    master_layer_track_id = nil, fps_mismatch_policy = "passthrough",
    enabled = true, volume = 1.0, playhead_frame = 0,
}) == CLIP_ID)

command_manager.init("e1", "p1")
supervisor.configure(
    driver.repo_root() .. "/tools/resolve-helper/helper.py")
driver.skip_unless_live("test_source_in_tc_origin_probe")

print(string.format(
    "  JVE side: media embedded TC origin=%d frames, clip absolute "
    .. "source_in=%d (== origin + in_offset %d)",
    TC_ORIGIN, ABS_SOURCE_IN, IN_OFFSET))

-- ── send the single clip, then read the live timeline back ──────────
local send = driver.run_bridge_command("SendToResolve",
    "send_to_resolve_completed", { project_id = "p1", sequence_id = "e1" })
assert(#send.result.mapping == 1 and #send.result.unrelinked == 0,
    string.format("probe send: expected 1 mapped / 0 unrelinked, got "
        .. "%d/%d", #send.result.mapping, #send.result.unrelinked))
local tl = send.result.resolve_timeline_id
local resolve_item_id = send.result.mapping[1].resolve_item_id
print("  ✓ send: 1 clip mapped, timeline " .. tl)

local rt = driver.helper_request("read_timeline", {})
local probe_item
for _, item in ipairs(rt.items) do
    if item.resolve_item_id == resolve_item_id then probe_item = item end
end
assert(probe_item, "probe: sent item not found in read_timeline")

local resolve_source_in = probe_item.source_in
local delta = ABS_SOURCE_IN - resolve_source_in
print(string.format(
    "  Resolve side: GetSourceStartFrame (read_timeline source_in)=%s",
    tostring(resolve_source_in)))
print(string.format(
    "  DELTA (JVE absolute %d − Resolve %s) = %s   [tc_origin=%d]",
    ABS_SOURCE_IN, tostring(resolve_source_in), tostring(delta),
    TC_ORIGIN))

-- ── teardown BEFORE the verdict assert, so a failed expectation does
-- not leak the fixture timeline on the live Resolve ─────────────────
local del = driver.helper_request("delete_timeline", {
    resolve_timeline_id = tl,
    change_token = driver.fresh_token("p1", "e1"),
})
assert(del.deleted == true, "probe teardown: delete failed")
print("  ✓ teardown: fixture timeline deleted")

-- ── verdict ─────────────────────────────────────────────────────────
-- Expectation derived from Resolve API semantics + TC math (NOT by
-- tracing JVE code): GetSourceStartFrame is media-relative, so it must
-- equal IN_OFFSET, and the delta must equal the embedded TC origin.
assert(resolve_source_in == IN_OFFSET, string.format(
    "PROBE RESULT: expected media-relative source_in == in_offset %d, "
    .. "got %s. If this fired, Resolve's source_in is NOT plain "
    .. "media-relative — re-examine the transform before coding the fix.",
    IN_OFFSET, tostring(resolve_source_in)))
assert(delta == TC_ORIGIN, string.format(
    "PROBE RESULT: JVE-absolute minus Resolve-relative must equal the "
    .. "embedded TC origin %d; got %d", TC_ORIGIN, delta))

supervisor.shutdown()
print(string.format(
    "✅ PROBE CONFIRMED: Resolve source_in is media-relative; JVE "
    .. "absolute source_in exceeds it by exactly media_tc_origin (%d "
    .. "frames). Position channel must normalize "
    .. "clip.source_in − media_tc_origin before comparing.", TC_ORIGIN))
