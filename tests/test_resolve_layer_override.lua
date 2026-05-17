-- T021 / CT-R4 (013): multicam layer override.
-- Master with V1/V2/V3 pointing at three different files and
-- default_video_layer_track_id=V1. A clip with master_layer_track_id=V2 must
-- resolve to V2's media file, not V1's.
-- Expected to FAIL until T030 lands.

require("test_env")
local database = require("core.database")

local DB_PATH = "/tmp/jve/test_resolve_layer_override.db"
os.remove(DB_PATH)
assert(database.init(DB_PATH), "schema.sql failed to execute")

local db = database.get_connection()
assert(db:exec(
    "INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at) "
    .. "VALUES ('p1', 'p', 'resample', 0, 0)"))
assert(db:exec(
    "INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, "
    .. "audio_sample_rate, width, height, created_at, modified_at) "
    .. "VALUES ('m', 'p1', 'm', 'master', 24, 1, 48000, 1920, 1080, 0, 0)"))
assert(db:exec(
    "INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, "
    .. "audio_sample_rate, width, height, created_at, modified_at) "
    .. "VALUES ('e', 'p1', 'e', 'sequence', 24, 1, 48000, 1920, 1080, 0, 0)"))

for _, name in ipairs({"V1", "V2", "V3"}) do
    local idx = tonumber(name:sub(2))
    assert(db:exec(string.format(
        "INSERT INTO tracks (id, sequence_id, name, track_type, track_index) "
        .. "VALUES ('m-%s', 'm', '%s', 'VIDEO', %d)", name, name, idx)))
    assert(db:exec(string.format(
        "INSERT INTO media (id, project_id, name, file_path, duration_frames, "
        .. "fps_numerator, fps_denominator, created_at, modified_at) "
        .. "VALUES ('med-%s', 'p1', 'angle %s', '/tmp/angle-%s.mov', 100, 24, 1, 0, 0)",
        name, name, name)))
    assert(db:exec(string.format(
        "INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id, media_id, "
        .. "source_in_frame, source_out_frame, sequence_start_frame, duration_frames, "
        .. "enabled, volume, playhead_frame, created_at, modified_at) "
        .. "VALUES ('mr-%s', 'p1', 'm', 'm-%s', 'med-%s', 0, 100, 0, 100, 1, 1.0, 0, 0, 0)",
        name, name, name)))
end
-- Master's default layer = V1.
assert(db:exec(
    "UPDATE sequences SET default_video_layer_track_id = 'm-V1' WHERE id = 'm'"))

assert(db:exec(
    "INSERT INTO tracks (id, sequence_id, name, track_type, track_index) "
    .. "VALUES ('e-v1', 'e', 'V1', 'VIDEO', 1)"))

-- Clip A: no override, should pick default (V1 → angle-V1.mov).
assert(db:exec(
    "INSERT INTO clips (id, project_id, owner_sequence_id, track_id, sequence_id, "
    .. "name, sequence_start_frame, duration_frames, source_in_frame, source_out_frame, "
    .. "master_layer_track_id, fps_mismatch_policy, enabled, volume, playhead_frame, "
    .. "created_at, modified_at) "
    .. "VALUES ('c-A', 'p1', 'e', 'e-v1', 'm', 'A', 0, 100, 0, 100, NULL, 'passthrough', 1, 1.0, 0, 0, 0)"))
-- Clip B: override to V2.
assert(db:exec(
    "INSERT INTO clips (id, project_id, owner_sequence_id, track_id, sequence_id, "
    .. "name, sequence_start_frame, duration_frames, source_in_frame, source_out_frame, "
    .. "master_layer_track_id, fps_mismatch_policy, enabled, volume, playhead_frame, "
    .. "created_at, modified_at) "
    .. "VALUES ('c-B', 'p1', 'e', 'e-v1', 'm', 'B', 200, 100, 0, 100, 'm-V2', 'passthrough', 1, 1.0, 0, 0, 0)"))

require("test_env").touch_media_fixtures()
local Sequence = require("models.sequence")
local entries = Sequence:resolve_in_range("e", 0, 400, {
    recursing_into = {},
    depth = 0,
    export_mode = false,
    project_fps_mismatch_policy = "passthrough",
})

-- Expect one video entry per clip.
assert(#entries == 2, "expected 2 entries (A and B); got " .. tostring(#entries))
local by_name = {}
for _, e in ipairs(entries) do
    -- provenance[1] = the outer clip id
    by_name[e.provenance[1]] = e
end
assert(by_name["c-A"].media_path == "/tmp/angle-V1.mov",
    "clip A (default) should resolve to V1 angle; got " .. tostring(by_name["c-A"].media_path))
assert(by_name["c-B"].media_path == "/tmp/angle-V2.mov",
    "clip B (overridden) should resolve to V2 angle; got " .. tostring(by_name["c-B"].media_path))

print("✅ test_resolve_layer_override.lua passed")
