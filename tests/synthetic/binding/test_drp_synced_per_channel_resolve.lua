-- test_drp_synced_per_channel_resolve.lua — a synced master resolves to ONE
-- audio entry per audio track, each reading a DISTINCT file channel.
--
-- Domain / ground truth (Resolve-authored "synced clip example.drp"):
--   * JVE models one clip per stream: an A/V file is a video clip + an audio
--     clip, and each audio CHANNEL is its own stream → its own track inside the
--     master. The external 5-channel WAV imports as 5 separate sync tracks.
--   * Resolving the master's audio over its content range must therefore yield
--     exactly one audio entry per audio track, and the five sync entries must
--     read the five DISTINCT WAV channels (0..4). Soloing a track plays that
--     channel — so each track must map to its own channel, not the whole file.
--
-- The bug this guards: the resolver fanned EACH audio media_ref across the
-- file's full channel count, so every one of the 5 single-purpose sync tracks
-- re-expanded into all 5 channels (5×5 = 25 audio entries), each reading the
-- whole file — identical audio and waveforms on every track.
--
-- Run: ./build/bin/jve.app/Contents/MacOS/jve --test \
--        <abs>/tests/synthetic/binding/test_drp_synced_per_channel_resolve.lua
local test_env     = require("test_env")
local drp_importer = require("importers.drp_importer")
local database     = require("core.database")
local Sequence     = require("models.sequence")

local FIXTURE = test_env.require_fixture(
    "tests/fixtures/resolve/synced clip example.drp")

local tmp_db = "/tmp/jve/test_drp_synced_per_channel_resolve.jvp"
os.execute("mkdir -p /tmp/jve")
os.remove(tmp_db); os.remove(tmp_db .. "-wal"); os.remove(tmp_db .. "-shm")
database.init(tmp_db)
local conn = assert(database.get_connection(), "no db connection")
assert(conn:exec(require("import_schema")), "schema creation failed")

local project_id = "test-synced-per-channel-resolve"
assert(conn:exec(string.format(
    "INSERT INTO projects (id, name, created_at, modified_at, fps_mismatch_policy, settings) "
    .. "VALUES ('%s', 'Synced Per Channel', 0, 0, 'resample', "
    .. "'{\"master_clock_hz\":192000,\"default_fps\":{\"num\":25,\"den\":1}}')",
    project_id)),
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

-- Find the synced master: a kind='master' sequence that owns a sync-routed
-- AUDIO track. Also count its AUDIO tracks and grab the content extent.
local function q1(sql)
    local st = assert(conn:prepare(sql), "prepare failed: " .. sql)
    assert(st:exec(), "exec failed: " .. sql)
    assert(st:next(), "no row: " .. sql)
    local v = st:value(0)
    st:finalize()
    return v
end

local master_id = q1([[
    SELECT s.id FROM sequences s
      JOIN tracks t ON t.sequence_id = s.id
     WHERE s.kind = 'master' AND t.track_type = 'AUDIO' AND t.source_kind = 'sync'
     LIMIT 1
]])
local n_audio_tracks = q1(string.format([[
    SELECT COUNT(*) FROM tracks
     WHERE sequence_id = '%s' AND track_type = 'AUDIO'
]], master_id))
local lo = q1(string.format([[
    SELECT MIN(mr.sequence_start_frame) FROM media_refs mr
     JOIN tracks t ON t.id = mr.track_id
     WHERE mr.owner_sequence_id = '%s' AND t.track_type = 'AUDIO'
]], master_id))
local hi = q1(string.format([[
    SELECT MAX(mr.sequence_start_frame + mr.duration_frames) FROM media_refs mr
     JOIN tracks t ON t.id = mr.track_id
     WHERE mr.owner_sequence_id = '%s' AND t.track_type = 'AUDIO'
]], master_id))

local seq = assert(Sequence.load(master_id), "Sequence.load failed for master")
local entries = seq:get_audio_in_range(lo, hi)
assert(type(entries) == "table", "get_audio_in_range returned non-table")

-- One audio entry per audio track — no per-file channel fan.
assert(#entries == n_audio_tracks, string.format(
    "resolved %d audio entries for a master with %d audio tracks — expected one "
    .. "entry per track. A larger count means the resolver re-fanned each "
    .. "single-channel ref across the file's channels (the all-tracks-identical bug)",
    #entries, n_audio_tracks))

-- Each entry maps to its own track (distinct track_index) and names a
-- concrete file channel.
local seen_track = {}
local sync_channels = {}
for _, e in ipairs(entries) do
    assert(e.track_index ~= nil, "audio entry missing track_index")
    assert(not seen_track[e.track_index], string.format(
        "two audio entries on track %d — a track fanned into multiple channels",
        e.track_index))
    seen_track[e.track_index] = true
    assert(type(e.source_channel) == "number" and e.source_channel >= 0,
        string.format("audio entry on track %s has no source_channel",
            tostring(e.track_index)))
end

-- The five sync tracks must read the five distinct WAV channels 0..4.
local sync_track_indexes = {}
local st = assert(conn:prepare(string.format([[
    SELECT track_index FROM tracks
     WHERE sequence_id = '%s' AND track_type = 'AUDIO' AND source_kind = 'sync'
]], master_id)))
assert(st:exec())
while st:next() do sync_track_indexes[st:value(0)] = true end
st:finalize()

for _, e in ipairs(entries) do
    if sync_track_indexes[e.track_index] then
        assert(not sync_channels[e.source_channel], string.format(
            "two sync tracks read the same file channel %d — channels must be distinct",
            e.source_channel))
        sync_channels[e.source_channel] = true
    end
end
local n_sync = 0
for _ in pairs(sync_channels) do n_sync = n_sync + 1 end
assert(n_sync == 5, string.format(
    "expected 5 distinct sync channels (0..4), got %d", n_sync))
for ch = 0, 4 do
    assert(sync_channels[ch], string.format(
        "sync channel %d not present — channels are not 0..4 distinct", ch))
end

print(string.format(
    "  ✓ synced master: %d audio entries (one per track); 5 sync tracks read "
    .. "distinct WAV channels 0..4", #entries))
print("✅ test_drp_synced_per_channel_resolve.lua passed")
