-- T029 (013): resolver G-R5 — dangling master_layer_track_id asserts.
-- FK ON DELETE SET NULL normally NULLs this column when its target track is
-- deleted through the ordinary command path. If the resolver arrives with a
-- live-but-dangling id, that's DB corruption or an external mutation; a
-- fallback would paper over the bug (rule 2.13 / rule 1.14). Assert loudly.
-- Expected to FAIL until T030 lands.

require("test_env")
local database = require("core.database")

local DB_PATH = "/tmp/jve/test_resolve_dangling_layer.db"
os.remove(DB_PATH)
assert(database.init(DB_PATH), "schema.sql failed to execute")

local db = database.get_connection()
assert(db:exec("PRAGMA foreign_keys = OFF"))  -- disable FK to permit dangling id
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
assert(db:exec(
    "INSERT INTO tracks (id, sequence_id, name, track_type, track_index) "
    .. "VALUES ('e-v1', 'e', 'V1', 'VIDEO', 1)"))
assert(db:exec(
    "UPDATE sequences SET default_video_layer_track_id = 'm-v1' WHERE id = 'm'"))
assert(db:exec(
    "INSERT INTO media (id, project_id, name, file_path, duration_frames, "
    .. "fps_numerator, fps_denominator, created_at, modified_at) "
    .. "VALUES ('med', 'p1', 'x', '/tmp/vid.mov', 100, 24, 1, 0, 0)"))
assert(db:exec(
    "INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id, media_id, "
    .. "source_in_frame, source_out_frame, sequence_start_frame, duration_frames, "
    .. "enabled, volume, playhead_frame, created_at, modified_at) "
    .. "VALUES ('mr', 'p1', 'm', 'm-v1', 'med', 0, 100, 0, 100, 1, 1.0, 0, 0, 0)"))
-- Clip points at a track id 'm-v-ghost' that doesn't exist (FK is off — simulate corruption).
assert(db:exec(
    "INSERT INTO clips (id, project_id, owner_sequence_id, track_id, sequence_id, "
    .. "name, sequence_start_frame, duration_frames, source_in_frame, source_out_frame, "
    .. "master_layer_track_id, fps_mismatch_policy, enabled, volume, playhead_frame, "
    .. "created_at, modified_at) "
    .. "VALUES ('c', 'p1', 'e', 'e-v1', 'm', 'c', 0, 100, 0, 100, 'm-v-ghost', "
    .. "'passthrough', 1, 1.0, 0, 0, 0)"))
-- Re-enable FK for subsequent ops (the corruption is already in place).
assert(db:exec("PRAGMA foreign_keys = ON"))

require("test_env").touch_media_fixtures()
local Sequence = require("models.sequence")
local ok, err = pcall(function()
    Sequence:resolve_in_range("e", 0, 200, {
        recursing_into = {},
        depth = 0,
        export_mode = false,
        project_fps_mismatch_policy = "passthrough",
    })
end)
assert(not ok, "resolver must assert loudly on dangling master_layer_track_id")
local msg = tostring(err)
assert(msg:find("c"), "error must name the clip id; got: " .. msg)
assert(msg:find("m%-v%-ghost"), "error must name the dangling track id; got: " .. msg)

print("✅ test_resolve_dangling_layer_assert.lua passed")
