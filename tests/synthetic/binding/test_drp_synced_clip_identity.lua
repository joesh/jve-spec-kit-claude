-- test_drp_synced_clip_identity.lua — a synced clip and its plain-camera
-- counterpart that wrap the SAME physical file must import as ONE media (the
-- file) and TWO distinct source clips (masters), not two media.
--
-- Domain: in Resolve you sync a camera .mov with an external WAV. Auto-sync
-- mints a NEW media-pool item that re-wraps the SAME camera file plus the WAV;
-- it does not copy media. So the project legitimately holds two pool items —
-- one plain camera clip, one synced clip — over a single physical .mov. JVE's
-- model is: a `media` row is a FILE; a kind='master' sequence is a SOURCE CLIP
-- (a pool/bin item). The right import is therefore:
--
--   * ONE media row for A008_05211408_C011.mov  (the file, online)
--   * ONE media row for S064-T002.WAV           (the file)
--   * the plain camera master      → references the .mov media (video + camera audio)
--   * the synced master            → references the .mov media (video + camera audio)
--                                     PLUS the WAV media on its sync tracks
--   * each master carries a DISTINCT import_uuid (its Resolve pool DbId)
--
-- The bug this guards: when source-clip identity was pinned to media.id, two
-- pool items over one file forced TWO media rows for that file. `file_path` is
-- UNIQUE, so one media took the real path and the other was left offline with a
-- bare filename. Relink then "salvaged" the offline one onto its online sibling,
-- collapsing the synced master's audio onto the plain master — so match-frame
-- (F) on the synced clip showed only the camera audio track.
--
-- Run: ./build/bin/jve.app/Contents/MacOS/jve --test \
--        tests/synthetic/binding/test_drp_synced_clip_identity.lua
local test_env     = require("test_env")
local drp_importer = require("importers.drp_importer")
local database     = require("core.database")

local FIXTURE = test_env.require_fixture(
    "tests/fixtures/resolve/synced clip example.drp")

local MOV = "A008_05211408_C011.mov"
local WAV = "S064-T002.WAV"

-- ── Import the DRP into a scratch project DB ────────────────────────────
local tmp_db = "/tmp/jve/test_drp_synced_clip_identity.jvp"
os.execute("mkdir -p /tmp/jve")
os.remove(tmp_db); os.remove(tmp_db .. "-wal"); os.remove(tmp_db .. "-shm")
database.init(tmp_db)
local conn = assert(database.get_connection(), "no db connection")
assert(conn:exec(require("import_schema")), "schema creation failed")

local project_id = "test-synced-identity"
assert(conn:exec(string.format(
    "INSERT INTO projects (id, name, created_at, modified_at, fps_mismatch_policy) "
    .. "VALUES ('%s', 'Synced Identity Test', 0, 0, 'resample')", project_id)),
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

-- ── small SQL helpers (tests are exempt from the SQL-isolation guard) ────
-- The sqlite3 wrapper reads result columns by INDEX (Statement:value(i)), so
-- callers pass the ordered column-name list the SELECT projects.
local function sql_quote(s) return (s:gsub("'", "''")) end
local function rows(sql, cols)
    local st = assert(conn:prepare(sql), "prepare failed: " .. sql)
    assert(st:exec(), "query failed: " .. sql)
    local out = {}
    while st:next() do
        local r = {}
        for i, name in ipairs(cols) do r[name] = st:value(i - 1) end
        out[#out + 1] = r
    end
    st:finalize()
    return out
end
local function count(sql)
    local st = assert(conn:prepare(sql), "prepare failed: " .. sql)
    assert(st:exec(), "query failed: " .. sql)
    local v = st:next() and st:value(0) or 0
    st:finalize()
    return v
end

-- ── 1. ONE media per physical file, and the .mov is online ──────────────
local function media_named(name)
    return rows(string.format(
        "SELECT id, file_path FROM media WHERE name = '%s'", sql_quote(name)),
        { "id", "file_path" })
end

local movs = media_named(MOV)
assert(#movs == 1, string.format(
    "expected exactly 1 media row for the camera file %s (one physical file = "
    .. "one media), got %d — source-clip identity is leaking into media identity",
    MOV, #movs))
local wavs = media_named(WAV)
assert(#wavs == 1, string.format(
    "expected exactly 1 media row for %s, got %d", WAV, #wavs))

local mov_media_id   = movs[1].id
local mov_media_path = movs[1].file_path
local wav_media_id   = wavs[1].id
-- The surviving .mov media must keep the ONLINE full path, not the bare
-- filename of the severed-link sibling.
assert(mov_media_path and mov_media_path:sub(1, 1) == "/", string.format(
    "the single %s media must keep the online absolute path; got %q",
    MOV, tostring(mov_media_path)))

-- ── 2. Two distinct .mov source clips (masters) over the one media ──────
local function masters_referencing(media_id)
    return rows(string.format([[
        SELECT DISTINCT s.id AS id, s.import_uuid AS import_uuid
        FROM sequences s
        JOIN tracks t      ON t.sequence_id = s.id
        JOIN media_refs mr ON mr.track_id   = t.id
        WHERE s.kind = 'master' AND mr.media_id = '%s'
        ORDER BY s.id]], sql_quote(media_id)), { "id", "import_uuid" })
end

local mov_masters = masters_referencing(mov_media_id)
assert(#mov_masters == 2, string.format(
    "expected the one %s media to back TWO masters (plain camera clip + synced "
    .. "clip), got %d masters", MOV, #mov_masters))
assert(mov_masters[1].import_uuid and mov_masters[2].import_uuid
       and mov_masters[1].import_uuid ~= mov_masters[2].import_uuid, string.format(
    "the two %s masters must carry DISTINCT import_uuid (their Resolve pool "
    .. "DbIds); got %q and %q", MOV,
    tostring(mov_masters[1].import_uuid), tostring(mov_masters[2].import_uuid)))

-- ── 3. Exactly one of them is the synced master (has WAV sync tracks) ───
local function sync_audio_track_count(master_id)
    return count(string.format([[
        SELECT COUNT(*) FROM tracks
        WHERE sequence_id = '%s' AND track_type = 'AUDIO' AND source_kind = 'sync'
    ]], sql_quote(master_id)))
end
local function wav_ref_count(master_id)
    return count(string.format([[
        SELECT COUNT(*) FROM media_refs mr
        JOIN tracks t ON t.id = mr.track_id
        WHERE t.sequence_id = '%s' AND mr.media_id = '%s'
    ]], sql_quote(master_id), sql_quote(wav_media_id)))
end

local synced_master, plain_master
for _, m in ipairs(mov_masters) do
    if sync_audio_track_count(m.id) > 0 then synced_master = m else plain_master = m end
end
assert(synced_master and plain_master, string.format(
    "expected one synced master (with WAV sync tracks) and one plain master; "
    .. "synced=%s plain=%s", tostring(synced_master and synced_master.id),
    tostring(plain_master and plain_master.id)))
assert(wav_ref_count(synced_master.id) > 0, string.format(
    "the synced master %s must reference the %s media on its sync tracks",
    synced_master.id, WAV))
assert(wav_ref_count(plain_master.id) == 0, string.format(
    "the plain camera master %s must NOT reference the WAV media", plain_master.id))

print(string.format(
    "  ✓ %s: 1 media → 2 masters (synced=%s with %d sync tracks, plain=%s)",
    MOV, synced_master.id, sync_audio_track_count(synced_master.id), plain_master.id))
print("✅ test_drp_synced_clip_identity.lua passed")
