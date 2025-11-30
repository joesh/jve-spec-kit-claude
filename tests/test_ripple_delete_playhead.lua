#!/usr/bin/env luajit

require('test_env')

local database = require('core.database')
local command_manager = require('core.command_manager')
local command_impl = require('core.command_implementations')
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
    INSERT INTO projects (id, name) VALUES ('default_project', 'Default Project');
    INSERT INTO sequences (id, project_id, name, kind, frame_rate, audio_sample_rate, width, height, timecode_start_frame, playhead_value, viewport_start_value, viewport_duration_frames_value)
    VALUES ('default_sequence', 'default_project', 'Sequence', 'timeline', 30.0, 48000, 1920, 1080, 0, 0, 0, 240);
    INSERT INTO tracks (id, sequence_id, name, track_type, timebase_type, timebase_rate, track_index, enabled)
    VALUES ('track_v1', 'default_sequence', 'Video 1', 'VIDEO', 'video_frames', 30.0, 1, 1);
    INSERT INTO tracks (id, sequence_id, name, track_type, timebase_type, timebase_rate, track_index, enabled)
    VALUES ('track_v2', 'default_sequence', 'Video 2', 'VIDEO', 'video_frames', 30.0, 2, 1);
]])

local function create_media(id, duration_value)
    local media = Media.create({
        id = id,
        project_id = 'default_project',
        file_path = '/tmp/jve/' .. id .. '.mov',
        name = id .. '.mov',
        duration_value = duration_value,
        frame_rate = 30,
        width = 1920,
        height = 1080,
        audio_channels = 2
    })
    assert(media, "failed to create media " .. id)
    assert(media:save(db), "failed to save media " .. id)
end

local function create_clip(id, track_id, start_value, duration_value, media_id)
    local clip = Clip.create("Clip " .. id, media_id, {
        id = id,
        project_id = 'default_project',
        track_id = track_id,
        owner_sequence_id = 'default_sequence',
        start_value = start_value,
        duration_value = duration_value,
        source_in_value = 0,
        source_out_value = duration_value,
        timebase_type = "video_frames",
        timebase_rate = 30.0,
        enabled = true,
        offline = false
    })
    assert(clip, "failed to allocate clip " .. id)
    assert(clip:save(db, {skip_occlusion = true}), "failed to persist clip " .. id)
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

local executors = {}
local undoers = {}
command_impl.register_commands(executors, undoers, db)
command_manager.init(db, 'default_sequence', 'default_project')

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
    string.format("Undo should restore playhead to %d, got %d", original_playhead, restored))

print("✅ RippleDeleteSelection undo restores playhead using real timeline_state")
