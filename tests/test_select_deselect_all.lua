#!/usr/bin/env luajit

-- Test SelectAll and DeselectAll commands

require('test_env')

local database = require('core.database')
local command_manager = require('core.command_manager')

local TEST_DB = "/tmp/jve/test_select_deselect_all.db"
os.remove(TEST_DB)

database.init(TEST_DB)
local db = database.get_connection()

db:exec(require('import_schema'))

db:exec([[
    INSERT INTO projects (id, name) VALUES ('default_project', 'Default Project');
    INSERT INTO sequences (id, project_id, name, fps_numerator, fps_denominator, width, height)
    VALUES ('default_sequence', 'default_project', 'Sequence', 30, 1, 1920, 1080);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
    VALUES ('track_v1', 'default_sequence', 'V1', 'VIDEO', 1, 1);
]])

-- Create clips for selection tests
db:exec([[
    INSERT INTO media (id, project_id, name, file_path, duration, frame_rate, created_at, modified_at)
    VALUES ('media_a', 'default_project', 'clip_a.mov', '/tmp/clip_a.mov', 100, 30.0, 0, 0);
    INSERT INTO media (id, project_id, name, file_path, duration, frame_rate, created_at, modified_at)
    VALUES ('media_b', 'default_project', 'clip_b.mov', '/tmp/clip_b.mov', 150, 30.0, 0, 0);

    INSERT INTO clips (id, track_id, media_id, timeline_start_frame, duration_frames, source_in_frame, source_out_frame, fps_numerator, fps_denominator, enabled)
    VALUES ('clip_a', 'track_v1', 'media_a', 0, 100, 0, 100, 30, 1, 1);
    INSERT INTO clips (id, track_id, media_id, timeline_start_frame, duration_frames, source_in_frame, source_out_frame, fps_numerator, fps_denominator, enabled)
    VALUES ('clip_b', 'track_v1', 'media_b', 100, 150, 0, 150, 30, 1, 1);
]])

-- Mock timeline_state
local timeline_state = {
    playhead_position = 0,
    clips = {
        {id = 'clip_a', timeline_start = 0, duration = 100},
        {id = 'clip_b', timeline_start = 100, duration = 150},
    },
    selected_clips = {},
    selected_edges = {},
}

function timeline_state.get_selected_clips() return timeline_state.selected_clips end
function timeline_state.get_selected_edges() return timeline_state.selected_edges end
function timeline_state.set_selection(clips) timeline_state.selected_clips = clips end
function timeline_state.clear_edge_selection() timeline_state.selected_edges = {} end
function timeline_state.reload_clips() end
function timeline_state.get_playhead_position() return timeline_state.playhead_position end
function timeline_state.set_playhead_position(pos) timeline_state.playhead_position = pos end
function timeline_state.get_clips() return timeline_state.clips end
function timeline_state.get_sequence_frame_rate() return {fps_numerator = 30, fps_denominator = 1} end
function timeline_state.capture_viewport() return {start_value = 0, duration_value = 500} end
function timeline_state.restore_viewport(_) end
function timeline_state.push_viewport_guard() return 1 end
function timeline_state.pop_viewport_guard() return 0 end

-- Mock focus_manager to default to timeline (not project_browser)
local focus_manager = {
    get_focused_panel = function() return "timeline" end
}
package.loaded['ui.focus_manager'] = focus_manager

package.loaded['ui.timeline.timeline_state'] = timeline_state

command_manager.init('default_sequence', 'default_project')

print("=== SelectAll / DeselectAll Tests ===")

-- Test 1: SelectAll selects all clips
print("Test 1: SelectAll selects all clips")
timeline_state.selected_clips = {}
timeline_state.selected_edges = {}
local result = command_manager.execute("SelectAll", { project_id = "default_project" })
assert(result.success, "SelectAll should succeed: " .. tostring(result.error_message))
assert(#timeline_state.selected_clips == 2,
    string.format("SelectAll should select 2 clips, got %d", #timeline_state.selected_clips))

-- Test 2: DeselectAll clears selection
print("Test 2: DeselectAll clears selection")
timeline_state.selected_clips = timeline_state.clips
timeline_state.selected_edges = {{clip_id = 'clip_a', edge = 'left'}}
result = command_manager.execute("DeselectAll", { project_id = "default_project" })
assert(result.success, "DeselectAll should succeed: " .. tostring(result.error_message))
assert(#timeline_state.selected_clips == 0,
    string.format("DeselectAll should clear clips, got %d selected", #timeline_state.selected_clips))
assert(#timeline_state.selected_edges == 0,
    string.format("DeselectAll should clear edges, got %d selected", #timeline_state.selected_edges))

-- Test 3: SelectAll with empty timeline
print("Test 3: SelectAll with empty timeline")
local saved_clips = timeline_state.clips
timeline_state.clips = {}
timeline_state.selected_clips = {}
result = command_manager.execute("SelectAll", { project_id = "default_project" })
assert(result.success, "SelectAll should succeed with empty timeline")
assert(#timeline_state.selected_clips == 0, "SelectAll with no clips should result in empty selection")
timeline_state.clips = saved_clips

-- Test 4: DeselectAll is idempotent (nothing selected)
print("Test 4: DeselectAll is idempotent")
timeline_state.selected_clips = {}
timeline_state.selected_edges = {}
result = command_manager.execute("DeselectAll", { project_id = "default_project" })
assert(result.success, "DeselectAll should succeed when nothing selected")
assert(#timeline_state.selected_clips == 0, "DeselectAll should stay empty")

-- Test 5: SelectAll clears edge selection
print("Test 5: SelectAll clears edge selection")
timeline_state.selected_clips = {}
timeline_state.selected_edges = {{clip_id = 'clip_a', edge = 'left'}, {clip_id = 'clip_b', edge = 'right'}}
result = command_manager.execute("SelectAll", { project_id = "default_project" })
assert(result.success, "SelectAll should succeed")
assert(#timeline_state.selected_edges == 0,
    string.format("SelectAll should clear edge selection, got %d edges", #timeline_state.selected_edges))

-- Test 6: SelectAll followed by DeselectAll round-trip
print("Test 6: SelectAll/DeselectAll round-trip")
timeline_state.selected_clips = {}
timeline_state.selected_edges = {}
result = command_manager.execute("SelectAll", { project_id = "default_project" })
assert(result.success, "SelectAll should succeed")
assert(#timeline_state.selected_clips == 2, "Should have 2 clips selected")
result = command_manager.execute("DeselectAll", { project_id = "default_project" })
assert(result.success, "DeselectAll should succeed")
assert(#timeline_state.selected_clips == 0, "Should have 0 clips selected after deselect")

print("✅ SelectAll/DeselectAll tests passed")
