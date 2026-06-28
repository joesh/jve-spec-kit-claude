require("test_env")

-- =============================================================================
-- file_mtime_us round-trips import → model → export payload, for the media that
-- CLIPS reference through their master sequences (spec 026, "persist for clip
-- sequences"). The DRT exporter requires file_mtime_us on every media-pool item
-- (the Clip blob's date + f13 derive from it) and loud-fails without it — so the
-- importer must capture+persist it for every clip-referenced online media, not
-- only for media-pool master clips parsed in isolation.
--
-- DOMAIN: import a Resolve-authored .drp whose media are all online (every clip
-- resolves to a real master with a decodable BtAudio/VideoInfo Clip blob), build
-- the export payload, and assert every payload media_ref carries a numeric
-- file_mtime_us. Black-box: drives the real drp_importer + payload_builder and
-- reads the payload the writer consumes — no internals traced.
--
-- Run: ./build/bin/jve.app/Contents/MacOS/jve --test \
--        <abs>/tests/synthetic/binding/test_drp_import_media_mtime.lua
-- =============================================================================

local test_env        = require("test_env")
local drp_importer    = require("importers.drp_importer")
local payload_builder = require("core.resolve_bridge.payload_builder")
local database        = require("core.database")
local json            = require("dkjson")

local FIXTURE = test_env.require_fixture(
    "tests/fixtures/resolve/resolve_authored_full.drp")

local tmp_db = "/tmp/jve/test_drp_import_media_mtime.jvp"
os.execute("mkdir -p /tmp/jve"); os.remove(tmp_db)
database.init(tmp_db)
local conn = assert(database.get_connection(), "no db connection")
assert(conn:exec(require("import_schema")), "schema creation failed")

local parsed = drp_importer.parse_drp_file(FIXTURE)
assert(parsed and parsed.success ~= false,
    "parse_drp_file failed: " .. tostring(parsed and parsed.error))
local rate     = drp_importer.pick_majority_audio_sample_rate(parsed)
local settings = drp_importer.derive_project_settings(parsed, rate)
local project_id = "test-media-mtime"
assert(conn:exec(string.format(
    "INSERT INTO projects (id, name, created_at, modified_at, fps_mismatch_policy, settings) "
    .. "VALUES ('%s', 'Media Mtime', 0, 0, 'resample', '%s')",
    project_id, (json.encode(settings):gsub("'", "''")))),
    "project insert failed")
assert((drp_importer.import_into_project(project_id, parsed,
    { project_settings = settings }) or {}).success ~= false, "import failed")

local function query_value(sql)
    local st = assert(conn:prepare(sql), "prepare failed: " .. sql)
    assert(st:exec(), "query failed: " .. sql)
    local v = st:next() and st:value(0) or nil
    st:finalize()
    return v
end
local sequence_id = assert(query_value(
    "SELECT id FROM sequences WHERE kind = 'sequence' LIMIT 1"),
    "no editing sequence imported")

local payload = payload_builder.build(conn, project_id, sequence_id)

-- Every media the export will author MUST carry a numeric mtime. (All media in
-- this fixture are online — a nil here means the import dropped the mtime
-- somewhere between the Clip-blob decode and the clip-referenced media row.)
assert(#payload.media_refs > 0, "no media_refs in payload")
for _, m in ipairs(payload.media_refs) do
    assert(type(m.file_mtime_us) == "number" and m.file_mtime_us > 0, string.format(
        "media %s (%s) reached the export payload with file_mtime_us=%s — the "
        .. "importer must capture+persist it for every clip-referenced media",
        tostring(m.file_uuid), tostring(m.file_path), tostring(m.file_mtime_us)))
end

print(string.format(
    "  ✓ all %d clip-referenced media carry file_mtime_us", #payload.media_refs))
print("✅ test_drp_import_media_mtime.lua passed")
