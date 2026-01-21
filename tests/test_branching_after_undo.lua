#!/usr/bin/env luajit

require('test_env')

local database = require('core.database')
local command_manager = require('core.command_manager')
local timeline_state = require('ui.timeline.timeline_state')
local Command = require('command')

local function stub_timeline_state()
    timeline_state.capture_viewport = function()
        return {start_value = 0, duration_value = 300, timebase_type = "video_frames", timebase_rate = 30.0}
    end
    timeline_state.push_viewport_guard = function() end
    timeline_state.pop_viewport_guard = function() end
    timeline_state.restore_viewport = function(_) end
    timeline_state.set_selection = function(_) end
    timeline_state.set_edge_selection = function(_) end
    timeline_state.set_gap_selection = function(_) end
    timeline_state.get_selected_clips = function() return {} end
    timeline_state.get_selected_edges = function() return {} end
    timeline_state.set_playhead_position = function(_) end
    timeline_state.get_playhead_position = function() return 0 end
    timeline_state.get_project_id = function() return 'default_project' end
    timeline_state.get_sequence_id = function() return 'default_sequence' end
    timeline_state.reload_clips = function() end
end

local function init_db(path)
    os.remove(path)
    assert(database.init(path))
    local db = database.get_connection()
    assert(db)

    db:exec(require('import_schema'))

    local now = os.time()
    local ok, err = db:exec(string.format([[INSERT INTO projects (id, name, created_at, modified_at) VALUES ('default_project', 'Default Project', %d, %d);]], now, now))
    assert(ok, err)
    ok, err = db:exec(string.format([[INSERT INTO sequences (id, project_id, name, kind, fps_numerator, fps_denominator, audio_rate, width, height,
                                               playhead_frame, view_start_frame, view_duration_frames, created_at, modified_at)
                        VALUES ('default_sequence', 'default_project', 'Default Sequence', 'timeline', 30, 1, 48000, 1920, 1080, 0, 0, 300, %d, %d);]], now, now))
    assert(ok, err)
    ok, err = db:exec([[INSERT INTO tracks (id, sequence_id, name, track_type, track_index, enabled)
                        VALUES ('track_v1', 'default_sequence', 'V1', 'VIDEO', 1, 1);]])
    assert(ok, err)

    return db
end

local executed_labels = {}

local function register_test_command()
    local test_spec = {
        args = {
            project_id = { required = true },
            label = {},
        }
    }
    command_manager.register_executor("TestOp", function(command)
        local label = command:get_parameter("label") or "?"
        table.insert(executed_labels, label)
        return true
    end, function(command)
        -- Undo logic (noop for test state logic, as executed_labels is reset manually in test)
        return true
    end, test_spec)
end

local function reset_log()
    for i = #executed_labels, 1, -1 do
        executed_labels[i] = nil
    end
end

stub_timeline_state()
local db_path = "/tmp/jve/test_branching_after_undo.db"
init_db(db_path)

command_manager.init('default_sequence', 'default_project')
register_test_command()

-- Execute initial command (acts like the XML import)
reset_log()
local import_cmd = Command.create("TestOp", "default_project")
import_cmd:set_parameter("label", "import")
assert(command_manager.execute(import_cmd).success)
assert(#executed_labels == 1 and executed_labels[1] == "import", "Initial command should run")

-- Undo to root
assert(command_manager.undo().success, "Undo to root should succeed")
reset_log()

-- Execute new command after undo (acts like importing a clip)
reset_log()
local clip_cmd = Command.create("TestOp", "default_project")
clip_cmd:set_parameter("label", "clip")
assert(command_manager.execute(clip_cmd).success)
assert(#executed_labels == 1 and executed_labels[1] == "clip", "New command should run")

assert(command_manager.undo().success, "Undo new command should succeed")
reset_log()

-- Redo should replay only the new command (clip) and NOT the original import
reset_log()
local redo_result = command_manager.redo()
assert(redo_result.success, "Redo should succeed")
assert(#executed_labels == 1 and executed_labels[1] == "clip", "Redo should replay the new branch only")

-- No further redo should be available
local redo_again = command_manager.redo()
assert(not redo_again.success, "Redo should be exhausted after replaying new branch")

print("✅ Branching after undo test passed")
