-- test_drp_import_audio_channel_select.lua — gap #3 import side (FR-007/008):
-- a timeline audio clip remembers WHICH file channel it reads.
--
-- DOMAIN (research D11, §F): Resolve stores, per timeline audio clip, a
-- VirtualAudioTrackBA whose channel index (1-based) selects which channel of a
-- multichannel source the clip plays. In `resolve_authored_full.drp` the
-- standalone `test_click_48k_stereo.wav` clip reads file channel 2 (VATBA
-- b52 = 0x02, and the clip's <MediaTrackIdx> = 1). JVE models a stream as
-- (media_id, source_channel) with source_channel 0-based, so after import this
-- clip must resolve to source_channel == 1 — NOT channel 0 (the first channel),
-- which is what a channel-blind import yields.
--
-- This is the import half of gap #3: until the clip carries its real channel,
-- the exporter cannot emit payload-driven routing. BLACK-BOX: drives the real
-- drp_importer and reads the resolved clip via the model, asserting the
-- user-visible fact (which channel plays), never an importer internal.
--
-- Run: ./build/bin/jve.app/Contents/MacOS/jve --test \
--        <abs>/tests/synthetic/binding/test_drp_import_audio_channel_select.lua
local test_env     = require("test_env")
local drp_importer = require("importers.drp_importer")
local database     = require("core.database")
local Clip         = require("models.clip")
local json         = require("dkjson")

local FIXTURE = test_env.require_fixture(
    "tests/fixtures/resolve/resolve_authored_full.drp")
local WAV_NAME = "test_click_48k_stereo.wav"  -- standalone, clip reads channel 2
local EXPECT_SOURCE_CHANNEL = 1               -- 0-based (file channel 2)

local tmp_db = "/tmp/jve/test_drp_import_audio_channel_select.jvp"
os.execute("mkdir -p /tmp/jve"); os.remove(tmp_db)
database.init(tmp_db)
local conn = assert(database.get_connection(), "no db connection")
assert(conn:exec(require("import_schema")), "schema creation failed")

local parsed = drp_importer.parse_drp_file(FIXTURE)
assert(parsed and parsed.success ~= false,
    "parse_drp_file failed: " .. tostring(parsed and parsed.error))
local rate     = drp_importer.pick_majority_audio_sample_rate(parsed)
local settings = drp_importer.derive_project_settings(parsed, rate)
local project_id = "test-audio-channel-select"
assert(conn:exec(string.format(
    "INSERT INTO projects (id, name, created_at, modified_at, fps_mismatch_policy, settings) "
    .. "VALUES ('%s', 'Audio Channel Select', 0, 0, 'resample', '%s')",
    project_id, (json.encode(settings):gsub("'", "''")))),
    "project insert failed")
assert((drp_importer.import_into_project(project_id, parsed,
    { project_settings = settings }) or {}).success ~= false, "import failed")

local function query_rows(sql)
    local out, st = {}, assert(conn:prepare(sql), "prepare failed: " .. sql)
    assert(st:exec(), "query failed: " .. sql)
    while st:next() do out[#out + 1] = st:value(0) end
    st:finalize()
    return out
end

-- The editing sequence's audio-track clips.
local sequence_id = query_rows(
    "SELECT id FROM sequences WHERE kind = 'sequence' LIMIT 1")[1]
assert(sequence_id, "no editing sequence imported")
local clip_ids = query_rows(string.format(
    "SELECT c.id FROM clips c JOIN tracks t ON c.track_id = t.id "
    .. "WHERE c.owner_sequence_id = '%s' AND t.track_type = 'AUDIO'",
    sequence_id))
assert(#clip_ids > 0, "no audio clips imported")

-- Find the clip(s) that play the standalone stereo WAV.
local wav_clips = {}
for _, id in ipairs(clip_ids) do
    local c = Clip.load(id)
    if c and c.resolved_media and c.resolved_media.name == WAV_NAME then
        wav_clips[#wav_clips + 1] = c
    end
end
assert(#wav_clips > 0, string.format(
    "no audio clip resolves to %q — fixture/import changed", WAV_NAME))

for _, c in ipairs(wav_clips) do
    assert(c.resolved_media.source_channel == EXPECT_SOURCE_CHANNEL, string.format(
        "clip %s plays %s at source_channel=%s — expected %d (clip reads file "
        .. "channel 2; VATBA b52=0x02). Channel selection lost on import.",
        tostring(c.id), WAV_NAME, tostring(c.resolved_media.source_channel),
        EXPECT_SOURCE_CHANNEL))
end

print(string.format(
    "  ✓ %d clip(s) for %s resolve source_channel=%d",
    #wav_clips, WAV_NAME, EXPECT_SOURCE_CHANNEL))
print("✅ test_drp_import_audio_channel_select.lua passed")
