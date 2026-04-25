-- 013 / Block A0: media_ref at non-zero file source position.
--
-- Domain behavior: a master imports a sub-range of a longer media file.
-- The media file is 200 frames; the master's media_ref points at file
-- frames [50, 150) (e.g. user trimmed the master's window to a sub-clip
-- of the source). The clip on the edit timeline picks the full master
-- window [0, 100).
--
-- Resolved entry's source range must be in FILE-NATIVE units. The portion
-- of the file the entry plays back is [50, 150) — NOT [0, 100), which
-- would only be correct if mr.source_in == 0.
--
-- Catches the unit-confusion bug where clamp_entries_to_clip_window
-- compares file-native units against master-timebase units.

require("test_env")
local database = require("core.database")

local DB_PATH = "/tmp/jve/test_resolve_master_subrange_source.db"
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
-- Media file is 200 frames long.
assert(db:exec(
    "INSERT INTO media (id, project_id, name, file_path, duration_frames, "
    .. "fps_numerator, fps_denominator, created_at, modified_at) "
    .. "VALUES ('med', 'p1', 'x', '/tmp/long.mov', 200, 24, 1, 0, 0)"))
-- Master's media_ref points at file frames [50, 150); placed at master-frame 0.
assert(db:exec(
    "INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id, media_id, "
    .. "source_in_frame, source_out_frame, timeline_start_frame, duration_frames, "
    .. "enabled, volume, playhead_frame, created_at, modified_at) "
    .. "VALUES ('mr', 'p1', 'm', 'm-v1', 'med', 50, 150, 0, 100, 1, 1.0, 0, 0, 0)"))
-- Clip on edit picks the full master window [0, 100), at edit-frame 0.
assert(db:exec(
    "INSERT INTO clips (id, project_id, owner_sequence_id, track_id, nested_sequence_id, "
    .. "name, timeline_start_frame, duration_frames, source_in_frame, source_out_frame, "
    .. "fps_mismatch_policy, enabled, volume, playhead_frame, created_at, modified_at) "
    .. "VALUES ('c', 'p1', 'e', 'e-v1', 'm', 'c', 0, 100, 0, 100, 'passthrough', 1, 1.0, 0, 0, 0)"))

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
assert(e.source_in == 50 and e.source_out == 150, string.format(
    "source range must be in file-native units (the portion of the file the "
    .. "entry plays back); expected [50, 150), got [%s, %s)",
    tostring(e.source_in), tostring(e.source_out)))
assert(e.timeline_start == 0 and e.duration == 100,
    "outer timeline range matches the clip's full window")

print("✅ test_resolve_master_subrange_source.lua passed")
