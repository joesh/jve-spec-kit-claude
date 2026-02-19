#!/usr/bin/env luajit

-- Regression: GoToStart and GoToEnd commands should move the playhead without
-- polluting the undo log or failing with "Unknown command type".

require('test_env')

local database = require('core.database')
local command_manager = require('core.command_manager')
require('core.command_implementations')

local TEST_DB = "/tmp/jve/test_timeline_navigation.db"
os.remove(TEST_DB)

database.init(TEST_DB)
local db = database.get_connection()

db:exec(require('import_schema'))

db:exec([[
    INSERT INTO projects (id, name, created_at, modified_at)
    VALUES ('default_project', 'Default Project', strftime('%s','now'), strftime('%s','now'));
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, audio_rate, width, height, view_start_frame, view_duration_frames, playhead_frame, created_at, modified_at)
    VALUES ('default_sequence', 'default_project', 'Sequence', 'timeline', 30, 1, 48000, 1920, 1080, 0, 10000, 0, strftime('%s','now'), strftime('%s','now'));
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
    VALUES ('track_v1', 'default_sequence', 'Track', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
]])

db:exec([[
    INSERT INTO media (id, project_id, name, file_path, duration_frames, fps_numerator, fps_denominator, width, height, audio_channels, codec, metadata, created_at, modified_at)
    VALUES ('media_clip_a', 'default_project', 'clip_a.mov', '/tmp/jve/clip_a.mov', 1000, 30, 1, 1920, 1080, 0, '', '{}', strftime('%s','now'), strftime('%s','now'));
    INSERT INTO media (id, project_id, name, file_path, duration_frames, fps_numerator, fps_denominator, width, height, audio_channels, codec, metadata, created_at, modified_at)
    VALUES ('media_clip_b', 'default_project', 'clip_b.mov', '/tmp/jve/clip_b.mov', 1500, 30, 1, 1920, 1080, 0, '', '{}', strftime('%s','now'), strftime('%s','now'));

    INSERT INTO clips (id, project_id, clip_kind, name, track_id, media_id, owner_sequence_id,
        timeline_start_frame, duration_frames, source_in_frame, source_out_frame,
        fps_numerator, fps_denominator, enabled, offline, created_at, modified_at)
    VALUES ('clip_a', 'default_project', 'timeline', 'Clip A', 'track_v1', 'media_clip_a', 'default_sequence',
        0, 1000, 0, 1000, 30, 1, 1, 0, strftime('%s','now'), strftime('%s','now'));
    INSERT INTO clips (id, project_id, clip_kind, name, track_id, media_id, owner_sequence_id,
        timeline_start_frame, duration_frames, source_in_frame, source_out_frame,
        fps_numerator, fps_denominator, enabled, offline, created_at, modified_at)
    VALUES ('clip_b', 'default_project', 'timeline', 'Clip B', 'track_v1', 'media_clip_b', 'default_sequence',
        2000, 1500, 0, 1500, 30, 1, 1, 0, strftime('%s','now'), strftime('%s','now'));
]])

local timeline_state = {
    playhead_position = 500,
    clips = {
        {id = 'clip_a', timeline_start = 0, duration = 1000},
        {id = 'clip_b', timeline_start = 2000, duration = 1500}
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
function timeline_state.set_playhead_position(time_val)
    if type(time_val) == "number" then
        timeline_state.playhead_position = time_val
    else
        timeline_state.playhead_position = time_val
    end
end
function timeline_state.get_clips() return timeline_state.clips end
function timeline_state.get_sequence_frame_rate() return {fps_numerator = 30, fps_denominator = 1} end

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

-- Mock sequence monitor for GoToStart/GoToEnd (routes through active monitor)
local mock_monitor = {
    sequence_id = "default_sequence",
    view_id = "timeline_monitor",
    total_frames = 3500,
    playhead = 500,
    engine = {
        is_playing = function() return false end,
        stop = function() end,
    },
}
function mock_monitor:seek_to_frame(frame)
    self.playhead = math.max(0, math.floor(frame))
    timeline_state.playhead_position = self.playhead
end

package.loaded['ui.panel_manager'] = {
    get_active_sequence_monitor = function() return mock_monitor end,
}

command_manager.init('default_sequence', 'default_project')

print("=== Timeline Navigation Command Tests ===\n")

local result = command_manager.execute("GoToStart", { project_id = "default_project" })
assert(result.success == true, "GoToStart should succeed")
local start_pos = timeline_state.get_playhead_position()
local start_frames = (type(start_pos) == "table" and start_pos.frames) or start_pos
assert(start_frames == 0, "GoToStart must set playhead to 0")

timeline_state.playhead_position = 321 -- ensure we move again

result = command_manager.execute("GoToEnd", { project_id = "default_project" })
assert(result.success == true, "GoToEnd should succeed")
local end_pos = timeline_state.get_playhead_position()
local end_frames = (type(end_pos) == "table" and end_pos.frames) or end_pos
assert(end_frames == 3500,
    string.format("GoToEnd must set playhead to timeline end (expected 3500, got %s)", tostring(end_frames)))

print("✅ GoToStart/GoToEnd navigation commands adjust playhead correctly")
