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
    INSERT INTO projects (id, name, fps_mismatch_policy, created_at, modified_at) VALUES ('default_project', 'Default Project', 'resample', %d, %d);
    INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, audio_sample_rate, width, height,
                           view_start_frame, view_duration_frames, playhead_frame,
                           selected_clip_ids, selected_edge_infos, selected_gap_infos,
                           current_sequence_number, created_at, modified_at)
    VALUES ('default_sequence', 'default_project', 'Sequence', 'sequence', 30, 1, 48000, 1920, 1080,
            0, 240, 0, '[]', '[]', '[]', 0, %d, %d);
    INSERT INTO tracks (id, sequence_id, name, track_type, track_index,
        enabled, locked, muted, soloed, volume, pan)
    VALUES ('track_v1', 'default_sequence', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
    -- V13 placeholder master sequence (was V8 NULL media_id)
INSERT INTO media (id, project_id, name, file_path, duration_frames, fps_numerator, fps_denominator, width, height, audio_channels, codec, created_at, modified_at)
VALUES ('_v13_placeholder_media', 'default_project', 'placeholder', '_placeholder', 150, 30, 1, 1920, 1080, 0, 'raw', 0, 0);
INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, audio_sample_rate, width, height, created_at, modified_at)
VALUES ('_v13_placeholder_master', 'default_project', 'placeholder_master', 'master', 30, 1, 48000, 1920, 1080, 0, 0);
INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled, locked, muted, soloed, volume, pan)
VALUES ('_v13_placeholder_track', '_v13_placeholder_master', 'V1', 'VIDEO', 1, 1, 0, 0, 0, 1.0, 0.0);
UPDATE sequences SET default_video_layer_track_id = '_v13_placeholder_track' WHERE id = '_v13_placeholder_master';
INSERT INTO media_refs (id, project_id, owner_sequence_id, track_id, media_id, source_in_frame, source_out_frame, sequence_start_frame, duration_frames, enabled, volume, playhead_frame, created_at, modified_at)
VALUES ('_v13_placeholder_mr', 'default_project', '_v13_placeholder_master', '_v13_placeholder_track', '_v13_placeholder_media', 0, 150, 0, 150, 1, 1.0, 0, 0, 0);

INSERT INTO clips (id, project_id, track_id, sequence_id, owner_sequence_id, name, sequence_start_frame, duration_frames, source_in_frame, source_out_frame, enabled, created_at, modified_at, master_layer_track_id, master_audio_track_id, fps_mismatch_policy, volume, playhead_frame) VALUES
    ('clip_a', 'default_project', 'track_v1', '_v13_placeholder_master', 'default_sequence', 'Clip A', 0, 100, 0, 100, 1, %d, %d, NULL, NULL, 'resample', 1.0, 0),
    ('clip_b', 'default_project', 'track_v1', '_v13_placeholder_master', 'default_sequence', 'Clip B', 100, 150, 0, 150, 1, %d, %d, NULL, NULL, 'resample', 1.0, 0);
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
