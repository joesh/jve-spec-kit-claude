-- test_drp_media_managed_synced_audio.lua — media-managed DRP keeps dual-system
-- sync audio linked, as offline media named by its WAV filename.
--
-- Domain: when a Resolve project is "media managed", Resolve copies media into a
-- managed folder and DISCARDS the original source path for pool-only dual-system
-- sync audio (the WAV recorded on a separate sound device, synced to a camera
-- clip). The .drp then carries, for each such WAV, only its filename + audio
-- format (channel count, sample rate, duration, TC origin) — no directory, no
-- full path anywhere in the archive.
--
-- The import must still preserve the dual-system relationship: each such WAV
-- becomes OFFLINE audio media, named by its filename (the relink anchor), with
-- its decoded channel count + sample rate, and stays linked as synced audio to
-- the camera clip it was shot with. Result: the user sees the sync audio on the
-- camera clip's master (offline, awaiting relink by filename) instead of the
-- audio silently vanishing.
--
-- This exercises `anamnesis-gold-timeline.drp`, a real media-managed export
-- whose 449 audio pool clips all use the compressed-FieldsBlob layout (no
-- BtAudioInfo/Clip path blob) and whose dual-system WAVs are pool-only.
--
-- Run: ./build/bin/jve.app/Contents/MacOS/jve --test \
--        tests/synthetic/binding/test_drp_media_managed_synced_audio.lua
local test_env     = require("test_env")
local drp_importer = require("importers.drp_importer")
local database     = require("core.database")

local FIXTURE = test_env.require_fixture(
    "tests/fixtures/resolve/anamnesis-gold-timeline.drp")

-- ── Import the DRP into a scratch project DB ────────────────────────────
local tmp_db = "/tmp/jve/test_drp_media_managed_synced_audio.jvp"
os.execute("mkdir -p /tmp/jve")
os.remove(tmp_db)
database.init(tmp_db)
local conn = assert(database.get_connection(), "no db connection")
assert(conn:exec(require("import_schema")), "schema creation failed")

local project_id = "test-mm-sync-audio"
assert(conn:exec(string.format(
    "INSERT INTO projects (id, name, created_at, modified_at, fps_mismatch_policy) "
    .. "VALUES ('%s', 'MM Sync Audio Test', 0, 0, 'resample')", project_id)),
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

-- ── Assertion 1: a known dual-system WAV is present as offline audio media ──
-- "S170-T002.WAV" is one of the pool-only sync WAVs in this fixture: 3 audio
-- channels, 48 kHz. Its source path was stripped by media management, so it
-- must land as offline media named by its filename.
local WAV_NAME = "S170-T002.WAV"
-- Run a SELECT and return the first row's `ncols` columns (0-indexed) as a
-- positional array, or nil when no row matched.
local function query_row(sql, ncols)
    local st = assert(conn:prepare(sql), "prepare failed: " .. sql)
    assert(st:exec(), "query failed: " .. sql)
    local row = nil
    if st:next() then
        row = {}
        for i = 0, ncols - 1 do row[i] = st:value(i) end
    end
    st:finalize()
    return row
end

local m = query_row(string.format(
    "SELECT id, name, file_path, audio_channels, audio_sample_rate "
    .. "FROM media WHERE name = '%s'", WAV_NAME), 5)
assert(m, string.format(
    "dual-system WAV '%s' was dropped — no offline media row created. "
    .. "(media-managed sync audio must be imported as offline media)", WAV_NAME))
local media_id, m_channels, m_rate, m_path = m[0], m[3], m[4], m[2]

assert(m_channels == 3, string.format(
    "%s: expected 3 audio channels (decoded from compressed FieldsBlob), got %s",
    WAV_NAME, tostring(m_channels)))
assert(m_rate == 48000, string.format(
    "%s: expected 48000 Hz sample rate, got %s", WAV_NAME, tostring(m_rate)))

-- Offline: the file_path is the bare filename (no directory) — it cannot
-- resolve on disk, which is exactly how it presents as offline + relinkable.
assert(m_path == WAV_NAME, string.format(
    "%s: offline media must use the filename as its relink anchor; got path %q",
    WAV_NAME, tostring(m_path)))
assert(not m_path:find("/"), string.format(
    "%s: offline sync-audio path must be a bare filename (no directory); got %q",
    WAV_NAME, m_path))
print("  ✓ " .. WAV_NAME .. " imported as offline audio media (3ch / 48kHz)")

-- ── Assertion 2: it is actually LINKED as sync audio to its camera master ──
-- Sync audio is placed on tracks tagged source_kind='sync' on the camera
-- clip's master sequence. A media_ref on such a track pointing at our WAV
-- proves the dual-system relationship survived import.
local linked = query_row(string.format(
    "SELECT mr.id FROM media_refs mr "
    .. "JOIN tracks t ON t.id = mr.track_id "
    .. "WHERE mr.media_id = '%s' AND t.source_kind = 'sync'", media_id), 1)
assert(linked, string.format(
    "%s: created as media but NOT linked as sync audio to any camera master "
    .. "(no media_ref on a source_kind='sync' track)", WAV_NAME))
print("  ✓ " .. WAV_NAME .. " linked as sync audio on a 'sync' track")

-- ── Assertion 3: the whole class survives, not just one clip ────────────────
-- Every pool-only dual-system WAV in this fixture has the same stripped-path
-- shape. Count offline audio media that are referenced on 'sync' tracks: this
-- regressed to ~0 before the fix (the refs were dropped) and should now be the
-- full set of media-managed sync WAVs.
local cnt = query_row(
    "SELECT COUNT(DISTINCT m.id) FROM media m "
    .. "JOIN media_refs mr ON mr.media_id = m.id "
    .. "JOIN tracks t ON t.id = mr.track_id "
    .. "WHERE t.source_kind = 'sync' AND m.file_path NOT LIKE '%/%'", 1)
local n_offline = cnt and cnt[0] or 0
assert(n_offline >= 300, string.format(
    "expected the full set of media-managed sync WAVs (>=300) as offline, "
    .. "sync-linked media; got %s", tostring(n_offline)))
print(string.format("  ✓ %d media-managed sync WAVs imported offline + linked", n_offline))

print("✅ test_drp_media_managed_synced_audio.lua passed")
