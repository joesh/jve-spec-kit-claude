#!/usr/bin/env luajit

require('test_env')

local database = require('core.database')
local command_manager = require('core.command_manager')
local Command = require('command')
local Media = require('models.media')
local Clip = require('models.clip')
local timeline_state = require('ui.timeline.timeline_state')

local TEST_DB = "/tmp/jve/test_ripple_delete_playhead.db"
os.remove(TEST_DB)

database.init(TEST_DB)
local db = database.get_connection()

db:exec(require('import_schema'))

db:exec([[
    INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at)
    VALUES ('default_project', 'Default Project', 'resample', 0, 0);
    INSERT INTO sequences (
        id, project_id, name, kind,
        fps_numerator, fps_denominator, audio_sample_rate,
        width, height, view_start_frame, view_duration_frames, playhead_frame,
        created_at, modified_at
    )
    VALUES ('default_sequence', 'default_project', 'Sequence', 'nested', 30, 1, 48000, 1920, 1080, 0, 240, 0, 0, 0);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
    VALUES ('track_v1', 'default_sequence', 'Video 1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
    VALUES ('track_v2', 'default_sequence', 'Video 2', 'VIDEO', 2, 1, 0, 0, 0, 1.0, 0.0);
]])

    -- V13 placeholder master sequence (test references nested_sequence_id='mc_test' literally)
    db:exec(string.format([[INSERT INTO media (id, project_id, name, file_path, duration_frames, fps_numerator, fps_denominator, width, height, audio_channels, codec, created_at, modified_at)
VALUES ('mc_test_media', 'default_project', 'placeholder', '_placeholder', 10000, 30, 1, 1920, 1080, 0, 'raw', 0, 0)]]))
    db:exec(string.format([[INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, audio_sample_rate, width, height, created_at, modified_at)
VALUES ('mc_test', 'default_project', 'mc_test', 'master', 30, 1, 48000, 1920, 1080, 0, 0)]]))
    db:exec(string.format([[INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
VALUES ('mc_test_v1', 'mc_test', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0)]]))
    db:exec(string.format([[UPDATE sequences SET default_video_layer_track_id = 'mc_test_v1' WHERE id = 'mc_test']]))
    db:exec(string.format([[INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id, media_id, source_in_frame, source_out_frame, timeline_start_frame, duration_frames, enabled, volume, playhead_frame, created_at, modified_at)
VALUES ('mc_test_mr', 'default_project', 'mc_test', 'mc_test_v1', 'mc_test_media', 0, 10000, 0, 10000, 1, 1.0, 0, 0, 0)]]))

local function create_media(id, duration_value)
    local media = Media.create({
        id = id,
        project_id = 'default_project',
        file_path = '/tmp/jve/' .. id .. '.mov',
        name = id .. '.mov',
        duration_frames = duration_value,
        fps_numerator = 30,
        fps_denominator = 1,
        width = 1920,
        height = 1080,
        audio_channels = 2
    })
    assert(media, "failed to create media " .. id)
    assert(media:save(db), "failed to save media " .. id)
end

local function create_clip(id, track_id, start_value, duration_value, media_id)
    local clip = Clip.create({
        name = "Clip " .. id,
        id = id,
        project_id = 'default_project',
        track_id = track_id,
        owner_sequence_id = 'default_sequence',
        nested_sequence_id = "mc_test",
        timeline_start_frame = start_value,
        duration_frames = duration_value,
        source_in_frame = 0,
        source_out_frame = duration_value,
        enabled = true,
        fps_mismatch_policy = "resample",
        volume = 1.0,
        playhead_frame = 0,
    })
    assert(clip, "failed to allocate clip " .. id)
    assert(clip ~= nil and clip ~= "", "failed to persist clip " .. id)
end

local clip_specs = {
    {id = "clip_a", track = "track_v1", start = 0, duration_value = 1000},
    {id = "clip_b", track = "track_v1", start = 1000, duration_value = 1200},
    {id = "clip_c", track = "track_v1", start = 2200, duration_value = 800},
    {id = "clip_d", track = "track_v2", start = 900, duration_value = 1600},
}

for index, spec in ipairs(clip_specs) do
    local media_id = "media_" .. spec.id
    create_media(media_id, spec.duration_value)
    create_clip(spec.id, spec.track, spec.start, spec.duration_value, media_id)
end

timeline_state.init('default_sequence')

-- command_impl.register_commands({}, {}, db)
command_manager.init('default_sequence', 'default_project')

local original_playhead = 8888
timeline_state.set_playhead_position(original_playhead)

local cmd = Command.create("RippleDeleteSelection", "default_project")
cmd:set_parameter("sequence_id", "default_sequence")
cmd:set_parameter("clip_ids", {"clip_b", "clip_d"})
local exec_result = command_manager.execute(cmd)
assert(exec_result.success, exec_result.error_message or "RippleDeleteSelection failed")

local undo_result = command_manager.undo()
assert(undo_result.success, undo_result.error_message or "Undo failed for ripple delete")

local restored = timeline_state.get_playhead_position()
assert(restored == original_playhead,
    string.format("Undo should restore playhead to %d, got %s", original_playhead, tostring(restored)))

print("✅ RippleDeleteSelection undo restores playhead using real timeline_state")
