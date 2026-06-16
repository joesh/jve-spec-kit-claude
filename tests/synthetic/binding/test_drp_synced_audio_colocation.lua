-- test_drp_synced_audio_colocation.lua — synced external audio must align to
-- its video by Resolve's stored SampleOffset, not by the audio file's own
-- record timecode.
--
-- Domain / ground truth (measured from the Resolve-authored fixture
-- "synced clip example.drp", per "follow the fixtures, invent nothing"):
--   * The .mov video take is at TC 14:08:14 (the camera).
--   * The external WAV is a 64s file at TC 11:21:24 — its timecode window does
--     NOT contain the video's, so this is a FREE-RUN sync (sound recorder not
--     jam-synced to camera). Timecode cannot align them.
--   * Resolve stores the real alignment as a per-channel SampleOffset in the
--     synced clip's audio FieldsBlob: 974399 samples. That is the WAV file
--     position that plays under the video's first frame (20.3s into the 64s
--     WAV; 20.3 + 32.8s take = 53.1s ≤ 64s).
--   * In the edit timeline Resolve places the synced video and audio clips at
--     the SAME record Start — they are co-located; the offset is in the source
--     mapping, not the placement.
--
-- So a correct import yields, on the synced master, for every WAV channel:
--   * sequence_start_frame == the video's sequence_start_frame (co-located), and
--   * a source whose file position at the clip origin == SampleOffset, i.e.
--     (source_in_frame − wav.audio_start_tc) == 974399.
--
-- The bug this guards: the importer ignored SampleOffset and placed the WAV at
-- its own record TC (sequence_start from audio_tc, file_pos 0). The WAV landed
-- 2h47m from the video; only the camera-audio track overlapped it, zoom-to-fit
-- blew out to hours, and relink reported the WAV "short at tail".
--
-- Run: ./build/bin/jve.app/Contents/MacOS/jve --test \
--        tests/synthetic/binding/test_drp_synced_audio_colocation.lua
local test_env     = require("test_env")
local drp_importer = require("importers.drp_importer")
local database     = require("core.database")

local FIXTURE = test_env.require_fixture(
    "tests/fixtures/resolve/synced clip example.drp")

local WAV = "S064-T002.WAV"
-- Measured from the fixture's synced-clip audio FieldsBlob (SampleOffset field).
local SAMPLE_OFFSET = 974399

local tmp_db = "/tmp/jve/test_drp_synced_audio_colocation.jvp"
os.execute("mkdir -p /tmp/jve")
os.remove(tmp_db); os.remove(tmp_db .. "-wal"); os.remove(tmp_db .. "-shm")
database.init(tmp_db)
local conn = assert(database.get_connection(), "no db connection")
assert(conn:exec(require("import_schema")), "schema creation failed")

local project_id = "test-synced-colocation"
assert(conn:exec(string.format(
    "INSERT INTO projects (id, name, created_at, modified_at, fps_mismatch_policy) "
    .. "VALUES ('%s', 'Synced Colocation Test', 0, 0, 'resample')", project_id)),
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

-- ── SQL helpers (tests are exempt from the SQL-isolation guard) ─────────
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

local wav_media = rows(string.format(
    "SELECT id, metadata FROM media WHERE name = '%s'", sql_quote(WAV)),
    { "id", "metadata" })
assert(#wav_media == 1, "expected exactly 1 WAV media row, got " .. #wav_media)
local wav_media_id = wav_media[1].id
-- The WAV's TC origin in samples (start_tc_audio_samples) is the reference for
-- file position: file_pos = source_in − audio_start_tc.
local wav_tc = tonumber(
    (wav_media[1].metadata or ""):match('"start_tc_audio_samples":(%d+)'))
assert(wav_tc, "WAV media metadata missing start_tc_audio_samples")

-- ── The synced master (the .mov master with WAV sync tracks) ────────────
local synced_masters = rows(string.format([[
    SELECT DISTINCT s.id AS id
    FROM sequences s
    JOIN tracks t      ON t.sequence_id = s.id
    JOIN media_refs mr ON mr.track_id   = t.id
    WHERE s.kind = 'master' AND t.source_kind = 'sync' AND mr.media_id = '%s'
]], sql_quote(wav_media_id)), { "id" })
assert(#synced_masters == 1, string.format(
    "expected exactly 1 synced master referencing the WAV on sync tracks, got %d",
    #synced_masters))
local synced_master_id = synced_masters[1].id

local video_refs = rows(string.format([[
    SELECT mr.sequence_start_frame AS ss, mr.duration_frames AS dur
    FROM media_refs mr JOIN tracks t ON t.id = mr.track_id
    WHERE t.sequence_id = '%s' AND t.track_type = 'VIDEO'
]], sql_quote(synced_master_id)), { "ss", "dur" })
assert(#video_refs == 1, string.format(
    "expected 1 video media_ref on the synced master, got %d", #video_refs))
local video_start = video_refs[1].ss
assert(type(video_start) == "number", "video media_ref has no sequence_start_frame")

local wav_refs = rows(string.format([[
    SELECT mr.sequence_start_frame AS ss, mr.source_in_frame AS src_in
    FROM media_refs mr JOIN tracks t ON t.id = mr.track_id
    WHERE t.sequence_id = '%s' AND t.source_kind = 'sync' AND mr.media_id = '%s'
]], sql_quote(synced_master_id), sql_quote(wav_media_id)), { "ss", "src_in" })
assert(#wav_refs >= 1, "expected at least one synced WAV media_ref")

for _, r in ipairs(wav_refs) do
    -- 1. Co-located with the video (Resolve stores the same record Start).
    assert(r.ss == video_start, string.format(
        "synced WAV channel is at sequence_start_frame %s but the video is at %s "
        .. "— a synced clip's audio and video are co-located; the WAV's own "
        .. "record timecode must NOT drive its placement",
        tostring(r.ss), tostring(video_start)))
    -- 2. The WAV plays its SampleOffset sample under the video's first frame.
    local file_pos = r.src_in - wav_tc
    assert(file_pos == SAMPLE_OFFSET, string.format(
        "synced WAV file position at the clip origin is %s but Resolve's stored "
        .. "SampleOffset is %d — the sync offset was not applied "
        .. "(source_in=%s, wav_tc=%s)",
        tostring(file_pos), SAMPLE_OFFSET, tostring(r.src_in), tostring(wav_tc)))
end

print(string.format(
    "  ✓ synced master: %d WAV channels co-located with video at frame %d, "
    .. "file_pos == SampleOffset (%d)", #wav_refs, video_start, SAMPLE_OFFSET))
print("✅ test_drp_synced_audio_colocation.lua passed")
