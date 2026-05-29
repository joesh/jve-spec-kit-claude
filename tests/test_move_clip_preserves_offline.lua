#!/usr/bin/env luajit
-- Regression / reproduction: moving an OFFLINE clip to another track must
-- NOT make its offline status disappear. A clip is offline when its media
-- carries an offline_note (the file is missing / short). Moving the clip
-- (cross-track, same track_type) changes only its track and position — the
-- media linkage is unchanged, so the clip must stay offline.
--
-- Black-box: drives the real MoveClipToTrack command, then reloads clips
-- from the DB (database.load_clips — the authoritative offline derivation)
-- and checks the moved clip's offline flag. Reported symptom: offline stays
-- gone after a cross-track (vertical) move.

require("test_env")

local database = require("core.database")
local command_manager = require("core.command_manager")

print("=== test_move_clip_preserves_offline.lua ===")

local DB_PATH = "/tmp/jve/test_move_clip_preserves_offline.db"
os.remove(DB_PATH)
assert(database.init(DB_PATH))
local db = database.get_connection()
db:exec(require("import_schema"))
db:exec("DROP TRIGGER IF EXISTS trg_prevent_video_overlap_insert;")
db:exec("DROP TRIGGER IF EXISTS trg_prevent_video_overlap_update;")

-- Edit sequence with V1+V2; master with a VIDEO media_ref to media that
-- carries a NON-NULL offline_note (→ the clip is offline).
db:exec([[
    INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
    VALUES ('p', 'p', 'passthrough', '{"master_clock_hz":192000,"default_fps":{"num":24,"den":1}}', 0, 0);
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator,
        audio_sample_rate, width, height, created_at, modified_at)
    VALUES ('e', 'p', 'edit', 'sequence', 24, 1, 48000, 1920, 1080, 0, 0),
           ('m', 'p', 'm', 'master', 24, 1, NULL, 1920, 1080, 0, 0);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index)
    VALUES ('e-v1', 'e', 'V1', 'VIDEO', 1),
           ('e-v2', 'e', 'V2', 'VIDEO', 2),
           ('m-v1', 'm', 'V1', 'VIDEO', 1);
    UPDATE sequences SET default_video_layer_track_id = 'm-v1' WHERE id = 'm';
    INSERT INTO media (id, project_id, name, file_path, duration_frames,
        fps_numerator, fps_denominator, audio_channels, offline_note, created_at, modified_at)
    VALUES ('med', 'p', 'gone.mov', '/tmp/gone.mov', 2000, 24, 1, 0,
        '{"reason":"FileNotFound"}', 0, 0);
    INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id, media_id,
        source_in_frame, source_out_frame, sequence_start_frame, duration_frames,
        audio_sample_rate, enabled, volume, playhead_frame, created_at, modified_at)
    VALUES ('mr', 'p', 'm', 'm-v1', 'med', 0, 2000, 0, 2000, 48000, 1, 1.0, 0, 0, 0);
    INSERT INTO clips (id, project_id, owner_sequence_id, track_id, sequence_id, name,
        sequence_start_frame, duration_frames, source_in_frame, source_out_frame,
        source_in_subframe, source_out_subframe, fps_mismatch_policy, enabled, volume,
        playhead_frame, created_at, modified_at)
    VALUES ('clip1', 'p', 'e', 'e-v1', 'm', 'clip1', 100, 200, 0, 200,
        NULL, NULL, 'passthrough', 1, 1.0, 0, 0, 0);
]])

local function offline_of(clip_id)
    local clips = database.load_clips("e")
    for _, c in ipairs(clips) do
        if c.id == clip_id then return c.offline, c.media_path, c.track_id end
    end
    error("clip not found on reload: " .. clip_id)
end

-- Precondition: the clip reads as offline (media has an offline_note).
local pre_offline, pre_path = offline_of("clip1")
assert(pre_offline == true, string.format(
    "precondition: clip on V1 must be offline (got offline=%s path=%s)",
    tostring(pre_offline), tostring(pre_path)))
print("  ✓ precondition: clip is offline on V1")

-- Cross-track (vertical) move V1 → V2 (same track_type).
command_manager.init("e", "p")
command_manager.begin_command_event("script")
local r1, r2 = command_manager.execute("MoveClipToTrack", {
    project_id      = "p",
    sequence_id     = "e",
    clip_id         = "clip1",
    target_track_id = "e-v2",
})
command_manager.end_command_event()
local res = r1 or r2
assert(res and res.success, "MoveClipToTrack should succeed: "
    .. tostring(res and res.error_message))

-- The moved clip must STILL be offline.
local post_offline, post_path, post_track = offline_of("clip1")
assert(post_track == "e-v2", "clip should be on V2 after move, got " .. tostring(post_track))
assert(post_offline == true, string.format(
    "BUG: moving the clip cross-track cleared its offline status "
    .. "(offline=%s, media_path=%s after move)",
    tostring(post_offline), tostring(post_path)))
print("  ✓ clip remains offline after cross-track move")

print("\n✅ test_move_clip_preserves_offline.lua passed")
