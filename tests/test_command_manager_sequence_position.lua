#!/usr/bin/env luajit

require('test_env')

local database = require('core.database')
local command_manager = require('core.command_manager')

local TEST_DB = "/tmp/test_command_manager_sequence_position.db"
os.remove(TEST_DB)

database.init(TEST_DB)
local db = database.get_connection()

assert(db:exec([[
    CREATE TABLE projects (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        settings TEXT NOT NULL DEFAULT '{}'
    );

    CREATE TABLE sequences (
        id TEXT PRIMARY KEY,
        project_id TEXT NOT NULL,
        name TEXT NOT NULL,
        kind TEXT NOT NULL DEFAULT 'timeline',
        frame_rate REAL NOT NULL,
        width INTEGER NOT NULL,
        height INTEGER NOT NULL,
        current_sequence_number INTEGER
    );

    CREATE TABLE commands (
        id TEXT PRIMARY KEY,
        parent_id TEXT,
        parent_sequence_number INTEGER,
        sequence_number INTEGER UNIQUE NOT NULL,
        command_type TEXT NOT NULL,
        command_args TEXT,
        pre_hash TEXT,
        post_hash TEXT,
        timestamp INTEGER,
        playhead_time INTEGER DEFAULT 0,
        selected_clip_ids TEXT DEFAULT '[]',
        selected_edge_infos TEXT DEFAULT '[]',
        selected_clip_ids_pre TEXT DEFAULT '[]',
        selected_edge_infos_pre TEXT DEFAULT '[]',
        selected_gap_infos TEXT DEFAULT '[]',
        selected_gap_infos_pre TEXT DEFAULT '[]'
    );

    INSERT INTO projects (id, name) VALUES ('default_project', 'Default Project');
    INSERT INTO sequences (id, project_id, name, frame_rate, width, height, current_sequence_number)
    VALUES ('default_sequence', 'default_project', 'Seq A', 30.0, 1920, 1080, 0);
    INSERT INTO sequences (id, project_id, name, frame_rate, width, height, current_sequence_number)
    VALUES ('sequence_b', 'default_project', 'Seq B', 30.0, 1920, 1080, 1);

    INSERT INTO commands (id, sequence_number, command_type, command_args, pre_hash, post_hash, timestamp)
    VALUES ('cmd_1', 1, 'TestCommand', '{}', '', '', strftime('%s','now'));
]]))

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
    get_playhead_time = function() return 0 end,
    set_playhead_time = function() end,
    push_viewport_guard = function() return 1 end,
    pop_viewport_guard = function() return 0 end,
    capture_viewport = function() return {start_time = 0, duration = 1000} end,
    restore_viewport = function() end,
    get_viewport_start_time = function() return 0 end,
    get_viewport_duration = function() return 1000 end,
    set_viewport_start_time = function() end,
    set_viewport_duration = function() end,
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
assert(command_manager.can_undo(), "Sequence B should restore saved undo position")

command_manager.activate_timeline_stack("default_sequence")
assert(not command_manager.can_undo(), "Switching back should restore default sequence position")

print("✅ command_manager restores per-sequence undo positions")
