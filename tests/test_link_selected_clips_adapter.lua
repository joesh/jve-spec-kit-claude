-- Unit test for the LinkSelectedClips keyboard/menu adapter
-- (see specs/013-timeline-placements-as/contracts/commands.md
-- "Cmd+L / Cmd+Shift+L keyboard adapters").
--
-- Black-box assertion: after dispatching LinkSelectedClips with a
-- 2-clip selection (one VIDEO, one AUDIO, both unlinked), the model
-- reports both clips as members of the same link group.
--
-- Pre-fix TDD demonstration: before LinkSelectedClips existed, the
-- Cmd+L keymap binding (LinkClips) crashed at dispatch with
-- "Command 'LinkClips' missing required param 'clips'" — the L2
-- dispatch gate caught the class of bug. This test fails-loud if a
-- future refactor undoes the adapter (removes the file, or breaks
-- selection→clips list conversion).

require("test_env")

local database = require("core.database")
local command_manager = require("core.command_manager")
local ClipLink = require("models.clip_link")
local timeline_state = require("ui.timeline.timeline_state")

local db_path = "/tmp/jve/test_link_selected_clips_adapter.db"
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

-- Stub timeline_state's selection + track-lookup surfaces. The
-- LinkSelectedClips adapter reads these to build the clips list.
timeline_state.get_selected_clips = function()
    return {
        { id = "clip_v", track_id = "trk_v", is_gap = false },
        { id = "clip_a", track_id = "trk_a", is_gap = false },
    }
end
timeline_state.get_track_by_id = function(track_id)
    if track_id == "trk_v" then
        return { id = "trk_v", track_type = "VIDEO" }
    elseif track_id == "trk_a" then
        return { id = "trk_a", track_type = "AUDIO" }
    end
    return nil
end

-- Pre-state: neither clip is linked.
assert(ClipLink.get_link_group_id("clip_v", db) == nil,
    "precondition: clip_v should not be linked before LinkSelectedClips")
assert(ClipLink.get_link_group_id("clip_a", db) == nil,
    "precondition: clip_a should not be linked before LinkSelectedClips")

-- Dispatch the adapter.
local ok, result = command_manager.execute("LinkSelectedClips", {
    project_id = "proj1",
})
assert(ok, "LinkSelectedClips dispatch should succeed")
assert(type(result) == "table",
    "LinkSelectedClips should return a result table")

-- Post-state: both clips share a single link group.
local group_v = ClipLink.get_link_group_id("clip_v", db)
local group_a = ClipLink.get_link_group_id("clip_a", db)
assert(group_v ~= nil, "clip_v should be in a link group after LinkSelectedClips")
assert(group_a ~= nil, "clip_a should be in a link group after LinkSelectedClips")
assert(group_v == group_a, string.format(
    "clip_v and clip_a should be in the SAME link group; got %s vs %s",
    group_v, group_a))

print("✅ test_link_selected_clips_adapter passed")
