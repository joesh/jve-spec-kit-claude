#!/usr/bin/env luajit

-- Regression: GoToStart and GoToEnd commands should move the playhead without
-- polluting the undo log or failing with "Unknown command type".

require('test_env')

local database = require('core.database')
local command_manager = require('core.command_manager')
local command_impl = require('core.command_implementations')

local TEST_DB = "/tmp/jve/test_timeline_navigation.db"
os.remove(TEST_DB)

database.init(TEST_DB)
local db = database.get_connection()

db:exec(require('import_schema'))

db:exec([[
    INSERT INTO projects (id, name) VALUES ('default_project', 'Default Project');
    INSERT INTO sequences (id, project_id, name, frame_rate, width, height)
    VALUES ('default_sequence', 'default_project', 'Sequence', 30.0, 1920, 1080);
    INSERT INTO tracks (id, sequence_id, name, track_type, timebase_type, timebase_rate, track_index, enabled) VALUES ('track_v1', 'default_sequence', 'Track', 'VIDEO', 'video_frames', 30.0, 1, 1);
]])

db:exec([[
    INSERT INTO media (id, project_id, name, file_path, duration, frame_rate, created_at, modified_at, metadata)
    VALUES ('media_clip_a', 'default_project', 'clip_a.mov', '/tmp/jve/clip_a.mov', 1000, 30.0, 0, 0, '{}');
    INSERT INTO media (id, project_id, name, file_path, duration, frame_rate, created_at, modified_at, metadata)
    VALUES ('media_clip_b', 'default_project', 'clip_b.mov', '/tmp/jve/clip_b.mov', 1500, 30.0, 0, 0, '{}');

    INSERT INTO clips (id, track_id, media_id, start_value, duration, source_in, source_out, enabled)
    VALUES ('clip_a', 'track_v1', 'media_clip_a', 0, 1000, 0, 1000, 1);
    INSERT INTO clips (id, track_id, media_id, start_value, duration, source_in, source_out, enabled)
    VALUES ('clip_b', 'track_v1', 'media_clip_b', 2000, 1500, 0, 1500, 1);
]])

local timeline_state = {
    playhead_value = 500,
    clips = {
        {id = 'clip_a', start_value = 0, duration = 1000},
        {id = 'clip_b', start_value = 2000, duration = 1500}
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
function timeline_state.get_playhead_position() return timeline_state.playhead_position end
function timeline_state.set_playhead_position(time_ms) timeline_state.playhead_position = time_ms end
function timeline_state.get_clips() return timeline_state.clips end

local viewport_guard = 0

function timeline_state.capture_viewport()
    return {
        start_value = timeline_state.viewport_start_value,
        duration = timeline_state.viewport_duration_frames_value,
    }
end

function timeline_state.restore_viewport(snapshot)
    if not snapshot then
        return
    end

    if snapshot.duration then
        timeline_state.viewport_duration_frames_value = snapshot.duration
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

print("=== Timeline Navigation Command Tests ===\n")

local result = command_manager.execute("GoToStart")
assert(result.success == true, "GoToStart should succeed")
assert(timeline_state.playhead_position == 0, "GoToStart must set playhead to 0")

timeline_state.playhead_position = 321 -- ensure we move again

result = command_manager.execute("GoToEnd")
assert(result.success == true, "GoToEnd should succeed")
assert(timeline_state.playhead_position == 3500,
    string.format("GoToEnd must set playhead to timeline end (expected 3500, got %d)", timeline_state.playhead_position))

print("✅ GoToStart/GoToEnd navigation commands adjust playhead correctly")
