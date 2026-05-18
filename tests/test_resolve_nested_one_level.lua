-- T019 / CT-R2 (013): nested resolution — one level.
-- A nested sequence contains a clip pointing at a master. Resolving through
-- the clip returns entries whose media_path comes from the master's media_ref,
-- provenance length is 2 (clip id + media_ref id), and sequence_start is
-- translated through the clip's window.
-- Expected to FAIL until T030 (resolve_in_range) lands.

require("test_env")
local database = require("core.database")

local DB_PATH = "/tmp/jve/test_resolve_nested_one_level.db"
os.remove(DB_PATH)
assert(database.init(DB_PATH), "schema.sql failed to execute")

local db = database.get_connection()
assert(db:exec(
    "INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at) "
    .. "VALUES ('p1', 'p', 'resample', 0, 0)"))
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
assert(db:exec(
    "INSERT INTO tracks (id, sequence_id, name, track_type, track_index) "
    .. "VALUES ('e-v1', 'e', 'V1', 'VIDEO', 1)"))
assert(db:exec(
    "INSERT INTO media (id, project_id, name, file_path, duration_frames, "
    .. "fps_numerator, fps_denominator, created_at, modified_at) "
    .. "VALUES ('med', 'p1', 'x', '/tmp/vid.mov', 100, 24, 1, 0, 0)"))
assert(db:exec(
    "INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id, media_id, "
    .. "source_in_frame, source_out_frame, sequence_start_frame, duration_frames, "
    .. "enabled, volume, playhead_frame, created_at, modified_at) "
    .. "VALUES ('mr', 'p1', 'm', 'm-v1', 'med', 0, 100, 0, 100, 1, 1.0, 0, 0, 0)"))
-- Clip on edit seq: window [10, 90) of master, placed at sequence_start=50 on the edit.
assert(db:exec(
    "INSERT INTO clips (id, project_id, owner_sequence_id, track_id, sequence_id, "
    .. "name, sequence_start_frame, duration_frames, source_in_frame, source_out_frame, "
    .. "fps_mismatch_policy, enabled, volume, playhead_frame, created_at, modified_at) "
    .. "VALUES ('c', 'p1', 'e', 'e-v1', 'm', 'c', 50, 80, 10, 90, 'passthrough', 1, 1.0, 0, 0, 0)"))

require("test_env").touch_media_fixtures()
local Sequence = require("models.sequence")
local entries = Sequence:resolve_in_range("e", 0, 200, {
    recursing_into = {},
    depth = 0,
    export_mode = false,
    project_fps_mismatch_policy = "passthrough",
})

assert(#entries == 1, "expected 1 entry, got " .. tostring(#entries))
local e = entries[1]
assert(e.media_path == "/tmp/vid.mov",
    "media_path must come from the master's media_ref; got " .. tostring(e.media_path))
assert(e.source_in == 10 and e.source_out == 90,
    string.format("source range should equal the clip's window in media units; got [%d, %d]",
        e.source_in or -1, e.source_out or -1))
assert(e.sequence_start == 50,
    "sequence_start must be translated to outermost (edit) timebase; got " .. tostring(e.sequence_start))
assert(#e.provenance == 2,
    "provenance length must be 2 (clip + media_ref); got " .. tostring(#e.provenance))
assert(e.provenance[1] == "c" and e.provenance[2] == "mr",
    "provenance order: outermost-clip first → leaf-media_ref last")

print("✅ test_resolve_nested_one_level.lua passed")
