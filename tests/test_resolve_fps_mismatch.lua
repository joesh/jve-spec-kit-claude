-- T025 / CT-R8 (013): fps-mismatch both paths.
-- 25fps master nested inside a 24fps non-master sequence via a clip. The clip's
-- fps_mismatch_policy (frozen at Insert time) controls how the resolver
-- translates positions into the outer sequence's timebase:
--   - 'resample': positions scaled by 24/25. duration 100 master frames → 96
--     outer frames. Consumer retimes at decode.
--   - 'passthrough': inner frames treated as outer frames. duration stays 100
--     outer frames; plays faster/slower by 25/24 ratio at decode.
-- Both paths must be driven by the clip's own fps_mismatch_policy column
-- (Insert/Overwrite/SetFpsMismatchPolicy set it; the resolver reads it).
-- Expected to FAIL until T030 lands.

require("test_env")
local database = require("core.database")

local DB_PATH = "/tmp/jve/test_resolve_fps_mismatch.db"
os.remove(DB_PATH)
assert(database.init(DB_PATH), "schema.sql failed to execute")

local db = database.get_connection()
assert(db:exec(
    "INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at) "
    .. "VALUES ('p1', 'p', 'resample', 0, 0)"))
-- 25fps master.
assert(db:exec(
    "INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, "
    .. "audio_sample_rate, width, height, created_at, modified_at) "
    .. "VALUES ('m25', 'p1', 'm', 'master', 25, 1, NULL, 1920, 1080, 0, 0)"))
-- 24fps edit.
assert(db:exec(
    "INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, "
    .. "audio_sample_rate, width, height, created_at, modified_at) "
    .. "VALUES ('e24', 'p1', 'e', 'sequence', 24, 1, 48000, 1920, 1080, 0, 0)"))
assert(db:exec(
    "INSERT INTO tracks (id, sequence_id, name, track_type, track_index) "
    .. "VALUES ('m-v1', 'm25', 'V1', 'VIDEO', 1)"))
assert(db:exec(
    "INSERT INTO tracks (id, sequence_id, name, track_type, track_index) "
    .. "VALUES ('e-v1', 'e24', 'V1', 'VIDEO', 1)"))
assert(db:exec(
    "INSERT INTO media (id, project_id, name, file_path, duration_frames, "
    .. "fps_numerator, fps_denominator, created_at, modified_at) "
    .. "VALUES ('med', 'p1', 'x', '/tmp/25fps.mov', 100, 25, 1, 0, 0)"))
assert(db:exec(
    "INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id, media_id, "
    .. "source_in_frame, source_out_frame, sequence_start_frame, duration_frames, "
    .. "enabled, volume, playhead_frame, created_at, modified_at) "
    .. "VALUES ('mr', 'p1', 'm25', 'm-v1', 'med', 0, 100, 0, 100, 1, 1.0, 0, 0, 0)"))

-- Two clips, one per policy, both referencing the same 25fps master.
-- Clip A: resample.    Expected duration_frames (outer 24fps) = round(100 * 24/25) = 96.
-- Clip B: passthrough. Expected duration_frames (outer 24fps) = 100 (same int).
assert(db:exec(
    "INSERT INTO clips (id, project_id, owner_sequence_id, track_id, sequence_id, "
    .. "name, sequence_start_frame, duration_frames, source_in_frame, source_out_frame, "
    .. "fps_mismatch_policy, enabled, volume, playhead_frame, created_at, modified_at) "
    .. "VALUES ('c-resample', 'p1', 'e24', 'e-v1', 'm25', 'A', 0, 96, 0, 100, 'resample', 1, 1.0, 0, 0, 0)"))
assert(db:exec(
    "INSERT INTO clips (id, project_id, owner_sequence_id, track_id, sequence_id, "
    .. "name, sequence_start_frame, duration_frames, source_in_frame, source_out_frame, "
    .. "fps_mismatch_policy, enabled, volume, playhead_frame, created_at, modified_at) "
    .. "VALUES ('c-passthru', 'p1', 'e24', 'e-v1', 'm25', 'B', 200, 100, 0, 100, 'passthrough', 1, 1.0, 0, 0, 0)"))

require("test_env").touch_media_fixtures()
local Sequence = require("models.sequence")
local entries = Sequence:resolve_in_range("e24", 0, 400, {
    recursing_into = {},
    depth = 0,
    export_mode = false,
    project_fps_mismatch_policy = "passthrough",
})

assert(#entries == 2, "expected 2 entries; got " .. tostring(#entries))
local by_clip = {}
for _, e in ipairs(entries) do by_clip[e.provenance[1]] = e end

-- Clip A (resample): output duration in outer timebase = 96.
assert(by_clip["c-resample"], "missing entry for resample clip")
assert(by_clip["c-resample"].duration == 96,
    "resample entry duration must be 96 (outer 24fps frames); got "
    .. tostring(by_clip["c-resample"].duration))

-- Clip B (passthrough): duration in outer timebase = 100 (unchanged integer).
assert(by_clip["c-passthru"], "missing entry for passthrough clip")
assert(by_clip["c-passthru"].duration == 100,
    "passthrough entry duration must be 100 (same frame count); got "
    .. tostring(by_clip["c-passthru"].duration))

-- Both clips' source_in/out are in the master's (25fps) timebase, unchanged.
assert(by_clip["c-resample"].source_in == 0 and by_clip["c-resample"].source_out == 100,
    "resample source range stays in 25fps timebase [0, 100]")
assert(by_clip["c-passthru"].source_in == 0 and by_clip["c-passthru"].source_out == 100,
    "passthrough source range stays in 25fps timebase [0, 100]")

print("✅ test_resolve_fps_mismatch.lua passed")
