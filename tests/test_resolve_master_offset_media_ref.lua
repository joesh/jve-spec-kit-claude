-- 013 / Block A0: master with media_ref at non-zero master-coord position.
--
-- Domain behavior under test:
--   When a master places its single video media_ref at master-frame 30
--   (not 0), and a clip on an edit timeline references the master with
--   timeline_start=200, the resolved entry's outer timeline_start must
--   reflect the master-coord offset:
--     outer timeline_start = clip.timeline_start + (mr.timeline_start - clip.source_in)
--                          = 200 + (30 - 0) = 230
--   Duration tracks the media_ref's own duration (70), not the clip's
--   duration (100), because the entry covers only [30, 100) of the master.
--
-- Catches the resolver bug that overrides translated timeline_start with
-- the OUTER clip's timeline_start, losing master-coord position info.

require("test_env")
local database = require("core.database")

local DB_PATH = "/tmp/jve/test_resolve_master_offset_media_ref.db"
os.remove(DB_PATH)
assert(database.init(DB_PATH), "schema.sql failed to execute")

local db = database.get_connection()
assert(db:exec(
    "INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at) "
    .. "VALUES ('p1', 'p', 'passthrough', 0, 0)"))
assert(db:exec(
    "INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, "
    .. "audio_rate, width, height, created_at, modified_at) "
    .. "VALUES ('m', 'p1', 'm', 'master', 24, 1, 48000, 1920, 1080, 0, 0)"))
assert(db:exec(
    "INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, "
    .. "audio_rate, width, height, created_at, modified_at) "
    .. "VALUES ('e', 'p1', 'e', 'nested', 24, 1, 48000, 1920, 1080, 0, 0)"))
assert(db:exec(
    "INSERT INTO tracks (id, sequence_id, name, track_type, track_index) "
    .. "VALUES ('m-v1', 'm', 'V1', 'VIDEO', 1)"))
assert(db:exec(
    "INSERT INTO tracks (id, sequence_id, name, track_type, track_index) "
    .. "VALUES ('e-v1', 'e', 'V1', 'VIDEO', 1)"))
assert(db:exec(
    "INSERT INTO media (id, project_id, name, file_path, duration_frames, "
    .. "fps_numerator, fps_denominator, created_at, modified_at) "
    .. "VALUES ('med', 'p1', 'x', '/tmp/v.mov', 70, 24, 1, 0, 0)"))
-- Media_ref placed at master-frame 30, covering [30, 100) of master timebase.
-- Source range in file: [0, 70).
assert(db:exec(
    "INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id, media_id, "
    .. "source_in_frame, source_out_frame, timeline_start_frame, duration_frames, "
    .. "enabled, volume, playhead_frame, created_at, modified_at) "
    .. "VALUES ('mr', 'p1', 'm', 'm-v1', 'med', 0, 70, 30, 70, 1, 1.0, 0, 0, 0)"))
-- Clip on edit: full master window [0, 100), placed at edit-frame 200.
assert(db:exec(
    "INSERT INTO clips (id, project_id, owner_sequence_id, track_id, nested_sequence_id, "
    .. "name, timeline_start_frame, duration_frames, source_in_frame, source_out_frame, "
    .. "fps_mismatch_policy, enabled, volume, playhead_frame, created_at, modified_at) "
    .. "VALUES ('c', 'p1', 'e', 'e-v1', 'm', 'c', 200, 100, 0, 100, 'passthrough', 1, 1.0, 0, 0, 0)"))

require("test_env").touch_media_fixtures()
local Sequence = require("models.sequence")
local entries = Sequence:resolve_in_range("e", 0, 1000, {
    recursing_into = {},
    depth = 0,
    export_mode = false,
    project_fps_mismatch_policy = "passthrough",
})

assert(#entries == 1, "expected 1 entry, got " .. tostring(#entries))
local e = entries[1]
assert(e.timeline_start == 230, string.format(
    "outer timeline_start must reflect mr.timeline_start translated through clip; "
    .. "expected 230, got %s", tostring(e.timeline_start)))
assert(e.duration == 70, string.format(
    "duration must equal mr.duration_frames (the media_ref covers only 70 of "
    .. "the 100-frame clip window); expected 70, got %s",
    tostring(e.duration)))
assert(e.source_in == 0 and e.source_out == 70,
    "source range must be the file-native portion the entry actually plays")

print("✅ test_resolve_master_offset_media_ref.lua passed")
