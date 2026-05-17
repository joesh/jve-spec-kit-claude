#!/usr/bin/env luajit

-- Regression test: moving a clip to another track and nudging it in a
-- single BatchCommand must not trim the clip that already lives on the
-- destination track. This used to happen because the MoveClipToTrack
-- command ran occlusion resolution before the follow-up nudge supplied
-- the clip's new time position.
-- Uses REAL timeline_state — no mock.

require('test_env')

-- No-op timer: prevent debounced persistence from firing mid-command
_G.qt_create_single_shot_timer = function() end

-- Only mock needed: panel_manager (Qt widget management)
package.loaded["ui.panel_manager"] = {
    get_active_sequence_monitor = function() return nil end,
}

local database = require('core.database')
local command_manager = require('core.command_manager')
local Command = require('command')

local TEST_DB = "/tmp/jve/test_track_move_nudge.db"
os.remove(TEST_DB)
os.remove(TEST_DB .. "-wal")
os.remove(TEST_DB .. "-shm")

database.init(TEST_DB)
local db = database.get_connection()

db:exec(require('import_schema'))

local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at)
    VALUES ('default_project', 'Default Project', 'resample', %d, %d);

    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, audio_sample_rate, width, height,
        view_start_frame, view_duration_frames, playhead_frame, selected_clip_ids, selected_edge_infos,
        selected_gap_infos, current_sequence_number, created_at, modified_at)
    VALUES ('default_sequence', 'default_project', 'Sequence', 'sequence',
        30, 1, 48000, 1920, 1080, 0, 240, 0,
        '[]', '[]', '[]', 0, %d, %d);

    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
    VALUES ('track_v1', 'default_sequence', 'Track', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
    VALUES ('track_v2', 'default_sequence', 'Track', 'VIDEO', 2, 1, 0, 0, 0, 1.0, 0.0);
]], now, now, now, now))

-- Existing clips:
--   track_v2: clip_dest (500-3000)
--   track_v1: clip_keep (0-2000), clip_move (2000-3500)
local clip_move_start = 2000
local clip_move_duration = 1500
local nudge_amount_frames = 2000

db:exec(string.format([[
    INSERT INTO media (id, project_id, name, file_path, duration_frames, fps_numerator, fps_denominator,
        width, height, audio_channels, codec, metadata, created_at, modified_at)
    VALUES ('media_dest', 'default_project', 'clip_dest.mov', '/tmp/jve/clip_dest.mov',
        2500, 30, 1, 1920, 1080, 0, '', '{}', %d, %d);
    INSERT INTO media (id, project_id, name, file_path, duration_frames, fps_numerator, fps_denominator,
        width, height, audio_channels, codec, metadata, created_at, modified_at)
    VALUES ('media_keep', 'default_project', 'clip_keep.mov', '/tmp/jve/clip_keep.mov',
        2000, 30, 1, 1920, 1080, 0, '', '{}', %d, %d);
    INSERT INTO media (id, project_id, name, file_path, duration_frames, fps_numerator, fps_denominator,
        width, height, audio_channels, codec, metadata, created_at, modified_at)
    VALUES ('media_move', 'default_project', 'clip_move.mov', '/tmp/jve/clip_move.mov',
        %d, 30, 1, 1920, 1080, 0, '', '{}', %d, %d);
]], now, now, now, now, clip_move_duration, now, now))

