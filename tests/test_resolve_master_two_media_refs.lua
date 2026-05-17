-- 013 / Block A0: master with two media_refs on the same V track.
--
-- Domain behavior: a master sequence's V track has two media_refs at
-- different timeline positions, e.g. an internally-edited master made
-- of two cuts: file A at master-frames [0, 50), file B at master-frames
-- [50, 100). A clip on the edit timeline picks the full master window
-- [0, 100) and is placed at edit-frame 1000.
--
-- The resolver must return TWO entries, with distinct outer sequence_starts
-- (1000 for A, 1050 for B) and distinct durations (50 each), each pointing
-- at its own file.
--
-- Catches the resolver bug where every entry under a clip is forced to
-- the clip's own sequence_start/duration, causing the two media_refs to
-- collapse into overlapping entries at the same outer position.

require("test_env")
local database = require("core.database")

local DB_PATH = "/tmp/jve/test_resolve_master_two_media_refs.db"
os.remove(DB_PATH)
assert(database.init(DB_PATH), "schema.sql failed to execute")

local db = database.get_connection()
assert(db:exec(
    "INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at) "
    .. "VALUES ('p1', 'p', 'passthrough', 0, 0)"))
assert(db:exec(
    "INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, "
    .. "audio_sample_rate, width, height, created_at, modified_at) "
    .. "VALUES ('m', 'p1', 'm', 'master', 24, 1, 48000, 1920, 1080, 0, 0)"))
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
-- Two media files.
assert(db:exec(
    "INSERT INTO media (id, project_id, name, file_path, duration_frames, "
    .. "fps_numerator, fps_denominator, created_at, modified_at) "
    .. "VALUES ('mA', 'p1', 'A', '/tmp/A.mov', 50, 24, 1, 0, 0)"))
assert(db:exec(
    "INSERT INTO media (id, project_id, name, file_path, duration_frames, "
    .. "fps_numerator, fps_denominator, created_at, modified_at) "
    .. "VALUES ('mB', 'p1', 'B', '/tmp/B.mov', 50, 24, 1, 0, 0)"))
-- Two media_refs on the master's V track, side by side.
assert(db:exec(
    "INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id, media_id, "
    .. "source_in_frame, source_out_frame, sequence_start_frame, duration_frames, "
    .. "enabled, volume, playhead_frame, created_at, modified_at) "
    .. "VALUES ('mrA', 'p1', 'm', 'm-v1', 'mA', 0, 50, 0, 50, 1, 1.0, 0, 0, 0)"))
assert(db:exec(
    "INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id, media_id, "
    .. "source_in_frame, source_out_frame, sequence_start_frame, duration_frames, "
    .. "enabled, volume, playhead_frame, created_at, modified_at) "
    .. "VALUES ('mrB', 'p1', 'm', 'm-v1', 'mB', 0, 50, 50, 50, 1, 1.0, 0, 0, 0)"))
-- Clip references the full master window, placed at edit-frame 1000.
assert(db:exec(
    "INSERT INTO clips (id, project_id, owner_sequence_id, track_id, sequence_id, "
    .. "name, sequence_start_frame, duration_frames, source_in_frame, source_out_frame, "
    .. "fps_mismatch_policy, enabled, volume, playhead_frame, created_at, modified_at) "
    .. "VALUES ('c', 'p1', 'e', 'e-v1', 'm', 'c', 1000, 100, 0, 100, 'passthrough', 1, 1.0, 0, 0, 0)"))

require("test_env").touch_media_fixtures()
local Sequence = require("models.sequence")
local entries = Sequence:resolve_in_range("e", 0, 2000, {
    recursing_into = {},
    depth = 0,
    export_mode = false,
    project_fps_mismatch_policy = "passthrough",
})

assert(#entries == 2, "expected 2 entries (one per media_ref); got " .. tostring(#entries))
table.sort(entries, function(a, b) return a.sequence_start < b.sequence_start end)
local A, B = entries[1], entries[2]
assert(A.media_path == "/tmp/A.mov" and B.media_path == "/tmp/B.mov",
    "first entry plays file A, second plays file B")
assert(A.sequence_start == 1000 and A.duration == 50, string.format(
    "entry A occupies [1000, 1050) on the edit timeline; got start=%s dur=%s",
    tostring(A.sequence_start), tostring(A.duration)))
assert(B.sequence_start == 1050 and B.duration == 50, string.format(
    "entry B occupies [1050, 1100) on the edit timeline; got start=%s dur=%s",
    tostring(B.sequence_start), tostring(B.duration)))

print("✅ test_resolve_master_two_media_refs.lua passed")
