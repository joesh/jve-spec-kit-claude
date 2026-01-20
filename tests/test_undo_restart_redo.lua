#!/usr/bin/env luajit

-- Regression: undoing to the beginning, restarting, and redoing should restore the command.
-- Currently fails because redo after restart reports "Nothing to redo".

package.path = package.path
    .. ";../src/lua/?.lua"
    .. ";../src/lua/core/?.lua"
    .. ";../src/lua/models/?.lua"
    .. ";../tests/?.lua"

require('test_env')

local database = require('core.database')
local Command = require('command')

local function install_timeline_stub()
    local timeline_state = {
        playhead_value = 0,
        playhead_position = 0,
        selected_clips = {},
        selected_edges = {},
        selected_gaps = {},
        viewport_start_value = 0,
        viewport_duration_frames_value = 300
    }
    local guard_depth = 0

    function timeline_state.get_sequence_id()
        return 'default_sequence'
    end

    function timeline_state.get_playhead_position()
        return timeline_state.playhead_position or 0
    end

    function timeline_state.set_playhead_position(ms)
        timeline_state.playhead_position = ms
    end

    function timeline_state.get_sequence_frame_rate()
        return 30.0
    end

    function timeline_state.get_sequence_audio_sample_rate()
        return 48000
    end

    function timeline_state.get_selected_clips()
        return timeline_state.selected_clips
    end

    function timeline_state.get_selected_edges()
        return timeline_state.selected_edges
    end

    function timeline_state.set_selection(clips)
        timeline_state.selected_clips = clips or {}
    end

    function timeline_state.set_edge_selection(edges)
        timeline_state.selected_edges = edges or {}
    end

    function timeline_state.set_gap_selection(gaps)
        timeline_state.selected_gaps = gaps or {}
    end

    function timeline_state.normalize_edge_selection() end
    function timeline_state.reload_clips() end
    function timeline_state.persist_state_to_db() end

    function timeline_state.set_viewport_start_time(ms)
        timeline_state.viewport_start_time = ms
    end

    function timeline_state.set_viewport_duration_frames_value(ms)
        timeline_state.viewport_duration_frames_value = ms
    end

    function timeline_state.capture_viewport()
        return {
            start_time = timeline_state.viewport_start_time,
            duration_value = timeline_state.viewport_duration_frames_value,
        }
    end

    function timeline_state.restore_viewport(snapshot)
        if not snapshot then
            return
        end
        if snapshot.start_time then
            timeline_state.viewport_start_time = snapshot.start_time
        end
        if snapshot.duration_value then
            timeline_state.viewport_duration_frames_value = snapshot.duration_value
        end
    end

    function timeline_state.push_viewport_guard()
        guard_depth = guard_depth + 1
        return guard_depth
    end

    function timeline_state.pop_viewport_guard()
        if guard_depth > 0 then
            guard_depth = guard_depth - 1
        end
        return guard_depth
    end

    package.loaded['ui.timeline.timeline_state'] = timeline_state
end

local function init_database(path)
    os.remove(path)
    assert(database.init(path))
    local db = database.get_connection()

    db:exec(require('import_schema'))

    db:exec([[
        INSERT INTO projects (id, name, created_at, modified_at)
        VALUES ('default_project', 'Default Project', strftime('%s','now'), strftime('%s','now'));
        INSERT INTO sequences (
            id, project_id, name, kind,
            fps_numerator, fps_denominator, audio_rate,
            width, height,
            view_start_frame, view_duration_frames, playhead_frame,
            selected_clip_ids, selected_edge_infos, selected_gap_infos,
            current_sequence_number, created_at, modified_at
        )
        VALUES (
            'default_sequence', 'default_project', 'Default Sequence', 'timeline',
            30, 1, 48000,
            1920, 1080,
            0, 300, 0,
            '[]', '[]', '[]',
            0, strftime('%s','now'), strftime('%s','now')
        );
    ]])

    return db
end

