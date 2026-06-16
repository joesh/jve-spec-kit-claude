-- test_drp_synced_relink_placement.lua — relinking the external WAV must NOT
-- move the synced clip's audio off the video.
--
-- Domain / ground truth (Resolve-authored "synced clip example.drp"):
--   * A synced clip co-locates the external WAV with the video: the audio
--     plays under the picture. Its placement is video-derived — it starts at
--     the video's timecode, lasts the video take, and references a sub-range
--     of the WAV ([audio_tc + per-channel SampleOffset, + take]).
--   * The same WAV ALSO imports as its own audio-only master, which DOES sit
--     at the file's own timecode origin spanning the whole file.
--   * Relink re-probes the WAV and syncs each media's duration to the file's
--     true length. For the audio-only master that rebases its media_ref to the
--     full file. For the SYNCED placement nothing changes: the synced range is
--     anchored to the video, not to the WAV's total length. Re-cutting the WAV
--     on disk doesn't move where the synced audio sits under the picture.
--
-- The bug this guards: Media.batch_set_durations rebased EVERY audio media_ref
-- of the relinked WAV to [file_tc_origin, +full_file_duration], treating the
-- synced placement like the audio-only master. That flung the synced audio MR
-- to the WAV's absolute sample timecode (sequence_start ~1.96 billion), blowing
-- the synced sequence's content extent out to hours and scattering the audio.
--
-- Run: ./build/bin/jve.app/Contents/MacOS/jve --test \
--        <abs>/tests/synthetic/binding/test_drp_synced_relink_placement.lua
local test_env     = require("test_env")
local drp_importer = require("importers.drp_importer")
local database     = require("core.database")
local Media        = require("models.media")

local FIXTURE = test_env.require_fixture(
    "tests/fixtures/resolve/synced clip example.drp")
local WAV = "S064-T002.WAV"

local tmp_db = "/tmp/jve/test_drp_synced_relink_placement.jvp"
os.execute("mkdir -p /tmp/jve")
os.remove(tmp_db); os.remove(tmp_db .. "-wal"); os.remove(tmp_db .. "-shm")
database.init(tmp_db)
local conn = assert(database.get_connection(), "no db connection")
assert(conn:exec(require("import_schema")), "schema creation failed")

local project_id = "test-synced-relink-placement"
assert(conn:exec(string.format(
    "INSERT INTO projects (id, name, created_at, modified_at, fps_mismatch_policy) "
    .. "VALUES ('%s', 'Synced Relink Placement', 0, 0, 'resample')", project_id)),
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

-- Locate the WAV media + its full-file sample count (what relink will sync to).
local st = assert(conn:prepare(string.format(
    "SELECT id FROM media WHERE name = '%s'", sql_quote(WAV))), "prepare failed")
assert(st:exec(), "query failed")
assert(st:next(), "WAV media not found")
local wav_id = st:value(0)
st:finalize()

local media = assert(Media.load(wav_id), "Media.load failed for WAV")
local full_file_samples = assert(media.duration, "WAV has no duration")

-- Snapshot the synced placement(s) of this WAV: media_refs that live on a
-- sync-routed track. These are co-located with the video and must survive a
-- relink duration-sync untouched.
local function read_sync_refs()
    local q = assert(conn:prepare(string.format([[
        SELECT mr.id, mr.sequence_start_frame, mr.duration_frames,
               mr.source_in_frame, mr.source_out_frame
          FROM media_refs mr
          JOIN tracks t ON t.id = mr.track_id
         WHERE mr.media_id = '%s' AND t.source_kind = 'sync'
    ]], sql_quote(wav_id))), "prepare sync-refs query failed")
    assert(q:exec(), "sync-refs query failed")
    local refs = {}
    while q:next() do
        refs[q:value(0)] = {
            seq_start  = q:value(1),
            duration   = q:value(2),
            source_in  = q:value(3),
            source_out = q:value(4),
        }
    end
    q:finalize()
    return refs
end

local before = read_sync_refs()
assert(next(before) ~= nil,
    "no sync-routed media_refs for the WAV — fixture/import changed")

-- Simulate relink's duration-sync: the re-probed WAV reports its true full
-- length. tc_updates nil (filename relink, TC origin unchanged) — the bug
-- reproduces regardless because the audio-only rebase branch anchors
-- sequence_start to source_in (the file's sample timecode).
Media.batch_set_durations({ [wav_id] = { audio_duration_samples = full_file_samples } }, nil)

local after = read_sync_refs()

for ref_id, b in pairs(before) do
    local a = assert(after[ref_id], "sync media_ref vanished after relink: " .. ref_id)
    assert(a.seq_start == b.seq_start, string.format(
        "synced audio media_ref %s moved on relink: sequence_start %d -> %d "
        .. "(the relink rebased the synced placement to the WAV's absolute "
        .. "timecode instead of leaving it co-located with the video)",
        ref_id, b.seq_start, a.seq_start))
    assert(a.duration == b.duration, string.format(
        "synced audio media_ref %s duration changed on relink: %d -> %d "
        .. "(the relink stretched the synced take to the full file length)",
        ref_id, b.duration, a.duration))
    assert(a.source_in == b.source_in and a.source_out == b.source_out,
        string.format(
        "synced audio media_ref %s source range changed on relink: "
        .. "[%d,%d] -> [%d,%d]",
        ref_id, b.source_in, b.source_out, a.source_in, a.source_out))
end

print(string.format(
    "  ✓ %d synced WAV media_ref(s) kept co-located placement across relink",
    (function() local n = 0 for _ in pairs(before) do n = n + 1 end return n end)()))
print("✅ test_drp_synced_relink_placement.lua passed")
