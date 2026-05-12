-- T020 / CT-R3 (013): deep nested resolution.
-- Three-level chain: outer nested sequence → middle nested → master. Resolver
-- returns entries with provenance length 3. Depth recursion is transparent.
-- Expected to FAIL until T030 lands.

require("test_env")
local database = require("core.database")

local DB_PATH = "/tmp/jve/test_resolve_nested_deep.db"
os.remove(DB_PATH)
assert(database.init(DB_PATH), "schema.sql failed to execute")

local db = database.get_connection()
assert(db:exec(
    "INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at) "
    .. "VALUES ('p1', 'p', 'resample', 0, 0)"))
for _, id in ipairs({"outer", "mid"}) do
    assert(db:exec(string.format(
        "INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, "
        .. "audio_sample_rate, width, height, created_at, modified_at) "
        .. "VALUES ('%s', 'p1', '%s', 'sequence', 24, 1, 48000, 1920, 1080, 0, 0)", id, id)))
    assert(db:exec(string.format(
        "INSERT INTO tracks (id, sequence_id, name, track_type, track_index) "
        .. "VALUES ('%s-v1', '%s', 'V1', 'VIDEO', 1)", id, id)))
end
assert(db:exec(
    "INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, "
    .. "audio_sample_rate, width, height, created_at, modified_at) "
    .. "VALUES ('m', 'p1', 'm', 'master', 24, 1, 48000, 1920, 1080, 0, 0)"))
assert(db:exec(
    "INSERT INTO tracks (id, sequence_id, name, track_type, track_index) "
    .. "VALUES ('m-v1', 'm', 'V1', 'VIDEO', 1)"))
assert(db:exec(
    "INSERT INTO media (id, project_id, name, file_path, duration_frames, "
    .. "fps_numerator, fps_denominator, created_at, modified_at) "
    .. "VALUES ('med', 'p1', 'x', '/tmp/v.mov', 100, 24, 1, 0, 0)"))
assert(db:exec(
    "INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id, media_id, "
    .. "source_in_frame, source_out_frame, timeline_start_frame, duration_frames, "
    .. "enabled, volume, playhead_frame, created_at, modified_at) "
    .. "VALUES ('mr', 'p1', 'm', 'm-v1', 'med', 0, 100, 0, 100, 1, 1.0, 0, 0, 0)"))
-- outer → mid → m
assert(db:exec(
    "INSERT INTO clips (id, project_id, owner_sequence_id, track_id, sequence_id, "
    .. "name, timeline_start_frame, duration_frames, source_in_frame, source_out_frame, "
    .. "fps_mismatch_policy, enabled, volume, playhead_frame, created_at, modified_at) "
    .. "VALUES ('c-mid-in-m', 'p1', 'mid', 'mid-v1', 'm', 'x', 0, 100, 0, 100, 'passthrough', 1, 1.0, 0, 0, 0)"))
assert(db:exec(
    "INSERT INTO clips (id, project_id, owner_sequence_id, track_id, sequence_id, "
    .. "name, timeline_start_frame, duration_frames, source_in_frame, source_out_frame, "
    .. "fps_mismatch_policy, enabled, volume, playhead_frame, created_at, modified_at) "
    .. "VALUES ('c-outer-in-mid', 'p1', 'outer', 'outer-v1', 'mid', 'x', 0, 100, 0, 100, 'passthrough', 1, 1.0, 0, 0, 0)"))

require("test_env").touch_media_fixtures()
local Sequence = require("models.sequence")
local entries = Sequence:resolve_in_range("outer", 0, 200, {
    recursing_into = {},
    depth = 0,
    export_mode = false,
    project_fps_mismatch_policy = "passthrough",
})
assert(#entries == 1, "expected 1 entry; got " .. tostring(#entries))
assert(#entries[1].provenance == 3,
    "provenance length must be 3 (outer clip + mid clip + leaf media_ref); got "
    .. tostring(#entries[1].provenance))
assert(entries[1].media_path == "/tmp/v.mov")

print("✅ test_resolve_nested_deep.lua passed")
