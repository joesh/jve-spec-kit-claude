-- test_drp_synced_relink_extent.lua — the file range a synced clip's timeline
-- usage maps to must lie INSIDE the WAV, so relink never reports the file
-- "short" for content that is genuinely present.
--
-- Domain / ground truth (Resolve-authored "synced clip example.drp"):
--   * The external WAV S064-T002.WAV is a finite file: it spans audio samples
--     [audio_tc, audio_tc + duration] (its TC origin .. origin + length).
--   * A synced clip places that WAV against the video by a per-channel
--     SampleOffset; the timeline only ever references WAV content that exists.
--   * Therefore the source-extent the relink computes for the WAV (the min/max
--     file sample its timeline usage touches) MUST fall within
--     [audio_tc, audio_tc + duration]. If it reaches the VIDEO's timecode
--     instead, relink wrongly reports the WAV short by ~9979s.
--
-- The bug this guards: Media.batch_get_source_extents mapped an edit clip's
-- master-frame source range to WAV samples by pure rate-scaling
-- (frame * sample_rate / fps), ignoring the master audio media_ref's sync
-- offset. For free-run synced audio that overshoots to the video's TC.
--
-- Run: ./build/bin/jve.app/Contents/MacOS/jve --test \
--        <abs>/tests/synthetic/binding/test_drp_synced_relink_extent.lua
local test_env     = require("test_env")
local drp_importer = require("importers.drp_importer")
local database     = require("core.database")
local Media        = require("models.media")

local FIXTURE = test_env.require_fixture(
    "tests/fixtures/resolve/synced clip example.drp")
local WAV = "S064-T002.WAV"

local tmp_db = "/tmp/jve/test_drp_synced_relink_extent.jvp"
os.execute("mkdir -p /tmp/jve")
os.remove(tmp_db); os.remove(tmp_db .. "-wal"); os.remove(tmp_db .. "-shm")
database.init(tmp_db)
local conn = assert(database.get_connection(), "no db connection")
assert(conn:exec(require("import_schema")), "schema creation failed")

local project_id = "test-synced-relink-extent"
assert(conn:exec(string.format(
    "INSERT INTO projects (id, name, created_at, modified_at, fps_mismatch_policy) "
    .. "VALUES ('%s', 'Synced Relink Extent', 0, 0, 'resample')", project_id)),
    "project insert failed")

local parsed = drp_importer.parse_drp_file(FIXTURE)
assert(parsed and parsed.success ~= false,
    "parse_drp_file failed: " .. tostring(parsed and parsed.error))
local rate     = drp_importer.pick_majority_audio_sample_rate(parsed)
local settings = drp_importer.derive_project_settings(parsed, rate)
local result   = drp_importer.import_into_project(project_id, parsed,
    { project_settings = settings })
assert(result and result.success ~= false,
    "import_into_project failed: " .. tostring(result and result.error))

-- Locate the WAV media + its file sample span.
local function sql_quote(s) return (s:gsub("'", "''")) end
local st = assert(conn:prepare(string.format(
    "SELECT id FROM media WHERE name = '%s'", sql_quote(WAV))), "prepare failed")
assert(st:exec(), "query failed")
assert(st:next(), "WAV media not found")
local wav_id = st:value(0)
st:finalize()

local media = assert(Media.load(wav_id), "Media.load failed for WAV")
local audio_tc = assert(media:get_audio_start_tc(), "WAV has no audio TC origin")
local sample_rate = assert(media.audio_sample_rate, "WAV has no audio_sample_rate")
local duration_samples = assert(media.duration, "WAV has no duration")
local file_end = audio_tc + duration_samples

-- Compute the source-extent the relink uses (samples at the WAV's rate).
local extents = Media.batch_get_source_extents({
    [wav_id] = { audio_sample_rate = sample_rate },
})
-- batch_get_source_extents flattens each bucket to {[1]=min_in, [2]=max_out, rate}.
local ext = extents[wav_id] and extents[wav_id].audio
assert(ext and ext[1] and ext[2], string.format(
    "no audio source-extent computed for WAV %s", wav_id))
local ext_in, ext_out = ext[1], ext[2]

print(string.format(
    "  WAV file span [%d, %d]; timeline source-extent [%d, %d]",
    audio_tc, file_end, ext_in, ext_out))

assert(ext_in >= audio_tc, string.format(
    "synced source-extent starts at %d, BEFORE the WAV's first sample %d — "
    .. "the sync offset was not applied to the relink extent",
    ext_in, audio_tc))
assert(ext_out <= file_end, string.format(
    "synced source-extent ends at %d, PAST the WAV's last sample %d (over by %d "
    .. "samples ~%.0fs) — the timeline usage was mapped to the video's timecode "
    .. "instead of through the master audio media_ref's sync offset",
    ext_out, file_end, ext_out - file_end,
    (ext_out - file_end) / sample_rate))

print(string.format(
    "  ✓ synced WAV source-extent lies within the file (no spurious shortfall)"))
print("✅ test_drp_synced_relink_extent.lua passed")
