#!/usr/bin/env luajit

-- Regression: GoToPrevEdit / GoToNextEdit should move the playhead to the
-- nearest clip boundary without creating undo entries.

require('test_env')

local dkjson = require('dkjson')
local database = require('core.database')
local command_manager = require('core.command_manager')
local command_impl = require('core.command_implementations')

local TEST_DB = "/tmp/jve/test_timeline_edit_navigation.db"
os.remove(TEST_DB)

database.init(TEST_DB)
local db = database.get_connection()

db:exec(require('import_schema'))

db:exec([[
    INSERT INTO projects (id, name) VALUES ('default_project', 'Default Project');
    INSERT INTO sequences (id, project_id, name, frame_rate, width, height)
    VALUES ('default_sequence', 'default_project', 'Sequence', 30.0, 1920, 1080);
    INSERT INTO tracks (id, sequence_id, name, track_type, timebase_type, timebase_rate, track_index, enabled) VALUES ('track_v1', 'default_sequence', 'Track', 'VIDEO', 'video_frames', 30.0, 1, 1);
    INSERT INTO tracks (id, sequence_id, name, track_type, timebase_type, timebase_rate, track_index, enabled) VALUES ('track_v2', 'default_sequence', 'Track', 'VIDEO', 'video_frames', 30.0, 2, 1);
]])

-- Timeline layout (in ms):
-- V1: clip_a [0, 1500), clip_b [3000, 4500)
-- V2: clip_c [1200, 2400), clip_d [5000, 6200)
db:exec([[
    INSERT INTO media (id, project_id, name, file_path, duration_value, frame_rate, created_at, modified_at, metadata)
    VALUES ('media_clip_a', 'default_project', 'clip_a.mov', '/tmp/jve/clip_a.mov', 1500, 30.0, 0, 0, '{}');
    INSERT INTO media (id, project_id, name, file_path, duration_value, frame_rate, created_at, modified_at, metadata)
    VALUES ('media_clip_b', 'default_project', 'clip_b.mov', '/tmp/jve/clip_b.mov', 1500, 30.0, 0, 0, '{}');
    INSERT INTO media (id, project_id, name, file_path, duration_value, frame_rate, created_at, modified_at, metadata)
    VALUES ('media_clip_c', 'default_project', 'clip_c.mov', '/tmp/jve/clip_c.mov', 1200, 30.0, 0, 0, '{}');
    INSERT INTO media (id, project_id, name, file_path, duration_value, frame_rate, created_at, modified_at, metadata)
    VALUES ('media_clip_d', 'default_project', 'clip_d.mov', '/tmp/jve/clip_d.mov', 1200, 30.0, 0, 0, '{}');

    INSERT INTO clips (id, track_id, media_id, start_value, duration_value, source_in_value, source_out_value, enabled)
    VALUES ('clip_a', 'track_v1', 'media_clip_a', 0, 1500, 0, 1500, 1);
    INSERT INTO clips (id, track_id, media_id, start_value, duration_value, source_in_value, source_out_value, enabled)
    VALUES ('clip_b', 'track_v1', 'media_clip_b', 3000, 1500, 0, 1500, 1);
    INSERT INTO clips (id, track_id, media_id, start_value, duration_value, source_in_value, source_out_value, enabled)
    VALUES ('clip_c', 'track_v2', 'media_clip_c', 1200, 1200, 0, 1200, 1);
    INSERT INTO clips (id, track_id, media_id, start_value, duration_value, source_in_value, source_out_value, enabled)
    VALUES ('clip_d', 'track_v2', 'media_clip_d', 5000, 1200, 0, 1200, 1);
]])

local timeline_state = {
    playhead_value = 2500,
    clips = {
        {id = 'clip_a', start_value = 0, duration_value = 1500},
        {id = 'clip_c', start_value = 1200, duration_value = 1200},
        {id = 'clip_b', start_value = 3000, duration_value = 1500},
        {id = 'clip_d', start_value = 5000, duration_value = 1200},
    },
    viewport_start_value = 0,
    viewport_duration_frames_value = 10000
}

function timeline_state.get_selected_clips() return {} end
function timeline_state.get_selected_edges() return {} end
function timeline_state.normalize_edge_selection() end
function timeline_state.clear_edge_selection() end
function timeline_state.set_selection(_) end
function timeline_state.reload_clips() end
function timeline_state.persist_state_to_db() end
function timeline_state.get_playhead_value() return timeline_state.playhead_value end
function timeline_state.set_playhead_value(time_ms) timeline_state.playhead_value = time_ms end
function timeline_state.get_clips() return timeline_state.clips end

local viewport_guard = 0

function timeline_state.capture_viewport()
    return {
        start_value = timeline_state.viewport_start_value,
        duration_value = timeline_state.viewport_duration_frames_value,
    }
end

function timeline_state.restore_viewport(snapshot)
    if not snapshot then
        return
    end

    if snapshot.duration_value then
        timeline_state.viewport_duration_frames_value = snapshot.duration_value
    end

    if snapshot.start_value then
        timeline_state.viewport_start_value = snapshot.start_value
    end
end

function timeline_state.push_viewport_guard()
    viewport_guard = viewport_guard + 1
    return viewport_guard
end

function timeline_state.pop_viewport_guard()
    if viewport_guard > 0 then
        viewport_guard = viewport_guard - 1
    end
    return viewport_guard
end

package.loaded['ui.timeline.timeline_state'] = timeline_state

local executors = {}
local undoers = {}
command_impl.register_commands(executors, undoers, db)

command_manager.init(db, 'default_sequence', 'default_project')

print("=== Timeline Edit Navigation Tests ===\n")

local result = command_manager.execute("GoToPrevEdit")
assert(result.success == true, "GoToPrevEdit should succeed")
assert(timeline_state.playhead_value == 2400,
    string.format("GoToPrevEdit expected 2400, got %d", timeline_state.playhead_value))

timeline_state.playhead_value = 3200

result = command_manager.execute("GoToNextEdit")
assert(result.success == true, "GoToNextEdit should succeed")
assert(timeline_state.playhead_value == 4500,
    string.format("GoToNextEdit expected 4500, got %d", timeline_state.playhead_value))

timeline_state.playhead_value = 6200
result = command_manager.execute("GoToNextEdit")
assert(result.success == true, "GoToNextEdit should succeed even at timeline end")
assert(timeline_state.playhead_value == 6200,
    string.format("GoToNextEdit at end should stay at 6200, got %d", timeline_state.playhead_value))

print("✅ GoToPrevEdit/GoToNextEdit navigation commands adjust playhead correctly")
