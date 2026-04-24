-- T026 / CT-R9 (013): offline leaf yields synthetic broken entry.
-- When a clip's chain terminates at a media row whose file can't be reached,
-- the resolver emits a ResolvedEntry with media_path=nil, enabled=false, and
-- a provenance chain identifying where the chain broke. Renderer surfaces it
-- via FR-022 loud-fail; caller never sees a silent blank.
-- Expected to FAIL until T030 lands.

require("test_env")
local database = require("core.database")

local DB_PATH = "/tmp/jve/test_resolve_offline_leaf.db"
os.remove(DB_PATH)
assert(database.init(DB_PATH), "schema.sql failed to execute")

local db = database.get_connection()
assert(db:exec(
    "INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at) "
    .. "VALUES ('p1', 'p', 'resample', 0, 0)"))
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
-- Note: a path that does NOT exist on disk. "Offline" is a derived state per
-- the new renderer contract (no clip.offline column); the resolver infers it
-- from the media row's reachability.
assert(db:exec(
    "INSERT INTO media (id, project_id, name, file_path, duration_frames, "
    .. "fps_numerator, fps_denominator, created_at, modified_at) "
    .. "VALUES ('med-gone', 'p1', 'gone', '/tmp/does_not_exist_abs_path_xyz.mov', 100, 24, 1, 0, 0)"))
assert(db:exec(
    "INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id, media_id, "
    .. "source_in_frame, source_out_frame, timeline_start_frame, duration_frames, "
    .. "enabled, volume, playhead_frame, created_at, modified_at) "
    .. "VALUES ('mr-gone', 'p1', 'm', 'm-v1', 'med-gone', 0, 100, 0, 100, 1, 1.0, 0, 0, 0)"))
assert(db:exec(
    "INSERT INTO clips (id, project_id, owner_sequence_id, track_id, nested_sequence_id, "
    .. "name, timeline_start_frame, duration_frames, source_in_frame, source_out_frame, "
    .. "fps_mismatch_policy, enabled, volume, playhead_frame, created_at, modified_at) "
    .. "VALUES ('c', 'p1', 'e', 'e-v1', 'm', 'c', 0, 100, 0, 100, 'passthrough', 1, 1.0, 0, 0, 0)"))

local Sequence = require("models.sequence")
local entries = Sequence:resolve_in_range("e", 0, 200, {
    recursing_into = {},
    depth = 0,
    export_mode = false,
    project_fps_mismatch_policy = "passthrough",
})

assert(#entries == 1, "expected 1 synthetic entry for the offline chain")
local e = entries[1]
assert(e.media_path == nil,
    "media_path must be nil for an offline leaf; got " .. tostring(e.media_path))
assert(e.enabled == false,
    "enabled must be false when the chain is broken")
assert(#e.provenance >= 2,
    "provenance must still identify the chain (outer clip + leaf media_ref)")

print("✅ test_resolve_offline_leaf.lua passed")
