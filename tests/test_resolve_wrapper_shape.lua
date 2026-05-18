-- T029b (013): thin-wrapper retrofit (T031) pre-impl test.
-- get_video_in_range and get_audio_in_range preserve the existing flat-entry
-- shape that TMB consumers expect. They're thin filters over
-- resolve_in_range by media_kind; rule 2.18 FFI stability.
-- Expected to FAIL until T030 + T031 land.

require("test_env")
local database = require("core.database")

local DB_PATH = "/tmp/jve/test_resolve_wrapper_shape.db"
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
    .. "VALUES ('m-a1', 'm', 'A1', 'AUDIO', 1)"))
assert(db:exec(
    "INSERT INTO tracks (id, sequence_id, name, track_type, track_index) "
    .. "VALUES ('e-v1', 'e', 'V1', 'VIDEO', 1)"))
assert(db:exec(
    "INSERT INTO tracks (id, sequence_id, name, track_type, track_index) "
    .. "VALUES ('e-a1', 'e', 'A1', 'AUDIO', 1)"))
assert(db:exec(
    "INSERT INTO media (id, project_id, name, file_path, duration_frames, "
    .. "fps_numerator, fps_denominator, created_at, modified_at) "
    .. "VALUES ('med-v', 'p1', 'v', '/tmp/v.mov', 100, 24, 1, 0, 0)"))
assert(db:exec(
    "INSERT INTO media (id, project_id, name, file_path, duration_frames, "
    .. "fps_numerator, fps_denominator, created_at, modified_at) "
    .. "VALUES ('med-a', 'p1', 'a', '/tmp/a.wav', 48000, 48000, 1, 0, 0)"))
assert(db:exec(
    "INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id, media_id, "
    .. "source_in_frame, source_out_frame, sequence_start_frame, duration_frames, "
    .. "enabled, volume, playhead_frame, created_at, modified_at) "
    .. "VALUES ('mr-v', 'p1', 'm', 'm-v1', 'med-v', 0, 100, 0, 100, 1, 1.0, 0, 0, 0)"))
assert(db:exec(
    "INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id, media_id, "
    .. "source_in_frame, source_out_frame, sequence_start_frame, duration_frames, "
    .. "enabled, volume, playhead_frame, created_at, modified_at) "
    .. "VALUES ('mr-a', 'p1', 'm', 'm-a1', 'med-a', 0, 48000, 0, 48000, 1, 1.0, 0, 0, 0)"))
assert(db:exec(
    "INSERT INTO clips (id, project_id, owner_sequence_id, track_id, sequence_id, "
    .. "name, sequence_start_frame, duration_frames, source_in_frame, source_out_frame, "
    .. "fps_mismatch_policy, enabled, volume, playhead_frame, created_at, modified_at) "
    .. "VALUES ('cv', 'p1', 'e', 'e-v1', 'm', 'cv', 0, 100, 0, 100, 'passthrough', 1, 1.0, 0, 0, 0)"))
assert(db:exec(
    "INSERT INTO clips (id, project_id, owner_sequence_id, track_id, sequence_id, "
    .. "name, sequence_start_frame, duration_frames, source_in_frame, source_out_frame, "
    .. "fps_mismatch_policy, enabled, volume, playhead_frame, created_at, modified_at) "
    .. "VALUES ('ca', 'p1', 'e', 'e-a1', 'm', 'ca', 0, 48000, 0, 48000, 'passthrough', 1, 1.0, 0, 0, 0)"))

require("test_env").touch_media_fixtures()
local Sequence = require("models.sequence")

-- Wrappers are instance methods on a sequence — call on the sequence object,
-- pass [from, to) range only. The wrapper resolves self.id internally.
local seq_e = Sequence.load("e")
assert(seq_e, "test fixture: failed to load sequence 'e'")

local v_entries = seq_e:get_video_in_range(0, 200)
assert(type(v_entries) == "table", "get_video_in_range must return table")
assert(#v_entries == 1, "expected 1 video entry; got " .. tostring(#v_entries))
assert(v_entries[1].media_kind == "video" or v_entries[1].media_kind == nil,
    "video wrapper must return only video entries")
assert(v_entries[1].media_path == "/tmp/v.mov",
    "video entry should point at the video file")

local a_entries = seq_e:get_audio_in_range(0, 48000)
assert(type(a_entries) == "table", "get_audio_in_range must return table")
assert(#a_entries >= 1, "expected at least one audio entry; got " .. tostring(#a_entries))
for _, e in ipairs(a_entries) do
    assert(e.media_path == "/tmp/a.wav",
        "audio entries should come from the audio media (/tmp/a.wav); got " .. tostring(e.media_path))
end

print("✅ test_resolve_wrapper_shape.lua passed")
