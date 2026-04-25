-- 013 / Block A0: clip with sub-range source window.
--
-- Domain behavior: a master is 100 frames long, single full-coverage
-- media_ref. A clip on the edit timeline picks a SUB-RANGE of the master:
-- source_in=20, source_out=70 (50 frames of master content), placed at
-- edit-frame 500.
--
-- Resolved entry must:
--   - source_in/out are in file-native units of the played portion: [20, 70).
--   - outer timeline_start = 500 (clip's own start, since the entry covers
--     the entire clip window).
--   - duration = 50 (the clip occupies 50 outer frames).
--
-- Catches the bug that returns the FULL master content [0, 100) regardless
-- of the clip's window narrowing.

require("test_env")
local database = require("core.database")

local DB_PATH = "/tmp/jve/test_resolve_clip_subrange.db"
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
    .. "VALUES ('med', 'p1', 'x', '/tmp/v.mov', 100, 24, 1, 0, 0)"))
assert(db:exec(
    "INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id, media_id, "
    .. "source_in_frame, source_out_frame, timeline_start_frame, duration_frames, "
    .. "enabled, volume, playhead_frame, created_at, modified_at) "
    .. "VALUES ('mr', 'p1', 'm', 'm-v1', 'med', 0, 100, 0, 100, 1, 1.0, 0, 0, 0)"))
-- Clip picks master sub-range [20, 70).
assert(db:exec(
    "INSERT INTO clips (id, project_id, owner_sequence_id, track_id, nested_sequence_id, "
    .. "name, timeline_start_frame, duration_frames, source_in_frame, source_out_frame, "
    .. "fps_mismatch_policy, enabled, volume, playhead_frame, created_at, modified_at) "
    .. "VALUES ('c', 'p1', 'e', 'e-v1', 'm', 'c', 500, 50, 20, 70, 'passthrough', 1, 1.0, 0, 0, 0)"))

require("test_env").touch_media_fixtures()
local Sequence = require("models.sequence")
local entries = Sequence:resolve_in_range("e", 0, 2000, {
    recursing_into = {},
    depth = 0,
    export_mode = false,
    project_fps_mismatch_policy = "passthrough",
})

assert(#entries == 1, "expected 1 entry, got " .. tostring(#entries))
local e = entries[1]
assert(e.source_in == 20 and e.source_out == 70, string.format(
    "source range must be the file-native portion the clip exposes; "
    .. "expected [20, 70), got [%s, %s)",
    tostring(e.source_in), tostring(e.source_out)))
assert(e.timeline_start == 500 and e.duration == 50, string.format(
    "outer position is the clip's window: expected start=500 dur=50; "
    .. "got start=%s dur=%s",
    tostring(e.timeline_start), tostring(e.duration)))

print("✅ test_resolve_clip_subrange.lua passed")
