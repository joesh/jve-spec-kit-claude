#!/usr/bin/env luajit

-- Test SelectAll and DeselectAll commands
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
local timeline_state = require('ui.timeline.timeline_state')
local focus_manager = require('ui.focus_manager')

local TEST_DB = "/tmp/jve/test_select_deselect_all.db"
os.remove(TEST_DB)
os.remove(TEST_DB .. "-wal")
os.remove(TEST_DB .. "-shm")

database.init(TEST_DB)
local db = database.get_connection()

db:exec(require('import_schema'))

local now = os.time()
db:exec(string.format([[
    INSERT INTO projects (id, name, created_at, modified_at) VALUES ('default_project', 'Default Project', %d, %d);
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, audio_rate, width, height,
                           view_start_frame, view_duration_frames, playhead_frame,
                           selected_clip_ids, selected_edge_infos, selected_gap_infos,
                           current_sequence_number, created_at, modified_at)
    VALUES ('default_sequence', 'default_project', 'Sequence', 'timeline', 30, 1, 48000, 1920, 1080,
            0, 240, 0, '[]', '[]', '[]', 0, %d, %d);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index,
        enabled, locked, muted, soloed, volume, pan)
    VALUES ('track_v1', 'default_sequence', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
    INSERT INTO clips (
        id, project_id, clip_kind, track_id, owner_sequence_id, media_id, name,
        timeline_start_frame, duration_frames, source_in_frame, source_out_frame,
        fps_numerator, fps_denominator, enabled, offline, created_at, modified_at
    ) VALUES
        ('clip_a', 'default_project', 'timeline', 'track_v1', 'default_sequence', NULL, 'Clip A',
         0, 100, 0, 100, 30, 1, 1, 0, %d, %d),
        ('clip_b', 'default_project', 'timeline', 'track_v1', 'default_sequence', NULL, 'Clip B',
         100, 150, 0, 150, 30, 1, 1, 0, %d, %d);
]], now, now, now, now, now, now, now, now))

-- Init with REAL timeline_state
command_manager.init('default_sequence', 'default_project')

-- Focus timeline (not project_browser) so SelectAll targets timeline clips
focus_manager.set_focused_panel("timeline")

print("=== SelectAll / DeselectAll Tests ===")

-- Test 1: SelectAll selects all clips
print("Test 1: SelectAll selects all clips")
timeline_state.set_selection({})
local result = command_manager.execute("SelectAll", { project_id = "default_project" })
assert(result.success, "SelectAll should succeed: " .. tostring(result.error_message))
local selected = timeline_state.get_selected_clips()
assert(#selected == 2,
    string.format("SelectAll should select 2 clips, got %d", #selected))

-- Test 2: DeselectAll clears selection
print("Test 2: DeselectAll clears selection")
-- Ensure some selection exists first
timeline_state.set_selection(timeline_state.get_clips())
result = command_manager.execute("DeselectAll", { project_id = "default_project" })
assert(result.success, "DeselectAll should succeed: " .. tostring(result.error_message))
selected = timeline_state.get_selected_clips()
assert(#selected == 0,
    string.format("DeselectAll should clear clips, got %d selected", #selected))
local edges = timeline_state.get_selected_edges()
assert(#edges == 0,
    string.format("DeselectAll should clear edges, got %d selected", #edges))

-- Test 3: DeselectAll is idempotent (nothing selected)
print("Test 3: DeselectAll is idempotent")
timeline_state.set_selection({})
result = command_manager.execute("DeselectAll", { project_id = "default_project" })
assert(result.success, "DeselectAll should succeed when nothing selected")
assert(#timeline_state.get_selected_clips() == 0, "DeselectAll should stay empty")

-- Test 4: SelectAll clears edge selection
print("Test 4: SelectAll clears edge selection")
timeline_state.set_selection({})
result = command_manager.execute("SelectAll", { project_id = "default_project" })
assert(result.success, "SelectAll should succeed")
assert(#timeline_state.get_selected_edges() == 0,
    string.format("SelectAll should clear edge selection, got %d edges", #timeline_state.get_selected_edges()))

-- Test 5: SelectAll followed by DeselectAll round-trip
print("Test 5: SelectAll/DeselectAll round-trip")
timeline_state.set_selection({})
result = command_manager.execute("SelectAll", { project_id = "default_project" })
assert(result.success, "SelectAll should succeed")
assert(#timeline_state.get_selected_clips() == 2, "Should have 2 clips selected")
result = command_manager.execute("DeselectAll", { project_id = "default_project" })
assert(result.success, "DeselectAll should succeed")
assert(#timeline_state.get_selected_clips() == 0, "Should have 0 clips selected after deselect")

print("✅ SelectAll/DeselectAll tests passed")
