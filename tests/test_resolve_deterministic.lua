-- T028 / CT-R11 (013): deterministic ordering.
-- Given the same DB state, repeated calls to resolve_in_range return the
-- entries in the same order. A sequence with multiple clips overlapping the
-- same range exercises the ordering path.
-- Expected to FAIL until T030 lands.

require("test_env")
local database = require("core.database")

local DB_PATH = "/tmp/jve/test_resolve_deterministic.db"
os.remove(DB_PATH)
assert(database.init(DB_PATH), "schema.sql failed to execute")

local db = database.get_connection()
assert(db:exec(
    "INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at) "
    .. "VALUES ('p1', 'p', 'resample', '{\"master_clock_hz\":192000,\"default_fps\":{\"num\":24,\"den\":1}}', 0, 0)"))
assert(db:exec(
    "INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, "
    .. "audio_sample_rate, width, height, created_at, modified_at) "
    .. "VALUES ('m', 'p1', 'm', 'master', 24, 1, NULL, 1920, 1080, 0, 0)"))
assert(db:exec(
    "INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, "
    .. "audio_sample_rate, width, height, created_at, modified_at) "
    .. "VALUES ('e', 'p1', 'e', 'sequence', 24, 1, 48000, 1920, 1080, 0, 0)"))
assert(db:exec(
    "INSERT INTO tracks (id, sequence_id, name, track_type, track_index) "
    .. "VALUES ('m-v1', 'm', 'V1', 'VIDEO', 1)"))
-- Three audio tracks on the edit sequence; overlapping clips at the same frame.
for i = 1, 3 do
    assert(db:exec(string.format(
        "INSERT INTO tracks (id, sequence_id, name, track_type, track_index) "
        .. "VALUES ('e-a%d', 'e', 'A%d', 'AUDIO', %d)", i, i, i)))
end
assert(db:exec(
    "INSERT INTO media (id, project_id, name, file_path, duration_frames, "
    .. "fps_numerator, fps_denominator, created_at, modified_at) "
    .. "VALUES ('med', 'p1', 'x', '/tmp/a.wav', 48000, 48000, 1, 0, 0)"))
assert(db:exec(
    "INSERT INTO tracks (id, sequence_id, name, track_type, track_index) "
    .. "VALUES ('m-a1', 'm', 'A1', 'AUDIO', 1)"))
assert(db:exec(
    "INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id, media_id, "
    .. "source_in_frame, source_out_frame, sequence_start_frame, duration_frames, "
    .. "audio_sample_rate, enabled, volume, playhead_frame, created_at, modified_at) "
    .. "VALUES ('mr', 'p1', 'm', 'm-a1', 'med', 0, 48000, 0, 48000, 48000, 1, 1.0, 0, 0, 0)"))
-- Three clips all overlapping the same 0..48000 range on different tracks.
for i = 1, 3 do
    assert(db:exec(string.format(
        "INSERT INTO clips (id, project_id, owner_sequence_id, track_id, sequence_id, "
        .. "name, sequence_start_frame, duration_frames, source_in_frame, source_out_frame, source_in_subframe, source_out_subframe, "
        .. "fps_mismatch_policy, enabled, volume, playhead_frame, created_at, modified_at) "
        .. "VALUES ('c%d', 'p1', 'e', 'e-a%d', 'm', 'c%d', 0, 48000, 0, 48000, 0, 0, "
        .. "'passthrough', 1, 1.0, 0, 0, 0)", i, i, i)))
end

require("test_env").touch_media_fixtures()
local Sequence = require("models.sequence")
local function order(entries)
    local ids = {}
    for i, e in ipairs(entries) do ids[i] = e.provenance[1] end
    return table.concat(ids, "|")
end

local ctx = function()
    return { recursing_into = {}, depth = 0, export_mode = false,
             project_fps_mismatch_policy = "passthrough" }
end
local first = Sequence:resolve_in_range("e", 0, 48000, ctx())
local second = Sequence:resolve_in_range("e", 0, 48000, ctx())
local third = Sequence:resolve_in_range("e", 0, 48000, ctx())
local o1, o2, o3 = order(first), order(second), order(third)
assert(o1 == o2, "order should be stable across calls; got " .. o1 .. " vs " .. o2)
assert(o2 == o3, "order should be stable across calls; got " .. o2 .. " vs " .. o3)

print("✅ test_resolve_deterministic.lua passed")
