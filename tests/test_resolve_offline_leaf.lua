-- 013 / CT-R9 (revised 2026-04-27): offline-leaf resolver shape.
--
-- Domain rule: a clip whose media is offline MUST surface from the
-- resolver to playback queries with `media_path = file_path` and
-- `enabled` preserved as the user set it. Offline routing is a
-- consumer concern (playback_engine queries media_status to flip
-- ClipInfo.offline=true → C++ TMB beep; renderer keys offline_frame_cache
-- on media_path). Blanking media_path here previously filtered offline
-- clips out of get_audio_in_range / get_video_in_range entirely, which
-- silenced the beep and blacked out the offline overlay during playback
-- (todo_offline_overlay_during_playback.md, surfaced 2026-04-26).
--
-- Test asserts the resolver pass-through contract; downstream beep and
-- offline-frame behaviors are pinned in their own tests
-- (test_resolver_keeps_offline_clips, test_tmb_audio_unbeeps_on_reconnect).

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

local OFFLINE_PATH = "/tmp/jve/__resolver_offline_leaf_" .. os.time() .. ".mov"
os.remove(OFFLINE_PATH)
assert(io.open(OFFLINE_PATH, "r") == nil,
    "test setup: OFFLINE_PATH must not exist on disk")

assert(db:exec(string.format(
    "INSERT INTO media (id, project_id, name, file_path, duration_frames, "
    .. "fps_numerator, fps_denominator, created_at, modified_at) "
    .. "VALUES ('med-gone', 'p1', 'gone', %q, 100, 24, 1, 0, 0)",
    OFFLINE_PATH)))
assert(db:exec(
    "INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id, media_id, "
    .. "source_in_frame, source_out_frame, sequence_start_frame, duration_frames, "
    .. "enabled, volume, playhead_frame, created_at, modified_at) "
    .. "VALUES ('mr-gone', 'p1', 'm', 'm-v1', 'med-gone', 0, 100, 0, 100, 1, 1.0, 0, 0, 0)"))
assert(db:exec(
    "INSERT INTO clips (id, project_id, owner_sequence_id, track_id, sequence_id, "
    .. "name, sequence_start_frame, duration_frames, source_in_frame, source_out_frame, "
    .. "fps_mismatch_policy, enabled, volume, playhead_frame, created_at, modified_at) "
    .. "VALUES ('c', 'p1', 'e', 'e-v1', 'm', 'c', 0, 100, 0, 100, 'passthrough', 1, 1.0, 0, 0, 0)"))

-- Deliberately NOT touching fixtures — the file is offline.
local Sequence = require("models.sequence")
local entries = Sequence:resolve_in_range("e", 0, 200, {
    recursing_into = {},
    depth = 0,
    export_mode = false,
    project_fps_mismatch_policy = "passthrough",
})

assert(#entries == 1, string.format(
    "offline leaf must still produce one resolver entry (got %d)", #entries))
local e = entries[1]
assert(e.media_path == OFFLINE_PATH, string.format(
    "media_path must pass through unchanged for offline leaves; "
    .. "got %s (expected %s) — blanking media_path filters offline clips "
    .. "out of get_{audio,video}_in_range and silences the beep",
    tostring(e.media_path), OFFLINE_PATH))
assert(e.enabled == true or e.enabled == 1, string.format(
    "enabled must reflect the user-set value (true) for offline clips, "
    .. "not be forced false; got %s — forcing false silences playback's "
    .. "beep placeholder", tostring(e.enabled)))
assert(#e.provenance >= 2,
    "provenance must still identify the chain (outer clip + leaf media_ref)")

print("✅ test_resolve_offline_leaf.lua passed")
