require("test_env")

-- =============================================================================
-- DRP import → media.width/height = INTRINSIC per-clip resolution (spec 026
-- gap #4, T019/FR-011). The importer used to stamp every video media with the
-- PROJECT resolution; it must instead decode each clip's own BtVideoInfo
-- <Geometry> so a non-project-res file round-trips its true dimensions.
--
-- DOMAIN: anamnesis-gold-timeline.drp is a 1920×1080 project that contains a
-- 2048×1152 camera file (A035_*.mov). A persisted media row of 2048×1152 proves
-- the intrinsic Geometry was decoded — under the old project-dims fallback every
-- video media would have been 1920×1080. Golden dims = the bytes Resolve wrote.
--
-- Run: ./build/bin/jve.app/Contents/MacOS/jve --test \
--        <abs>/tests/synthetic/binding/test_drp_import_video_resolution.lua
-- =============================================================================

local drp_importer = require("importers.drp_importer")
local database     = require("core.database")
local json         = require("dkjson")

local FIXTURE = require("test_env").require_fixture(
    "tests/fixtures/resolve/anamnesis-gold-timeline.drp")

local tmp_db = "/tmp/jve/test_drp_import_video_resolution.jvp"
os.execute("mkdir -p /tmp/jve"); os.remove(tmp_db)
database.init(tmp_db)
local conn = assert(database.get_connection(), "no db connection")
assert(conn:exec(require("import_schema")), "schema creation failed")

local parsed = drp_importer.parse_drp_file(FIXTURE)
assert(parsed and parsed.success ~= false,
    "parse_drp_file failed: " .. tostring(parsed and parsed.error))
local rate     = drp_importer.pick_majority_audio_sample_rate(parsed)
local settings = drp_importer.derive_project_settings(parsed, rate)
local project_id = "test-video-res"
assert(conn:exec(string.format(
    "INSERT INTO projects (id, name, created_at, modified_at, fps_mismatch_policy, settings) "
    .. "VALUES ('%s', 'Video Res', 0, 0, 'resample', '%s')",
    project_id, (json.encode(settings):gsub("'", "''")))),
    "project insert failed")
assert((drp_importer.import_into_project(project_id, parsed,
    { project_settings = settings }) or {}).success ~= false, "import failed")

-- Collect distinct (width,height) among video media (width>0).
local dims = {}
local st = assert(conn:prepare("SELECT DISTINCT width, height FROM media WHERE width > 0"))
assert(st:exec(), "media query failed")
while st:next() do dims[st:value(0) .. "x" .. st:value(1)] = true end
st:finalize()

assert(dims["2048x1152"], "no 2048×1152 media row — intrinsic Geometry resolution "
    .. "not decoded/persisted (got: " .. table.concat(
        (function() local t = {} for k in pairs(dims) do t[#t+1] = k end return t end)(), ", ")
    .. ")")

print("✅ test_drp_import_video_resolution.lua passed")
