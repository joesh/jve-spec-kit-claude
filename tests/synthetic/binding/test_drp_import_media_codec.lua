require("test_env")

-- =============================================================================
-- DRP import → media.codec populated from the Clip blob (spec 026 gap #4, T019,
-- FR-010). Before this, media.codec was empty for every gold media, so the DRT
-- exporter had nothing to author and hard-coded "avc1"/"AAC". The importer must
-- decode the Clip-blob f5 codec (decode_bt_clip_codec) and persist it.
--
-- DOMAIN: import a Resolve-authored .drp with both video and audio media and
-- assert the persisted media rows carry their real codecs — video media =
-- "avc1" (decoded from the COMPRESSED BtVideoInfo blob), standalone audio =
-- "Linear PCM". Black-box: drives the real importer + reads the media table.
--
-- Run: ./build/bin/jve.app/Contents/MacOS/jve --test \
--        <abs>/tests/synthetic/binding/test_drp_import_media_codec.lua
-- =============================================================================

local drp_importer = require("importers.drp_importer")
local database     = require("core.database")
local json         = require("dkjson")

local FIXTURE = require("test_env").require_fixture(
    "tests/fixtures/resolve/resolve_authored_full.drp")

local tmp_db = "/tmp/jve/test_drp_import_media_codec.jvp"
os.execute("mkdir -p /tmp/jve"); os.remove(tmp_db)
database.init(tmp_db)
local conn = assert(database.get_connection(), "no db connection")
assert(conn:exec(require("import_schema")), "schema creation failed")

local parsed = drp_importer.parse_drp_file(FIXTURE)
assert(parsed and parsed.success ~= false,
    "parse_drp_file failed: " .. tostring(parsed and parsed.error))
local rate     = drp_importer.pick_majority_audio_sample_rate(parsed)
local settings = drp_importer.derive_project_settings(parsed, rate)
local project_id = "test-media-codec"
assert(conn:exec(string.format(
    "INSERT INTO projects (id, name, created_at, modified_at, fps_mismatch_policy, settings) "
    .. "VALUES ('%s', 'Media Codec', 0, 0, 'resample', '%s')",
    project_id, (json.encode(settings):gsub("'", "''")))),
    "project insert failed")
assert((drp_importer.import_into_project(project_id, parsed,
    { project_settings = settings }) or {}).success ~= false, "import failed")

-- Collect (width, codec) for every imported media. Video media have width>0.
local seen = {}
local st = assert(conn:prepare("SELECT codec, width FROM media"))
assert(st:exec(), "media query failed")
while st:next() do
    local codec = st:value(0)
    local width = st:value(1)
    seen[#seen + 1] = { codec = codec, width = width }
end
st:finalize()
assert(#seen > 0, "no media imported")

-- A video media (width>0) must carry its VIDEO codec (avc1), proving the
-- compressed BtVideoInfo blob was decompressed — not the embedded-audio AAC.
local video_codecs, audio_codecs = {}, {}
for _, m in ipairs(seen) do
    if type(m.width) == "number" and m.width > 0 then
        video_codecs[tostring(m.codec)] = true
    else
        audio_codecs[tostring(m.codec)] = true
    end
end
assert(video_codecs["avc1"], "video media did not persist codec 'avc1' (got: "
    .. table.concat((function() local t = {} for k in pairs(video_codecs) do t[#t+1]=k end return t end)(), ",")
    .. ") — compressed BtVideoInfo codec not decoded/persisted")
assert(audio_codecs["Linear PCM"], "standalone-audio media did not persist 'Linear PCM' (got: "
    .. table.concat((function() local t = {} for k in pairs(audio_codecs) do t[#t+1]=k end return t end)(), ",")
    .. ")")

print("✅ test_drp_import_media_codec.lua passed")