db:exec(string.format([[
    -- V13 master sequence + track + media_ref for media_dest
INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, audio_sample_rate, width, height, created_at, modified_at)
VALUES ('master_media_dest', 'default_project', 'media_dest_master', 'master', 30, 1, 48000, 1920, 1080, 0, 0);
INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
VALUES ('master_v_media_dest', 'master_media_dest', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
UPDATE sequences SET default_video_layer_track_id = 'master_v_media_dest' WHERE id = 'master_media_dest';
INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id, media_id, source_in_frame, source_out_frame, sequence_start_frame, duration_frames, enabled, volume, playhead_frame, created_at, modified_at)
VALUES ('mr_media_dest', 'default_project', 'master_media_dest', 'master_v_media_dest', 'media_dest', 0, 2500, 0, 2500, 1, 1.0, 0, 0, 0);

-- V13 master sequence + track + media_ref for media_keep
INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, audio_sample_rate, width, height, created_at, modified_at)
VALUES ('master_media_keep', 'default_project', 'media_keep_master', 'master', 30, 1, 48000, 1920, 1080, 0, 0);
INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
VALUES ('master_v_media_keep', 'master_media_keep', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
UPDATE sequences SET default_video_layer_track_id = 'master_v_media_keep' WHERE id = 'master_media_keep';
INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id, media_id, source_in_frame, source_out_frame, sequence_start_frame, duration_frames, enabled, volume, playhead_frame, created_at, modified_at)
VALUES ('mr_media_keep', 'default_project', 'master_media_keep', 'master_v_media_keep', 'media_keep', 0, 2000, 0, 2000, 1, 1.0, 0, 0, 0);

-- V13 master sequence + track + media_ref for media_move
INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, audio_sample_rate, width, height, created_at, modified_at)
VALUES ('master_media_move', 'default_project', 'media_move_master', 'master', 30, 1, 48000, 1920, 1080, 0, 0);
INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
VALUES ('master_v_media_move', 'master_media_move', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
UPDATE sequences SET default_video_layer_track_id = 'master_v_media_move' WHERE id = 'master_media_move';
INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id, media_id, source_in_frame, source_out_frame, sequence_start_frame, duration_frames, enabled, volume, playhead_frame, created_at, modified_at)
VALUES ('mr_media_move', 'default_project', 'master_media_move', 'master_v_media_move', 'media_move', 0, %d, 0, %d, 1, 1.0, 0, 0, 0);

INSERT INTO clips (id, project_id, name, track_id, sequence_id, owner_sequence_id, sequence_start_frame, duration_frames, source_in_frame, source_out_frame, enabled, created_at, modified_at, master_layer_track_id, master_audio_track_id, fps_mismatch_policy, volume, playhead_frame)
VALUES
    ('clip_dest', 'default_project', 'Clip Dest', 'track_v2', 'master_media_dest', 'default_sequence', 500, 2500, 0, 2500, 1, %d, %d, NULL, NULL, 'resample', 1.0, 0);
    INSERT INTO clips (id, project_id, name, track_id, sequence_id, owner_sequence_id, sequence_start_frame, duration_frames, source_in_frame, source_out_frame, enabled, created_at, modified_at, master_layer_track_id, master_audio_track_id, fps_mismatch_policy, volume, playhead_frame)
VALUES
    ('clip_keep', 'default_project', 'Clip Keep', 'track_v1', 'master_media_keep', 'default_sequence', 0, 2000, 0, 2000, 1, %d, %d, NULL, NULL, 'resample', 1.0, 0);
    INSERT INTO clips (id, project_id, name, track_id, sequence_id, owner_sequence_id, sequence_start_frame, duration_frames, source_in_frame, source_out_frame, enabled, created_at, modified_at, master_layer_track_id, master_audio_track_id, fps_mismatch_policy, volume, playhead_frame)
VALUES
    ('clip_move', 'default_project', 'Clip Move', 'track_v1', 'master_media_move', 'default_sequence', %d, %d, 0, %d, 1, %d, %d, NULL, NULL, 'resample', 1.0, 0);
]], clip_move_duration, clip_move_duration, now, now, now, now, clip_move_start, clip_move_duration, clip_move_duration, now, now))

command_manager.init('default_sequence', 'default_project')

print("=== MoveClipToTrack + Nudge Regression ===\n")

local function fetch_clip(id)
    local stmt = db:prepare("SELECT sequence_start_frame, duration_frames FROM clips WHERE id = ?")
    assert(stmt, "failed to prepare clip fetch statement")
    stmt:bind_value(1, id)
    assert(stmt:exec() and stmt:next(), "clip not found: " .. id)
    local start_val = stmt:value(0)
    local dur_val = stmt:value(1)
    stmt:finalize()
    return start_val, dur_val
end

local original_start, original_duration = fetch_clip('clip_dest')

command_manager.begin_undo_group("move_nudge")

local move_cmd = Command.create("MoveClipToTrack", "default_project")
move_cmd:set_parameter("clip_id", "clip_move")
move_cmd:set_parameter("target_track_id", "track_v2")
move_cmd:set_parameter("skip_occlusion", true)
move_cmd:set_parameter("pending_new_start", clip_move_start + nudge_amount_frames)
move_cmd:set_parameter("pending_duration", clip_move_duration)
local move_result = command_manager.execute(move_cmd)
assert(move_result.success, "MoveClipToTrack failed: " .. tostring(move_result.error_message))

local nudge_cmd = Command.create("Nudge", "default_project")
nudge_cmd:set_parameter("nudge_amount", nudge_amount_frames)
nudge_cmd:set_parameter("selected_clip_ids", {"clip_move"})
local nudge_result = command_manager.execute(nudge_cmd)
assert(nudge_result.success, "Nudge failed: " .. tostring(nudge_result.error_message))

command_manager.end_undo_group()

local new_start, new_duration = fetch_clip('clip_dest')

assert(new_start == original_start,
    string.format("Destination clip start changed: %d -> %d", original_start, new_start))
assert(new_duration == original_duration,
    string.format("Destination clip duration changed: %d -> %d", original_duration, new_duration))

print("✅ MoveClipToTrack + Nudge preserves upstream clip on destination track")
