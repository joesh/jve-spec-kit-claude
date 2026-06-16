-- test_drp_audio_master_tc_origin.lua — an audio-only master's declared TC
-- origin must match where its audio actually sits, so opening it shows the clip
-- at the ruler origin instead of flung hours downstream.
--
-- Domain / ground truth (Resolve-authored "synced clip example.drp"):
--   * A master sequence's timebase IS absolute timecode space: each media_ref
--     sits at sequence_start = the file's TC origin and spans
--     [tc_origin, tc_origin + duration]; the range [0, tc_origin) is empty.
--   * For that to display sanely, the master's own TC origin
--     (start_timecode_frame — the ruler/view anchor) MUST equal where its
--     content sits. The video master gets this right (start_timecode_frame =
--     video_tc, content at video_tc).
--   * The external WAV S064-T002.WAV imports as an audio-only master. Its BWF
--     time_reference puts the audio at a large sample timecode (~11h at 48kHz).
--     Its start_timecode_frame must equal that sample timecode — otherwise the
--     ruler sits at 0, the audio sits ~2 billion samples to the right, and
--     zoom-to-fit blows the view out to hours of empty space.
--
-- The bug this guards: create_master_row set start_timecode_frame = video_tc
-- unconditionally. For an audio-only master video_tc is nil (stored 0), while
-- the audio camera media_ref is placed at audio_tc — a multi-hour disagreement
-- between the declared origin and the actual content.
--
-- Run: ./build/bin/jve.app/Contents/MacOS/jve --test \
--        <abs>/tests/synthetic/binding/test_drp_audio_master_tc_origin.lua
local test_env     = require("test_env")
local drp_importer = require("importers.drp_importer")
local database     = require("core.database")

local FIXTURE = test_env.require_fixture(
    "tests/fixtures/resolve/synced clip example.drp")
local WAV = "S064-T002.WAV"

local tmp_db = "/tmp/jve/test_drp_audio_master_tc_origin.jvp"
os.execute("mkdir -p /tmp/jve")
os.remove(tmp_db); os.remove(tmp_db .. "-wal"); os.remove(tmp_db .. "-shm")
database.init(tmp_db)
local conn = assert(database.get_connection(), "no db connection")
assert(conn:exec(require("import_schema")), "schema creation failed")

local project_id = "test-audio-master-tc-origin"
assert(conn:exec(string.format(
    "INSERT INTO projects (id, name, created_at, modified_at, fps_mismatch_policy) "
    .. "VALUES ('%s', 'Audio Master TC Origin', 0, 0, 'resample')", project_id)),
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

local function sql_quote(s) return (s:gsub("'", "''")) end

-- Every audio-only master named for the WAV (one per pool item) must have its
-- declared TC origin agree with where its audio content sits.
local q = assert(conn:prepare(string.format([[
    SELECT s.id, s.start_timecode_frame, mr.sequence_start_frame, mr.duration_frames
      FROM sequences s
      JOIN media_refs mr ON mr.owner_sequence_id = s.id
      JOIN tracks t ON t.id = mr.track_id
     WHERE s.kind = 'master' AND s.name = '%s' AND t.track_type = 'AUDIO'
]], sql_quote(WAV))), "prepare query failed")
assert(q:exec(), "query failed")

local checked = 0
while q:next() do
    checked = checked + 1
    local seq_id        = q:value(0)
    local declared_tc   = q:value(1)   -- start_timecode_frame
    local content_start = q:value(2)   -- media_ref sequence_start_frame
    assert(declared_tc == content_start, string.format(
        "audio-only master %s declares TC origin %d but its audio content sits "
        .. "at %d (off by %d samples ~%.0fs) — the ruler anchors at the wrong "
        .. "place and the view blows out to hours of empty space",
        seq_id, declared_tc, content_start,
        content_start - declared_tc, (content_start - declared_tc) / 48000))
end
q:finalize()

assert(checked > 0, "no audio-only WAV masters found — fixture/import changed")
print(string.format(
    "  ✓ %d audio-only master(s): declared TC origin matches content placement",
    checked))
print("✅ test_drp_audio_master_tc_origin.lua passed")
