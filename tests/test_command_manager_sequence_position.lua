#!/usr/bin/env luajit

require('test_env')

local database = require('core.database')
local command_manager = require('core.command_manager')

local TEST_DB = "/tmp/jve/test_command_manager_sequence_position.db"
os.remove(TEST_DB)

database.init(TEST_DB)
local db = database.get_connection()

assert(db:exec(require('import_schema')))

local timeline_state = {
    get_selected_clips = function() return {} end,
    get_selected_edges = function() return {} end,
    clear_edge_selection = function() end,
    clear_gap_selection = function() end,
    set_selection = function() end,
    reload_clips = function() end,
    persist_state_to_db = function() end,
    get_sequence_id = function() return 'default_sequence' end,
    get_project_id = function() return 'default_project' end,
    get_playhead_value = function() return 0 end,
    set_playhead_value = function() end,
    push_viewport_guard = function() return 1 end,
    pop_viewport_guard = function() return 0 end,
    capture_viewport = function() return {start_value = 0, duration = 1000} end,
    restore_viewport = function() end,
    get_viewport_start_value = function() return 0 end,
    get_viewport_duration_frames_value = function() return 1000 end,
    set_viewport_start_value = function() end,
    set_viewport_duration_frames_value = function() end,
    set_dragging_playhead = function() end,
    is_dragging_playhead = function() return false end,
    get_selected_gaps = function() return {} end,
    get_all_tracks = function()
        return {
            {id = "track_v1", track_type = "VIDEO"}
        }
    end,
    get_track_height = function() return 50 end,
    time_to_pixel = function(value) return value end,
    pixel_to_time = function(value) return value end,
    get_sequence_frame_rate = function() return 30 end,
}

package.loaded['ui.timeline.timeline_state'] = timeline_state

command_manager.init(db, "default_sequence", "default_project")

assert(not command_manager.can_undo(), "Default sequence should start at fully-undone position")

command_manager.activate_timeline_stack("sequence_b")
assert(not command_manager.can_undo(), "Sequence B should start with no undo history")

command_manager.activate_timeline_stack("default_sequence")
assert(not command_manager.can_undo(), "Switching back should restore default sequence position")

print("✅ command_manager restores per-sequence undo positions")
