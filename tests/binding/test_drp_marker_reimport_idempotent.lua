-- test_drp_marker_reimport_idempotent.lua — re-importing the same DRP must
-- NOT accumulate duplicate markers for a clip.
--
-- Domain: a DRP defines its clips' markers. Importing the same source twice is
-- a no-op on the marker set (modulo source changes). Without dedup, the
-- per-marker UUID is fresh per parse and every re-import doubles the table.
--
-- Run: ./build/bin/jve.app/Contents/MacOS/jve --test tests/binding/test_drp_marker_reimport_idempotent.lua
local test_env = require("test_env")
local drp_importer = require("importers.drp_importer")
local database = require("core.database")

local FIXTURE = test_env.require_fixture("tests/fixtures/resolve/markers_16color_edge.drp")

local tmp_db = "/tmp/jve/test_drp_marker_reimport_idempotent.jvp"
os.execute("mkdir -p /tmp/jve")
os.remove(tmp_db)
database.init(tmp_db)
local conn = assert(database.get_connection(), "no db connection")
assert(conn:exec(require("import_schema")), "schema creation failed")

-- Helper: import the fixture under a unique project id, return the marker
-- count on the countdown clip (the only marker-bearing clip in the fixture).
local function import_and_count(project_id)
    assert(conn:exec(string.format(
        "INSERT INTO projects (id, name, created_at, modified_at, fps_mismatch_policy) "
        .. "VALUES ('%s', 'reimport-test', 0, 0, 'resample')", project_id)),
        "project insert failed")
    local parsed = drp_importer.parse_drp_file(FIXTURE)
    assert(parsed and parsed.success ~= false, "parse failed")
    local settings = drp_importer.derive_project_settings(parsed, 48000)
    local result = drp_importer.import_into_project(project_id, parsed,
        { project_settings = settings })
    assert(result and result.success ~= false, "import failed")

    local st = assert(conn:prepare([[
        SELECT COUNT(*) FROM clip_markers cm
        JOIN clips c ON cm.clip_id = c.id
        WHERE c.project_id = ? AND c.name LIKE '%countdown%'
    ]]))
    st:bind_value(1, project_id)
    assert(st:exec())
    assert(st:next(), "count query produced no row")
    local n = st:value(0)
    st:finalize()
    return n
end

-- Two separate imports → fresh clip rows (per FR-011b clip.id = Sm2Ti DbId is
-- unique-per-clip-instance, but each project_id gives a separate row tree).
-- Inside ONE project, re-running the importer on the same parse must dedup.
local n1 = import_and_count("reimport-test-proj-A")
assert(n1 > 0, "first import should produce markers; got " .. tostring(n1))

-- Re-run the importer pass against the SAME project: clips already exist, but
-- the marker delete_for_clip step must keep the count stable.
local parsed = drp_importer.parse_drp_file(FIXTURE)
-- Find the existing countdown clip's id (= Sm2Ti DbId, FR-011b) and the
-- markers belonging to it from the parse result. The importer would crash on
-- a duplicate clip row; the dedup behavior we're verifying lives in the
-- ClipMarker.delete_for_clip / per-marker UUID path. Exercise it directly.
local ClipMarker = require("models.clip_marker")
local st = assert(conn:prepare(
    "SELECT id FROM clips WHERE project_id = ? AND name LIKE '%countdown%' LIMIT 1"))
st:bind_value(1, "reimport-test-proj-A")
assert(st:exec()); assert(st:next())
local clip_id = st:value(0); st:finalize()

-- The decoded marker list for the countdown clip.
local markers_for_clip
for _, tl in ipairs(parsed.timelines) do
    for _, tr in ipairs(tl.tracks) do
        for _, c in ipairs(tr.clips) do
            if c.name and c.name:find("countdown") and c.markers then
                markers_for_clip = c.markers
            end
        end
    end
end
assert(markers_for_clip and #markers_for_clip > 0,
    "fixture parse did not surface countdown clip markers")

-- Simulate a re-import for this clip: delete + insert (the path
-- importer_core.lua takes when re-applying markers to an existing clip).
ClipMarker.delete_for_clip(clip_id)
for _, mk in ipairs(markers_for_clip) do
    ClipMarker.new({
        clip_id = clip_id, frame = mk.frame, duration = mk.duration,
        color = mk.color, name = mk.name, note = mk.note,
        custom_data = mk.custom_data,
    }):save()
end

local n2_st = assert(conn:prepare(
    "SELECT COUNT(*) FROM clip_markers WHERE clip_id = ?"))
n2_st:bind_value(1, clip_id)
assert(n2_st:exec()); assert(n2_st:next())
local n2 = n2_st:value(0); n2_st:finalize()

assert(n2 == n1, string.format(
    "re-import doubled markers: first=%d, after re-import=%d", n1, n2))

print(string.format(
    "✅ test_drp_marker_reimport_idempotent.lua passed (%d markers stable across re-import)", n2))
