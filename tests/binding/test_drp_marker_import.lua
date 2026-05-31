-- test_drp_marker_import.lua — DRP import persists per-clip markers
--
-- Domain: when a project is imported from a DRP, the markers a user placed on
-- a timeline clip in DaVinci Resolve must come across — drawn on that clip,
-- with the same position, color, name, note, span (duration) and custom data.
--
-- Integration test: runs the real DRP parse + import into a scratch project DB
-- and asserts the persisted clip_markers rows for the marker-bearing clip.
-- The fixture `markers_16color_edge.drp` has one marker of each of Resolve's
-- 16 colors plus edge cases (empty note, empty custom data) on its third
-- clip ("countdown_chirp_30s.mp4"); `.truth.json` records exactly what was
-- entered.
--
-- Run: ./build/bin/jve.app/Contents/MacOS/jve --test tests/binding/test_drp_marker_import.lua
local test_env = require("test_env")
local drp_importer = require("importers.drp_importer")
local database = require("core.database")
local dkjson = require("dkjson")

local FIXTURE = test_env.require_fixture("tests/fixtures/resolve/markers_16color_edge.drp")
local TRUTH   = test_env.require_fixture("tests/fixtures/resolve/markers_16color_edge.truth.json")

-- ── Import the DRP into a scratch project DB ────────────────────────────
-- Bootstrap mirrors tests/binding/test_import_resolve_drp.lua exactly.
local tmp_db = "/tmp/jve/test_drp_marker_import.jvp"
os.execute("mkdir -p /tmp/jve")
os.remove(tmp_db)
database.init(tmp_db)
local conn = assert(database.get_connection(), "no db connection")
assert(conn:exec(require("import_schema")), "schema creation failed")

-- The project row must pre-exist; import_into_project fills sequences/clips.
local project_id = "test-marker-project"
assert(conn:exec(string.format(
    "INSERT INTO projects (id, name, created_at, modified_at, fps_mismatch_policy) "
    .. "VALUES ('%s', 'DRP Marker Test', 0, 0, 'resample')", project_id)),
    "project insert failed")

local parsed = drp_importer.parse_drp_file(FIXTURE)
assert(parsed and parsed.success ~= false,
    "parse_drp_file failed: " .. tostring(parsed and parsed.error))

-- The fixture's timeline is video-only (the marker-bearing clips carry no
-- audio), so the importer can't derive an audio sample rate from it. Supply
-- one explicitly via derived settings — the importer requires it (rule 2.13).
local settings = drp_importer.derive_project_settings(parsed, 48000)
local result = drp_importer.import_into_project(project_id, parsed,
    { project_settings = settings })
assert(result and result.success ~= false,
    "import_into_project failed: " .. tostring(result and result.error))

-- ── Load the truth ──────────────────────────────────────────────────────
local tf = assert(io.open(TRUTH, "r"))
local truth = assert(dkjson.decode(tf:read("*a")))
tf:close()

-- ── Query the countdown clip's persisted markers ────────────────────────
local db = database.get_connection()
local st = db:prepare([[
    SELECT cm.frame, cm.duration, cm.color, cm.name, cm.note, cm.custom_data
    FROM clip_markers cm JOIN clips c ON cm.clip_id = c.id
    WHERE c.name LIKE '%countdown%'
    ORDER BY cm.frame ASC
]])
assert(st, "prepare failed")
assert(st:exec(), "query failed")
local by_frame = {}
local count = 0
while st:next() do
    by_frame[st:value(0)] = {
        frame = st:value(0), duration = st:value(1), color = st:value(2),
        name = st:value(3), note = st:value(4), custom_data = st:value(5),
    }
    count = count + 1
end
st:finalize()

-- ── Assert: every entered marker round-tripped through import + DB ───────
local function check(expected)
    local got = by_frame[expected.frame]
    assert(got, string.format("no persisted marker at frame %d", expected.frame))
    local function eq(field, want)
        assert(got[field] == want, string.format(
            "frame %d: %s = %q, expected %q",
            expected.frame, field, tostring(got[field]), tostring(want)))
    end
    eq("color", expected.color)
    eq("name", expected.name)
    eq("note", expected.note)
    eq("duration", expected.duration)
    eq("custom_data", expected.customData or "")
end

for _, c in ipairs(truth.colors) do check(c) end   -- all 16 colors
local edge_added = 0
for _, e in ipairs(truth.edge) do
    if e.added then check(e); edge_added = edge_added + 1 end
end

local expected_total = 16 + edge_added
assert(count == expected_total, string.format(
    "countdown clip persisted %d markers, expected %d", count, expected_total))

-- Duration (span) markers: the colors are duration 3, edges duration 5.
local spans = 0
for _, m in pairs(by_frame) do if m.duration > 1 then spans = spans + 1 end end
assert(spans == expected_total, string.format(
    "expected all %d markers to be duration spans (>1), got %d", expected_total, spans))

-- Empty note + empty custom data must persist as "" (not NULL / not dropped).
local empty_note = by_frame[400]
assert(empty_note and empty_note.note == "" and empty_note.custom_data == "hascd",
    "empty-note marker (frame 400) did not round-trip")
local empty_cd = by_frame[420]
assert(empty_cd and empty_cd.custom_data == "" and empty_cd.note == "hasnote",
    "empty-custom-data marker (frame 420) did not round-trip")

print(string.format(
    "✅ test_drp_marker_import.lua passed (%d markers persisted on countdown clip)", count))
