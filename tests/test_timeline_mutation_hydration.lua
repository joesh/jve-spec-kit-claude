#!/usr/bin/env luajit

require('test_env')

local database = require('core.database')
local Command = require('command')
local command_manager = require('core.command_manager')
local command_impl = require('core.command_implementations')

local TEST_DB = "/tmp/jve/test_timeline_mutation_hydration.db"

local function setup_db()
    os.remove(TEST_DB)
    assert(database.init(TEST_DB))
    local conn = database.get_connection()
    assert(conn:exec(require('import_schema')))

    assert(conn:exec([[
        INSERT INTO projects (id, name) VALUES ('default_project', 'Default Project');
    INSERT INTO sequences (id, project_id, name, kind, frame_rate, audio_sample_rate, width, height, timecode_start_frame, playhead_value, viewport_start_value, viewport_duration_frames_value)
    VALUES ('default_sequence', 'default_project', 'Timeline', 'timeline', 30.0, 48000, 1920, 1080, 0, 0, 0, 240);
    INSERT INTO tracks (id, sequence_id, name, track_type, timebase_type, timebase_rate, track_index, enabled)
    VALUES ('track_v1', 'default_sequence', 'V1', 'VIDEO', 'video_frames', 30.0, 1, 1);
    INSERT INTO media (id, project_id, file_path, name, duration_value, timebase_type, timebase_rate, frame_rate)
    VALUES ('media_a', 'default_project', '/tmp/jve/a.mov', 'Media A', 4000, 'video_frames', 30.0, 30.0);
    INSERT INTO media (id, project_id, file_path, name, duration_value, timebase_type, timebase_rate, frame_rate)
    VALUES ('media_b', 'default_project', '/tmp/jve/b.mov', 'Media B', 4000, 'video_frames', 30.0, 30.0);
    INSERT INTO clips (id, project_id, track_id, owner_sequence_id, start_value, duration_value, source_in_value, source_out_value, timebase_type, timebase_rate, media_id)
    VALUES ('clip_a', 'default_project', 'track_v1', 'default_sequence', 0, 4000, 0, 4000, 'video_frames', 30.0, 'media_a');
    INSERT INTO clips (id, project_id, track_id, owner_sequence_id, start_value, duration_value, source_in_value, source_out_value, timebase_type, timebase_rate, media_id)
    VALUES ('clip_b', 'default_project', 'track_v1', 'default_sequence', 4000, 4000, 0, 4000, 'video_frames', 30.0, 'media_b');
    ]]))

command_impl.register_commands({}, {}, conn)
command_manager.init(conn, 'default_sequence', 'default_project')
end

setup_db()

local timeline_state = require('ui.timeline.timeline_state')
local original_reload = timeline_state.reload_clips
local reload_count = 0
timeline_state.reload_clips = function(sequence_id, opts)
    reload_count = reload_count + 1
    if original_reload then
        return original_reload(sequence_id, opts)
    end
    return true
end

assert(timeline_state.init('default_sequence'))

assert(timeline_state.get_clip_by_id('clip_b') ~= nil, "clip_b should load initially")
timeline_state._internal_remove_clip_from_command('clip_b')
assert(timeline_state.get_clip_by_id('clip_b') == nil, "clip_b should be missing before mutation")

local ripple_cmd = Command.create("RippleEdit", "default_project")
ripple_cmd:set_parameter("edge_info", {
    clip_id = "clip_b",
    edge_type = "out",
    track_id = "track_v1"
})
ripple_cmd:set_parameter("delta_ms", -250)
ripple_cmd:set_parameter("sequence_id", "default_sequence")

local result = command_manager.execute(ripple_cmd)
assert(result.success, result.error_message or "RippleEdit should succeed")
assert(reload_count == 0, "Hydrated mutation should not trigger reload fallback")

local hydrated_clip = timeline_state.get_clip_by_id('clip_b')
assert(hydrated_clip, "clip_b should be hydrated back into state")
assert(hydrated_clip.duration < 4000, "Ripple trim should update hydrated clip")

print("✅ Timeline state hydrates missing clips during mutation replay without reload fallback")
