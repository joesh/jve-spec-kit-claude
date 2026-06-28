-- test_drt_audio_routing.lua — gap #3 (FR-007/008/009): audio clip routing is
-- payload-driven, not the hardcoded mono→A1 / MediaTrackIdx=0.
--
-- DOMAIN (research D11, first-hand fixture decode + phase0 §F): each audio
-- timeline clip carries a routing descriptor that distinguishes how its audio
-- reaches the channel:
--   • embedded / standalone:  MediaTrackIdx = source_channel (0-based file ch)
--   • linked / synced:        MediaTrackIdx = 2 (virtual-track slot)
-- and a kind (mono / stereo / synced) + the 1-based VATBA channel index
-- (source_channel + 1). In `resolve_authored_full.drp` the standalone
-- `test_click_48k_stereo.wav` clip reads file channel 2 (VATBA b52 = 0x02,
-- MediaTrackIdx = 1) while the embedded-audio .mp4 clips read channel 1
-- (MediaTrackIdx = 0). A correct exporter must therefore emit DIFFERENT
-- MediaTrackIdx values across these clips — today the writer hardcodes 0 for
-- all, and payload_builder emits NO routing descriptor at all.
--
-- PRODUCER test: asserts the routing descriptor in the payload (the writer's
-- VATBA byte synthesis is verified at the gap-#2 round-trip, since the writer
-- cannot emit a standalone-audio pool item until then). RED until T014.
--
-- Run: ./build/bin/jve.app/Contents/MacOS/jve --test \
--        <abs>/tests/synthetic/binding/test_drt_audio_routing.lua
local test_env        = require("test_env")
local drp_importer    = require("importers.drp_importer")
local payload_builder = require("core.resolve_bridge.payload_builder")
local database        = require("core.database")
local json            = require("dkjson")

local FIXTURE = test_env.require_fixture(
    "tests/fixtures/resolve/resolve_authored_full.drp")
local WAV_NAME = "test_click_48k_stereo.wav"   -- standalone, reads file channel 2

local tmp_db = "/tmp/jve/test_drt_audio_routing.jvp"
os.execute("mkdir -p /tmp/jve"); os.remove(tmp_db)
database.init(tmp_db)
local conn = assert(database.get_connection(), "no db connection")
assert(conn:exec(require("import_schema")), "schema creation failed")

local parsed = drp_importer.parse_drp_file(FIXTURE)
assert(parsed and parsed.success ~= false,
    "parse_drp_file failed: " .. tostring(parsed and parsed.error))
local rate     = drp_importer.pick_majority_audio_sample_rate(parsed)
local settings = drp_importer.derive_project_settings(parsed, rate)
local project_id = "test-audio-routing"
assert(conn:exec(string.format(
    "INSERT INTO projects (id, name, created_at, modified_at, fps_mismatch_policy, settings) "
    .. "VALUES ('%s', 'Audio Routing', 0, 0, 'resample', '%s')",
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

-- ── Collect every audio clip + its routing descriptor ──────────────────────
local audio_clips, wav_clip = {}, nil
for _, track in ipairs(payload.sequence.tracks) do
    if track.type == "audio" then
        for _, c in ipairs(track.clips) do
            audio_clips[#audio_clips + 1] = c
            -- match the standalone WAV by its media item name
            for _, ref in ipairs(payload.media_refs) do
                if ref.file_uuid == c.media_uuid and ref.name == WAV_NAME then
                    wav_clip = c
                end
            end
        end
    end
end
assert(#audio_clips > 0, "no audio clips in payload")
assert(wav_clip, "standalone WAV clip absent from payload audio tracks")

-- ── Assertion 1 (FR-007): every audio clip carries a routing descriptor ────
local idx_values = {}
for _, c in ipairs(audio_clips) do
    assert(type(c.routing) == "table", string.format(
        "audio clip %s has no routing descriptor — gap #3 not applied",
        tostring(c.id)))
    assert(c.routing.kind == "mono" or c.routing.kind == "stereo"
        or c.routing.kind == "synced", string.format(
        "audio clip %s routing.kind=%q — expected mono|stereo|synced",
        tostring(c.id), tostring(c.routing.kind)))
    assert(type(c.routing.media_track_idx) == "number", string.format(
        "audio clip %s routing.media_track_idx missing/non-number",
        tostring(c.id)))
    idx_values[c.routing.media_track_idx] = true
end

-- ── Assertion 2 (FR-008): MediaTrackIdx is NOT a constant 0 — it varies by
--    relationship. The standalone WAV reads file channel 2, so its descriptor
--    must differ from the embedded ch-1 clips (which are 0). ────────────────
local distinct = 0
for _ in pairs(idx_values) do distinct = distinct + 1 end
assert(distinct > 1, string.format(
    "all %d audio clips share one MediaTrackIdx — routing still hardcoded, "
    .. "not payload-driven (the standalone WAV reads a different channel)",
    #audio_clips))

-- ── Assertion 3 (FR-008): the WAV reads file channel 2 → non-synced rule
--    MediaTrackIdx == source_channel == 1 (0-based). ─────────────────────────
assert(wav_clip.routing.kind ~= "synced", string.format(
    "standalone WAV routing.kind=%q — a standalone file is not synced",
    tostring(wav_clip.routing.kind)))
assert(wav_clip.routing.source_channel == 1, string.format(
    "standalone WAV routing.source_channel=%s — fixture clip reads file "
    .. "channel 2 (0-based 1)", tostring(wav_clip.routing.source_channel)))
assert(wav_clip.routing.media_track_idx == wav_clip.routing.source_channel,
    string.format("standalone WAV MediaTrackIdx=%s != source_channel=%s — "
    .. "non-synced rule is MediaTrackIdx = source_channel (D11)",
    tostring(wav_clip.routing.media_track_idx),
    tostring(wav_clip.routing.source_channel)))

print("  ✓ per-clip routing descriptor; MediaTrackIdx payload-driven")
print("✅ test_drt_audio_routing.lua passed")
