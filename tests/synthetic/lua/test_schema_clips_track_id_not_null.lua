-- 013 / Block A: clips.track_id is NOT NULL.
--
-- data-model.md §`clips` says track_id is NOT NULL. The schema's first
-- V13 landing accidentally relaxed it to nullable. This test catches
-- the relaxation: an INSERT with track_id=NULL must be rejected by the
-- DB (NOT NULL constraint), and a normal INSERT with a real track_id
-- must succeed (regression guard so the constraint isn't silently
-- moved back to nullable).

require("test_env")
local database = require("core.database")

local DB_PATH = "/tmp/jve/test_schema_clips_track_id_not_null.db"
os.remove(DB_PATH)
assert(database.init(DB_PATH), "schema.sql failed to execute")

local db = database.get_connection()

assert(db:exec(
    "INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at) "
    .. "VALUES ('p1', 'p', 'resample', '{\"master_clock_hz\":192000,\"default_fps\":{\"num\":24,\"den\":1}}', 0, 0)"))
assert(db:exec(
    "INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, "
    .. "audio_sample_rate, width, height, created_at, modified_at) "
    .. "VALUES ('e', 'p1', 'e', 'sequence', 24, 1, 48000, 1920, 1080, 0, 0)"))
assert(db:exec(
    "INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, "
    .. "audio_sample_rate, width, height, created_at, modified_at) "
    .. "VALUES ('m', 'p1', 'm', 'master', 24, 1, NULL, 1920, 1080, 0, 0)"))
assert(db:exec(
    "INSERT INTO tracks (id, sequence_id, name, track_type, track_index) "
    .. "VALUES ('e-v1', 'e', 'V1', 'VIDEO', 1)"))

-- (1) NULL track_id is rejected.
local stmt = db:prepare([[
    INSERT INTO clips (id, project_id, owner_sequence_id, track_id,
        sequence_id, name, sequence_start_frame, duration_frames,
        source_in_frame, source_out_frame, fps_mismatch_policy,
        enabled, volume, playhead_frame, created_at, modified_at)
    VALUES (?, 'p1', 'e', NULL, 'm', 'c', 0, 10, 0, 10, 'passthrough',
        1, 1.0, 0, 0, 0)
]])
assert(stmt, "prepare failed")
stmt:bind_value(1, "c-null")
local null_ok = stmt:exec()
local null_err = (not null_ok) and stmt:last_error() or nil
stmt:finalize()
assert(not null_ok, "Expected NOT NULL violation for clips.track_id=NULL; "
    .. "INSERT unexpectedly succeeded")
assert(null_err and null_err:lower():find("not null"),
    "Expected NOT NULL error message; got: " .. tostring(null_err))

-- (2) Real track_id succeeds (regression guard).
local stmt2 = db:prepare([[
    INSERT INTO clips (id, project_id, owner_sequence_id, track_id,
        sequence_id, name, sequence_start_frame, duration_frames,
        source_in_frame, source_out_frame, fps_mismatch_policy,
        enabled, volume, playhead_frame, created_at, modified_at)
    VALUES ('c-real', 'p1', 'e', 'e-v1', 'm', 'c', 0, 10, 0, 10,
        'passthrough', 1, 1.0, 0, 0, 0)
]])
assert(stmt2, "prepare 2 failed")
local ok = stmt2:exec()
local err = (not ok) and stmt2:last_error() or nil
stmt2:finalize()
assert(ok, "INSERT with real track_id failed: " .. tostring(err))

print("✅ test_schema_clips_track_id_not_null.lua passed")
