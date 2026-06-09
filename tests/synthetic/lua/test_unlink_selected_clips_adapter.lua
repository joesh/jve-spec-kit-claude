-- Unit test for the UnlinkSelectedClips keyboard/menu adapter
-- (see specs/013-timeline-placements-as/contracts/commands.md
-- "Cmd+L / Cmd+Shift+L keyboard adapters").
--
-- Black-box assertion: after dispatching UnlinkSelectedClips with a
-- 2-clip selection where both clips share a link group, neither clip
-- is in a link group anymore.

require("test_env")

local database = require("core.database")
local command_manager = require("core.command_manager")
local ClipLink = require("models.clip_link")
local timeline_state = require("ui.timeline.timeline_state")

local db_path = "/tmp/jve/test_unlink_selected_clips_adapter.db"
os.remove(db_path)
assert(database.init(db_path))
local db = database.get_connection()
db:exec(require("import_schema"))

local now = os.time()

db:exec(string.format([[
    INSERT INTO projects (id, name, fps_mismatch_policy, settings, created_at, modified_at)
    VALUES ('proj1', 'Test', 'resample', '{"master_clock_hz":192000,"default_fps":{"num":24,"den":1}}', %d, %d);
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator,
        audio_sample_rate, width, height, view_start_frame, view_duration_frames,
        playhead_frame, selected_clip_ids, selected_edge_infos, created_at, modified_at)
    VALUES ('seq1', 'proj1', 'Seq', 'sequence', 24000, 1001, 48000,
        1920, 1080, 0, 240, 0, '[]', '[]', %d, %d);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index,
        enabled, locked, muted, soloed, volume, pan)
    VALUES ('trk_v', 'seq1', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index,
        enabled, locked, muted, soloed, volume, pan)
    VALUES ('trk_a', 'seq1', 'A1', 'AUDIO', 2, 1, 0, 0, 0, 1.0, 0.0);
    INSERT INTO media (id, project_id, name, file_path, duration_frames,
        fps_numerator, fps_denominator, width, height, audio_channels,
        codec, metadata, created_at, modified_at)
    VALUES ('med1', 'proj1', 'media.mov', '/tmp/media.mov', 1000,
        24000, 1001, 1920, 1080, 2, 'prores', '{}', %d, %d);
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, audio_sample_rate, width, height, created_at, modified_at)
    VALUES ('master_med1', 'proj1', 'med1_master', 'master', 30, 1, NULL, 1920, 1080, 0, 0);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
    VALUES ('master_v_med1', 'master_med1', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
    UPDATE sequences SET default_video_layer_track_id = 'master_v_med1' WHERE id = 'master_med1';
    INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id, media_id, source_in_frame, source_out_frame, sequence_start_frame, duration_frames, audio_sample_rate, enabled, volume, playhead_frame, created_at, modified_at)
    VALUES ('mr_med1', 'proj1', 'master_med1', 'master_v_med1', 'med1', 0, 1000, 0, 1000, 48000, 1, 1.0, 0, 0, 0);
    INSERT INTO clips (id, project_id, name, track_id, owner_sequence_id, sequence_id, sequence_start_frame, duration_frames, source_in_frame, source_out_frame, source_in_subframe, source_out_subframe, enabled, created_at, modified_at, master_layer_track_id, master_audio_track_id, fps_mismatch_policy, volume, playhead_frame)
    VALUES ('clip_v', 'proj1', 'Video Clip', 'trk_v', 'seq1', 'master_med1', 0, 100, 0, 100, NULL, NULL, 1, %d, %d, NULL, NULL, 'resample', 1.0, 0);
    INSERT INTO clips (id, project_id, name, track_id, owner_sequence_id, sequence_id, sequence_start_frame, duration_frames, source_in_frame, source_out_frame, source_in_subframe, source_out_subframe, enabled, created_at, modified_at, master_layer_track_id, master_audio_track_id, fps_mismatch_policy, volume, playhead_frame)
    VALUES ('clip_a', 'proj1', 'Audio Clip', 'trk_a', 'seq1', 'master_med1', 0, 100, 0, 100, 0, 0, 1, %d, %d, NULL, NULL, 'resample', 1.0, 0);
]], now, now, now, now, now, now, now, now, now, now))

command_manager.init("seq1", "proj1")

-- Pre-state: explicitly link the two clips so UnlinkSelectedClips has
-- something to unwind.
local link_group_id = ClipLink.create_link_group({
    { clip_id = "clip_v", role = "video", time_offset = 0 },
    { clip_id = "clip_a", role = "audio", time_offset = 0 },
}, db)
assert(link_group_id, "setup: create_link_group should return a group id")
assert(ClipLink.get_link_group_id("clip_v", db) == link_group_id,
    "setup: clip_v should be in the new link group")
assert(ClipLink.get_link_group_id("clip_a", db) == link_group_id,
    "setup: clip_a should be in the new link group")

-- Stub timeline_state.get_selected_clips to return both linked clips.
timeline_state.get_selected_clips = function()
    return {
        { id = "clip_v", track_id = "trk_v", is_gap = false },
        { id = "clip_a", track_id = "trk_a", is_gap = false },
    }
end

local ok = command_manager.execute("UnlinkSelectedClips", {
    project_id = "proj1",
})
assert(ok, "UnlinkSelectedClips dispatch should succeed")

-- Post-state: neither clip is in a link group.
assert(ClipLink.get_link_group_id("clip_v", db) == nil,
    "clip_v should NOT be linked after UnlinkSelectedClips")
assert(ClipLink.get_link_group_id("clip_a", db) == nil,
    "clip_a should NOT be linked after UnlinkSelectedClips")

print("✅ test_unlink_selected_clips_adapter passed")