local function create_sequence_command(name)
    local cmd = Command.create("CreateSequence", "default_project")
    cmd:set_parameter("name", name or "Redo Regression Sequence")
    cmd:set_parameter("project_id", "default_project")
    cmd:set_parameter("frame_rate", 30.0)
    cmd:set_parameter("width", 1920)
    cmd:set_parameter("height", 1080)
    return cmd
end

print("=== Undo/Restart Redo Regression ===\n")

local DB_PATH = "/tmp/jve/test_undo_restart_redo.db"

install_timeline_stub()
local db = init_database(DB_PATH)

local command_manager = require('core.command_manager')
command_manager.init(db, 'default_sequence', 'default_project')

print("Step 1: Execute initial command")
local exec_result = command_manager.execute(create_sequence_command())
assert(exec_result.success, exec_result.error_message or "CreateSequence failed")

print("Step 2: Undo to beginning of stack")
local undo_result = command_manager.undo()
assert(undo_result.success, undo_result.error_message or "Undo failed")
assert(command_manager.get_last_command('default_project') == nil, "Expected no command at undo stack head after undo")

print("Step 3: Simulate application restart")
-- Close and reopen database (database.init handles closing existing connection)
assert(database.init(DB_PATH))

-- Drop cached command_manager module so init() simulates a fresh run
package.loaded['core.command_manager'] = nil
command_manager = require('core.command_manager')
command_manager.init(database.get_connection(), 'default_sequence', 'default_project')

-- Re-establish command event after module reload
command_manager.begin_command_event("script")

print("Step 4: Attempt redo after restart (should succeed)")
local redo_result = command_manager.redo()
assert(redo_result.success, redo_result.error_message or "Redo failed after restart")

-- Verify the sequence was recreated
local check_stmt = database.get_connection():prepare([[
    SELECT COUNT(*) FROM sequences WHERE name = 'Redo Regression Sequence'
]])
assert(check_stmt:exec() and check_stmt:next(), "Failed to query sequences after redo")
local recreated = check_stmt:value(0)
check_stmt:finalize()
assert(recreated == 1, string.format("Expected recreated sequence count 1, got %d", recreated))

print("✅ Redo works after restart when previously undone to beginning")

print("Step 5: Execute additional command to extend history")
local second_cmd = create_sequence_command("Redo Regression Sequence B")
local exec_second = command_manager.execute(second_cmd)
assert(exec_second.success, exec_second.error_message or "Second CreateSequence failed")

print("Step 6: Undo stack back to beginning")
local undo_second = command_manager.undo()
assert(undo_second.success, undo_second.error_message or "First undo of extended history failed")
local undo_first = command_manager.undo()
assert(undo_first.success, undo_first.error_message or "Second undo of extended history failed")
assert(command_manager.get_last_command('default_project') == nil,
    "Expected undo stack to be at beginning after two undos")

print("Step 7: Restart application again")
assert(database.init(DB_PATH))
package.loaded['core.command_manager'] = nil
command_manager = require('core.command_manager')
command_manager.init(database.get_connection(), 'default_sequence', 'default_project')

-- Re-establish command event after second module reload
command_manager.begin_command_event("script")

print("Step 8: Redo full history after restart")
local redo_first = command_manager.redo()
assert(redo_first.success, redo_first.error_message or "First redo after second restart failed")
local redo_second = command_manager.redo()
assert(redo_second.success, redo_second.error_message or "Second redo after second restart failed")

local seq_stmt = database.get_connection():prepare([[
    SELECT COUNT(*) FROM sequences
    WHERE name IN ('Redo Regression Sequence', 'Redo Regression Sequence B')
]])
assert(seq_stmt:exec() and seq_stmt:next(), "Failed to query sequences after multi-redo")
local total_recreated = seq_stmt:value(0)
seq_stmt:finalize()
assert(total_recreated == 2,
    string.format("Expected both sequences to exist after redo, found %d", total_recreated))

print("✅ Redo across restart restores entire command history")
