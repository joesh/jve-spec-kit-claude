-- test_drt_audio_tc_source_range.lua — gap #1 (FR-001/002/003): audio-media TC
-- origin + source range are FRAME-domain at the sequence fps, not sample-domain.
--
-- DOMAIN (research D10, first-hand fixture decode of resolve_authored_full.drp):
-- a standalone .wav placed on a 23.976 timeline is conformed to the timeline.
-- Resolve writes the audio timeline clip's <MediaFrameRate> as the SEQUENCE fps
-- (23.976 — the fixture's Sm2TiAudioClip for test_click_48k_stereo.wav carries the
-- byte-identical 23.976 encoding A005's video clip uses), NOT the file's 48000
-- sample rate. The clip's source range is likewise in timeline FRAMES, not samples.
-- The 48000-sample domain lives only inside the Sm2MpAudioClip TracksBA (gap #2).
--
-- This is a PRODUCER test: payload_builder must convert audio media's
-- sample-domain TC origin (get_audio_start_tc → samples) into frame-domain at the
-- sequence fps before the (already-generic) writer math runs. Today
-- payload_builder.media_to_payload calls get_start_tc() unconditionally and
-- asserts it is a number (:149) — that is nil for audio-only media, so build()
-- CRASHES on the first standalone-WAV clip. RED until T011/T012 land.
--
-- We assert the PRODUCED PAYLOAD (not the writer output) because the writer
-- cannot round-trip a standalone-audio media-pool item until gap #2 (T017).
--
-- Run: ./build/bin/jve.app/Contents/MacOS/jve --test \
--        <abs>/tests/synthetic/binding/test_drt_audio_tc_source_range.lua
local test_env        = require("test_env")
local drp_importer    = require("importers.drp_importer")
local payload_builder = require("core.resolve_bridge.payload_builder")
local database        = require("core.database")
local json            = require("dkjson")

local FIXTURE = test_env.require_fixture(
    "tests/fixtures/resolve/resolve_authored_full.drp")

local WAV_NAME = "test_click_48k_stereo.wav"   -- standalone audio, on the timeline
local FILE_SAMPLE_RATE = 48000                 -- the WAV's native sample rate
local SEQ_FPS = 24000 / 1001                   -- 23.976 — the conformed timeline fps

-- ── Import the DRP into a scratch project DB (real import path, no hand-built
--    rows — rule feedback_tests_drive_via_user_primitives) ──────────────────
local tmp_db = "/tmp/jve/test_drt_audio_tc_source_range.jvp"
os.execute("mkdir -p /tmp/jve")
os.remove(tmp_db)
database.init(tmp_db)
local conn = assert(database.get_connection(), "no db connection")
assert(conn:exec(require("import_schema")), "schema creation failed")

local parsed = drp_importer.parse_drp_file(FIXTURE)
assert(parsed and parsed.success ~= false,
    "parse_drp_file failed: " .. tostring(parsed and parsed.error))
local rate     = drp_importer.pick_majority_audio_sample_rate(parsed)
local settings = drp_importer.derive_project_settings(parsed, rate)

-- The project row must carry valid settings JSON (master_clock_hz, default_fps)
-- so Project.load (which payload_builder.build calls) succeeds — the editor's
-- two-phase create writes these; we persist the importer-derived settings.
local project_id = "test-audio-tc"
assert(conn:exec(string.format(
    "INSERT INTO projects (id, name, created_at, modified_at, fps_mismatch_policy, settings) "
    .. "VALUES ('%s', 'Audio TC Source Range', 0, 0, 'resample', '%s')",
    project_id, (json.encode(settings):gsub("'", "''")))),
    "project insert failed")

local result   = drp_importer.import_into_project(project_id, parsed,
    { project_settings = settings })
assert(result and result.success ~= false,
    "import_into_project failed: " .. tostring(result and result.error))

-- ── Find the imported editing timeline (kind='sequence', not a master) ──────
local function query_value(sql)
    local st = assert(conn:prepare(sql), "prepare failed: " .. sql)
    assert(st:exec(), "query failed: " .. sql)
    local v = st:next() and st:value(0) or nil
    st:finalize()
    return v
end

local sequence_id = query_value(
    "SELECT id FROM sequences WHERE kind = 'sequence' LIMIT 1")
assert(sequence_id, "no editing sequence imported from the DRP")

-- ── Build the export payload (RED: crashes on audio media at payload_builder
--    :149 today; GREEN once gap #1 supplies frame-domain audio values) ───────
local payload = payload_builder.build(conn, project_id, sequence_id)
assert(type(payload) == "table", "payload_builder.build returned non-table")

-- ── Assertion 1 (FR-001/002, T011): the standalone-WAV media item is conformed
--    to the timeline fps, NOT carried at its 48000 sample rate ───────────────
local wav_ref
for _, ref in ipairs(payload.media_refs) do
    if ref.name == WAV_NAME then wav_ref = ref break end
end
assert(wav_ref, "standalone WAV media_ref '" .. WAV_NAME
    .. "' absent from payload.media_refs")
assert(wav_ref.track_type == "audio", string.format(
    "WAV media_ref track_type=%q, expected 'audio'", tostring(wav_ref.track_type)))
assert(math.abs(wav_ref.native_rate - SEQ_FPS) < 1e-6, string.format(
    "audio media native_rate=%s — expected the SEQUENCE fps %s (frame-domain, "
    .. "research D10), not the file rate", tostring(wav_ref.native_rate), SEQ_FPS))
assert(math.abs(wav_ref.native_rate - FILE_SAMPLE_RATE) > 1.0, string.format(
    "audio media native_rate=%s is the file's 48000 sample rate — gap #1 not "
    .. "applied; the timeline clip must be frame-domain at the seq fps",
    tostring(wav_ref.native_rate)))

-- ── Assertion 2 (FR-003, T012): the WAV's timeline clip source range is in
--    FRAMES. For a unity (non-retimed) clip, source_out − source_in equals the
--    clip's timeline duration (frames). If the producer left the range in audio
--    samples it would be ~(48000/23.976)× larger than the frame duration. ─────
local wav_clip
for _, track in ipairs(payload.sequence.tracks) do
    if track.type == "audio" then
        for _, c in ipairs(track.clips) do
            if c.media_uuid == wav_ref.file_uuid then wav_clip = c break end
        end
    end
end
assert(wav_clip, "no audio timeline clip references the WAV media item")
-- Unity (non-retimed) clip: source span == timeline duration when both are in
-- frames. Sub-frame epsilon is expected (D10 keeps the fractional remainder for
-- sample accuracy); a sample-domain range would be ~(48000/23.976)× = ~2000×
-- larger, so a <0.001-frame tolerance cleanly separates the two domains.
local source_span = wav_clip.source_out - wav_clip.source_in
assert(math.abs(source_span - wav_clip.duration) < 1e-3, string.format(
    "audio clip source span (source_out−source_in = %.6f) != timeline duration %s "
    .. "frames — source range is not frame-domain (looks like samples: %.1f× off)",
    source_span, tostring(wav_clip.duration),
    wav_clip.duration ~= 0 and source_span / wav_clip.duration or 0))

print("  ✓ audio media conformed to seq fps; clip source range in frames")
print("✅ test_drt_audio_tc_source_range.lua passed")
