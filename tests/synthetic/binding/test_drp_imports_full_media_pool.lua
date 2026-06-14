-- test_drp_imports_full_media_pool.lua — opening a Resolve project imports the
-- ENTIRE media pool, not just the clips used on a timeline.
--
-- Domain: Resolve's media pool holds every clip the editor ingested, organized
-- in bins. Many are never cut into a timeline (selects, alternates, sound that
-- didn't make the edit). When JVE opens the project, the user expects to see the
-- whole pool in the media browser — a clip filed in a bin but never placed on a
-- timeline must still import as usable media. In JVE a media item is usable (and
-- browseable / openable in the source viewer) only when it has BOTH a `media`
-- row AND a kind='master' source sequence. So the guarantee is: every pool clip
-- that carries a real file reference and a real duration must end up with both.
--
-- `resolve_authored_full.drp` is a real Resolve export with 6 pool clips, two of
-- which (`A002_C018_0922BW_002.mp4`, `test_bars_tone.mp4`) sit in the pool but on
-- no timeline. Before full-pool import they never became media + masters.
--
-- Run: ./build/bin/jve.app/Contents/MacOS/jve --test \
--        tests/synthetic/binding/test_drp_imports_full_media_pool.lua
local test_env     = require("test_env")
local drp_importer = require("importers.drp_importer")
local database     = require("core.database")

local FIXTURE = test_env.require_fixture(
    "tests/fixtures/resolve/resolve_authored_full.drp")

-- ── Import the DRP into a scratch project DB ────────────────────────────
local tmp_db = "/tmp/jve/test_drp_imports_full_media_pool.jvp"
os.execute("mkdir -p /tmp/jve")
os.remove(tmp_db)
database.init(tmp_db)
local conn = assert(database.get_connection(), "no db connection")
assert(conn:exec(require("import_schema")), "schema creation failed")

local project_id = "test-full-pool"
assert(conn:exec(string.format(
    "INSERT INTO projects (id, name, created_at, modified_at, fps_mismatch_policy) "
    .. "VALUES ('%s', 'Full Pool Test', 0, 0, 'resample')", project_id)),
    "project insert failed")

local parsed = drp_importer.parse_drp_file(FIXTURE)
assert(parsed and parsed.success ~= false,
    "parse_drp_file failed: " .. tostring(parsed and parsed.error))

-- The set the user expects to see: every pool clip with a real file reference
-- and a real duration. Derived from Resolve's own pool export, not from JVE's
-- import logic.
local expected = {}
for _, p in ipairs(parsed.pool_master_clips or {}) do
    local has_file = (p.file_path and p.file_path ~= "") or (p.name and p.name ~= "")
    local has_dur  = (p.num_frames and p.num_frames > 0)
        or (p.audio_duration and p.audio_duration.samples and p.audio_duration.samples > 0)
    if has_file and has_dur and p.name and p.name ~= "" then
        expected[p.name] = true
    end
end
local n_expected = 0
for _ in pairs(expected) do n_expected = n_expected + 1 end
assert(n_expected >= 6, string.format(
    "fixture sanity: expected >=6 usable pool clips, got %d", n_expected))

local rate     = drp_importer.pick_majority_audio_sample_rate(parsed)
local settings = drp_importer.derive_project_settings(parsed, rate)
local result   = drp_importer.import_into_project(project_id, parsed,
    { project_settings = settings })
assert(result and result.success ~= false,
    "import_into_project failed: " .. tostring(result and result.error))

-- ── Every usable pool clip must have a media row AND a master sequence ──
local function query_value(sql)
    local st = assert(conn:prepare(sql), "prepare failed: " .. sql)
    assert(st:exec(), "query failed: " .. sql)
    local v = st:next() and st:value(0) or nil
    st:finalize()
    return v
end

local function sql_quote(s) return (s:gsub("'", "''")) end

local missing_media, missing_master = {}, {}
for name in pairs(expected) do
    local q = sql_quote(name)
    local media_id = query_value(string.format(
        "SELECT id FROM media WHERE name = '%s' LIMIT 1", q))
    if not media_id then
        missing_media[#missing_media + 1] = name
    else
        local master = query_value(string.format(
            "SELECT s.id FROM sequences s "
            .. "JOIN media_refs mr ON mr.owner_sequence_id = s.id "
            .. "WHERE s.kind = 'master' AND mr.media_id = '%s' LIMIT 1", sql_quote(media_id)))
        if not master then missing_master[#missing_master + 1] = name end
    end
end

assert(#missing_media == 0, string.format(
    "%d/%d pool clips imported NO media row (pool-only clips not materialized): %s",
    #missing_media, n_expected, table.concat(missing_media, ", ")))
assert(#missing_master == 0, string.format(
    "%d/%d pool clips have media but NO master sequence (not browseable/openable): %s",
    #missing_master, n_expected, table.concat(missing_master, ", ")))

print(string.format("  ✓ all %d pool clips imported with media + master sequence", n_expected))
print("✅ test_drp_imports_full_media_pool.lua passed")
